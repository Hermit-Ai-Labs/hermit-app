import Foundation
import HermitCore
import MLX
import MLXLLM
import MLXLMCommon
import os
#if os(iOS)
import UIKit
#endif

private let modelLog = os.Logger(subsystem: "my.hermit", category: "local-model")

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

/// Hermit running on the on-device model, with the same tools as Private Cloud. Loads the model once and keeps it
/// warm, keeps the conversation (and its KV cache) until New chat, and streams text as it is generated.
/// The model can call Hermit's tools (prices, balances, maths, NEAR Intents quotes, and preparing trades, swaps and
/// sends); the loop lives in `ToolChat`, the tools in the app's toolbox. Cancelling the reply stops generation.
public final class LocalAgent: Agent, @unchecked Sendable {
    /// The prompt the model gets: Hermit 1.2's trained agent prompt (hermit_fmt.SYSTEM_AGENT).
    public static let systemPrompt = HermitPrompt.agentSystem

    /// The system prompt with the user's name and their hermit.md notes.
    public static func instructions(name: String, memory: [String]) -> String {
        HermitPrompt.system(name: name, memory: memory)
    }

    private let store: ModelStore
    private let engine = LocalEngine()
    private let chat = ToolChat(config: .init(family: .instruct))
    private let onStats: (@Sendable (GenerationStats) -> Void)?
    /// Runs the model's tool calls. nil answers in plain text only (the tool block is still in the prompt so the
    /// model's format stays the trained one; calls then get an error result).
    public var toolbox: AgentToolbox?
    /// Notification observers (iPhone), kept for as long as the agent lives.
    private var observers: [NSObjectProtocol] = []

    @MainActor
    public init(store: ModelStore? = nil, toolbox: AgentToolbox? = nil, onStats: (@Sendable (GenerationStats) -> Void)? = nil) {
        let store = store ?? .shared
        self.store = store
        self.toolbox = toolbox
        self.onStats = onStats
        let engine = self.engine
        store.onDelete { id in Task { await engine.unload(ifID: id) } }
        #if os(iOS)
        // iOS doesn't let an app that has left the screen use the GPU, and it ends apps that hold on to memory when the
        // system runs short. Stop the reply when Hermit leaves the screen; on a memory warning also free the model
        // (it wakes again on the next question).
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                Task { await engine.interrupt(.background) }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                Task { await engine.interrupt(.memory) }
            },
        ]
        #endif
    }

    /// Load the model ahead of the first question, and read the system prompt into the cache, so the first answer
    /// starts quickly.
    public func warmUp() {
        Task { [store, engine, chat] in
            guard let ready = await MainActor.run(body: { store.readyModel }) else { return }
            guard (try? await engine.load(id: ready.spec.id, directory: ready.directory)) != nil else { return }
            await chat.setFamily(await engine.family)
            await engine.prefill(await chat.systemPrefix())
        }
    }

    public func reset() {
        Task { [chat] in await chat.reset() }
    }

    /// Name and hermit.md for the system prompt. The model reads its instructions when a conversation starts,
    /// so this applies from the next new chat (or right away if this one hasn't started).
    public func setContext(name: String, memory: [String]) {
        let text = Self.instructions(name: name, memory: memory)
        Task { [chat, engine] in
            await chat.setSystem(text)
            // Before the chat starts, read the new system prompt into the cache too, so the first answer is quick.
            if await chat.history.isEmpty, await engine.isLoaded { await engine.prefill(await chat.systemPrefix()) }
        }
    }

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        AsyncStream { cont in
            let task = Task { [store, engine, chat, toolbox, onStats] in
                defer { cont.finish() }
                guard let ready = await MainActor.run(body: { store.readyModel }) else {
                    cont.yield(.text("The on-device model isn't downloaded yet."))
                    return
                }
                await engine.beginReply()
                var failure: Error?
                do {
                    var loadTime: TimeInterval?
                    if await !engine.isLoaded(ready.spec.id) {
                        cont.yield(.status("Waking up \(ready.spec.name)…"))
                        loadTime = try await engine.load(id: ready.spec.id, directory: ready.directory)
                    }
                    await chat.setFamily(await engine.family)
                    // A hot device slows the model down: say so instead of leaving the wait unexplained.
                    let heat = ProcessInfo.processInfo.thermalState
                    cont.yield(.status(heat == .serious || heat == .critical ? "Thinking, slower while this device is hot…" : "Thinking…"))
                    let generator = EngineGenerator(engine: engine, onStats: onStats, loadTime: loadTime)
                    await chat.reply(to: prompt, generator: generator, toolbox: toolbox, cont: cont)
                } catch {
                    failure = error
                }
                let end = await engine.endReply()
                if Task.isCancelled { return }
                if let why = end.interruption {
                    cont.yield(.block(.text(why.note)))
                } else if let failure, !(failure is CancellationError) {
                    // Raw engine and file-system wording means nothing to the user: log it, show a next step.
                    modelLog.error("on-device model failed to start: \(String(describing: failure), privacy: .public)")
                    cont.yield(.steps(0))
                    cont.yield(.text("The model couldn't start. Close some apps and ask again. If it keeps failing, download it again in Settings, Models."))
                } else if failure == nil, end.cut {
                    // The last turn ran into the token limit: say so instead of ending mid-sentence as if it were done.
                    cont.yield(.block(.text("That reply hit the length limit.")))
                    cont.yield(.block(.actions([HermitCore.Action("Continue", ask: "Continue")])))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

extension ToolChat {
    /// The system turn alone (with the tool block), the part of every prompt that never changes within a chat.
    func systemPrefix() -> String {
        HermitPrompt.render([messages[0]], tools: config.tools, family: config.family, addGenerationPrompt: false)
    }
}

/// One assistant turn from the engine, timed for the stats line.
struct EngineGenerator: TurnGenerator {
    let engine: LocalEngine
    let onStats: (@Sendable (GenerationStats) -> Void)?
    let loadTime: TimeInterval?

    func generate(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let start = Date()
            let firstToken = LockedBox<TimeInterval?>(nil)
            let task = Task { [engine, onStats, loadTime] in
                do {
                    try await engine.generate(prompt, onText: { text in
                        if firstToken.value == nil { firstToken.value = Date().timeIntervalSince(start) }
                        cont.yield(text)
                    }, onInfo: { info in
                        onStats?(GenerationStats(loadTime: loadTime, timeToFirstToken: firstToken.value ?? 0,
                                                 promptTokens: info.promptTokenCount, tokens: info.generationTokenCount,
                                                 tokensPerSecond: info.tokensPerSecond))
                    })
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

/// The KV cache and the exact tokens it holds. The prompt text only grows within a chat (system, then each turn), so
/// each turn feeds only the tokens past the longest cached prefix; anything that differs is trimmed off first.
final class PromptCache: @unchecked Sendable {
    var cache: [KVCache]?
    var tokens: [Int] = []
    /// The last turn stopped at the token limit, not at an end-of-turn token.
    var cut = false
    func clear() { cache = nil; tokens = [] }
}

/// Why a reply was stopped from outside the chat, so the chat can say so.
enum Interruption: Sendable, Equatable {
    case background, memory
    var note: String {
        switch self {
        case .background: "Stopped because Hermit left the screen. Ask again."
        case .memory: "Stopped because this device ran low on memory. The model was unloaded. Ask again to wake it."
        }
    }
}

/// Owns the loaded model and the KV cache. One generation at a time, so it is an actor.
actor LocalEngine {
    private var container: ModelContainer?
    private var loadedID: String?
    private var parameters = GenerateParameters()
    private let prompt = PromptCache()
    private(set) var family: HermitPrompt.Family = .instruct
    /// The generation running now; the next one waits for it, so the cache is never touched by two at once.
    private var current: Task<Void, Never>?
    /// The same generation as its own task: cancelling it stops the model (cancelling `current` only stops waiting).
    private var currentRun: Task<Result<Void, Error>, Never>?
    /// Replies under way (each spans all its turns and tool calls), why one was stopped from outside, and whether its
    /// last turn ran out of tokens.
    private var replies = 0
    private var interruption: Interruption?
    private var lastCut = false

    /// A new reply starts clean: a stop from an earlier one no longer applies (the user is back and asking).
    func beginReply() { replies += 1; interruption = nil; lastCut = false }

    /// Ends a reply: whether it was stopped from outside, and whether its last turn hit the token limit.
    func endReply() -> (interruption: Interruption?, cut: Bool) {
        replies = max(replies - 1, 0)
        let out = (interruption: interruption, cut: lastCut)
        interruption = nil; lastCut = false
        return out
    }

    /// Hermit left the screen, or the device is short of memory: stop generating now. Nothing new starts until the next
    /// reply; on a memory warning the model is freed too.
    func interrupt(_ why: Interruption) async {
        if replies > 0 { interruption = why }
        currentRun?.cancel()
        if why == .memory { await unload() } else { await current?.value; Memory.clearCache() }
    }

    func isLoaded(_ id: String) -> Bool { loadedID == id && container != nil }
    var isLoaded: Bool { container != nil }

    /// Hermit never shows reasoning. Templates that switch it off with `enable_thinking is false` don't take effect in
    /// swift-jinja, so a downloaded template with that switch is rewritten to always close the think block.
    /// (Prompts are rendered by HermitPrompt, so this only matters to code that still applies the template.)
    static func closeThinkInTemplate(_ directory: URL) {
        let url = directory.appending(path: "chat_template.jinja")
        guard let t = try? String(contentsOf: url, encoding: .utf8), t.contains("enable_thinking"), t.contains("<|im_start|>") else { return }
        let fixed = """
        {{- bos_token }}
        {%- for message in messages %}
        {%- if message.role == 'assistant' %}
        {{- '<|im_start|>assistant\n<think>\n\n</think>\n\n' + message.content + '<|im_end|>\n' }}
        {%- else %}
        {{- '<|im_start|>' + message.role + '\n' + message.content + '<|im_end|>\n' }}
        {%- endif %}
        {%- endfor %}
        {%- if add_generation_prompt %}
        {{- '<|im_start|>assistant\n<think>\n\n</think>\n\n' }}
        {%- endif %}
        """
        try? fixed.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Qwen3-1.7B (Lite) is a reasoning model: training put an empty think block after every assistant prefix.
    /// Qwen3-4B-Instruct-2507 has none. Read from the repo name and the shipped template.
    static func family(id: String, directory: URL) -> HermitPrompt.Family {
        if id.lowercased().contains("lite") { return .thinking }
        var t = (try? String(contentsOf: directory.appending(path: "chat_template.jinja"), encoding: .utf8)) ?? ""
        if t.isEmpty, let d = try? Data(contentsOf: directory.appending(path: "tokenizer_config.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { t = j["chat_template"] as? String ?? "" }
        if t.contains("enable_thinking") || t.contains("assistant\\n<think>\\n\\n</think>") { return .thinking }
        return .instruct
    }

    /// A load in progress: a second caller (the first question during warm-up) waits for it instead of loading twice.
    private var loading: (id: String, task: Task<TimeInterval, Error>)?

    /// Loads the model (once). Returns how long it took, or nil if it was already loaded.
    func load(id: String, directory: URL) async throws -> TimeInterval? {
        if isLoaded(id) { return nil }
        if let l = loading, l.id == id { _ = try await l.task.value; return nil }
        let task = Task { try await self.loadNow(id: id, directory: directory) }
        loading = (id, task)
        defer { if loading?.id == id { loading = nil } }
        return try await task.value
    }

    private func loadNow(id: String, directory: URL) async throws -> TimeInterval {
        await unload()
        // Freed GPU buffers are cached for reuse; keep that cache small on 8 GB devices.
        Memory.cacheLimit = (ModelCatalog.deviceMemoryGB <= 8 ? 64 : 512) << 20
        let start = Date()
        family = Self.family(id: id, directory: directory)
        Self.closeThinkInTemplate(directory)
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        parameters = Self.parameters(directory)
        loadedID = id
        return Date().timeIntervalSince(start)
    }

    func unload(ifID id: String? = nil) async {
        guard id == nil || id == loadedID else { return }
        currentRun?.cancel()
        await current?.value
        prompt.clear(); container = nil; loadedID = nil
        Memory.clearCache()
    }

    /// Reads `text` into the cache without answering (the system prompt, right after loading).
    func prefill(_ text: String) async {
        var p = parameters
        p.maxTokens = 1
        try? await generate(text, parameters: p, onText: { _ in }, onInfo: { _ in })
    }

    /// Streams the model's text for one turn that continues `text`, through `onText`. Returns when the turn ends
    /// (end-of-turn token or the token limit) or the calling task is cancelled.
    func generate(_ text: String, parameters custom: GenerateParameters? = nil,
                  onText: @escaping @Sendable (String) -> Void, onInfo: @escaping @Sendable (GenerateCompletionInfo) -> Void) async throws {
        let previous = current
        guard let container, interruption == nil else { throw CancellationError() }
        let params = custom ?? parameters
        let cache = prompt
        let run = Task<Result<Void, Error>, Never> {
            await previous?.value
            do {
                try await container.perform { context in
                    try await Self.run(text, cache: cache, parameters: params, context: context, onText: onText, onInfo: onInfo)
                }
                return .success(())
            } catch { return .failure(error) }
        }
        let done = Task<Void, Never> { _ = await run.value }
        current = done; currentRun = run
        let result = await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
        // Reply turns only (a prefill passes its own parameters).
        if custom == nil {
            if case .success = result { lastCut = cache.cut } else { lastCut = false }
        }
        if case .failure(let e) = result { throw e }
    }

    private static func run(_ text: String, cache: PromptCache, parameters: GenerateParameters, context: ModelContext,
                            onText: @Sendable (String) -> Void, onInfo: @Sendable (GenerateCompletionInfo) -> Void) async throws {
        cache.cut = false
        let tokenizer = context.tokenizer
        let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
        guard !tokens.isEmpty else { return }
        // Reuse the longest cached prefix; always feed at least one token.
        var keep = zip(cache.tokens, tokens).prefix { $0 == $1 }.count
        if keep == tokens.count { keep -= 1 }
        if let kv = cache.cache, keep < cache.tokens.count {
            let drop = cache.tokens.count - keep
            if canTrimPromptCache(kv), trimPromptCache(kv, numTokens: drop) == drop { cache.tokens.removeLast(drop) }
            else { cache.clear(); keep = 0 }
        }
        if cache.cache == nil { cache.cache = try context.model.newCache(parameters: parameters); cache.tokens = []; keep = 0 }
        let feed = Array(tokens[keep...])

        var stops = Set<Int>()
        for t in ["<|im_end|>", "<|endoftext|>", "<|im_start|>"] { if let id = tokenizer.convertTokenToId(t) { stops.insert(id) } }
        if let e = tokenizer.eosTokenId { stops.insert(e) }

        let (stream, task) = try generateTokensTask(input: LMInput(tokens: MLXArray(feed)), cache: cache.cache, parameters: parameters,
                                                    context: context, includeStopToken: true)
        var detok = NaiveStreamingDetokenizer(tokenizer: tokenizer)
        var generated: [Int] = []
        for await item in stream {
            if Task.isCancelled { break }
            switch item {
            case .token(let t):
                generated.append(t)
                if stops.contains(t) { continue }
                detok.append(token: t)
                if let s = detok.next(), !s.isEmpty { onText(s) }
            case .info(let info): onInfo(info)
            }
        }
        task.cancel()
        await task.value
        // Stopped by the token limit: neither an end-of-turn token nor a cancel.
        let limit = parameters.maxTokens ?? Int.max
        cache.cut = !Task.isCancelled && generated.count >= limit && !(generated.last.map { stops.contains($0) } ?? false)
        // The cache now holds the prompt and as many generated tokens as the model has read.
        let known = cache.tokens + feed + generated
        let offset = cache.cache?.first?.offset ?? 0
        if offset <= known.count { cache.tokens = Array(known.prefix(offset)) } else { cache.clear() }
        if Task.isCancelled { throw CancellationError() }
    }

    /// The longest reply turn, in tokens. Long enough for a full answer or a batch send with many recipients; a turn
    /// that still runs out is flagged so the chat offers Continue.
    static let replyTokenLimit = 1024

    /// Sampling for a small chat model on a phone. Some models ship temperature 1.0 and no repetition penalty, which
    /// lets them wander and loop, so Hermit caps the temperature at 0.6, uses top-p 0.9,
    /// and always applies a mild repetition penalty over the last 256 tokens (long enough to cover a repeating paragraph).
    static func parameters(_ directory: URL) -> GenerateParameters {
        let json = (try? Data(contentsOf: directory.appending(path: "generation_config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func num(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        var p = GenerateParameters(maxTokens: replyTokenLimit, temperature: Float(min(num("temperature") ?? 0.6, 0.6)),
                                   topP: Float(min(num("top_p") ?? 0.9, 0.9)), topK: Int(num("top_k") ?? 0))
        p.repetitionPenalty = Float(max(num("repetition_penalty") ?? 1.05, 1.05))
        p.repetitionContextSize = 256
        if json["do_sample"] as? Bool == false { p.temperature = 0 }
        return p
    }
}
