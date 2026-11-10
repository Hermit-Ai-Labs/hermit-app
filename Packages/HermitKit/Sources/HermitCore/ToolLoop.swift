import Foundation

/// Generates one assistant turn: given the whole prompt text so far, streams the raw text the model writes until it
/// ends its turn. The on-device engine (MLX) and the tests' scripted generator both implement it.
public protocol TurnGenerator: Sendable {
    func generate(_ prompt: String) -> AsyncThrowingStream<String, Error>
}

/// Hermit's agent loop on the device: the model writes `<tool_call>` blocks, the shared toolbox runs them, the results go
/// back as `<tool_response>` turns, and the model continues, up to `maxRounds` turns per message.
///
/// The user sees the model's text as it streams and a short step line per tool ("Checking the HYPE price…"); raw
/// tool-call text is never shown. Money tools only ever prepare: their actions become buttons that open the approval
/// sheet, and nothing moves without the user's Face ID there.
public actor ToolChat {
    public struct Config: Sendable {
        public var family: HermitPrompt.Family
        /// Tool lines for the system prompt. nil runs plain chat with no tools.
        public var tools: [String]?
        public var maxRounds = 5
        public var maxCallsPerTurn = 6
        /// Older exchanges are dropped once the prompt grows past this (about 6k tokens), so memory stays bounded.
        public var maxPromptChars = 22_000
        public init(family: HermitPrompt.Family, tools: [String]? = HermitPrompt.toolLines) { self.family = family; self.tools = tools }
    }

    public private(set) var config: Config
    private var system: String
    private var nextSystem: String?
    public private(set) var history: [HermitPrompt.Message] = []
    private let toolNames: Set<String>
    /// One reply at a time: a cancelled reply finishes its bookkeeping before the next one starts.
    private var busy = false

    public init(system: String = HermitPrompt.system(name: "", memory: []), config: Config) {
        self.system = system; self.config = config
        toolNames = Set(config.tools.map(HermitPrompt.names) ?? [])
    }

    public var messages: [HermitPrompt.Message] { [.system(system)] + history }

    /// The model reads its instructions when a conversation starts, so a new system prompt applies from the next chat
    /// (or right away if this one hasn't started).
    public func setSystem(_ s: String) {
        if history.isEmpty { system = s; nextSystem = nil } else { nextSystem = s }
    }

    public func setFamily(_ f: HermitPrompt.Family) {
        guard f != config.family else { return }
        config.family = f
    }

    public func reset() {
        history = []
        if let s = nextSystem { system = s; nextSystem = nil }
    }

    /// The full prompt for the next assistant turn. `tools: false` renders it with no tools offered (the last-chance
    /// plain answer below).
    public func prompt(tools: Bool = true) -> String {
        HermitPrompt.render(messages, tools: tools ? config.tools : [], family: config.family, addGenerationPrompt: true)
    }

    static let answerNowNote = #"{"note": "No more tools for this message. Answer the user now, in a few plain sentences, from what you know and any results above. If a tool couldn't help, say so in one short clause and answer anyway."}"#

    /// What the user typed in this chat, without attached files (an address inside a file doesn't count as typed).
    public func userText() -> String {
        history.compactMap { if case .user(let s) = $0 { return Self.withoutFiles(s) }; return nil }.joined(separator: "\n")
    }

    /// What the user gave in this chat including the files they attached (a batch send's list is the user's own file).
    public func userTextWithFiles() -> String {
        history.compactMap { if case .user(let s) = $0 { return s }; return nil }.joined(separator: "\n")
    }

    public static func withoutFiles(_ s: String) -> String {
        var t = s
        while let a = t.range(of: "<file>") {
            if let b = t.range(of: "</file>", range: a.upperBound..<t.endIndex) { t.removeSubrange(a.lowerBound..<b.upperBound) }
            else { t.removeSubrange(a.lowerBound..<t.endIndex) }
        }
        return t
    }

    private func trimHistory() {
        // Keep the newest user message and what follows it; drop whole exchanges from the front.
        while prompt().count > config.maxPromptChars {
            guard let next = history.dropFirst().firstIndex(where: { if case .user = $0 { return true }; return false }) else { return }
            history.removeSubrange(0..<next)
        }
    }

    /// "Face ID" on a phone, "Touch ID" on a Mac; the app sets it at launch.
    public static var bioWord = "Face ID"

    static let malformedReply = #"{"error": "That tool call wasn't valid JSON. Write it again as {\"name\": ..., \"arguments\": {...}} inside <tool_call></tool_call>, or answer without tools."}"#

    /// Answers one message. Events go to `cont` in the app's usual order: steps, text, then action buttons.
    public func reply(to prompt: String, generator: TurnGenerator, toolbox: AgentToolbox?,
                      cont: AsyncStream<AgentEvent>.Continuation) async {
        while busy { if Task.isCancelled { return }; try? await Task.sleep(for: .milliseconds(20)) }
        busy = true
        defer { busy = false }
        if Task.isCancelled { return }
        history.append(.user(HermitPrompt.neutralize(prompt)))
        trimHistory()

        var filter = OutputFilter()
        var steps = 0, actions: [Action] = [], shownAny = false, malformedTurns = 0
        var finalAnswer = false
        var prepared = false   // a money tool opened a review this message
        var said = ""          // everything shown, for the honesty check
        var results: [String: String] = [:], repeatTurns = 0
        var quoteArgs: String?  // the last successful get_quote, for the swap follow-through below
        var triedMoney = false  // the model called a money tool (even one that answered "blocked" or asked a question)
        var blockedReason: String?  // why a money tool refused, for the honesty check

        rounds: for round in 0..<config.maxRounds {
            var parser = ToolCallStream(known: toolNames)
            var calls: [ToolCall] = [], malformed: [String] = []
            var visible = ""
            var roundShown = false

            func show(_ text: String) {
                guard !text.isEmpty else { return }
                if !shownAny { cont.yield(.steps(steps)) }
                if !roundShown && shownAny { cont.yield(.text("\n\n")) }
                cont.yield(.text(text))
                visible += text; said += text; roundShown = true; shownAny = true
            }
            func handle(_ pieces: [ToolCallStream.Piece]) {
                for p in pieces {
                    switch p {
                    case .text(let t): show(filter.push(t))
                    case .call(let c): calls.append(c)
                    case .malformed(let m): malformed.append(m)
                    }
                }
            }

            do {
                for try await chunk in generator.generate(self.prompt()) {
                    handle(parser.push(chunk))
                    if filter.finished { break }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    show("\n\nThe model stopped: \(error.localizedDescription)")
                    history.append(.assistant(visible.trimmingCharacters(in: .whitespacesAndNewlines), calls: []))
                }
                cont.yield(.steps(steps))
                return
            }
            if Task.isCancelled {
                history.append(.assistant(visible.trimmingCharacters(in: .whitespacesAndNewlines), calls: []))
                return
            }
            if !filter.finished { handle(parser.finish()) }
            show(filter.newTurn())
            let content = visible.trimmingCharacters(in: .whitespacesAndNewlines)

            // A plain answer (or a turn the repeat guard ended): done.
            if (calls.isEmpty && malformed.isEmpty) || filter.finished {
                history.append(.assistant(content, calls: []))
                finalAnswer = !content.isEmpty
                break rounds
            }
            if calls.isEmpty {
                // Only unreadable calls. Tell the model once; a second time, stop and answer plainly.
                malformedTurns += 1
                let body = malformed.map { "<tool_call>\n" + $0.trimmingCharacters(in: .whitespacesAndNewlines) + "\n</tool_call>" }.joined(separator: "\n")
                history.append(.assistant(content.isEmpty ? body : content + "\n" + body, calls: []))
                history.append(.tool(Self.malformedReply))
                if malformedTurns >= 2 { break rounds }
                continue
            }

            let run = Array(calls.prefix(config.maxCallsPerTurn))
            history.append(.assistant(content, calls: run))
            let typed = userText()
            var fresh = 0
            for call in run {
                if Task.isCancelled { return }
                // The same call again in this message: answer from the first run (a repeated prepare_ never opens a
                // second review).
                let key = call.name + " " + call.argumentsJSON
                if let earlier = results[key] { history.append(.tool(earlier)); continue }
                fresh += 1
                // A send's chain the user never named is dropped here: the toolbox picks it from the balances or asks.
                let argsJSON = ToolGuard.adjusted(call.name, argumentsJSON: call.argumentsJSON, userText: typed)
                let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
                cont.yield(.status(ToolStatus.label(call.name, arguments: args) + "…"))
                steps += 1
                let out: ToolOutcome
                if !toolNames.contains(call.name) {
                    out = ToolOutcome(content: #"{"error": "Unknown tool \#(call.name)."}"#)
                } else if let refusal = ToolGuard.refusal(call.name, arguments: args, userText: typed) {
                    out = ToolOutcome(content: refusal)
                } else if call.name == "prepare_multisend", let refusal = ToolGuard.multisendRefusal(args, userTextWithFiles: userTextWithFiles()) {
                    out = ToolOutcome(content: refusal)
                } else if let toolbox {
                    out = await toolbox.run(call.name, arguments: argsJSON)
                } else {
                    out = ToolOutcome(content: #"{"error": "Tools are off."}"#)
                }
                if let a = out.action, !actions.contains(where: { $0.title == a.title }) { actions.append(a) }
                if ToolGuard.moneyTools.contains(call.name), out.action?.approval != nil || Self.opened(out.content) { prepared = true }
                if call.name == "get_quote", !out.content.contains("\"error\"") { quoteArgs = call.argumentsJSON }
                if ToolGuard.moneyTools.contains(call.name) {
                    triedMoney = true
                    if let v = JSONValue.parse(out.content), case .array(let r)? = v["reasons"], let first = r.first?.string { blockedReason = first }
                }
                let cleaned = ToolResult.clean(out.content)
                results[key] = cleaned
                history.append(.tool(cleaned))
            }
            // A model stuck asking the same thing: one more chance, then stop.
            if fresh == 0 { repeatTurns += 1; if repeatTurns >= 2 { break rounds } }
            if round == config.maxRounds - 1 { break rounds }
        }
        if Task.isCancelled { return }

        // Tools got nowhere (a failed lookup, a repeated call, an unreadable one) and nothing was said yet: one more turn
        // with no tools offered, so the model answers from what it knows instead of the user getting a dead end.
        if !finalAnswer && actions.isEmpty && !shownAny && !Task.isCancelled {
            history.append(.tool(Self.answerNowNote))
            var parser = ToolCallStream(known: toolNames)
            var last = OutputFilter()
            var plain = ""
            do {
                for try await chunk in generator.generate(self.prompt(tools: false)) {
                    for p in parser.push(chunk) { if case .text(let t) = p { let v = last.push(t); if !v.isEmpty { if !shownAny { cont.yield(.steps(steps)) }; cont.yield(.text(v)); plain += v; said += v; shownAny = true } } }
                    if last.finished { break }
                }
            } catch {}
            let content = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { history.append(.assistant(content, calls: [])); finalAnswer = true }
        }
        if !finalAnswer {
            // The model ran out of rounds, or couldn't write a readable call: a plain line instead of anything raw.
            let text = !actions.isEmpty ? "It's ready for your review below. Nothing moves until you approve it with \(Self.bioWord)."
                : shownAny ? "" : "I couldn't finish that here. Try asking another way."
            if !text.isEmpty {
                if !shownAny { cont.yield(.steps(steps)) }
                cont.yield(.text((shownAny ? "\n\n" : "") + text))
            }
            if case .assistant? = history.last {} else { history.append(.assistant(text, calls: [])) }
        }
        // The user asked to swap, the model quoted but didn't prepare: open the same swap's review (the user still
        // approves it with Face ID). A question like "how much would I get" stays a quote.
        if !prepared, let q = quoteArgs, let toolbox, Self.asksToSwap(prompt), !Task.isCancelled {
            let args = (try? JSONSerialization.jsonObject(with: Data(q.utf8))) as? [String: Any] ?? [:]
            if ToolGuard.refusal("prepare_swap", arguments: args, userText: userText()) == nil {
                cont.yield(.status(ToolStatus.label("prepare_swap", arguments: args) + "…"))
                steps += 1
                let out = await toolbox.run("prepare_swap", arguments: q)
                if let a = out.action, !actions.contains(where: { $0.title == a.title }) { actions.append(a) }
                if out.action != nil || Self.opened(out.content) || out.content.contains("prepared") { prepared = true }
                history.append(.tool(ToolResult.clean(out.content)))
            }
        }
        // Asked plainly for a batch send, a deposit or a withdrawal and the model didn't prepare it: the app opens the
        // same review itself (only if the model wasn't stopped by a guard). The user still approves with Face ID.
        if !prepared, !triedMoney, let toolbox, !Task.isCancelled, toolNames.contains("prepare_deposit") || toolNames.contains("prepare_multisend"),
           let (name, args) = Self.appRoute(prompt), toolNames.contains(name) {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
            let argsJSON = ToolGuard.adjusted(name, argumentsJSON: args, userText: userText())
            let refused = name == "prepare_multisend" ? ToolGuard.multisendRefusal(parsed, userTextWithFiles: userTextWithFiles()) : nil
            if refused == nil {
                cont.yield(.status(ToolStatus.label(name, arguments: parsed) + "…"))
                steps += 1
                let out = await toolbox.run(name, arguments: argsJSON)
                if let a = out.action, !actions.contains(where: { $0.title == a.title }) { actions.append(a) }
                if out.action != nil || Self.opened(out.content) { prepared = true }
                history.append(.tool(ToolResult.clean(out.content)))
                // The model didn't prepare it, so its text may not say why nothing opened: say what the app did.
                if let note = Self.routeNote(out, tool: name, arguments: parsed) {
                    if !shownAny { cont.yield(.steps(steps)) }
                    cont.yield(.text((shownAny ? "\n\n" : "") + note)); shownAny = true
                }
            }
        }
        // A model can say "prepared for review" without calling the tool. Nothing is waiting then, so say so.
        if !prepared, Self.claimsPrepared(said) {
            cont.yield(.text("\n\n" + (blockedReason.map { "Nothing was prepared: \($0)" } ?? Self.notPrepared)))
        }
        cont.yield(.steps(steps))
        if !actions.isEmpty { cont.yield(.block(.actions(actions))) }
    }

    /// "swap 20 USDC to NEAR", "bridge my USDC to Arbitrum": an instruction, not a question about a price.
    public static func asksToSwap(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: #"^(please\s+|can you\s+|could you\s+)?(swap|bridge|convert|exchange|trade)\b"#, options: .regularExpression) != nil
        else { return false }
        return !t.contains("how much") && !t.contains("what would") && !t.contains("quote")
    }

    /// The tool the app runs for a plain request the model didn't act on, with its arguments.
    public static func appRoute(_ prompt: String) -> (String, String)? {
        if let a = MoneyIntent.multisendArguments(prompt) { return ("prepare_multisend", a) }
        if let a = MoneyIntent.depositArguments(prompt) { return ("prepare_deposit", a) }
        if let a = MoneyIntent.withdrawArguments(prompt) { return ("prepare_withdraw", a) }
        return nil
    }

    /// One plain line about an app-routed tool's result: ready for review, or why not (its error or block reason).
    static func routeNote(_ out: ToolOutcome, tool: String = "", arguments: [String: Any] = [:]) -> String? {
        if out.action != nil || opened(out.content) {
            if tool == "prepare_withdraw", arguments["amount"] == nil {
                let sym = (arguments["symbol"] as? String).map { " \($0)" } ?? ""
                return "I opened the withdrawal for all of your\(sym) in Aave below. Tell me an amount if you want less. Nothing moves until you approve it with \(Self.bioWord)."
            }
            return "It's ready for your review below. Nothing moves until you approve it with \(Self.bioWord)."
        }
        guard let v = JSONValue.parse(out.content) else { return nil }
        if let e = v["error"]?.string { return e }
        if let q = v["question"]?.string { return q }
        if case .array(let r)? = v["reasons"], let first = r.first?.string { return first }
        return nil
    }

    static let notPrepared = "Nothing is waiting for your approval yet. Ask me to prepare it and the review will open."

    static func opened(_ content: String) -> Bool {
        content.contains("review_opened") || content.contains("prepared_for_review")
    }

    /// The reply says a trade, swap or send is prepared or waiting for approval.
    public static func claimsPrepared(_ text: String) -> Bool {
        let t = text.lowercased()
        let patterns = [#"\b(is|been|now|trade|order|swap|send|transfer|it|position)\s+(prepared|ready for (your )?(review|approval))"#,
                        #"\bprepared for (your )?(review|approval)"#, #"\bwaiting for (your )?(face id|approval)"#,
                        #"\b(review|approval) (sheet|screen) (is )?open"#, #"\bi(['’]ve| have) prepared\b"#,
                        #"\bon the review (sheet|screen)\b"#]
        // Sentence by sentence, skipping denials ("nothing is prepared for review", "it isn't ready for approval").
        let sentences = t.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).filter {
            $0.range(of: #"\b(nothing|not|no|never)\b|n['’]t\b"#, options: .regularExpression) == nil
        }
        return sentences.contains { s in patterns.contains { s.range(of: $0, options: .regularExpression) != nil } }
    }
}
