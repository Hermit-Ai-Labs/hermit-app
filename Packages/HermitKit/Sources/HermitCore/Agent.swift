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

/// The agent behind the chat box: the on-device model (see HybridAgent).
public protocol Agent: Sendable {
    func reply(to prompt: String) -> AsyncStream<AgentEvent>
    /// Forget the conversation (New chat). Agents without memory ignore it.
    func reset()
    /// Who the user is and what hermit.md says, for the system prompt. Takes effect from the next new chat.
    func setContext(name: String, memory: [String])
}

public extension Agent {
    func reset() {}
    func setContext(name: String, memory: [String]) {}
}

/// A scripted reply: tool steps run first, then blocks appear one by one.
public struct Script: Sendable {
    public var tools: [String]
    public var blocks: [Block]
    public init(tools: [String], blocks: [Block]) { self.tools = tools; self.blocks = blocks }
}

/// Streams fixed replies at a model-like pace. Chat no longer uses it for answers (everything goes to the on-device
/// model); it streams the replies the app writes itself, like "Saved to hermit.md", and the snapshot tests use the
/// demo scenarios to render every card.
public struct ScriptedAgent: Agent {
    /// 1 is the demo's pace. Tests set 0 to get replies instantly.
    public var pace: Double
    public init(pace: Double = 1) { self.pace = pace }

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        stream(Scenario.match(prompt)?.script ?? Script(tools: [], blocks: [.text(prompt)]))
    }

    /// Plain text as a reply, streamed like the model's.
    public func say(_ text: String) -> AsyncStream<AgentEvent> { stream(Script(tools: [], blocks: [.text(text)])) }

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

    public static let payAlice = Approval(
        kind: "Payment",
        title: "Pay alice.eth 200 USDC",
        lines: [["To", "alice.eth"], ["Amount", "200 USDC"], ["When", "Friday 09:00"], ["Fee", "$0.01"]],
        checks: Approval.checks(["Address matches past payments"]),
        success: "Scheduled for Friday",
        receipt: .receipt(title: "Scheduled", rows: [["To", "alice.eth"], ["Amount", "200 USDC"], ["When", "Friday 09:00"]])
    )

    // MARK: Memory

    /// "Remember X", "/remember X", "add X to your long-term memory": the line to save, or nil. Questions don't count.
    public static func memoryItem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.hasSuffix("?") else { return nil }
        let patterns = [
            #"^(?:please\s+)?/?remember(?:\s+that)?\s*:?\s+(.+)$"#,
            #"^(?:please\s+)?(?:add|save|note)\s*:?\s+(.+?)\s+(?:to|in|into)\s+(?:your\s+)?(?:long[- ]term\s+)?(?:memory|hermit\.md)\.?$"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            let item = t[r].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ."))
            guard let first = item.first else { return nil }
            return first.uppercased() + item.dropFirst()
        }
        return nil
    }

    public static func memoryScript(_ item: String) -> Script {
        Script(tools: ["Updating hermit.md"], blocks: [.text("Saved to hermit.md. I'll follow it from your next chat on."), .card(.memory(item))])
    }
}
