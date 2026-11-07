import Foundation
import HermitCore
import MLX
import MLXLLM
import MLXLMCommon

/// How one reply went, for tuning and the benchmark tool.
public struct GenerationStats: Sendable, CustomStringConvertible {
    /// Seconds spent loading the model before this reply (nil when it was already warm).
    public let loadTime: TimeInterval?
    /// Seconds from asking to the first visible text, model load excluded.
    public let timeToFirstToken: TimeInterval
    public let promptTokens: Int
    public let tokens: Int
    public let tokensPerSecond: Double

    public var description: String {
        let load = loadTime.map { String(format: "load %.2fs, ", $0) } ?? ""
        return load + String(format: "first token %.2fs, %d prompt tokens, %d tokens at %.1f tok/s",
                             timeToFirstToken, promptTokens, tokens, tokensPerSecond)
    }
}

/// Hermit running on the on-device model. Loads the model once and keeps it warm, keeps the conversation
/// (with its KV cache) until New chat, and streams text as it is generated. Cancelling the reply stops generation.
public final class LocalAgent: Agent, @unchecked Sendable {
    public static let systemPrompt = """
    You are Hermit, a private AI assistant that runs entirely on this device. Nothing the user types leaves the \
    device: there is no cloud and no server. You help with questions, writing, explaining, planning and files the user attaches.
    In chat you can't see the user's wallets or balances, move money, trade, browse the web or read email. If asked, \
    say so plainly and point them to the Wallets page in the app for their own wallets. Never pretend you did something you can't do.
    Keep answers short and plain: a few sentences, simple words, no filler. Do not use middle dots as separators. \
    If you don't know something, say so.
    """

    /// The system prompt with the user's name and their hermit.md notes.
    public static func instructions(name: String, memory: [String]) -> String {
        var s = systemPrompt
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { s += "\nThe user wants to be called \(name)." }
        // Keep the notes to a sane size so they don't crowd out the conversation.
        var notes: [String] = [], used = 0
        for line in memory where used + line.count < 2000 { notes.append("- " + line); used += line.count }
        if !notes.isEmpty { s += "\nThe user's standing notes (hermit.md). Follow them:\n" + notes.joined(separator: "\n") }
        return s
    }

    private let store: ModelStore
    private let engine = LocalEngine()
    private let onStats: (@Sendable (GenerationStats) -> Void)?

    @MainActor
    public init(store: ModelStore? = nil, onStats: (@Sendable (GenerationStats) -> Void)? = nil) {
        let store = store ?? .shared
        self.store = store
        self.onStats = onStats
        let engine = self.engine
        store.onDelete { id in Task { await engine.unload(ifID: id) } }
    }

    /// Load the model ahead of the first question so the first answer starts quickly.
    public func warmUp() {
        Task { [store, engine] in
            guard let ready = await MainActor.run(body: { store.readyModel }) else { return }
            _ = try? await engine.load(id: ready.spec.id, directory: ready.directory)
        }
    }

    public func reset() {
        Task { [engine] in await engine.reset() }
    }

    /// Name and hermit.md for the system prompt. The model reads its instructions when a conversation starts,
    /// so this applies from the next new chat (or right away if this one hasn't started).
    public func setContext(name: String, memory: [String]) {
        let text = Self.instructions(name: name, memory: memory)
        Task { [engine] in await engine.setInstructions(text) }
    }

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        AsyncStream { cont in
            let task = Task { [store, engine, onStats] in
                defer { cont.finish() }
                guard let ready = await MainActor.run(body: { store.readyModel }) else {
                    cont.yield(.text("The on-device model isn't downloaded yet."))
                    return
                }
                do {
                    var loadTime: TimeInterval?
                    if await !engine.isLoaded(ready.spec.id) {
                        cont.yield(.status("Waking up \(ready.spec.name)…"))
                        loadTime = try await engine.load(id: ready.spec.id, directory: ready.directory)
                    }
                    cont.yield(.status("Thinking…"))
                    let start = Date()
                    var firstToken: TimeInterval?
                    var filter = OutputFilter()
                    generation: for try await item in try await engine.stream(prompt) {
                        switch item {
                        case .chunk(let raw):
                            let text = filter.push(raw)
                            if !text.isEmpty {
                                if firstToken == nil { firstToken = Date().timeIntervalSince(start); cont.yield(.steps(0)) }
                                cont.yield(.text(text))
                            }
                            // The model began a new turn or started repeating itself: end the reply here.
                            if filter.finished { break generation }
                        case .info(let info):
                            onStats?(GenerationStats(loadTime: loadTime, timeToFirstToken: firstToken ?? 0,
                                                     promptTokens: info.promptTokenCount, tokens: info.generationTokenCount,
                                                     tokensPerSecond: info.tokensPerSecond))
                        default: break
                        }
                    }
                    let rest = filter.flush()
                    if !rest.isEmpty { cont.yield(.text(rest)) }
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { cont.yield(.text("\n\nThe model stopped: \(error.localizedDescription)")) }
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Owns the loaded model and the chat session. One at a time, so it is an actor.
actor LocalEngine {
    private var container: ModelContainer?
    private var session: ChatSession?
    private var loadedID: String?
    private var instructions = LocalAgent.systemPrompt
    /// The session has answered something since the last reset. Its instructions are fixed until the next reset.
    private var started = false

    func setInstructions(_ text: String) {
        instructions = text
        if !started { session?.instructions = text }
    }

    func isLoaded(_ id: String) -> Bool { loadedID == id && session != nil }

    /// Loads the model (once). Returns how long it took, or nil if it was already loaded.
    func load(id: String, directory: URL) async throws -> TimeInterval? {
        if isLoaded(id) { return nil }
        unload()
        // Freed GPU buffers are cached for reuse; keep that cache small on 8 GB devices.
        Memory.cacheLimit = (ModelCatalog.deviceMemoryGB <= 8 ? 64 : 512) << 20
        let start = Date()
        let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        self.container = container
        session = ChatSession(container, instructions: instructions,
                              generateParameters: Self.parameters(directory),
                              additionalContext: ["enable_thinking": false])
        loadedID = id
        return Date().timeIntervalSince(start)
    }

    func unload(ifID id: String? = nil) {
        guard id == nil || id == loadedID else { return }
        session = nil; container = nil; loadedID = nil; started = false
        Memory.clearCache()
    }

    func reset() async {
        await session?.clear()
        session?.instructions = instructions
        started = false
    }

    func stream(_ prompt: String) throws -> AsyncThrowingStream<Generation, Error> {
        guard let session else { throw CancellationError() }
        started = true
        return session.streamDetails(to: prompt)
    }

    /// Sampling for a small chat model on a phone. The model's generation_config.json asks for temperature 1.0 and no
    /// repetition penalty, which lets a 2B model wander and loop, so Hermit caps the temperature at 0.6, uses top-p 0.9,
    /// and always applies a mild repetition penalty over the last 256 tokens (long enough to cover a repeating paragraph).
    static func parameters(_ directory: URL) -> GenerateParameters {
        let json = (try? Data(contentsOf: directory.appending(path: "generation_config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func num(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        var p = GenerateParameters(maxTokens: 640, temperature: Float(min(num("temperature") ?? 0.6, 0.6)),
                                   topP: Float(min(num("top_p") ?? 0.9, 0.9)), topK: Int(num("top_k") ?? 0))
        p.repetitionPenalty = Float(max(num("repetition_penalty") ?? 1.15, 1.15))
        p.repetitionContextSize = 256
        if json["do_sample"] as? Bool == false { p.temperature = 0 }
        return p
    }
}

/// Cleans the raw stream: drops a <think>…</think> block if the model writes one, trims leading blank
/// lines, and turns middle-dot separators into commas.
struct OutputFilter {
    private var buffer = ""
    private var started = false
    private var inThink = false
    /// True once the reply should end: the model wrote a turn marker, or repeated a whole sentence.
    private(set) var finished = false
    static let stopMarkers = ["<|im_start|>", "<|im_end|>", "</s>"]

    mutating func push(_ chunk: String) -> String {
        guard !finished else { return "" }
        buffer += chunk
        if let cut = Self.stopMarkers.compactMap({ buffer.range(of: $0)?.lowerBound }).min() {
            buffer = String(buffer[..<cut]); finished = true
        }
        var out = ""
        while !buffer.isEmpty {
            if inThink {
                guard let end = buffer.range(of: "</think>") else { return out }
                buffer = String(buffer[end.upperBound...]); inThink = false; continue
            }
            if let open = buffer.range(of: "<think>") {
                out += buffer[..<open.lowerBound]; buffer = String(buffer[open.upperBound...]); inThink = true; continue
            }
            // Hold back a possible partial "<think" at the end.
            if let lt = buffer.lastIndex(of: "<"), "<think>".hasPrefix(buffer[lt...]) {
                out += buffer[..<lt]; buffer = String(buffer[lt...]); break
            }
            out += buffer; buffer = ""
        }
        if !started {
            out = String(out.drop { $0.isWhitespace })
            if !out.isEmpty { started = true }
        }
        out = out.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "·", with: ",")
        return guardRepeats(out)
    }

    // MARK: Repetition guard
    // Text is released a sentence (or line) at a time. A sentence or line that already appeared ends the reply before
    // it is shown. A long unfinished sentence is released early unless it is the start of one we've already shown.

    private var pending = ""
    private var seen = Set<String>()
    private var releasedTail = 0   // characters of `pending` already shown while its sentence was still open
    private var repeated = false

    private mutating func guardRepeats(_ text: String) -> String {
        pending += text
        var out = ""
        while let end = pending.firstIndex(where: { ".!?\n".contains($0) }) {
            let cut = pending.index(after: end)
            let piece = String(pending[..<cut])
            let key = Self.key(piece)
            if key.count >= 18 {
                if seen.contains(key) { finished = true; repeated = true; pending = ""; return out }
                seen.insert(key)
            }
            out += piece.dropFirst(releasedTail)
            releasedTail = 0
            pending = String(pending[cut...])
        }
        // Open sentence: show it once it's clearly new, so long sentences still stream.
        let tailKey = Self.key(pending)
        if pending.count - releasedTail > 0, tailKey.count >= 40, !seen.contains(where: { $0.hasPrefix(tailKey) }) {
            out += pending.dropFirst(releasedTail)
            releasedTail = pending.count
        }
        return out
    }

    private static func key(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "*" || $0 == "#" }).joined(separator: " ")
    }

    /// Whatever is still held back when the reply ends normally.
    mutating func flush() -> String {
        guard !repeated else { return "" }
        let rest = String(pending.dropFirst(releasedTail))
        pending = ""; releasedTail = 0
        return rest
    }
}
