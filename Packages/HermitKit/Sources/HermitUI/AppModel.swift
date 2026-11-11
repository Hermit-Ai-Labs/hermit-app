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
    public var approval: Approval? {
        didSet {
            guard !settingApproval else { return }
            // The sheet closed: whatever it signed has reported back.
            if approval == nil { signing.removeAll(); signingTitles.removeAll(); return }
            guard let a = approval, a.uid != oldValue?.uid else { return }
            settingApproval = true; defer { settingApproval = false }
            // From Approve until the sheet reports back (it locks itself), a new review can't replace it, and the same
            // move asked again is ignored. A move that failed frees the sheet at once.
            // The replacements below write the stored value itself: reviews compare by what they show (not uid or
            // perform), so going through the observed setter could drop an assignment it sees as equal.
            if let old = oldValue, signing.contains(old.uid) { _approval = old; toast("Wait for the last approval to finish", kind: .info); return }
            if signingTitles.contains(a.title) { _approval = oldValue; toast("That one is still being signed", kind: .info); return }
            guard let inner = a.perform else { return }
            var tracked = a
            let uid = a.uid, title = a.title
            tracked.perform = { @Sendable () async throws -> String in
                await self.markSigning(uid, title, true)
                do {
                    return try await inner()
                } catch {
                    await self.markSigning(uid, title, false)
                    throw error
                }
            }
            _approval = tracked
        }
    }
    /// Reviews whose `perform` is running or has finished but not reported back yet, by request and by title.
    @ObservationIgnored private var signing: Set<UUID> = []
    @ObservationIgnored private var signingTitles: Set<String> = []
    /// True while `approval`'s didSet replaces the value it was given, so that assignment isn't checked again.
    @ObservationIgnored private var settingApproval = false
    private func markSigning(_ uid: UUID, _ title: String, _ on: Bool) {
        if on { signing.insert(uid); signingTitles.insert(title) } else { signing.remove(uid); signingTitles.remove(title) }
    }
    /// The Add funds sheet, opened from anywhere (Trade, Wallets, Earn). RootView presents it.
    var fundGoal: FundGoal?
    public var busy = false
    /// Short confirmation shown at the bottom; set it with `toast(_:)`.
    public var toastText: String?
    /// A file dropped anywhere on the chat; the composer picks it up and attaches it.
    public var droppedFile: URL?
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
    /// Its project.md goes into the model's instructions (see `pushContext`).
    public var chatProject: String? { didSet { if chatProject != oldValue && !switchingChat { pushContext(onlyIfChanged: true) } } }

    // Projects, automations, project.md, paused costs and to-dos are saved with the chats (chats.json) on every change.
    public var projectList: [Project] = Project.seed { didSet { save() } }
    /// The project page open on the Projects route (nil shows the list).
    public var projectOpen: String?
    /// Costs switched off on a project page, "project/what".
    public var costsOff: Set<String> = [] { didSet { save() } }
    /// Edited project.md per project.
    public var projectMD: [String: String] = [:] { didSet { save(); pushContext(onlyIfChanged: true) } }

    // Automations
    public var automations: [Automation] = Automation.seed { didSet { save(); AutomationScheduler.shared.changed(self) } }
    /// The automation thread open on the Automations route: a name, or a new draft from a sentence.
    public var automationOpen: AutomationOpen?
    public enum AutomationOpen: Hashable { case existing(String), new(String) }

    // Everything else
    public var todos: [Todo] = Todo.seed { didSet { save() } }
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
    /// A photo, screenshot or scanned PDF was read with text recognition in this chat. A batch the assistant prepares
    /// then refuses addresses without a checksum (a misread character still parses). Mirrored for the toolbox.
    public var pictureInChat = false { didSet { HermitToolbox.pictureInChat = pictureInChat } }
    /// Sidebar shape kept for other pages: (name, colour).
    public var projects: [(String, Color)] { projectList.map { ($0.name, $0.color) } }
    /// Titles of standalone chats, newest first.
    public var recents: [String] { recentConversations.map(\.title) }
    public var recentConversations: [Conversation] { conversations.filter { $0.project == nil } }
    public func chats(in project: String) -> [Conversation] { conversations.filter { $0.project == project } }
    public func project(_ name: String?) -> Project? { projectList.first { $0.name == name } }

    private let agent: Agent
    private var replyTask: Task<Void, Never>?
    /// Goes up with every reply started or dropped, so a cancelled reply's tail never clears `busy` or saves for a newer one.
    @ObservationIgnored private var replyGen = 0
    /// What the agent last got for its system prompt, so the same context isn't sent (and prefilled) twice.
    @ObservationIgnored private var pushedName: String?
    @ObservationIgnored private var pushedNotes: [String]?
    /// True while `load()` fills the saved state in, so restoring doesn't write it straight back.
    @ObservationIgnored private var restoring = false
    /// True while newChat / openConversation set the project; they push the context themselves once.
    @ObservationIgnored private var switchingChat = false
    @ObservationIgnored private var flushObserver: NSObjectProtocol?
    /// Off for snapshots and the Debug Mac tour: nothing is written back.
    var persist: Bool

    /// The on-device models (download, pick, delete).
    public let models: ModelStore

    /// Defaults to the mode agent: the on-device model, or Private Cloud (NEAR AI, TEE) when picked in the chat box.
    public init(agent: Agent? = nil, models: ModelStore? = nil) {
        ToolChat.bioWord = Device.bio
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
            // Quitting (Mac) or leaving the app (iPhone) writes the open chat at once, so its last reply is never lost.
            #if os(macOS)
            let leave = NSApplication.willTerminateNotification
            #else
            let leave = UIApplication.didEnterBackgroundNotification
            #endif
            flushObserver = NotificationCenter.default.addObserver(forName: leave, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        #if DEBUG
        applyLaunchArguments()
        #endif
        pushContext()
        // First launch: Hermit's model starts downloading by itself (on Wi-Fi; mobile data asks first). Not in
        // snapshots, the Debug tour or tests.
        if persist && NSClassFromString("XCTestCase") == nil {
            models.autoStart()
            // Scheduled automations run while the app is open (AutomationScheduler.swift).
            AutomationScheduler.shared.attach(self)
        }
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

    /// Hands the name, hermit.md and the open project's project.md to the model's system prompt (used from the next
    /// new chat, or right away if this one hasn't started).
    public func pushContext() { pushContext(onlyIfChanged: false) }

    /// `onlyIfChanged`: for project and project.md changes, which can fire often; the same context isn't sent twice.
    private func pushContext(onlyIfChanged: Bool) {
        var notes = memory
        if let p = projectNote() { notes.insert(p, at: 0) }
        if onlyIfChanged && pushedName == user && pushedNotes == notes { return }
        pushedName = user; pushedNotes = notes
        agent.setContext(name: user, memory: notes)
    }

    /// The open project's project.md as one note for the system prompt: nil when there's no project, or its
    /// instructions are still the placeholder. The heading line is dropped and the text is capped like hermit.md.
    func projectNote() -> String? {
        guard let p = project(chatProject), let md = projectMD[p.name] else { return nil }
        var body = md.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body != p.defaultInstructions else { return nil }
        if body.hasPrefix("# ") {
            let rest = body.firstIndex(of: "\n").map { body[$0...] }
            body = rest.map(String.init) ?? ""
        }
        let text = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return "This chat is in the user's project \(p.name). Follow its instructions (project.md): " + String(text.prefix(1500))
    }

    public var inChat: Bool { !messages.isEmpty }

    /// Shows a toast over whatever is in front (page or sheet). See ToastCenter.
    public func toast(_ text: String) { ToastCenter.shared.show(text) }
    /// A toast whose kind the caller knows (a failure is `.error`, so it never shows the green check).
    func toast(_ text: String, kind: ToastCenter.Kind) { ToastCenter.shared.show(text, kind: kind) }

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
        // Stop the reply first, so the chat is saved as it stands and its tail can't touch the new one.
        replyTask?.cancel(); replyGen &+= 1
        cancelBackgroundRun()
        commit()
        switchingChat = true; chatProject = project; switchingChat = false
        pushContext()
        agent.reset(); messages = []; busy = false; route = .home
        currentID = nil; drawerOpen = false; batchFile = nil; pictureInChat = false
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
        replyTask?.cancel(); replyGen &+= 1
        cancelBackgroundRun()
        commit()
        // The model starts this one fresh: it doesn't carry the other chat's context in.
        agent.reset(); busy = false
        messages = c.messages; currentID = id; batchFile = nil; pictureInChat = false
        switchingChat = true; chatProject = c.project; switchingChat = false
        // Only when the context changed: an unchanged one is already the agent's, and reset() keeps it.
        pushContext(onlyIfChanged: true)
        route = .home; drawerOpen = false
    }

    public func deleteConversation(_ id: String) {
        withAnimation(.snappy) { conversations.removeAll { $0.id == id } }
        if currentID == id {
            // Deleting the open chat stops its reply and clears the model, so the next chat doesn't start inside it.
            replyTask?.cancel(); replyGen &+= 1; cancelBackgroundRun(); agent.reset(); busy = false
            messages = []; currentID = nil; batchFile = nil; pictureInChat = false
        }
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
        // You come first: an automation answering in the background stops (it runs again on a later check), and the
        // model starts this message from your chat, not from the automation's.
        cancelBackgroundRun()
        lastSendAt = Date()
        route = .home; drawerOpen = false
        if currentID == nil {
            let c = Conversation(title: String(text.prefix(60)), project: chatProject, when: "Today", messages: [])
            currentID = c.id
            withAnimation(.snappy) { conversations.insert(c, at: 0) }
        }
        if attachment?.readFromPicture == true { pictureInChat = true }
        // Read before this message goes in: did Hermit's last reply ask which network?
        let askedNetwork = Self.asksNetwork(messages.last { $0.role == .assistant })
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
            // A newer file replaces the list: one without rows (a receipt) leaves no list from an older file behind.
            batchFile = nil
            if let rows = a.recipients, !rows.isEmpty { batchFile = (a.name, rows) }
            if let body = a.text {
                stream = agent.reply(to: Self.prompt(text, with: a, body))
            } else {
                stream = ScriptedAgent(pace: 0).say(Self.unreadable(a))
            }
        } else if let f = batchFile, MoneyIntent.asksToMultisend(text) || (askedNetwork && Self.answersNetwork(text)) {
            // The follow-up to "which network?" for the list attached earlier in this chat. A bare chain name only
            // counts as that answer right after Hermit asked for one.
            stream = Self.batchFromFile(text, file: f.name, rows: f.rows)
        } else {
            stream = agent.reply(to: text)
        }
        replyGen &+= 1
        let gen = replyGen
        replyTask = Task { [weak self] in
            for await event in stream {
                self?.apply(event, to: reply.id)
            }
            // A newer reply (or another chat) took over: this one's tail leaves busy and saving to it.
            guard let self, self.replyGen == gen else { return }
            self.update(reply.id) { $0.done = true; $0.status = nil }
            self.busy = false
            self.commit()
        }
    }

    /// Whether a reply asked the user to pick a network (its plain text or its text blocks).
    static func asksNetwork(_ m: Message?) -> Bool {
        guard let m else { return false }
        let texts: [String] = [m.text] + m.blocks.compactMap { (b: Block) -> String? in
            if case .text(let t) = b { return t }
            return nil
        }
        return texts.contains { $0.lowercased().contains("network") && $0.contains("?") }
    }

    /// What the model sees for a message with a readable file: what it is and how much of it is included, the file
    /// between markers, then the question.
    static func prompt(_ question: String, with a: Attachment, _ body: String) -> String {
        var about: [String] = []
        if let d = a.detail { about.append(d) }
        if let c = a.cutNote { about.append("only \(c) are included, the file is longer") }
        else if a.truncated { about.append("only the first \(Attachment.maxChars) characters, the file is longer") }
        let note = about.isEmpty ? "" : " (" + about.joined(separator: "; ") + ")"
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(the file is empty)" : ToolChat.fileSafe(body)
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
                // Beyond the fixed list: SOL or a ticker written with its amount ("0.1 SOL each", "500 BONK"), for Solana.
                let ticker = p.symbol == nil ? MoneyIntent.batchTicker(text) : nil
                let said = text.lowercased().range(of: #"\b(each|every|per)\b"#, options: .regularExpression) != nil
                let each = said ? (ticker != nil ? ticker?.amount : p.amount) : nil
                guard let symbol = p.symbol ?? ticker?.symbol ?? (text.lowercased().contains("eth") ? "ETH" : nil) else {
                    cont.yield(.steps(1))
                    cont.yield(.text("I found \(rows.count) address\(rows.count == 1 ? "" : "es") in \(file). Which token should go out, and on which network? For example: send USDC on Base to everyone in this file."))
                    return
                }
                let recips: [[String: Any]] = rows.prefix(WalletService.batchMax + 1).map { ["address": $0.address, "amount": $0.amount.isEmpty ? (each ?? "") : $0.amount] }
                var args: [String: Any] = ["symbol": symbol, "recipients": recips]
                if let c = p.chain { args["chain"] = c }
                cont.yield(.status("Checking every address and your balance…"))
                let out: ToolOutcome
                // A list read from a picture can misread a character and still parse, so the checksum rule holds here too.
                do { out = try await HermitToolbox.prepareMultisend(args, origin: .user, source: file, fromPicture: HermitToolbox.pictureInChat) }
                catch { out = HermitToolbox.json(["error": HermitToolbox.message(error)]) }
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
        // Solana: recipients without a token account for this token get one, and the sender pays its rent.
        if let rent = v["account_rent"]?.string, !s.isEmpty { s += " Account rent: \(rent)." }
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
        update(id) { Self.fold(event, into: &$0) }
    }

    /// One agent event written into a reply (the visible chat's, or a background run's).
    static func fold(_ event: AgentEvent, into m: inout Message) {
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
            case "fund-wallet": fundGoal = .wallet
            case "fund-hyperliquid": fundGoal = .hyperliquid
            case "swap": open(.wallets, tab: "swap")
            case let o where o.hasPrefix("batch:"): BatchStore.shared.review(String(o.dropFirst("batch:".count)), model: self)
            case let o where o.hasPrefix("earn-deposit:"): EarnFlow.open(link: o, model: self)
            case "earn-positions": open(.earn, tab: "positions")
            case let o where o.hasPrefix("agent-swap:"):
                // A swap an automation prepared in the background: its review opens only now, when you ask for it.
                if let i = heldSwaps[String(o.dropFirst("agent-swap:".count))] {
                    WalletsViewModel.shared.pendingSwap = i
                    open(.wallets, tab: "agent-swap")
                } else { toast("That review has expired. Ask Hermit again.", kind: .info) }
            case let o where o.hasPrefix("page:"):
                // open_page's button: a page of the app, optionally on one of its tabs. Only what the allow-list holds.
                let parts = o.dropFirst("page:".count).split(separator: ":").map(String.init)
                if let first = parts.first, let target = ToolsV3.pageTarget(first, tab: parts.count > 1 ? parts[1] : nil) { open(target.route, tab: target.tab) }
                else { toast("That link isn't available anymore", kind: .info) }
            case let o where o.hasPrefix("app:"):
                // open_app's button: a site in Hermit's browser. Nothing connects until the user approves the connect sheet.
                if let u = DappBrowserSession.normalize(String(o.dropFirst("app:".count))) {
                    let name = u.host().flatMap { DappBrowser.directoryName(for: $0) }
                    DappBrowser.shared.open(u, dapp: ExploreData.dapps.first { $0.name == name }, model: self)
                } else { toast("That link isn't available anymore", kind: .info) }
            case let o where o.hasPrefix("chat:"):
                let id = String(o.dropFirst("chat:".count))
                if conversations.contains(where: { $0.id == id }) { openConversation(id) } else { toast("That chat was deleted", kind: .info) }
            // A link this build doesn't know (a typo, or one saved by an older version) opens nothing.
            default: toast("That link isn't available anymore", kind: .info)
            }
        }
        else if let q = action.ask { ask(q) }
        else if let r = action.reply { react(action.title, r) }
        else if let t = action.toast { toast(t) }
        else { send(action.title) }
    }

    /// Called by the approval sheet once Touch ID / Face ID passed and the move went through.
    public func approved(_ a: Approval, hash: String? = nil) {
        approval = nil
        // A demo trade (no `perform`, only `live`) placed nothing: a release build never posts "Order filled" for it.
        #if DEBUG
        let demoOnly = false
        #else
        let demoOnly = !SnapshotMode.active && a.perform == nil && hash == nil && a.live != nil
        #endif
        if demoOnly { toast("Trading from chat is coming soon"); return }
        // A site's request (Dapp browser) is named by the site ("Approve USDC", "Contract call"). It must never mark a
        // chat card with the same title as done or take its button away, so it is only confirmed with a toast.
        if Self.fromSite(a) {
            approvalCount += 1
            toast(a.success)
            return
        }
        approvedIDs.insert(a.title)
        approvalCount += 1
        guard route == .home, inChat else { toast(a.success); return }
        // The button that opened this review is done: take it out of every message it was in.
        for i in messages.indices {
            messages[i].actions.removeAll { $0.approval == a }
            messages[i].blocks = messages[i].blocks.compactMap { b in
                if case .actions(let list) = b {
                    let kept = list.filter { $0.approval != a }
                    return kept.isEmpty ? nil : .actions(kept)
                }
                return b
            }
        }
        withAnimation(.smooth) {
            if let r = a.receipt {
                messages.append(Message(role: .assistant, blocks: [.card(r)]))
            } else {
                // "Sent 0.5 USDC. Tx 0xeb32…5a95": the hash is in Activity with its explorer link.
                // A Hyperliquid fill ("Filled 0.5 at $72.2") is a result line, not a hash: shown as it is.
                let tx = hash.flatMap { $0.isEmpty ? nil : $0 }.map { h in !TxText.looksLikeHash(h) ? " " + h : h.count > 16 ? " Tx \(h.prefix(8))…\(h.suffix(6))" : " Tx \(h)" } ?? ""
                messages.append(Message(role: .assistant, text: a.success + "." + tx, note: true))
            }
            if let live = a.live { messages.append(Message(role: .assistant, blocks: [.card(.liveTrade(live))])) }
        }
        commit()
    }

    /// Requests from a web page in the Dapp browser (DappProvider's kinds), not from chat or a page of the app.
    static func fromSite(_ a: Approval) -> Bool {
        a.kind == "Connect a site" || ["Transaction from ", "Signature request from ", "Sign-in request from "].contains { a.kind.hasPrefix($0) }
    }

    // MARK: Background runs (scheduled automations)

    /// What a background run left: its new saved chat, the reply, and whether that reply holds a money review waiting
    /// for the user (a prepared send, swap, batch or deposit). Nothing was approved: reviews only open from a tap.
    struct BackgroundReply {
        let chatID: String
        let reply: Message
        let needsApproval: Bool
    }

    /// The reply an automation is writing in the background (nil when none). The visible chat never waits on it.
    @ObservationIgnored private var backgroundTask: Task<Message?, Never>?
    /// Goes up with every background run started or stopped, so a stopped run's tail never resets the model again.
    @ObservationIgnored private var backgroundGen = 0
    /// Swaps an automation prepared, kept until the user opens their review from the automation's chat ("agent-swap:<id>").
    @ObservationIgnored private var heldSwaps: [String: SwapIntent] = [:]
    @ObservationIgnored private var heldNow: [String] = []
    /// When the user last sent a message: a background run waits until they have been quiet for a moment.
    @ObservationIgnored private var lastSendAt = Date.distantPast

    var backgroundRunActive: Bool { backgroundTask != nil }

    /// Hermit is free for an automation: no reply streaming, no approval sheet open, no other run, the user isn't in
    /// the middle of a back-and-forth, and the model that would answer is there.
    var canRunInBackground: Bool {
        guard persist, !busy, approval == nil, backgroundTask == nil, !user.isEmpty else { return false }
        guard Date().timeIntervalSince(lastSendAt) >= 30 else { return false }
        return ChatMode.current == .cloud || models.readyModel != nil
    }

    /// Answers `prompt` in a new saved chat without touching the open one: no route change, `messages`, `currentID` and
    /// `busy` stay as they are. The chat is added to the list only once the reply is complete. Returns nil when the run
    /// didn't finish (the user sent a message, started or opened a chat, or the app left the screen); it can run again.
    /// The model is shared, so the open chat's next message starts the model fresh, as reopening a chat does.
    func runInBackground(_ prompt: String, title: String) async -> BackgroundReply? {
        guard !busy, backgroundTask == nil else { return nil }
        backgroundGen &+= 1
        let gen = backgroundGen
        heldNow = []
        // A fresh conversation with the name and hermit.md, but no project's instructions.
        agent.reset()
        agent.setContext(name: user, memory: memory)
        pushedName = nil; pushedNotes = nil
        let stream = agent.reply(to: prompt)
        let task = Task { () -> Message? in
            var m = Message(role: .assistant, done: false)
            for await event in stream { AppModel.fold(event, into: &m) }
            return Task.isCancelled ? nil : m
        }
        backgroundTask = task
        let answer = await task.value
        // Stopped for the user's own chat: that path already reset the model and gave it the open chat's context.
        guard backgroundGen == gen else { return nil }
        backgroundTask = nil
        agent.reset(); pushContext()
        let held = heldNow
        heldNow = []
        guard var reply = answer else {
            for id in held { heldSwaps[id] = nil }
            return nil
        }
        reply.done = true; reply.status = nil
        if !held.isEmpty {
            reply.blocks.append(.actions(held.enumerated().map { i, id in
                Action(i == 0 ? "Review the swap" : "Review swap \(i + 1)", primary: true, symbol: "arrow.left.arrow.right", open: "agent-swap:" + id)
            }))
        }
        let c = Conversation(title: String(title.prefix(60)), project: nil, when: "Today",
                             messages: [Message(role: .user, text: prompt), reply])
        withAnimation(.snappy) { conversations.insert(c, at: 0) }
        save()
        return BackgroundReply(chatID: c.id, reply: reply, needsApproval: Self.needsApproval(reply))
    }

    /// Stops a background run (the user comes first). It runs again on a later check.
    func cancelBackgroundRun() {
        guard let t = backgroundTask else { return }
        t.cancel()
        backgroundTask = nil
        backgroundGen &+= 1
        for id in heldNow { heldSwaps[id] = nil }
        heldNow = []
        agent.reset(); pushContext()
    }

    /// prepare_swap during a background run: the review is kept for the automation's chat instead of opening Wallets
    /// over whatever the user is doing. False when no run is going (the swap review opens as usual).
    func holdForBackground(_ intent: SwapIntent) -> Bool {
        guard backgroundTask != nil else { return false }
        let id = UUID().uuidString
        heldSwaps[id] = intent
        heldNow.append(id)
        return true
    }

    /// A reply that holds a money move to review: a button with a review, a batch, deposit or held swap link, or a card
    /// with its own Approve.
    static func needsApproval(_ m: Message) -> Bool {
        func money(_ a: Action) -> Bool {
            a.approval != nil || ["batch:", "earn-deposit:", "agent-swap:"].contains { a.open?.hasPrefix($0) == true }
        }
        func pays(_ c: Card?) -> Bool {
            guard let c else { return false }
            switch c {
            // A confirm card waits for a tap too (a cancel, a contact, an automation, a payment reminder).
            case .perpTicket, .apiBuy, .inbox, .confirm: return true
            default: return false
            }
        }
        if m.actions.contains(where: money) || pays(m.card) { return true }
        return m.blocks.contains { b in
            switch b {
            case .actions(let list): return list.contains(where: money)
            case .card(let c): return pays(c)
            case .text: return false
            }
        }
    }

    /// A reply as one plain line: its text without Markdown marks, for a run's entry and history.
    static func preview(_ m: Message, max: Int = 160) -> String {
        let texts = [m.text] + m.blocks.compactMap { (b: Block) -> String? in
            if case .text(let t) = b { return t }
            return nil
        }
        let flat = texts.joined(separator: " ")
            .replacingOccurrences(of: #"[*`#>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > max ? String(flat.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
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

    /// Pause or switch on. Switching on starts its clock now, so slots missed while it was paused don't run.
    public func toggleAutomation(_ name: String) {
        guard let i = automations.firstIndex(where: { $0.name == name }) else { return }
        var a = automations[i]
        a.on.toggle()
        if a.on { a.since = Date() }
        withAnimation(.snappy) { automations[i] = a }
        if a.on {
            AutomationScheduler.shared.askPermission()
            if let next = a.upcoming() { toast("On. Next run \(Automation.dayText(next))", kind: .success) } else { toast("On", kind: .success) }
        } else {
            toast("Paused", kind: .info)
        }
    }

    /// Names are ids: saving one that already exists (a card's Save pressed twice) keeps the saved one and its runs.
    public func addAutomation(_ a: Automation) {
        guard !automations.contains(where: { $0.name == a.name }) else { return }
        withAnimation(.snappy) { automations.insert(a, at: 0) }
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

    /// 2: no more seeded demo chats or memory. Installs from before saved them, so they are dropped once.
    private static let dataVersion = 2
    private static let versionKey = "hermit.dataVersion"

    /// Queues a write of everything saved. Writes go one at a time and always carry the newest state.
    private func save() {
        guard persist, !restoring, let url = store else { return }
        let data = SavedChats(conversations: conversations, projects: projectList, projectMD: projectMD, automations: automations,
                         todos: todos, costsOff: costsOff.sorted())
        ChatsWriter.shared.write(data, to: url)
    }

    /// Saves the open chat and waits for the write (quit, or the app going to the background).
    func flush() {
        guard persist else { return }
        commit()
        ChatsWriter.shared.flushNow()
    }

    private func load() {
        restoring = true
        if let url = store, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedChats.self, from: data) {
            conversations = saved.conversations
            projectList = saved.projects
            projectMD = saved.projectMD
            // Switched on before schedules ran (no `since`): its clock starts now, so it never runs at once for an old slot.
            automations = saved.automations.map { a in
                var a = a
                if a.on && a.since == nil { a.since = Date() }
                return a
            }
            todos = saved.todos
            costsOff = Set(saved.costsOff)
            // A chat whose project wasn't saved (files from before projects were) goes back to Recents instead of hiding.
            let names = Set(projectList.map(\.name))
            for i in conversations.indices {
                if let p = conversations[i].project, !names.contains(p) { conversations[i].project = nil }
            }
        }
        restoring = false
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

/// What chats.json holds. Files from before projects and automations were saved have only `conversations`.
private struct SavedChats: Codable, @unchecked Sendable {
    var conversations: [Conversation]
    var projects: [Project]
    var projectMD: [String: String]
    var automations: [Automation]
    var todos: [Todo]
    var costsOff: [String]

    enum CodingKeys: String, CodingKey { case conversations, projects, projectMD, automations, todos, costsOff }

    init(conversations: [Conversation], projects: [Project], projectMD: [String: String], automations: [Automation],
         todos: [Todo], costsOff: [String]) {
        self.conversations = conversations; self.projects = projects; self.projectMD = projectMD
        self.automations = automations; self.todos = todos; self.costsOff = costsOff
    }

    // A part that doesn't decode is left empty instead of losing the chats with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decode([Conversation].self, forKey: .conversations)
        projects = (try? c.decodeIfPresent([Project].self, forKey: .projects)) ?? []
        projectMD = (try? c.decodeIfPresent([String: String].self, forKey: .projectMD)) ?? [:]
        automations = (try? c.decodeIfPresent([Automation].self, forKey: .automations)) ?? []
        todos = (try? c.decodeIfPresent([Todo].self, forKey: .todos)) ?? []
        costsOff = (try? c.decodeIfPresent([String].self, forKey: .costsOff)) ?? []
    }
}

/// Writes chats.json off the main thread, one write at a time and always the newest state: quick saves coalesce, and
/// an older snapshot can never land after a newer one.
private final class ChatsWriter: @unchecked Sendable {
    static let shared = ChatsWriter()
    private let queue = DispatchQueue(label: "hermit.chats.save", qos: .utility)
    private let lock = NSLock()
    private var pending: (url: URL, saved: SavedChats)?

    func write(_ saved: SavedChats, to url: URL) {
        let idle: Bool = lock.withLock {
            let wasIdle = pending == nil
            pending = (url, saved)
            return wasIdle
        }
        if idle { queue.async { self.writePending() } }
    }

    /// Waits for a write in progress, then writes whatever is still waiting.
    func flushNow() { queue.sync { writePending() } }

    private func writePending() {
        let next: (url: URL, saved: SavedChats)? = lock.withLock {
            let p = pending
            pending = nil
            return p
        }
        guard let next, let json = try? JSONEncoder().encode(next.saved) else { return }
        try? json.write(to: next.url, options: .atomic)
    }
}
