import SwiftUI
import Observation
import HermitCore

public enum Route: String, CaseIterable, Identifiable, Hashable {
    case home, projects, automations, trade, earn, payments, explore, calendar
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "New chat"
        case .projects: "Projects"
        case .automations: "Automations"
        case .trade: "Trade"
        case .earn: "Earn"
        case .payments: "Payments"
        case .explore: "Explore"
        case .calendar: "Calendar"
        }
    }
    var symbol: String {
        switch self {
        case .home: "plus"
        case .projects: "folder"
        case .automations: "bolt"
        case .trade: "chart.bar.xaxis"
        case .earn: "leaf"
        case .payments: "dollarsign.square"
        case .explore: "safari"
        case .calendar: "calendar"
        }
    }
}

/// App-wide state: where you are, the open conversation, and the approval sheet.
@MainActor @Observable
public final class AppModel {
    public var route: Route = .home
    public var messages: [Message] = []
    public var approval: Approval?
    public var busy = false
    public let user = "Ryan"
    public let projects: [(String, Color)] = [
        ("Dev: HYPE news bot", Color(hex: 0x2563EB)), ("Stablecoin yield ladder", Color(hex: 0x15803D)),
        ("HYPE perp scripts", Color(hex: 0x4E1F96)), ("Airdrop farming S3", Color(hex: 0xC2410C)),
        ("Meme auto-trader", Color(hex: 0xA16207)), ("Research: AI agent tokens", Color(hex: 0x0E7490)),
    ]
    public let recents = ["AI budgeting app: get API key", "Send USDC to 48 wallets", "What news is moving markets?", "Weekly ETH DCA"]

    private let agent: Agent
    private var replyTask: Task<Void, Never>?

    public init(agent: Agent = ScriptedAgent()) { self.agent = agent }

    public var inChat: Bool { !messages.isEmpty }

    public func newChat() {
        replyTask?.cancel(); messages = []; busy = false; route = .home
    }

    public func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        route = .home
        messages.append(Message(role: .user, text: text))
        let reply = Message(role: .assistant, done: false)
        messages.append(reply)
        busy = true
        replyTask = Task { [agent] in
            for await event in agent.reply(to: text) {
                update(reply.id) { m in
                    switch event {
                    case .status(let s): m.status = s
                    case .steps(let n): m.steps = n; m.status = nil
                    case .text(let chunk): m.text += chunk
                    case .card(let c): m.card = c
                    case .actions(let a): m.actions = a
                    }
                }
            }
            update(reply.id) { $0.done = true; $0.status = nil }
            busy = false
        }
    }

    /// The user tapped an action under a reply. Money moves go through the approval sheet.
    public func run(_ action: Action) {
        if let a = action.approval { approval = a } else { send(action.title) }
    }

    /// Called by the approval sheet once Touch ID / Face ID passed and the move went through.
    public func approved(_ a: Approval) {
        approval = nil
        if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[idx].actions = []
        }
        messages.append(Message(role: .assistant, text: a.success + ".", card: a.receipt))
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
    }
}
