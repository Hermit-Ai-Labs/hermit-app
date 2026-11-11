import SwiftUI
import HermitCore

/// A project: its own chats, files, instructions (project.md), money and costs. Claude-style.
public struct Project: Identifiable, Equatable, Codable {
    public var id: String { name }
    public var name: String
    public var symbol: String
    public var desc: String
    public var status: String
    public var pnl: String
    public var money: Double
    public var cost: Double
    public var gain: Double
    public var gainLabel: String
    public var gainNote: String
    public var files: [String]
    public var hex: UInt32
    /// Monthly auto-payments (APIs, hosting, gas refills).
    public var burn: [Cost]
    public var forecast: Forecast?
    /// Where the gain came from (30 days).
    public var gains: [Cost]
    public var color: Color { Color(hex: hex) }

    public struct Cost: Equatable, Identifiable, Codable {
        public var id: String { what }
        public let what: String
        public let amount: Double
        public init(_ what: String, _ amount: Double) { self.what = what; self.amount = amount }
    }
    public struct Forecast: Equatable, Codable {
        public let monthly: Double
        public let basis: String
        public let updatedHoursAgo: Int
    }

    public init(name: String, symbol: String, desc: String, status: String, pnl: String, money: Double, cost: Double, gain: Double,
                gainLabel: String, gainNote: String, files: [String] = ["strategy.ts", "backtest.csv", "notes.md"], hex: UInt32,
                burn: [Cost] = [], forecast: Forecast? = nil, gains: [Cost] = []) {
        self.name = name; self.symbol = symbol; self.desc = desc; self.status = status; self.pnl = pnl; self.money = money
        self.cost = cost; self.gain = gain; self.gainLabel = gainLabel; self.gainNote = gainNote; self.files = files; self.hex = hex
        self.burn = burn; self.forecast = forecast; self.gains = gains
    }

    /// project.md before the user edits it.
    var defaultInstructions: String {
        "# \(name)\n\nWhat Hermit should know in every chat of this project: the goal, rules to follow, how to reply."
    }

    static let templates: [(String, String)] = [("DeFi yield", "leaf"), ("Trading bot", "chart.line.uptrend.xyaxis"), ("Airdrop farming", "gift"),
                                                ("Research", "book"), ("Dev tool", "chevron.left.forwardslash.chevron.right"), ("Blank", "folder")]

    /// Projects start empty; people make their own.
    static let seed: [Project] = []
}

/// A prompt on a schedule: when it runs, what it asks Hermit, and its thread (the request, then every run).
public struct Automation: Identifiable, Equatable, Codable {
    public var id: String { name }
    public var name: String
    public var trigger: String
    public var action: String
    public var limit: String
    public var on: Bool
    public var last: String
    public var prompt: String?
    public var asks: Bool
    /// The thread: the request, the confirmation, then every run as a reply.
    public var thread: [Message]
    /// When it last ran (nil until the first run).
    public var lastRun: Date?

    public var isSchedule: Bool { Automation.nextRun(trigger, after: Date()) != nil }
    /// What a run sends to Hermit.
    public var runPrompt: String { prompt ?? action }

    init(name: String, trigger: String, action: String, limit: String, on: Bool, last: String, prompt: String? = nil, asks: Bool = false, runs: [(String, String)]? = nil) {
        self.name = name; self.trigger = trigger; self.action = action; self.limit = limit; self.on = on; self.last = last
        self.prompt = prompt; self.asks = asks
        thread = [Message(role: .user, text: prompt ?? "\(trigger): \(action.prefix(1).lowercased() + action.dropFirst())"),
                  // Nothing runs on a schedule yet, so the reply doesn't promise it.
                  Message(role: .assistant, text: "Saved. It runs when you press Run now. Schedules are coming soon.", note: true)]
            + (runs ?? []).reversed().map { Message(role: .assistant, text: $0.1, run: $0.0) }
    }

    /// Nothing is pre-made; people describe their own.
    static let seed: [Automation] = []

    /// The next time a schedule trigger fires: "Every day 08:00", "Every Monday 09:00", "Every hour".
    /// Nil for triggers that wait on an event (prices, email), which can only run by hand for now.
    static func nextRun(_ trigger: String, after now: Date) -> Date? {
        let cal = Calendar.current
        if trigger == "Every hour" {
            return cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
        }
        guard trigger.hasPrefix("Every "), let clock = trigger.split(separator: " ").last,
              clock.count == 5, let h = Int(clock.prefix(2)), let m = Int(clock.suffix(2)) else { return nil }
        let day = trigger.dropFirst(6).split(separator: " ").first.map(String.init) ?? ""
        var parts = DateComponents(hour: h, minute: m)
        if day != "day" {
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            guard let i = days.firstIndex(of: day) else { return nil }
            parts.weekday = i + 1
        }
        return cal.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
    }
}

/// A to-do or event. Home's Today card and project home cards read these.
public struct Todo: Identifiable, Equatable, Codable {
    public let id: Int
    public var title: String
    /// Days from today (0 = today, negative = past).
    public var day: Int
    public var time: String?
    public var project: String?
    /// Where the row opens.
    public var route: Route?
    /// Or a prompt it sends.
    public var ask: String?
    public var event: Bool
    public var done: Bool

    /// Starts empty: to-dos come from the user.
    static let seed: [Todo] = []

    private enum CodingKeys: String, CodingKey { case id, title, day, time, project, route, ask, event, done }

    init(id: Int, title: String, day: Int, time: String? = nil, project: String? = nil, route: Route? = nil, ask: String? = nil, event: Bool, done: Bool) {
        self.id = id; self.title = title; self.day = day; self.time = time; self.project = project
        self.route = route; self.ask = ask; self.event = event; self.done = done
    }

    // The route is saved by its raw value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        day = try c.decode(Int.self, forKey: .day); time = try c.decodeIfPresent(String.self, forKey: .time)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        route = try c.decodeIfPresent(String.self, forKey: .route).flatMap(Route.init(rawValue:))
        ask = try c.decodeIfPresent(String.self, forKey: .ask)
        event = try c.decode(Bool.self, forKey: .event); done = try c.decode(Bool.self, forKey: .done)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(day, forKey: .day)
        try c.encodeIfPresent(time, forKey: .time); try c.encodeIfPresent(project, forKey: .project)
        try c.encodeIfPresent(route?.rawValue, forKey: .route); try c.encodeIfPresent(ask, forKey: .ask)
        try c.encode(event, forKey: .event); try c.encode(done, forKey: .done)
    }
}

enum Money {
    static func usd(_ v: Double, signed: Bool = false) -> String {
        let s = "$" + abs(v).formatted(.number.precision(.fractionLength(0)))
        if v < 0 { return "−" + s }
        return signed && v > 0 ? "+" + s : s
    }
}
