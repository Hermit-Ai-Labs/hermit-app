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
    You are Hermit, a private AI agent that runs entirely on this device. Nothing the user types leaves the \
    device: there is no cloud and no server. You help with payments, crypto, trading, research and everyday questions.
    You never move money yourself. When a payment, swap, trade or transfer is needed, you propose it and the user \
    approves it with Touch ID or Face ID.
    Keep answers short and plain: a few sentences, simple words, no filler. Do not use middle dots as separators. \
    If you don't know something, say so. You can't browse the web.
    """

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
                    for try await item in try await engine.stream(prompt) {
                        switch item {
                        case .chunk(let raw):
                            let text = filter.push(raw)
                            guard !text.isEmpty else { continue }
                            if firstToken == nil { firstToken = Date().timeIntervalSince(start); cont.yield(.steps(0)) }
                            cont.yield(.text(text))
                        case .info(let info):
                            onStats?(GenerationStats(loadTime: loadTime, timeToFirstToken: firstToken ?? 0,
                                                     promptTokens: info.promptTokenCount, tokens: info.generationTokenCount,
                                                     tokensPerSecond: info.tokensPerSecond))
                        default: break
                        }
                    }
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
        session = ChatSession(container, instructions: LocalAgent.systemPrompt,
                              generateParameters: Self.parameters(directory),
                              additionalContext: ["enable_thinking": false])
        loadedID = id
        return Date().timeIntervalSince(start)
    }

    func unload(ifID id: String? = nil) {
        guard id == nil || id == loadedID else { return }
        session = nil; container = nil; loadedID = nil
        Memory.clearCache()
    }

    func reset() async { await session?.clear() }

    func stream(_ prompt: String) throws -> AsyncThrowingStream<Generation, Error> {
        guard let session else { throw CancellationError() }
        return session.streamDetails(to: prompt)
    }

    /// Sampling from the model's generation_config.json (temperature, top_p, top_k), with sane defaults.
    static func parameters(_ directory: URL) -> GenerateParameters {
        let json = (try? Data(contentsOf: directory.appending(path: "generation_config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func num(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        var p = GenerateParameters(maxTokens: 1024, temperature: Float(num("temperature") ?? 0.7),
                                   topP: Float(num("top_p") ?? 0.95), topK: Int(num("top_k") ?? 0))
        if let r = num("repetition_penalty"), r != 1 { p.repetitionPenalty = Float(r) }
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

    mutating func push(_ chunk: String) -> String {
        buffer += chunk
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
        return out.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "·", with: ",")
    }
}
