import SwiftUI
import Observation
import HermitCore

public enum Route: String, CaseIterable, Identifiable, Hashable {
    case home, projects, automations, trade, earn, payments, explore, calendar, wallets, connectors, files, settings
    public var id: String { rawValue }
    /// Pages listed in the sidebar. Wallets, Connectors, Files and Settings open from the account menu.
    static let sidebar: [Route] = [.home, .projects, .automations, .trade, .earn, .payments, .explore, .calendar]
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
        case .wallets: "Wallets"
        case .connectors: "Connectors"
        case .files: "Files"
        case .settings: "Settings"
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
        case .wallets: "wallet.bifold"
        case .connectors: "puzzlepiece.extension"
        case .files: "doc"
        case .settings: "gearshape"
        }
    }
}

/// App-wide state: where you are, the open conversation and the saved ones, projects, automations,
/// to-dos, memory and the approval sheet.
@MainActor @Observable
public final class AppModel {
    public var route: Route = .home
    /// The open conversation.
    public var messages: [Message] = []
    public var approval: Approval?
    public var busy = false
    /// Short confirmation shown at the bottom; set it with `toast(_:)`.
    public var toastText: String?
    public let user = "Ryan"
    public let email = "ryan@hermit.my"

    // Conversations
    /// Every saved chat, newest first. Recents are the ones outside a project.
    public var conversations: [Conversation] = Threads.all
    /// The saved conversation `messages` belongs to (nil for a new chat until its first message).
    public var currentID: String?
    /// The project a new or open chat belongs to (back link, strip under the chat box, project home cards).
    public var chatProject: String?

    // Projects
    public var projectList: [Project] = Project.seed
    /// The project page open on the Projects route (nil shows the list).
    public var projectOpen: String?
    /// Costs switched off on a project page, "project/what".
    public var costsOff: Set<String> = []
    /// Edited project.md per project.
    public var projectMD: [String: String] = [:]

    // Automations
    public var automations: [Automation] = Automation.seed
    /// The automation thread open on the Automations route: a name, or a new draft from a sentence.
    public var automationOpen: AutomationOpen?
    public enum AutomationOpen: Hashable { case existing(String), new(String) }

    // Everything else
    public var todos: [Todo] = Todo.seed
    /// hermit.md: what Hermit remembers in every chat.
    public var memory: [String] = ["Never use more than 5x leverage", "Prefer audited protocols for stablecoin yield", "Keep replies short, numbers first"]
    /// Titles of approvals that went through, so cards can show their after-state (sent, live, key added).
    public var approvedIDs: Set<String> = []
    /// Bumped by ⌘K so the chat box takes focus.
    public var focusTick = 0
    /// iPhone: the sidebar drawer.
    public var drawerOpen = false
    /// Home cards (Settings › Home can hide them).
    public var showManaged = true
    public var showToday = true

    /// Sidebar shape kept for other pages: (name, colour).
    public var projects: [(String, Color)] { projectList.map { ($0.name, $0.color) } }
    /// Titles of standalone chats, newest first.
    public var recents: [String] { recentConversations.map(\.title) }
    public var recentConversations: [Conversation] { conversations.filter { $0.project == nil } }
    public func chats(in project: String) -> [Conversation] { conversations.filter { $0.project == project } }
    public func project(_ name: String?) -> Project? { projectList.first { $0.name == name } }

    private let agent: Agent
    private var replyTask: Task<Void, Never>?
    private let persist: Bool

    public init(agent: Agent = ScriptedAgent()) {
        self.agent = agent
        persist = !SnapshotMode.active
        if persist { load() }
    }

    public var inChat: Bool { !messages.isEmpty }

    public func toast(_ text: String) {
        withAnimation(.snappy) { toastText = text }
        Task { try? await Task.sleep(for: .seconds(2.4)); if toastText == text { withAnimation(.smooth) { toastText = nil } } }
    }

    /// Open a page, optionally on a tab (pages read `tabRequest` once on appear).
    public var tabRequest: String?
    public func open(_ r: Route, tab: String? = nil) {
        tabRequest = tab
        if r == .projects && route != .projects { projectOpen = nil }
        if r == .automations && route != .automations { automationOpen = nil }
        route = r; drawerOpen = false
    }

    // MARK: Conversations

    /// A fresh chat, optionally inside a project.
    public func newChat(project: String?) {
        commit()
        replyTask?.cancel(); messages = []; busy = false; route = .home
        currentID = nil; chatProject = project; drawerOpen = false
        focusTick += 1
    }

    public func newChat() { newChat(project: nil) }

    /// Reopen a saved conversation.
    public func openConversation(_ id: String) {
        guard let c = conversations.first(where: { $0.id == id }) else { return }
        commit()
        replyTask?.cancel(); busy = false
        messages = c.messages; currentID = id; chatProject = c.project
        route = .home; drawerOpen = false
    }

    public func deleteConversation(_ id: String) {
        withAnimation(.snappy) { conversations.removeAll { $0.id == id } }
        if currentID == id { messages = []; currentID = nil }
        save()
    }

    public var currentTitle: String {
        if let id = currentID, let c = conversations.first(where: { $0.id == id }) { return c.title }
        return messages.first(where: { $0.role == .user })?.text ?? "New chat"
    }

    /// Writes the open conversation back to the saved list.
    func commit() {
        guard !messages.isEmpty else { return }
        if let id = currentID, let i = conversations.firstIndex(where: { $0.id == id }) {
            conversations[i].messages = messages.map { var m = $0; m.done = true; m.status = nil; return m }
        }
        save()
    }

    /// Ask from anywhere: opens chat and sends.
    public func ask(_ prompt: String) {
        if route != .home { route = .home }
        send(prompt)
    }

    public func send(_ raw: String) { send(raw, attachment: nil) }

    public func send(_ raw: String, attachment: Attachment?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachment != nil, !busy else { return }
        if text.isEmpty, let a = attachment { text = "What's in \(a.name)?" }
        route = .home; drawerOpen = false
        if currentID == nil {
            let c = Conversation(title: String(text.prefix(60)), project: chatProject, when: "Today", messages: [])
            currentID = c.id
            withAnimation(.snappy) { conversations.insert(c, at: 0) }
        }
        if let item = attachment == nil ? ScriptedAgent.memoryItem(text) : nil { memory.append(item) }
        messages.append(Message(role: .user, text: text, attachment: attachment))
        let reply = Message(role: .assistant, done: false)
        messages.append(reply)
        busy = true
        let stream: AsyncStream<AgentEvent>
        if let a = attachment, let scripted = agent as? ScriptedAgent {
            stream = scripted.stream(ScriptedAgent.script(for: text, attachment: a))
        } else {
            stream = agent.reply(to: text)
        }
        replyTask = Task { [weak self] in
            for await event in stream {
                self?.apply(event, to: reply.id)
            }
            self?.update(reply.id) { $0.done = true; $0.status = nil }
            self?.busy = false
            self?.commit()
        }
    }

    /// Stop the reply that is streaming.
    public func stop() {
        replyTask?.cancel()
        if let last = messages.last, !last.done { update(last.id) { $0.done = true; $0.status = nil } }
        busy = false
    }

    private func apply(_ event: AgentEvent, to id: UUID) {
        update(id) { m in
            switch event {
            case .status(let s):
                m.status = s
                m.tools.append(s.hasSuffix("…") ? String(s.dropLast()) : s)
            case .steps(let n): m.steps = n; m.status = nil
            case .text(let chunk):
                if case .text(let t)? = m.blocks.last { m.blocks[m.blocks.count - 1] = .text(t + chunk) } else { m.text += chunk }
            case .card(let c): m.card = c
            case .actions(let a): m.actions = a
            case .block(let b): m.blocks.append(b)
            }
        }
    }

    /// A button's outcome in chat: your action as a message, then Hermit's reply.
    public func react(_ label: String, _ reply: String) {
        guard route == .home, inChat else { toast(reply); return }
        withAnimation(.smooth) { messages.append(Message(role: .user, text: label)) }
        Task {
            try? await Task.sleep(for: .milliseconds(SnapshotMode.active ? 0 : 450))
            withAnimation(.smooth) { messages.append(Message(role: .assistant, text: reply, note: true)) }
            commit()
        }
    }

    /// The user tapped an action under a reply. Money moves go through the approval sheet.
    public func run(_ action: Action) {
        if let a = action.approval { approval = a }
        else if let q = action.ask { ask(q) }
        else if let r = action.reply { react(action.title, r) }
        else if let t = action.toast { toast(t) }
        else { send(action.title) }
    }

    /// Called by the approval sheet once Touch ID / Face ID passed and the move went through.
    public func approved(_ a: Approval) {
        approval = nil
        approvedIDs.insert(a.title)
        guard route == .home, inChat else { toast(a.success); return }
        if let idx = messages.lastIndex(where: { $0.role == .assistant }), messages[idx].blocks.isEmpty {
            messages[idx].actions = []
        }
        withAnimation(.smooth) {
            if let r = a.receipt {
                messages.append(Message(role: .assistant, blocks: [.card(r)]))
            } else {
                messages.append(Message(role: .assistant, text: a.success + ".", note: true))
            }
            if let live = a.live { messages.append(Message(role: .assistant, blocks: [.card(.liveTrade(live))])) }
        }
        commit()
    }

    // MARK: Projects

    public func openProject(_ name: String) {
        projectOpen = name; route = .projects; drawerOpen = false
    }

    public func addProject(name: String, template: String, budget: Double) {
        let symbol = Project.templates.first { $0.0 == template }?.1 ?? "folder"
        let palette: [UInt32] = [0x2563EB, 0x15803D, 0x4E1F96, 0xC2410C, 0xA16207, 0x0E7490, 0xBE185D]
        let p = Project(name: name, symbol: symbol, desc: template, status: "Draft", pnl: "—", money: budget, cost: 0, gain: 0,
                        gainLabel: "Gain", gainNote: "Just created", files: ["project.md"], hex: palette[projectList.count % palette.count])
        withAnimation(.snappy) { projectList.insert(p, at: 0) }
        projectOpen = name
    }

    public func burn(of p: Project) -> Double {
        p.burn.filter { !costsOff.contains("\(p.name)/\($0.what)") }.reduce(0) { $0 + $1.amount }
    }

    public func toggleCost(_ p: Project, _ c: Project.Cost) {
        let key = "\(p.name)/\(c.what)"
        if costsOff.contains(key) { costsOff.remove(key); toast("\(c.what) back on") }
        else { costsOff.insert(key); toast("\(c.what) paused, saves \(Money.usd(c.amount)) a month") }
    }

    public func instructions(for p: Project) -> String { projectMD[p.name] ?? p.defaultInstructions }

    // MARK: Automations

    public func toggleAutomation(_ name: String) {
        guard let i = automations.firstIndex(where: { $0.name == name }) else { return }
        withAnimation(.snappy) { automations[i].on.toggle() }
    }

    public func addAutomation(_ a: Automation) {
        withAnimation(.snappy) { automations.removeAll { $0.name == a.name }; automations.insert(a, at: 0) }
    }

    // MARK: To-dos

    public func toggleTodo(_ id: Int) {
        guard let i = todos.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { todos[i].done.toggle() }
    }

    public func openTodo(_ t: Todo) {
        if let q = t.ask { newChat(project: t.project); send(q) }
        else if let r = t.route { open(r) }
        else if let p = t.project { openProject(p) }
    }

    // MARK: Saving

    private var store: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Hermit") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats.json")
    }

    private struct Saved: Codable { var conversations: [Conversation]; var memory: [String] }

    private func save() {
        guard persist, let url = store else { return }
        let data = Saved(conversations: conversations, memory: memory)
        Task.detached(priority: .utility) {
            if let json = try? JSONEncoder().encode(data) { try? json.write(to: url, options: .atomic) }
        }
    }

    private func load() {
        guard let url = store, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        conversations = saved.conversations
        memory = saved.memory
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
    }
}
