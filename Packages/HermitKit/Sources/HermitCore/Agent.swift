import Foundation

/// What the agent emits while it answers, in order.
public enum AgentEvent: Sendable {
    case status(String)
    case steps(Int)
    case text(String)        // a chunk to append
    case card(Card)
    case actions([Action])
}

/// The agent behind the chat box. Today a scripted stand-in; next, the on-device model with tools.
public protocol Agent: Sendable {
    func reply(to prompt: String) -> AsyncStream<AgentEvent>
}

/// Scripted replies taken from the web demo, streamed at a model-like pace so the UI can be tuned for real use.
public struct ScriptedAgent: Agent {
    public init() {}

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        let script = Self.script(for: prompt)
        return AsyncStream { cont in
            let task = Task {
                for status in script.statuses {
                    cont.yield(.status(status))
                    try? await Task.sleep(for: .milliseconds(700))
                }
                cont.yield(.steps(script.statuses.count))
                for word in script.text.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    cont.yield(.text(String(word) + " "))
                    try? await Task.sleep(for: .milliseconds(28))
                }
                if let card = script.card { cont.yield(.card(card)) }
                if !script.actions.isEmpty { cont.yield(.actions(script.actions)) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    struct Script { var statuses: [String]; var text: String; var card: Card?; var actions: [Action] }

    public static let payAlice = Approval(
        kind: "Payment",
        title: "Pay alice.eth 200 USDC",
        lines: [["To", "alice.eth"], ["Amount", "200 USDC"], ["When", "Friday 09:00"], ["Fee", "$0.01"]],
        checks: ["Requested by you, not by a web page or email", "Simulation matches summary", "Contract verified and audited",
                 "Exact-amount token approval", "Address matches past payments", "Within daily limit"],
        success: "Scheduled for Friday",
        receipt: .receipt(title: "Scheduled", rows: [["To", "alice.eth"], ["Amount", "200 USDC"], ["When", "Friday 09:00"]])
    )

    static func script(for prompt: String) -> Script {
        let p = prompt.lowercased()
        if p.contains("alice") || p.contains("pay") {
            return Script(
                statuses: ["Resolving alice.eth…", "Checking past payments…"],
                text: "alice.eth is the same address you've paid 3 times before. I'll send **200 USDC** on Friday at 09:00.",
                card: .bars(title: "Paid to alice.eth", rows: [
                    BarRow("Aug", 800, "$800"), BarRow("Sep", 1200, "$1,200"), BarRow("Oct", 1200, "$1,200"),
                    BarRow("Friday", 200, "$200", highlight: true),
                ]),
                actions: [Action("Schedule", approval: payAlice)]
            )
        }
        return Script(
            statuses: ["Thinking…"],
            text: "I run on this Mac, so nothing you type here leaves it. Ask me to pay someone, earn on idle USDC or watch a token, and I'll check it before any money moves.",
            card: nil, actions: []
        )
    }
}
