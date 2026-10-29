import Foundation

/// What the agent emits while it answers, in order.
public enum AgentEvent: Sendable {
    case status(String)
    case steps(Int)
    case text(String)        // a chunk to append (to the last text block, or to the plain text)
    case card(Card)
    case actions([Action])
    /// A new piece of a rich reply (text streams into it with `.text` chunks).
    case block(Block)
}

/// The agent behind the chat box. Today a scripted stand-in; next, the on-device model with tools.
public protocol Agent: Sendable {
    func reply(to prompt: String) -> AsyncStream<AgentEvent>
}

/// A scripted reply: tool steps run first, then blocks appear one by one. In production these come from the
/// local model and its tool calls; the shapes are the contract.
public struct Script: Sendable {
    public var tools: [String]
    public var blocks: [Block]
    public init(tools: [String], blocks: [Block]) { self.tools = tools; self.blocks = blocks }
}

/// Scripted replies taken from the web demo, streamed at a model-like pace so the UI can be tuned for real use.
public struct ScriptedAgent: Agent {
    /// 1 is the demo's pace. Tests set 0 to get replies instantly.
    public var pace: Double
    public init(pace: Double = 1) { self.pace = pace }

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        stream(Self.script(for: prompt))
    }

    /// Streams any script: each tool step as a status, then text word by word and cards one at a time.
    public func stream(_ script: Script) -> AsyncStream<AgentEvent> {
        let pace = self.pace
        return AsyncStream { cont in
            let task = Task {
                func nap(_ ms: Double) async { if pace > 0 { try? await Task.sleep(for: .milliseconds(Int(ms * pace))) } }
                for tool in script.tools {
                    cont.yield(.status(tool + "…"))
                    await nap(560)
                }
                cont.yield(.steps(script.tools.count))
                for block in script.blocks {
                    if Task.isCancelled { break }
                    switch block {
                    case .text(let t):
                        cont.yield(.block(.text("")))
                        for word in t.split(separator: " ", omittingEmptySubsequences: false) {
                            if Task.isCancelled { break }
                            cont.yield(.text(String(word) + " "))
                            await nap(22)
                        }
                        await nap(120)
                    default:
                        cont.yield(.block(block))
                        await nap(380)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// The reply for a prompt: memory, a scenario from the demo, or a short fallback with prompts to try.
    public static func script(for prompt: String) -> Script {
        if let item = memoryItem(prompt) { return memoryScript(item) }
        if let s = Scenario.match(prompt) { return s.script }
        return Script(tools: ["Thinking"], blocks: [
            .text("I run on this device, so nothing you type here leaves it. Ask me to pay someone, earn on idle USDC or trade the news, and I'll check it before any money moves. Try one:"),
            .card(.suggestions(Scenario.all.map(\.prompt))),
        ])
    }

    public static let payAlice = Approval(
        kind: "Payment",
        title: "Pay alice.eth 200 USDC",
        lines: [["To", "alice.eth"], ["Amount", "200 USDC"], ["When", "Friday 09:00"], ["Fee", "$0.01"]],
        checks: Approval.checks(["Address matches past payments"]),
        success: "Scheduled for Friday",
        receipt: .receipt(title: "Scheduled", rows: [["To", "alice.eth"], ["Amount", "200 USDC"], ["When", "Friday 09:00"]])
    )

    // MARK: Memory

    /// "Remember X", "add X to your long-term memory": the line to save, or nil.
    public static func memoryItem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: #"\b(remember|long[- ]term|memory|knowledge)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var item = t
        item = item.replacingOccurrences(of: #"^(please\s+)?(remember( that)?|add|save|note)\s*:?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        item = item.replacingOccurrences(of: #"\s*(to|in|into)\s+(your\s+)?(long[- ]term\s+)?(memory|knowledge)\s*\.?$"#, with: "", options: [.regularExpression, .caseInsensitive])
        item = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard let first = item.first else { return nil }
        return first.uppercased() + item.dropFirst()
    }

    public static func memoryScript(_ item: String) -> Script {
        Script(tools: ["Updating hermit.md"], blocks: [.text("Saved. I'll follow this in every chat from now on."), .card(.memory(item))])
    }

    // MARK: Attachments

    /// Reading an attached file. A wallet spreadsheet plus "send" runs the batch send instead.
    public static func script(for prompt: String, attachment f: Attachment) -> Script {
        let sheetSend = (f.kind == .sheet || f.kind == .csv || f.name.lowercased().hasSuffix(".xlsx"))
            && prompt.range(of: "send|pay|distribute|airdrop", options: [.regularExpression, .caseInsensitive]) != nil
        if sheetSend { return Scenario.multisend.script }
        let read = "Reading \(f.name)"
        switch f.kind {
        case .invoice:
            return Script(tools: [read, "Checking the payee"], blocks: [
                .text("Figma invoice #2291 for **$45**, due tomorrow. Same amount and bank details as your last 6 invoices."),
                .actions([
                    Action("Pay $45", approval: Approval(kind: "Bill payment", title: "Pay Figma $45",
                        lines: [["To", "Figma, Inc."], ["Amount", "$45.00"], ["Route", "USDC to bank via Bridge"], ["Invoice", "#2291"]],
                        checks: Approval.checks(["Bank details match past invoices"]), success: "Invoice paid",
                        receipt: .result(Receipt(title: "Invoice #2291 paid", rows: [["Amount", "$45.00"], ["Arrives", "1 business day"]])))),
                    Action("Pay on due date", toast: "Scheduled for Oct 27"),
                ]),
            ])
        case .csv, .sheet:
            return Script(tools: ["\(read), 412 rows", "Matching fills to prices"], blocks: [
                .text("Q3 net **+$2,140**. Funding arb carried it. Memes lost $380."),
                .card(.bars(title: "PnL by strategy", rows: [
                    BarRow("Funding arb", 1840, "$1,840", tone: .green), BarRow("Breakout", 520, "$520", tone: .green),
                    BarRow("Spot", 160, "$160", tone: .green), BarRow("Memes, loss", 380, "$380", tone: .red),
                ])),
                .card(.pnl(title: "Equity, Q3", total: "+$2,140", days: 90, seed: 71)),
                .actions([Action("Pause meme trading", toast: "Meme sniper paused", primary: true), Action("Save as journal", toast: "Saved to Files")]),
            ])
        case .paper:
            return Script(tools: ["\(read), 38 pages", "Checking claims on-chain"], blocks: [
                .text("A parallel EVM chain claiming 10,000 TPS. The live network averages about 3,100. **38% of supply** goes to team and investors after a 1-year cliff."),
                .card(.bars(title: "Token allocation", rows: [BarRow("Community", 40, "40%"), BarRow("Treasury", 22, "22%"), BarRow("Investors", 20, "20%"), BarRow("Team", 18, "18%")])),
                .text("Main risk: the large unlock in November 2027."),
                .actions([Action("Farm the airdrop", ask: "Farm the Monad airdrop for me", primary: true), Action("Save to Research", toast: "Added to Research: AI agent tokens")]),
            ])
        case .chart:
            return Script(tools: ["Reading the chart image", "Matching it to live PENGU data"], blocks: [
                .text("PENGU on the 4H. A breakout above $0.031 on rising volume. Next resistance is $0.036."),
                .card(.token(TokenSpec(sym: "PENGU", name: "Pudgy Penguins", price: 0.0334, change: 18.2, seed: 11,
                    stats: [["Market cap", "$2.1B"], ["Liquidity", "$48M"], ["Volume 24h", "$612M"], ["Holders", "712k"]],
                    marks: [ChartMark(0.031, "Breakout", .text), ChartMark(0.036, "Resistance", .accent)]))),
            ])
        case .code:
            return Script(tools: [read], blocks: [
                .text("\(f.name) runs every morning at 08:00, searches HYPE news through Perplexity, and posts a summary to Telegram. It spends about **$0.10 a day**."),
            ])
        case .doc:
            return Script(tools: [read], blocks: [
                .text("**\(f.name)**: three decisions and three follow-ups. The most urgent is shipping wallet onboarding by Nov 8."),
                .actions([Action("Add tasks to calendar", toast: "3 tasks added to Calendar", primary: true)]),
            ])
        }
    }
}
