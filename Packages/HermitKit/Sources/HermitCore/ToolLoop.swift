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
        // No tools renders no tool block at all, as training does (an empty <tools></tools> never occurs there).
        let text = HermitPrompt.render(messages, tools: tools ? config.tools : nil, family: config.family, addGenerationPrompt: true)
        return Self.bioWord == "Face ID" ? text : text.replacingOccurrences(of: "Face ID", with: Self.bioWord)
    }

    static let answerNowNote = #"{"note": "No more tools for this message. If a live price, balance or position was needed and no result above has it, say you couldn't get it right now and say nothing about its value. Otherwise answer in a few plain sentences."}"#

    /// What the last-chance answer says instead when it states a dollar amount or a percent no result or message had.
    static let noLiveNumber = "I couldn't get a live number just now. Try again in a moment."

    /// What the user typed in this chat, without attached files (an address inside a file doesn't count as typed).
    public func userText() -> String {
        history.compactMap { if case .user(let s) = $0 { return Self.withoutFiles(s) }; return nil }.joined(separator: "\n")
    }

    /// What the user gave in this chat including the files they attached (a batch send's list is the user's own file).
    public func userTextWithFiles() -> String {
        history.compactMap { if case .user(let s) = $0 { return s }; return nil }.joined(separator: "\n")
    }

    /// The message without its attached file. The app writes "The user attached the file NAME:", the file between
    /// <file> and </file>, then the question. A file can hold "</file>" itself, so the file runs to the LAST closing
    /// tag, never the first (text after a fake closing tag would otherwise count as typed). The line naming the file
    /// goes too: a file's name isn't typed by the user either.
    public static func withoutFiles(_ s: String) -> String {
        var t = s
        while let a = t.range(of: "<file>", options: .caseInsensitive) {
            let from = t.range(of: "The user attached the file", options: [.anchored, .caseInsensitive])?.lowerBound ?? a.lowerBound
            if let b = t.range(of: "</file>", options: [.caseInsensitive, .backwards], range: a.upperBound..<t.endIndex) { t.removeSubrange(from..<b.upperBound) }
            else { t.removeSubrange(from..<t.endIndex) }
        }
        return t
    }

    /// A file's text made safe to put between the app's <file> markers: tags inside it can't end the block early.
    public static func fileSafe(_ body: String) -> String {
        body.replacingOccurrences(of: "</file>", with: "</ file>", options: .caseInsensitive)
            .replacingOccurrences(of: "<file>", with: "< file>", options: .caseInsensitive)
    }

    /// Keeps the newest user message and what follows it; drops whole exchanges from the front. Once over the cap it
    /// trims to about 70 percent, so the model's cache is rebuilt now and then rather than on every message.
    /// True when something was dropped.
    private func trimHistory() -> Bool {
        guard prompt().count > config.maxPromptChars else { return false }
        let target = config.maxPromptChars * 7 / 10
        var dropped = false
        while prompt().count > target {
            guard let next = history.dropFirst().firstIndex(where: { if case .user = $0 { return true }; return false }) else { break }
            history.removeSubrange(0..<next); dropped = true
        }
        return dropped
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
        if trimHistory() { cont.yield(.status("Setting older messages aside to make room…")) }

        var filter = OutputFilter()
        var steps = 0, actions: [Action] = [], shownAny = false, malformedTurns = 0
        var finalAnswer = false
        var prepared = false   // a money tool opened a review this message
        var said = ""          // everything shown, for the honesty check
        var results: [String: String] = [:], repeatTurns = 0
        var quoteArgs: String?  // the last successful get_quote, for the swap follow-through below
        var triedMoney = false  // the model called a money tool (even one that answered "blocked" or asked a question)
        var blockedReason: String?  // why a money tool refused, for the honesty check
        var executed = false        // a tool result said money actually moved
        var listSent = false        // the attached list of payees already went out as one batch

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
            for original in run {
                if Task.isCancelled { return }
                var call = original
                // A spreadsheet of payees is one batch send, whatever the model did with it: it tends to split the list
                // into single sends (and invent a network). The app builds the batch from the user's own rows instead.
                // Only a send to one of those rows (or to no one yet): a send to someone else stays a send.
                if call.name == "prepare_send", let (n, a) = Self.appRoute(prompt), n == "prepare_multisend", Self.recipientCount(a) >= 2,
                   Self.isPayee(original.arguments["to_address"]?.string, of: a) {
                    // Every call gets a result, so the history has one per call.
                    if listSent { history.append(.tool(Self.inBatchNote)); continue }
                    call = ToolCall(name: n, arguments: JSONValue.parse(a) ?? .object([])); listSent = true
                }
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
                if let a = out.action { Self.add(a, to: &actions) }
                if ToolGuard.moneyTools.contains(call.name), out.action?.approval != nil || Self.opened(out.content) { prepared = true }
                if out.content.contains("\"executed\":true") || out.content.contains("\"status\":\"sent\"") || out.content.contains("\"status\": \"sent\"") { executed = true }
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
        // It is held back until it ends: no tool answered, so a dollar amount or percent in it must come from a result
        // or a message in this chat, or it is replaced (a small model fills a failed price lookup from memory).
        if !finalAnswer && actions.isEmpty && !shownAny && !Task.isCancelled {
            history.append(.tool(Self.answerNowNote))
            var parser = ToolCallStream(known: toolNames)
            var last = OutputFilter()
            var plain = ""
            do {
                for try await chunk in generator.generate(self.prompt(tools: false)) {
                    for p in parser.push(chunk) { if case .text(let t) = p { plain += last.push(t) } }
                    if last.finished { break }
                }
            } catch {}
            if Task.isCancelled { return }
            plain += last.flush()
            var content = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty, !Self.numbersBacked(content, by: history) { content = Self.noLiveNumber }
            if !content.isEmpty {
                if !shownAny { cont.yield(.steps(steps)) }
                cont.yield(.text(content)); said += content; shownAny = true
                history.append(.assistant(content, calls: [])); finalAnswer = true
            }
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
                if let a = out.action { Self.add(a, to: &actions) }
                // Only a review that opened counts: a refusal ("Nothing was prepared", "prepared": false) doesn't.
                if out.action != nil || Self.opened(out.content) { prepared = true }
                else if let v = JSONValue.parse(out.content), case .array(let r)? = v["reasons"], let first = r.first?.string { blockedReason = first }
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
                if let a = out.action { Self.add(a, to: &actions) }
                if out.action != nil || Self.opened(out.content) { prepared = true }
                history.append(.tool(ToolResult.clean(out.content)))
                // The model didn't prepare it, so its text may not say why nothing opened: say what the app did.
                if let note = Self.routeNote(out, tool: name, arguments: parsed) {
                    if !shownAny { cont.yield(.steps(steps)) }
                    cont.yield(.text((shownAny ? "\n\n" : "") + note)); shownAny = true
                }
            }
        }
        // Both checks below only run when this message is about moving money, so an email "prepared below" or a
        // history answer ("the first bitcoin was sent in 2009") gets no money note.
        let typedNow = Self.withoutFiles(prompt)
        // A model can say "prepared for review" without calling the tool. Nothing is waiting then, so say so.
        if !prepared, triedMoney || Self.asksMoneyMove(typedNow) || Self.namesMoneyMove(said), Self.claimsPrepared(said, inMoneyMessage: true) {
            cont.yield(.text("\n\n" + (blockedReason.map { "Nothing was prepared: \($0)" } ?? Self.notPrepared)))
        }
        // And it can't know money moved unless a tool said so: approvals happen on the review screen, out of its sight.
        if !executed, triedMoney || prepared || Self.asksMoneyMove(typedNow), Self.claimsDone(said, inMoneyMessage: true) {
            cont.yield(.text("\n\nTo be clear: I can't see approvals or results from here, so I don't know whether that went through. Activity in Wallets shows what actually happened."))
        }
        cont.yield(.steps(steps))
        if !actions.isEmpty { cont.yield(.block(.actions(actions))) }
    }

    /// Adds a button unless the very same one is there. Two different reviews can share a title ("Review send" to two
    /// people): both stay, and their titles say who each one pays (or get a number), so every button has its own id.
    public static func add(_ action: Action, to actions: inout [Action]) {
        guard !actions.contains(where: { $0.isSame(as: action) }) else { return }
        let base = action.title
        guard actions.contains(where: { $0.title == base || $0.title.hasPrefix(base + " to ") || $0.title.hasPrefix(base + " (") }) else {
            actions.append(action); return
        }
        if let i = actions.firstIndex(where: { $0.title == base }), let named = recipientTitle(actions[i]), !actions.contains(where: { $0.title == named }) {
            actions[i] = actions[i].titled(named)
        }
        let wanted = recipientTitle(action) ?? base
        var title = wanted, n = 2
        while actions.contains(where: { $0.title == title }) { title = "\(wanted) (\(n))"; n += 1 }
        actions.append(action.titled(title))
    }

    /// "Review send to 0x5aAe…eAed": the title with the review's "To" line, or nil when it has none.
    static func recipientTitle(_ a: Action) -> String? {
        guard let to = a.approval?.lines.first(where: { $0.first == "To" }), to.count > 1 else { return nil }
        let t = to[1].trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var short = t
        if !t.contains(" "), t.count > 16 { short = String(t.prefix(6)) + "…" + String(t.suffix(4)) }
        else if t.count > 28 { short = String(t.prefix(27)) + "…" }
        return a.title + " to " + short
    }

    static let inBatchNote = #"{"note": "This payee is already in the batch send above. Nothing else was prepared."}"#

    /// The send's recipient is one of the batch's rows, or it names none: the model split the user's list.
    static func isPayee(_ address: String?, of argumentsJSON: String) -> Bool {
        guard let a = address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return true }
        guard let v = JSONValue.parse(argumentsJSON), case .array(let rows)? = v["recipients"] else { return false }
        return rows.contains { r in
            guard let to = r["address"]?.string else { return false }
            return to.hasPrefix("0x") ? to.lowercased() == a.lowercased() : to == a
        }
    }

    /// Every dollar amount and percent in `text` is near a number the user wrote or a tool returned in this chat.
    static func numbersBacked(_ text: String, by history: [HermitPrompt.Message]) -> Bool {
        let claimed = numbers(in: text, pattern: #"\$\s?([0-9][0-9,]*(?:\.[0-9]+)?)|([0-9][0-9,]*(?:\.[0-9]+)?)\s?(?:%|percent\b|usd\b|dollars\b)"#)
        guard !claimed.isEmpty else { return true }
        let source = history.compactMap { (m: HermitPrompt.Message) -> String? in
            switch m {
            case .user(let s), .tool(let s): return s
            default: return nil
            }
        }.joined(separator: "\n")
        let known = numbers(in: source, pattern: #"([0-9][0-9,]*(?:\.[0-9]+)?)"#)
        return claimed.allSatisfy { c in known.contains { k in abs(k - c) <= max(0.01, abs(k) * 0.01) } }
    }

    /// The numbers the pattern's groups capture, commas dropped.
    static func numbers(in text: String, pattern: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> Double? in
            for g in 1..<max(m.numberOfRanges, 1) {
                if let r = Range(m.range(at: g), in: text) { return Double(text[r].replacingOccurrences(of: ",", with: "")) }
            }
            return nil
        }
    }

    /// The user's message asks for (or about) a money move: a send, swap, trade, deposit or withdrawal.
    static func asksMoneyMove(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(send|sending|sent|pay|paying|paid|transfer\w*|swap\w*|bridg\w*|convert|trade\w*|buy|sell|long|short|deposit\w*|withdraw\w*|multisend|batch|stake|supply|lend|order|position|leverage)\b"#,
                                options: .regularExpression) != nil
    }

    /// The reply talks about a money move ("the swap", "your send"), not about an email or a plan.
    static func namesMoneyMove(_ text: String) -> Bool {
        text.lowercased().range(of: #"\b(send|transfer|swap|bridge|trade|deposit|withdrawal|payment|multisend|batch send)s?\b"#, options: .regularExpression) != nil
    }

    /// "swap 20 USDC to NEAR", "bridge my USDC to Arbitrum": an instruction, not a question about a price.
    public static func asksToSwap(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: #"^(please\s+|can you\s+|could you\s+)?(swap|bridge|convert|exchange|trade)\b"#, options: .regularExpression) != nil
        else { return false }
        return !t.contains("how much") && !t.contains("what would") && !t.contains("quote")
    }

    /// The tool the app runs for a plain request the model didn't act on, with its arguments.
    static func recipientCount(_ argumentsJSON: String) -> Int {
        guard let v = JSONValue.parse(argumentsJSON), case .array(let r)? = v["recipients"] else { return 0 }
        return r.count
    }

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

    /// "the sends went through", "your swap is done", "has been sent": a claim that money moved. Bare passives ("was
    /// sent", "was executed") and "it's done" are not claims on their own: history, file summaries and how-to answers
    /// use them all the time. In a message about moving money (`inMoneyMessage`) they count again: there "10 USDC was
    /// sent to alice.near" is a claim about this move.
    public static func claimsDone(_ text: String, inMoneyMessage: Bool = false) -> Bool {
        let t = text.lowercased()
        var patterns = [#"\b(went|gone) through\b"#, #"\b(has|have|had) been (sent|transferred|swapped|deposited|withdrawn|executed|completed|filled)\b"#,
                        #"\bsuccessfully (sent|transferred|swapped|deposited|withdrew|withdrawn|executed|placed|filled)\b"#,
                        #"\btransaction (is|was) (complete|confirmed|successful)\b"#,
                        #"\b(your|the) (send|swap|transfer|trade|order|deposit|withdrawal|payment|batch send)s? (is|are|was|were) (now )?(done|complete|completed|confirmed|sent|filled|executed|through)\b"#,
                        #"\bi(['’]ve| have)? (sent|transferred|swapped|deposited|withdrawn|executed)\b"#]
        if inMoneyMessage {
            patterns += [#"\b(was|were) (sent|transferred|swapped|deposited|withdrawn|executed)\b"#, #"\bit(['’]s| is) (done|sent|confirmed)\b"#,
                         #"\bfunds are (now )?in\b"#]
        }
        let sentences = t.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).filter {
            $0.range(of: #"\b(nothing|not|no|never|once|after|when|if|until|unless|will|would)\b|n['’]t\b"#, options: .regularExpression) == nil
        }
        return sentences.contains { s in patterns.contains { s.range(of: $0, options: .regularExpression) != nil } }
    }

    /// The reply says a trade, swap or send is prepared or waiting for approval. "is prepared" alone isn't enough (a
    /// meal plan is prepared too): the thing prepared is a money move, or it is prepared for review or approval. In a
    /// message about moving money (`inMoneyMessage`), "it's prepared" and "has been prepared" count too.
    public static func claimsPrepared(_ text: String, inMoneyMessage: Bool = false) -> Bool {
        let t = text.lowercased()
        var patterns = [#"\b(trade|order|swap|send|transfer|position|deposit|withdrawal|payment|batch send)s?\s+(is\s+|are\s+)?(now\s+)?(prepared|ready for (your )?(review|approval))"#,
                        #"\bprepared for (your )?(review|approval)"#, #"\bready for (your )?(review|approval)"#, #"\bwaiting for (your )?(face id|touch id|approval)"#,
                        #"\b(review|approval) (sheet|screen) (is )?open"#, #"\bi(['’]ve| have) prepared\b"#,
                        #"\bon the review (sheet|screen)\b"#]
        if inMoneyMessage { patterns.append(#"\b(is|been|now|it|it['’]s)\s+(prepared|ready for (your )?(review|approval))"#) }
        // Sentence by sentence, skipping denials ("nothing is prepared for review", "it isn't ready for approval").
        let sentences = t.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).filter {
            $0.range(of: #"\b(nothing|not|no|never)\b|n['’]t\b"#, options: .regularExpression) == nil
        }
        return sentences.contains { s in patterns.contains { s.range(of: $0, options: .regularExpression) != nil } }
    }
}
