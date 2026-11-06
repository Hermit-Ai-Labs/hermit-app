import Foundation

/// One line in a conversation.
public struct Message: Identifiable, Equatable, Sendable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public let id: UUID
    public let role: Role
    /// Plain text (user messages, short notes). Rich replies put their text in `blocks`.
    public var text: String
    /// While the agent works: "Checking past payments…". Cleared when the answer starts.
    public var status: String?
    /// How many tool steps the agent took (shown as "2 steps").
    public var steps: Int
    /// The tool steps themselves, shown when "3 steps" is expanded.
    public var tools: [String]
    public var card: Card?
    /// A rich reply: text and cards in the order the agent posted them.
    public var blocks: [Block]
    public var actions: [Action]
    public var done: Bool
    /// A file the user attached to this message.
    public var attachment: Attachment?
    /// Short confirmation from the agent (green tick), e.g. "Automation on…".
    public var note: Bool
    /// Set on automation runs: "Oct 20, 09:00".
    public var run: String?

    public init(id: UUID = UUID(), role: Role, text: String = "", status: String? = nil, steps: Int = 0, tools: [String] = [],
                card: Card? = nil, blocks: [Block] = [], actions: [Action] = [], done: Bool = true,
                attachment: Attachment? = nil, note: Bool = false, run: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.status = status; self.steps = steps; self.tools = tools
        self.card = card; self.blocks = blocks; self.actions = actions; self.done = done
        self.attachment = attachment; self.note = note; self.run = run
    }
}

/// One piece of a rich reply.
public enum Block: Equatable, Sendable, Codable {
    case text(String)
    case card(Card)
    case actions([Action])
}

/// A file attached in the composer. `kind` decides how Hermit reads it.
public struct Attachment: Equatable, Sendable, Codable, Hashable, Identifiable {
    public var id: String { name }
    public enum Kind: String, Sendable, Codable { case invoice, csv, sheet, paper, chart, code, doc }
    public let name: String
    public let kind: Kind
    public let size: String
    public let source: String
    /// The file's text when Hermit can read it (plain text, markdown, CSV, JSON, code), cut to fit the model.
    /// nil for files it can't read. Not saved with the chat.
    public var text: String? = nil
    /// True when `text` is only the start of the file.
    public var truncated = false

    enum CodingKeys: String, CodingKey { case name, kind, size, source }

    public init(_ name: String, kind: Kind? = nil, size: String = "", source: String = "Device", text: String? = nil, truncated: Bool = false) {
        self.name = name; self.kind = kind ?? Attachment.kind(of: name); self.size = size; self.source = source
        self.text = text; self.truncated = truncated
    }

    /// Extensions read as text. Files without an extension are read too when they decode as text.
    public static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "ini", "xml", "html", "htm", "css",
        "js", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "sh", "zsh", "sql",
        "sol", "log", "prompt", "env", "rtf",
    ]
    /// Most characters of one file passed to the model (about 2,000 tokens, so the answer starts quickly on a phone).
    public static let maxChars = 8000

    /// Reads a file the user picked: name, size, and its text when it is a text file.
    public static func read(_ url: URL) -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var a = Attachment(url.lastPathComponent, size: bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : "")
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || textExtensions.contains(ext), let h = try? FileHandle(forReadingFrom: url) else { return a }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: maxChars * 4)) ?? Data()
        guard !data.contains(0) else { return a }
        let s = String(decoding: data, as: UTF8.self)
        // Mostly replacement characters means it isn't text after all.
        guard s.unicodeScalars.filter({ $0 == "\u{FFFD}" }).count <= max(2, s.count / 100) else { return a }
        a.text = String(s.prefix(maxChars))
        a.truncated = s.count > maxChars || bytes > data.count
        return a
    }
    public static func kind(of name: String) -> Kind {
        let n = name.lowercased()
        if n.hasSuffix(".png") || n.hasSuffix(".jpg") { return .chart }
        if n.hasSuffix(".xlsx") { return .sheet }
        if n.hasSuffix(".csv") { return .csv }
        if n.contains("invoice") { return .invoice }
        if [".ts", ".js", ".json", ".prompt", ".swift", ".py"].contains(where: n.hasSuffix) { return .code }
        if n.hasSuffix(".pdf") { return .paper }
        return .doc
    }
}

/// Colour roles a chart bar can take. Purple only for the highlighted row.
public enum Tone: String, Equatable, Sendable, Codable { case text, accent, lilac, green, red, amber }

/// Structured results the agent can post under its text. Numbers always come with a chart.
public indirect enum Card: Equatable, Sendable, Codable {
    case bars(title: String, rows: [BarRow])
    case receipt(title: String, rows: [[String]])
    /// Receipt after an approval: rows, optional stats grid, optional allocation donut and a note.
    case result(Receipt)
    case token(TokenSpec)
    /// Price since an event, as candles.
    case price(title: String, total: String, days: Int, seed: Int)
    /// PnL / balance line (not a price, so a line chart).
    case pnl(title: String, total: String, days: Int, seed: Int)
    case holders(verdict: String, clusters: [Cluster], legend: [[String]])
    case kols(onboarded: Int, rows: [Kol])
    case perpTicket(Approval)
    case flow(title: String, steps: [FlowStep])
    case news([NewsItem])
    case opportunities(title: String, items: [Opportunity])
    case catalog(group: String)
    case agentPaid(to: String, amount: String, what: String, budget: String)
    case code(String)
    case quests([Quest])
    case inbox(items: [InboxItem], approval: Approval)
    case injection(source: String, quote: String)
    case apiBuy(Approval)
    case buildProgress
    case apiCheckout
    case multiSend
    case flapLaunch
    case memory(String)
    case liveTrade(LiveTrade)
    /// Prompts to try, shown as chips.
    case suggestions([String])
}

public struct BarRow: Equatable, Sendable, Identifiable, Codable {
    public var id: String { label }
    public let label: String
    public let value: Double
    public let display: String
    public let highlight: Bool
    public var sub: String?
    public var tone: Tone
    public init(_ label: String, _ value: Double, _ display: String, highlight: Bool = false, sub: String? = nil, tone: Tone? = nil) {
        self.label = label; self.value = value; self.display = display; self.highlight = highlight
        self.sub = sub; self.tone = tone ?? (highlight ? .accent : .text)
    }
}

public struct Receipt: Equatable, Sendable, Codable {
    public var title: String
    public var rows: [[String]]
    public var stats: [[String]]
    public var alloc: [Slice]
    public var note: String?
    public init(title: String, rows: [[String]] = [], stats: [[String]] = [], alloc: [Slice] = [], note: String? = nil) {
        self.title = title; self.rows = rows; self.stats = stats; self.alloc = alloc; self.note = note
    }
}

public struct Slice: Equatable, Sendable, Codable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: Double
    public let hex: UInt32
    public init(_ label: String, _ value: Double, _ hex: UInt32) { self.label = label; self.value = value; self.hex = hex }
}

public struct ChartMark: Equatable, Sendable, Codable {
    public let value: Double
    public let label: String
    public let tone: Tone
    public init(_ value: Double, _ label: String, _ tone: Tone) { self.value = value; self.label = label; self.tone = tone }
}

public struct TokenSpec: Equatable, Sendable, Codable {
    public let sym: String
    public let name: String
    public let price: Double
    public let change: Double
    public let seed: Int
    public let stats: [[String]]
    public let marks: [ChartMark]
    public init(sym: String, name: String, price: Double, change: Double, seed: Int, stats: [[String]], marks: [ChartMark]) {
        self.sym = sym; self.name = name; self.price = price; self.change = change; self.seed = seed; self.stats = stats; self.marks = marks
    }
}

public struct Cluster: Equatable, Sendable, Codable {
    public let x, y: Double
    public let n: Int
    public let size: Double
    public let hex: UInt32
    public init(x: Double, y: Double, n: Int, size: Double, hex: UInt32) { self.x = x; self.y = y; self.n = n; self.size = size; self.hex = hex }
}

public struct Kol: Equatable, Sendable, Codable, Identifiable {
    public var id: String { handle }
    public let handle, followers, note, state: String
    public let hex: UInt32
    public init(_ handle: String, _ followers: String, _ note: String, _ state: String, _ hex: UInt32) {
        self.handle = handle; self.followers = followers; self.note = note; self.state = state; self.hex = hex
    }
}

public struct FlowStep: Equatable, Sendable, Codable {
    public let title: String
    public let detail: String
    public let isGuard: Bool
    public init(_ title: String, _ detail: String, guard g: Bool = false) { self.title = title; self.detail = detail; self.isGuard = g }
}

public struct NewsItem: Equatable, Sendable, Codable, Identifiable {
    public var id: String { title }
    public let sym, title, source, ago, impact: String
    public let move: Double
    public let price: Double
    public let ask: String
    public init(sym: String, title: String, source: String, ago: String, impact: String, move: Double, price: Double, ask: String) {
        self.sym = sym; self.title = title; self.source = source; self.ago = ago; self.impact = impact; self.move = move; self.price = price; self.ask = ask
    }
}

/// A chip under an opportunity: opens an approval, or asks a follow-up.
public struct Tag: Equatable, Sendable, Codable {
    public let label: String
    public let approval: Approval?
    public let ask: String?
    public init(_ label: String, approval: Approval? = nil, ask: String? = nil) { self.label = label; self.approval = approval; self.ask = ask }
}

public struct Opportunity: Equatable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public let logo, name, metric, why: String
    public let up: Bool
    public let tags: [Tag]
    public init(logo: String, name: String, metric: String, why: String, up: Bool = true, tags: [Tag]) {
        self.logo = logo; self.name = name; self.metric = metric; self.why = why; self.up = up; self.tags = tags
    }
}

public struct Quest: Equatable, Sendable, Codable, Identifiable {
    public var id: String { title }
    public let title: String
    public let detail: String?
    public let points: String
    public let done: Bool
    public init(_ title: String, _ detail: String? = nil, _ points: String, done: Bool = false) {
        self.title = title; self.detail = detail; self.points = points; self.done = done
    }
}

public struct InboxItem: Equatable, Sendable, Codable, Identifiable {
    public var id: String { from }
    public let from, subject: String
    public let logo: String?
    public let pay: Int?
    public let when: String?
    public let calendar: Bool
    public init(from: String, subject: String, logo: String? = nil, pay: Int? = nil, when: String? = nil, calendar: Bool = false) {
        self.from = from; self.subject = subject; self.logo = logo; self.pay = pay; self.when = when; self.calendar = calendar
    }
}

/// An open position posted after a trade is approved: candles with entry, TP and SL, ticking live.
public struct LiveTrade: Equatable, Sendable, Codable {
    public let sym, title, side: String
    public let entry: Double
    public let tp, sl, liq: Double?
    public let size: Double
    public init(sym: String, title: String, side: String, entry: Double, tp: Double?, sl: Double?, liq: Double?, size: Double) {
        self.sym = sym; self.title = title; self.side = side; self.entry = entry; self.tp = tp; self.sl = sl; self.liq = liq; self.size = size
    }
}

/// A button under a reply. Money moves always open the approval sheet; the rest post the action and get a reply.
public struct Action: Equatable, Sendable, Identifiable, Codable {
    public var id: String { title }
    public let title: String
    public let approval: Approval?
    /// Hermit's answer when tapped ("Run daily" → "Run daily set…").
    public var reply: String?
    /// Sent as a new prompt when tapped.
    public var ask: String?
    /// Confirmation only, no chat message.
    public var toast: String?
    public var primary: Bool
    /// SF Symbol shown before the title.
    public var symbol: String?
    public init(_ title: String, approval: Approval? = nil, reply: String? = nil, ask: String? = nil, toast: String? = nil,
                primary: Bool = false, symbol: String? = nil) {
        self.title = title; self.approval = approval; self.reply = reply; self.ask = ask; self.toast = toast
        self.primary = primary || approval != nil; self.symbol = symbol
    }
}

/// Everything the approval sheet shows before money moves.
public struct Approval: Equatable, Sendable, Identifiable, Codable {
    public var id: String { title }
    public let kind: String
    public let title: String
    public let lines: [[String]]
    public let checks: [String]
    public let success: String
    public let receipt: Card?
    /// Posted into chat after approval when this opens a position.
    public var live: LiveTrade?
    /// Does the real work after Approve (sign and send) and returns a transaction hash. nil keeps the demo flow.
    /// Not saved with the chat and not part of equality.
    public var perform: (@Sendable () async throws -> String)?
    public init(kind: String, title: String, lines: [[String]], checks: [String], success: String, receipt: Card? = nil,
                live: LiveTrade? = nil, perform: (@Sendable () async throws -> String)? = nil) {
        self.kind = kind; self.title = title; self.lines = lines; self.checks = checks; self.success = success; self.receipt = receipt
        self.live = live; self.perform = perform
    }

    enum CodingKeys: String, CodingKey { case kind, title, lines, checks, success, receipt, live }

    public static func == (a: Approval, b: Approval) -> Bool {
        a.kind == b.kind && a.title == b.title && a.lines == b.lines && a.checks == b.checks && a.success == b.success
            && a.receipt == b.receipt && a.live == b.live
    }

    /// The hazard scan every money move runs, with any extra checks for this move.
    public static func checks(_ extra: [String] = []) -> [String] {
        ["Requested by you, not by a web page or email", "Simulation matches summary", "Contract verified and audited",
         "Exact-amount token approval"] + extra + ["Within daily limit"]
    }
}

/// A saved chat: what the sidebar Recents and project Chats list, and what reopens.
public struct Conversation: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public var title: String
    public var project: String?
    public var when: String
    public var messages: [Message]
    public init(id: String = UUID().uuidString, title: String, project: String? = nil, when: String, messages: [Message]) {
        self.id = id; self.title = title; self.project = project; self.when = when; self.messages = messages
    }
}
