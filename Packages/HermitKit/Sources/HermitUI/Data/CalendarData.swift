import SwiftUI
import Observation
import EventKit

// The calendar shows three things on one grid: your own events from the device calendar (EventKit, read with
// permission), tasks and events you add in Hermit (kept on this device), and Hermit's scheduled payments.

enum CalStatus: String, CaseIterable, Hashable, Codable {
    case todo, doing, done
    var label: String {
        switch self { case .todo: "To do"; case .doing: "In progress"; case .done: "Done" }
    }
}

struct CalItem: Identifiable, Hashable, Codable {
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
    /// Colour (a project's, or the device calendar's).
    var hex: UInt32?
    /// Set on events that come from the device calendar.
    var ekID: String?
    var calendar: String?
    var location: String?

    var isNew: Bool { id == 0 }
    /// From the device calendar (read only here).
    var external: Bool { ekID != nil }
    /// One of Hermit's scheduled payments.
    var payment: Bool { to == "payments" && id < 0 && ekID == nil }
    var color: Color { hex.map { Color(hex: $0) } ?? (event ? Color(hex: 0x8A8A8A) : Theme.text) }
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

    /// 0xRRGGBB from a CGColor (device calendar colours).
    static func hex(_ c: CGColor?) -> UInt32? {
        guard let c, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let comps = c.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, comps.count >= 3 else { return nil }
        func b(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return b(comps[0]) << 16 | b(comps[1]) << 8 | b(comps[2])
    }
}

/// Everything behind Week, Month and Board. Lives as long as the app, so edits survive page changes.
@MainActor @Observable
final class CalendarStore {
    static let shared = CalendarStore()

    /// What Hermit may do with the device calendar.
    enum Access { case unknown, full, writeOnly, denied }

    /// Tasks and events added in Hermit.
    private(set) var local: [CalItem]
    /// Events read from the device calendar for the visible range.
    private(set) var events: [CalItem] = []
    private(set) var access: Access = .unknown
    private var nextId: Int
    private let ek: EKEventStore? = SnapshotMode.active ? nil : EKEventStore()
    private var range: DateInterval?
    private var watching = false

    init() {
        let saved = LocalJSON.load("calendar.json", as: [CalItem].self) ?? []
        local = saved
        nextId = (saved.map(\.id).max() ?? 0) + 1
        refreshAccess()
    }

    /// Everything on the grid: device events, your items, and scheduled payments.
    var items: [CalItem] { events + local + PaymentsStore.shared.calendarItems }

    // MARK: Device calendar

    func refreshAccess() {
        guard ek != nil else { access = .unknown; return }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .full
        case .writeOnly: access = .writeOnly
        case .denied, .restricted: access = .denied
        default: access = .unknown
        }
    }

    /// Asks for calendar access (the system prompt), then loads events.
    func requestAccess() async {
        guard let ek else { return }
        _ = try? await ek.requestFullAccessToEvents()
        refreshAccess()
        if let r = range { load(r) }
    }

    /// Loads device events around a date (the visible month plus a week either side).
    func show(around d: Date) {
        let month = CalendarData.cal.dateInterval(of: .month, for: d)!
        let r = DateInterval(start: CalendarData.add(month.start, days: -7), end: CalendarData.add(month.end, days: 7))
        if let old = range, old.contains(r.start), old.contains(r.end) { return }
        load(r)
    }

    private func load(_ r: DateInterval) {
        range = r
        guard let ek, access == .full else { events = []; return }
        watch()
        let found = ek.events(matching: ek.predicateForEvents(withStart: r.start, end: r.end, calendars: nil))
        let cal = CalendarData.cal, lo = cal.startOfDay(for: r.start)
        var id = -1_000_000
        var out: [CalItem] = []
        // One item per day an event touches, so a 3-day trip or a 22:00 to 02:00 event shows on every day it covers.
        // Timed events are clamped to each day: the first runs to midnight, the last starts at 00:00, any between are all day.
        for e in found {
            let start = e.startDate ?? r.start
            let end = max(e.endDate ?? start, start)
            let first = cal.startOfDay(for: start)
            // An event ending exactly at midnight (and every all-day event) doesn't spill into the next day.
            let last = max(first, cal.startOfDay(for: end.addingTimeInterval(-1)))
            let comps = cal.dateComponents([.hour, .minute], from: start)
            let startMins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let total = Int(end.timeIntervalSince(start) / 60)
            var d = max(first, lo)
            while d <= last && d < r.end {
                let time: Int?, dur: Int
                if e.isAllDay { time = nil; dur = total }
                else if first == last { time = startMins; dur = total }
                else if d == first { time = startMins; dur = 24 * 60 - startMins }
                else if d == last { time = 0; dur = Int(end.timeIntervalSince(d) / 60) }
                else { time = nil; dur = 24 * 60 }
                id -= 1
                out.append(CalItem(id: id, t: e.title ?? "Event", date: d, time: time, dur: max(15, dur),
                                   event: true, hex: CalendarData.hex(e.calendar?.cgColor), ekID: e.eventIdentifier,
                                   calendar: e.calendar?.title, location: e.location))
                d = CalendarData.add(d, days: 1)
            }
        }
        events = out
    }

    /// Reload when the calendar changes outside Hermit.
    private func watch() {
        guard !watching, let ek else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, let r = self.range else { return }; self.load(r) }
        }
    }

    /// Adds an event to the device's default calendar. False when there is no access.
    func addToCalendar(_ item: CalItem) -> Bool {
        guard let ek, access == .full || access == .writeOnly, let cal = ek.defaultCalendarForNewEvents else { return false }
        let e = EKEvent(eventStore: ek)
        e.calendar = cal
        e.title = item.t
        if let m = item.time {
            e.startDate = item.date.addingTimeInterval(TimeInterval(m * 60))
            e.endDate = e.startDate.addingTimeInterval(TimeInterval(item.dur * 60))
        } else {
            e.isAllDay = true; e.startDate = item.date; e.endDate = item.date
        }
        guard (try? ek.save(e, span: .thisEvent)) != nil else { return false }
        if let r = range { load(r) }
        return true
    }

    // MARK: Hermit items

    func save(_ item: CalItem) {
        var it = item
        withAnimation(.snappy) {
            if it.isNew { it.id = nextId; nextId += 1; local.append(it) }
            else if let i = local.firstIndex(where: { $0.id == it.id }) { local[i] = it }
        }
        persist()
    }
    func remove(_ id: Int) { withAnimation(.snappy) { local.removeAll { $0.id == id } }; persist() }
    func setStatus(_ id: Int, _ s: CalStatus) {
        withAnimation(.snappy(duration: 0.35)) { if let i = local.firstIndex(where: { $0.id == id }) { local[i].status = s } }
        persist()
    }

    private func persist() { LocalJSON.save(local, "calendar.json") }
}
