import SwiftUI
import Observation
import HermitCore
import HermitModel
import HermitWallet

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
    /// The Add funds sheet, opened from anywhere (Trade, Wallets, Earn). RootView presents it.
    var fundGoal: FundGoal?
    public var busy = false
    /// Short confirmation shown at the bottom; set it with `toast(_:)`.
    public var toastText: String?
    /// What Hermit calls you, asked on first launch and editable in Settings > Profile. Empty until then.
    public var user = "" {
        didSet {
            if persist { UserDefaults.standard.set(user, forKey: Self.nameKey) }
            pushContext()
        }
    }
    static let nameKey = "hermit.userName"

    // Conversations
    /// Every saved chat, newest first. Recents are the ones outside a project.
    public var conversations: [Conversation] = []
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
    /// hermit.md: what Hermit remembers in every chat (edited in Settings > Memory).
    public var memory: [String] { MemoryStore.shared.items }
    /// Titles of approvals that went through, so cards can show their after-state (sent, live, key added).
    public var approvedIDs: Set<String> = []
    /// Goes up by one each time an approval goes through. Pages compare it to know a sheet was approved, not cancelled.
    public private(set) var approvalCount = 0
    /// Bumped by ⌘K so the chat box takes focus.
    public var focusTick = 0
    /// iPhone: the sidebar drawer.
    public var drawerOpen = false
    /// Sidebar shape kept for other pages: (name, colour).
    public var projects: [(String, Color)] { projectList.map { ($0.name, $0.color) } }
    /// Titles of standalone chats, newest first.
    public var recents: [String] { recentConversations.map(\.title) }
    public var recentConversations: [Conversation] { conversations.filter { $0.project == nil } }
    public func chats(in project: String) -> [Conversation] { conversations.filter { $0.project == project } }
    public func project(_ name: String?) -> Project? { projectList.first { $0.name == name } }

    private let agent: Agent
    private var replyTask: Task<Void, Never>?
    /// Off for snapshots and the Debug Mac tour: nothing is written back.
    var persist: Bool

    /// The on-device models (download, pick, delete).
    public let models: ModelStore

    /// Defaults to the mode agent: the on-device model, or Private Cloud (NEAR AI, TEE) when picked in the chat box.
    public init(agent: Agent? = nil, models: ModelStore? = nil) {
        let models = models ?? .shared
        self.models = models
        self.agent = agent ?? ModeAgent(local: HybridAgent(store: models))
        persist = !SnapshotMode.active
        #if DEBUG
        // `-hermitFresh YES`: start like a new install (no saved chats or name read, nothing written back), so store
        // screenshots never show this Mac's own history.
        if UserDefaults.standard.bool(forKey: "hermitFresh") { persist = false }
        #endif
        if persist {
            user = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
            load()
        }
        #if DEBUG
        applyLaunchArguments()
        #endif
        pushContext()
        // First launch: Hermit's model starts downloading by itself (on Wi-Fi; mobile data asks first). Not in
        // snapshots, the Debug tour or tests.
        if persist && NSClassFromString("XCTestCase") == nil { models.autoStart() }
    }

    #if DEBUG
    /// Debug builds only: `-hermitUser Rahul -hermitRoute trade -hermitTab markets -hermitDrawer YES` opens the app on
    /// a given screen; `-hermitDownload YES` starts the selected model's download. Used by the simulator scripts
    /// (scripts/phone-shots.sh screenshots every page).
    private func applyLaunchArguments() {
        let d = UserDefaults.standard
        if let u = d.string(forKey: "hermitUser") { user = u }
        if let r = d.string(forKey: "hermitRoute").flatMap(Route.init(rawValue:)) { open(r, tab: d.string(forKey: "hermitTab")) }
        if route == .home, tabRequest == "help" { tabRequest = nil; showHelp() }
        if d.bool(forKey: "hermitDrawer") { drawerOpen = true }
        if d.bool(forKey: "hermitDownload") { models.download(models.selectedID) }
        if let m = d.string(forKey: "hermitMode").flatMap({ ChatMode(rawValue: $0) }) { d.set(m.rawValue, forKey: ChatMode.key) }
        if let q = d.string(forKey: "hermitAsk"), !q.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                // -hermitAttach csv|pdf|photo: the message goes with a generated file (Debug/DebugFixtures.swift).
                if let k = d.string(forKey: "hermitAttach"), !k.isEmpty { DebugFixtures.ask(q, attach: k, model: self) } else { self.send(q) }
            }
        }
    }
    #endif

    /// Hands the name and hermit.md to the model's system prompt (used from the next new chat).
    public func pushContext() { agent.setContext(name: user, memory: memory) }

    public var inChat: Bool { !messages.isEmpty }

    /// Shows a toast over whatever is in front (page or sheet). See ToastCenter.
    public func toast(_ text: String) { ToastCenter.shared.show(text) }

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
        pushContext()
        replyTask?.cancel(); agent.reset(); messages = []; busy = false; route = .home
        currentID = nil; chatProject = project; drawerOpen = false; batchFile = nil
        focusTick += 1
    }

    public func newChat() { newChat(project: nil) }

    /// Get help: a new chat that opens with a short explainer.
    public func showHelp() {
        newChat()
        messages = [Message(role: .user, text: "How does Hermit work?"),
                    Message(role: .assistant, text: "Ask anything in chat. Hermit answers with a model that runs on this device, so it works offline and nothing you type leaves it. Attach a text file (plain text, Markdown, CSV, JSON or code) to ask about it, and say \"remember …\" to add a note to hermit.md. Your wallets are under Wallets.")]
    }

    /// Reopen a saved conversation.
    public func openConversation(_ id: String) {
        guard let c = conversations.first(where: { $0.id == id }) else { return }
        commit()
        // The model starts this one fresh: it doesn't carry the other chat's context in.
        replyTask?.cancel(); agent.reset(); busy = false
        messages = c.messages; currentID = id; chatProject = c.project; batchFile = nil
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
        messages.append(Message(role: .user, text: text, attachment: attachment))
        let reply = Message(role: .assistant, done: false)
        messages.append(reply)
        busy = true
        let stream: AsyncStream<AgentEvent>
        if let item = attachment == nil ? ScriptedAgent.memoryItem(text) : nil {
            MemoryStore.shared.append(item)
            pushContext()
            stream = ScriptedAgent(pace: SnapshotMode.active ? 0 : 0.5).stream(ScriptedAgent.memoryScript(item))
        } else if let a = attachment, let rows = a.recipients, !rows.isEmpty, MoneyIntent.asksToMultisend(text) {
            // "Send 25 USDC to everyone in this sheet": the app reads the list from the user's own file and opens the
            // batch review itself; the model never retypes 50 addresses. Approve still needs Face ID.
            batchFile = (a.name, rows)
            stream = Self.batchFromFile(text, file: a.name, rows: rows)
        } else if let a = attachment {
            if a.recipients?.isEmpty == false { batchFile = (a.name, a.recipients!) }
            if let body = a.text {
                stream = agent.reply(to: Self.prompt(text, with: a, body))
            } else {
                stream = ScriptedAgent(pace: 0).say(Self.unreadable(a))
            }
        } else if let f = batchFile, MoneyIntent.asksToMultisend(text) || Self.answersNetwork(text) {
            // The follow-up to "which network?" for the list attached earlier in this chat.
            stream = Self.batchFromFile(text, file: f.name, rows: f.rows)
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

    /// What the model sees for a message with a readable file: what it is and how much of it is included, the file
    /// between markers, then the question.
    static func prompt(_ question: String, with a: Attachment, _ body: String) -> String {
        var about: [String] = []
        if let d = a.detail { about.append(d) }
        if let c = a.cutNote { about.append("only \(c) are included, the file is longer") }
        else if a.truncated { about.append("only the first \(Attachment.maxChars) characters, the file is longer") }
        let note = about.isEmpty ? "" : " (" + about.joined(separator: "; ") + ")"
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(the file is empty)" : body
        return "The user attached the file \(a.name)\(note):\n<file>\n\(content)\n</file>\n\n\(question)"
    }

    /// Why a file gave no text, in plain words.
    static func unreadable(_ a: Attachment) -> String {
        switch a.kind {
        case .chart: return "I didn't find any text in \(a.name). On this device I read the text in images (receipts, screenshots, tables), but I can't describe pictures yet."
        case .paper: return "I couldn't read text from \(a.name)\(a.detail.map { " (\($0))" } ?? ""). If it's protected, export it again without a password."
        case .sheet: return "I couldn't open \(a.name). Save it as .xlsx or CSV and attach it again."
        default: return "I can't read \(a.name) yet. On this device I read text files (plain text, Markdown, CSV, JSON, code), spreadsheets (.xlsx), PDFs and the text in images."
        }
    }

    /// The address and amount rows of the last file attached in this chat, for a batch send asked for later.
    var batchFile: (name: String, rows: [RecipientTable.Row])?

    /// A short reply that only names a network ("on Base", "arbitrum"): the answer to the batch's "which network?".
    static func answersNetwork(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.count <= 24 && ChainWords.mentioned(in: t).count == 1
            && t.range(of: #"^(on |use |via |the )?[a-z ]+( please| network| chain)?$"#, options: .regularExpression) != nil
    }

    /// The batch review for a list in the user's file: token and network from what they typed (or the file's only
    /// option), each row's own amount, or "25 each" for all. Streams one short reply with the review button.
    static func batchFromFile(_ text: String, file: String, rows: [RecipientTable.Row]) -> AsyncStream<AgentEvent> {
        AsyncStream { cont in
            let task = Task { @MainActor in
                defer { cont.finish() }
                cont.yield(.status("Reading \(rows.count) row\(rows.count == 1 ? "" : "s") from \(file)…"))
                let p = MoneyIntent.parts(text)
                let each = text.lowercased().range(of: #"\b(each|every|per)\b"#, options: .regularExpression) != nil ? p.amount : nil
                guard let symbol = p.symbol ?? (text.lowercased().contains("eth") ? "ETH" : nil) else {
                    cont.yield(.steps(1))
                    cont.yield(.text("I found \(rows.count) address\(rows.count == 1 ? "" : "es") in \(file). Which token should go out, and on which network? For example: send USDC on Base to everyone in this file."))
                    return
                }
                let recips: [[String: Any]] = rows.prefix(WalletService.batchMax + 1).map { ["address": $0.address, "amount": $0.amount.isEmpty ? (each ?? "") : $0.amount] }
                var args: [String: Any] = ["symbol": symbol, "recipients": recips]
                if let c = p.chain { args["chain"] = c }
                cont.yield(.status("Checking every address and your balance…"))
                let out: ToolOutcome
                do { out = try await HermitToolbox.prepareMultisend(args, origin: .user, source: file) }
                catch { out = HermitToolbox.json(["error": (error as? CustomStringConvertible)?.description ?? "\(error)"]) }
                cont.yield(.steps(2))
                cont.yield(.block(.text("")))
                cont.yield(.text(batchReply(out, file: file)))
                if let a = out.action { cont.yield(.block(.actions([a]))) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// The reply for a file batch, from the tool's result.
    static func batchReply(_ out: ToolOutcome, file: String) -> String {
        guard let v = JSONValue.parse(out.content) else { return "I couldn't check that list." }
        if let q = v["question"]?.string { return q }
        if let e = v["error"]?.string { return e }
        let reasons: [String] = { if case .array(let r)? = v["reasons"] { return r.compactMap(\.string) }; return [] }()
        let n = v["recipients"].flatMap { if case .number(let s) = $0 { return Int(s) }; return nil } ?? 0
        let total = v["total"]?.string ?? "", net = v["network"]?.string ?? ""
        var left: [String] = []
        if case .array(let l)? = v["left_out"] { left = l.compactMap(\.string) }
        var s = n > 0 ? "\(file) has **\(n) recipient\(n == 1 ? "" : "s")**, \(total) in total on \(net)." : ""
        if !left.isEmpty {
            let more = (v["left_out_count"].flatMap { if case .number(let x) = $0 { return Int(x) }; return nil } ?? left.count) - left.count
            s += " Left out: " + left.joined(separator: "; ") + (more > 0 ? ", and \(more) more" : "") + "."
        }
        if !reasons.isEmpty { return (s.isEmpty ? "" : s + " ") + "It can't go out yet: " + reasons.joined(separator: " ") }
        return s + " Review the list below. One \(Device.bio) approval sends them one after another, and you can follow each transfer here."
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
                // The step list under "n steps" names what was done; waiting lines aren't steps.
                if !s.hasPrefix("Thinking") && !s.hasPrefix("Waking up") { m.tools.append(s.hasSuffix("…") ? String(s.dropLast()) : s) }
            case .steps(let n): m.steps = n; m.status = nil
            case .text(let chunk):
                if case .text(let t)? = m.blocks.last { m.blocks[m.blocks.count - 1] = .text(t + chunk) } else { m.text += chunk }
            case .card(let c): m.card = c
            case .actions(let a): m.actions = a
            case .block(let b): m.blocks.append(b)
            case .proof(let p): m.proof = p
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
        else if let o = action.open {
            switch o {
            case "fund-hyperliquid": fundGoal = .hyperliquid
            case "swap": open(.wallets, tab: "swap")
            case let o where o.hasPrefix("batch:"): BatchStore.shared.review(String(o.dropFirst("batch:".count)), model: self)
            case let o where o.hasPrefix("earn-deposit:"): EarnFlow.open(link: o, model: self)
            case "earn-positions": open(.earn, tab: "positions")
            default: fundGoal = .wallet
            }
        }
        else if let q = action.ask { ask(q) }
        else if let r = action.reply { react(action.title, r) }
        else if let t = action.toast { toast(t) }
        else { send(action.title) }
    }

    /// Called by the approval sheet once Touch ID / Face ID passed and the move went through.
    public func approved(_ a: Approval) {
        approval = nil
        approvedIDs.insert(a.title)
        approvalCount += 1
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

    private struct Saved: Codable { var conversations: [Conversation] }
    /// 2: no more seeded demo chats or memory. Installs from before saved them, so they are dropped once.
    private static let dataVersion = 2
    private static let versionKey = "hermit.dataVersion"

    private func save() {
        guard persist, let url = store else { return }
        let data = Saved(conversations: conversations)
        Task.detached(priority: .utility) {
            if let json = try? JSONEncoder().encode(data) { try? json.write(to: url, options: .atomic) }
        }
    }

    private func load() {
        if let url = store, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            conversations = saved.conversations
        }
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.versionKey) < Self.dataVersion {
            // The demo's chats had fixed ids; real ones are UUIDs.
            conversations.removeAll { UUID(uuidString: $0.id) == nil }
            MemoryStore.shared.dropDemoSeed()
            defaults.set(Self.dataVersion, forKey: Self.versionKey)
            save()
        }
    }

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
    }
}
