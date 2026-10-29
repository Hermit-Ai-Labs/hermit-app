import SwiftUI
import Observation

// Calendar items from hermit-demo/src/data.js (todos, projectColors). Tasks and events share one list.
// The demo pins "today" to 2026-10-26; here every item keeps its distance from that day, so the
// calendar always looks lived-in around the real today.

enum CalStatus: String, CaseIterable, Hashable {
    case todo, doing, done
    var label: String {
        switch self { case .todo: "To do"; case .doing: "In progress"; case .done: "Done" }
    }
}

struct CalItem: Identifiable, Hashable {
    var id: Int
    var t: String
    var date: Date
    /// Minutes after midnight; nil means all day.
    var time: Int?
    var dur = 30
    var project: String?
    var status: CalStatus = .todo
    var event = false
    /// A page this item belongs to (Route raw value), opened by "Open".
    var to: String?
    /// A prompt for Hermit, sent by "Open".
    var ask: String?

    var isNew: Bool { id == 0 }
    var color: Color { CalendarData.color(project, event: event) }
    var timeText: String? { time.map(CalendarData.clock) }
}

enum CalendarData {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    static var today: Date { cal.startOfDay(for: Date()) }

    static let projects: [(name: String, color: Color)] = [
        ("Dev: HYPE news bot", Color(hex: 0x2563EB)),
        ("Stablecoin yield ladder", Color(hex: 0x15803D)),
        ("HYPE perp scripts", Color(hex: 0x4E1F96)),
        ("Airdrop farming S3", Color(hex: 0xC2410C)),
        ("Meme auto-trader", Color(hex: 0xA16207)),
        ("Research: AI agent tokens", Color(hex: 0x0E7490)),
        ("Presale tracker", Color(hex: 0xBE185D)),
    ]

    static func color(_ project: String?, event: Bool) -> Color {
        if let p = project, let c = projects.first(where: { $0.name == p })?.color { return c }
        return event ? Color(hex: 0x8A8A8A) : Theme.text
    }

    static func short(_ project: String) -> String {
        project.replacingOccurrences(of: "Research: ", with: "").replacingOccurrences(of: "Dev: ", with: "")
    }

    static func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }

    static func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }

    static func add(_ d: Date, days: Int) -> Date { cal.date(byAdding: .day, value: days, to: d)! }
    static func monday(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)!.start }
    static func same(_ a: Date, _ b: Date) -> Bool { cal.isDate(a, inSameDayAs: b) }
    static func dayNumber(_ d: Date) -> Int { cal.component(.day, from: d) }

    static func format(_ d: Date, _ f: String) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US"); df.calendar = cal; df.dateFormat = f
        return df.string(from: d)
    }

    // (id, title, day offset from today, "HH:mm" or nil, length, project, status, event, page, ask)
    static var seed: [CalItem] {
        func i(_ id: Int, _ t: String, _ off: Int, _ time: String? = nil, _ dur: Int = 30, project: String? = nil,
               status: CalStatus = .todo, event: Bool = false, to: String? = nil, ask: String? = nil) -> CalItem {
            let mins = time.map { s -> Int in let p = s.split(separator: ":").compactMap { Int($0) }; return p[0] * 60 + p[1] }
            return CalItem(id: id, t: t, date: day(off), time: mins, dur: dur, project: project, status: status, event: event, to: to, ask: ask)
        }
        return [
            i(1, "Approve ETH DCA", 0, "09:00", 30, to: "automations"),
            i(2, "Claim HYPE rewards", 0, to: "earn"),
            i(3, "Standup with dev team", 0, "14:30", 30, project: "Dev: HYPE news bot", event: true),
            i(13, "Review arb bot PnL", 0, "11:00", 60, project: "HYPE perp scripts", status: .doing),
            i(4, "Pay Figma $45", 1, "10:00", 15, to: "payments"),
            i(14, "MegaETH testnet tasks", 1, "16:00", 45, project: "Airdrop farming S3"),
            i(15, "Backtest SOL funding arb", 2, "10:00", 90, project: "HYPE perp scripts"),
            i(16, "Add SOL news to bot", 2, "15:00", 60, project: "Dev: HYPE news bot", status: .doing),
            i(5, "Finish Monad quests", 3, "13:00", 30, project: "Airdrop farming S3", ask: "Farm the Monad airdrop for me"),
            i(17, "Legion KYC for Hermes sale", 3, "11:00", 30, project: "Presale tracker"),
            i(6, "Vercel renews $20", 4, event: true, to: "payments"),
            i(18, "Write agent-token thesis", 4, "09:30", 120, project: "Research: AI agent tokens", status: .doing),
            i(7, "Pay alice.eth $1,200", 6, to: "payments"),
            i(9, "ETH DCA buy", 7, "09:00", 15, event: true, to: "automations"),
            i(8, "Rent $2,400", 8, event: true, to: "payments"),
            i(10, "Berachain claim opens", 9, project: "Airdrop farming S3", event: true),
            i(19, "Restart meme sniper?", 10, "10:00", 30, project: "Meme auto-trader"),
            i(11, "Presale unlock $640", 15, project: "Presale tracker", event: true),
            i(20, "Pendle rollover plan", 25, project: "Stablecoin yield ladder"),
            i(21, "Ship news bot v1", -2, project: "Dev: HYPE news bot", status: .done),
            i(22, "Deploy arb bot", -14, project: "HYPE perp scripts", status: .done),
            i(12, "Pendle PT matures", 61, project: "Stablecoin yield ladder", event: true),
        ]
    }
}

/// The one list behind Week, Month and Board. Lives as long as the app, so edits survive page changes.
@MainActor @Observable
final class CalendarStore {
    static let shared = CalendarStore()
    var items = CalendarData.seed
    private var nextId = 100

    func save(_ item: CalItem) {
        var it = item
        withAnimation(.snappy) {
            if it.isNew { it.id = nextId; nextId += 1; items.append(it) }
            else if let i = items.firstIndex(where: { $0.id == it.id }) { items[i] = it }
        }
    }
    func remove(_ id: Int) { withAnimation(.snappy) { items.removeAll { $0.id == id } } }
    func setStatus(_ id: Int, _ s: CalStatus) {
        withAnimation(.snappy(duration: 0.35)) { if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s } }
    }
}
