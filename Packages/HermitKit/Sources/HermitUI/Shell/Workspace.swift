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
    /// When its clock started: saved, switched on, or given a new time. Slots before this never count as missed.
    /// Nil in files from before schedules ran (they start counting from now).
    public var since: Date?

    public var isSchedule: Bool { Automation.nextRun(trigger, after: Date()) != nil }
    /// What a run sends to Hermit.
    public var runPrompt: String { prompt ?? action }

    /// The slot it runs at next: the first one after its last run (or after it was switched on). It is due once that
    /// has passed, and a run moves it past now, so time away from the app gives one run, never one per missed slot.
    /// Nil when it is paused or isn't a schedule.
    public func nextDue(_ now: Date = Date()) -> Date? {
        guard on else { return nil }
        // A one-off is done once it has run at or after its time. Run now pressed before then doesn't use it up.
        if isOnce, let last = lastRun, let slot = Automation.nextRun(trigger, after: since ?? last), last >= slot { return nil }
        let base = [lastRun, since].compactMap { $0 }.max() ?? now
        return Automation.nextRun(trigger, after: base)
    }

    /// Runs once ("Once at 14:32", or a draft's "In 2 minutes"), then stays saved for Run now.
    public var isOnce: Bool { trigger.hasPrefix("Once at ") || Automation.minutes(in: trigger, prefix: "In ") != nil }

    public func isDue(_ now: Date = Date()) -> Bool { nextDue(now).map { $0 <= now } ?? false }

    /// The next slot still ahead of now (the row's "Next run" and the reminder's time). Nil when paused or not a schedule.
    public func upcoming(_ now: Date = Date()) -> Date? {
        guard let d = nextDue(now) else { return nil }
        return d > now ? d : Automation.nextRun(trigger, after: now)
    }

    init(name: String, trigger: String, action: String, limit: String, on: Bool, last: String, prompt: String? = nil, asks: Bool = false, runs: [(String, String)]? = nil) {
        self.name = name; self.trigger = trigger; self.action = action; self.limit = limit; self.on = on; self.last = last
        self.prompt = prompt; self.asks = asks
        since = on ? Date() : nil
        thread = [Message(role: .user, text: prompt ?? "\(trigger): \(action.prefix(1).lowercased() + action.dropFirst())"),
                  Message(role: .assistant, text: Automation.savedNote(trigger: trigger, on: on), note: true)]
            + (runs ?? []).reversed().map { Message(role: .assistant, text: $0.1, run: $0.0) }
    }

    /// The reply to Save: when it runs next, that it is paused, or that it waits for Run now.
    static func savedNote(trigger: String, on: Bool) -> String {
        guard let next = nextRun(trigger, after: Date()) else { return "Saved. It runs when you press Run now." }
        return on ? "Saved. Next run \(dayText(next))." : "Saved. It's paused: switch it on in Automations to run it on schedule."
    }

    /// "Mon 09:00": the weekday in the user's language, the time in 24 hours like the triggers.
    static func dayText(_ d: Date) -> String { format(d, "EEE HH:mm") }
    /// "09:00".
    static func timeText(_ d: Date) -> String { format(d, "HH:mm") }

    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// Nothing is pre-made; people describe their own.
    static let seed: [Automation] = []

    /// The next time a schedule trigger fires: "Every day 08:00", "Every Monday 09:00", "Every hour".
    /// Nil for triggers that wait on an event (prices, email) or say "When you run it": those run only from Run now.
    /// Short ones too: "Every minute", "Every 5 minutes" (the next whole minute that many minutes on), "In 2 minutes" (a
    /// draft's one-off, from now) and "Once at 14:32" (that one-off once saved; see `isOnce`).
    static func nextRun(_ trigger: String, after now: Date) -> Date? {
        let cal = Calendar.current
        if trigger == "Every hour" {
            return cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
        }
        if let n = minutes(in: trigger, prefix: "Every ") {
            // From the start of the minute, so runs land on whole minutes.
            let start = cal.dateInterval(of: .minute, for: now)?.start ?? now
            return start.addingTimeInterval(TimeInterval(n * 60))
        }
        if let n = minutes(in: trigger, prefix: "In ") { return now.addingTimeInterval(TimeInterval(n * 60)) }
        if trigger.hasPrefix("Once at "), let clock = trigger.split(separator: " ").last,
           clock.count == 5, let h = Int(clock.prefix(2)), let m = Int(clock.suffix(2)), h < 24, m < 60 {
            return cal.nextDate(after: now, matching: DateComponents(hour: h, minute: m), matchingPolicy: .nextTime)
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

    /// 1 for "Every minute" or "In 1 minute", n for "Every n minutes" or "In n minutes" (1 to 59), else nil.
    static func minutes(in trigger: String, prefix: String) -> Int? {
        guard trigger.hasPrefix(prefix) else { return nil }
        let rest = trigger.dropFirst(prefix.count)
        if rest == "minute" || rest == "1 minute" { return 1 }
        let words = rest.split(separator: " ")
        guard words.count == 2, words[1] == "minutes", let n = Int(words[0]), (1...59).contains(n) else { return nil }
        return n
    }

    /// "In 2 minutes" as the one-off it becomes on Save: "Once at 14:32". Other triggers stay as they are.
    static func pinned(_ trigger: String, at now: Date = Date()) -> String {
        guard minutes(in: trigger, prefix: "In ") != nil, let d = nextRun(trigger, after: now) else { return trigger }
        return "Once at " + timeText(d)
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
