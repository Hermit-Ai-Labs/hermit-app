import SwiftUI
import Observation
import HermitWallet

// Payments: the payees you save and the payments you schedule, kept on this device. Nothing here moves money
// itself: Pay now and Transfer open the wallet's Send filled in, which reviews, scans and asks for Face ID.

/// Someone you pay: a name and where the money goes (an address, an ENS name or a NEAR account).
struct Payee: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var addr: String
}

/// How often a scheduled payment repeats.
enum PayRepeat: String, CaseIterable, Hashable, Codable {
    case once, weekly, monthly
    var label: String { switch self { case .once: "Once"; case .weekly: "Every week"; case .monthly: "Every month" } }
}

/// A payment you scheduled: who, how much, which token, and when.
struct ScheduledPayment: Identifiable, Hashable, Codable {
    var id = UUID()
    var payee: String
    var addr: String
    var amount: Double
    var token: String
    var note: String
    var next: Date
    var repeats: PayRepeat
    var paused = false
    // Added later, so optional: payments.json files saved before them still decode.
    /// The saved payee this pays. Editing that payee updates `payee` and `addr` here too (see PaymentsStore.save).
    var payeeID: UUID? = nil
    /// The amount exactly as typed and checked ("1200.50"), what Send gets. `amount` is for display and totals.
    var exact: String? = nil
    /// When Pay now last went through for this payment.
    var lastPaid: Date? = nil

    var due: Bool { !paused && next < Date() }
    /// The decimal string Send is filled in with.
    var sendAmount: String { exact ?? PayAmount.plain(amount) }
    var amountText: String { "\(PayFormat.amount(amount).replacingOccurrences(of: "$", with: "")) \(token)" }
    var whenText: String {
        if paused { return "Paused" }
        if due { return "Due" }
        if CalendarData.same(next, Date()) { return "Today" }
        if CalendarData.same(next, CalendarData.day(1)) { return "Tomorrow" }
        return CalendarData.format(next, "MMM d")
    }

    /// Dates it falls on between two days (for the calendar and the next-7-days chart).
    func dates(from start: Date, to end: Date) -> [Date] {
        guard !paused else { return [] }
        var out: [Date] = [], d = CalendarData.cal.startOfDay(for: next)
        while d < end && out.count < 60 {
            if d >= start { out.append(d) }
            switch repeats {
            case .once: return out
            case .weekly: d = CalendarData.add(d, days: 7)
            case .monthly: d = CalendarData.cal.date(byAdding: .month, value: 1, to: d)!
            }
        }
        return out
    }
}

struct PayCatalogItem: Identifiable, Hashable {
    var id: String { by + name }
    let name: String
    let by: String
    let price: String
    let cat: String
}

enum PaymentsData {
    /// Paid APIs Hermit will be able to buy with USDC (x402). Listed with their public prices; buying is not live yet.
    static let apiCatalog: [PayCatalogItem] = [
        .init(name: "GPT-5", by: "OpenAI", price: "$20 credits", cat: "AI"),
        .init(name: "Sonar", by: "Perplexity", price: "$0.005 / call", cat: "Search"),
        .init(name: "Flux", by: "Black Forest Labs", price: "$0.03 / image", cat: "AI"),
        .init(name: "Voice", by: "ElevenLabs", price: "$5 / month", cat: "AI"),
        .init(name: "Scrape", by: "Firecrawl", price: "$0.001 / page", cat: "Data"),
        .init(name: "Token data", by: "Birdeye", price: "$49 / month", cat: "Crypto"),
        .init(name: "Smart money", by: "Nansen", price: "$0.02 / call", cat: "Crypto"),
        .init(name: "SQL", by: "Dune", price: "$0.01 / query", cat: "Crypto"),
    ]
    static let apiCategories = ["All", "AI", "Search", "Data", "Crypto"]

    /// What Payments can send. The network follows the address and the token (see `payChain`).
    static let tokens = ["USDC", "USDT", "ETH", "SOL", "NEAR"]
    /// Counted in dollars in the next-7-days chart.
    static let usdTokens: Set<String> = ["USDC", "USDT"]

    /// "Explore more services" under APIs: asking Hermit about one of them.
    static var moreServices: [PayMoreItem] {
        apiCatalog.map { PayMoreItem(name: "\($0.by) \($0.name)", logo: $0.by, sub: $0.price, tag: $0.cat) }
    }
}

struct PayMoreItem: Identifiable, Hashable {
    var id: String { name + (tag ?? "") }
    let name: String
    let logo: String
    let sub: String
    var tag: String? = nil
}

/// Payees and scheduled payments. Lives as long as the app and is saved to disk on every change.
@MainActor @Observable
final class PaymentsStore {
    static let shared = PaymentsStore()

    private struct Saved: Codable { var payees: [Payee]; var schedule: [ScheduledPayment] }

    /// Change these through the methods below so every change is saved.
    private(set) var payees: [Payee]
    private(set) var schedule: [ScheduledPayment]

    init() {
        let saved = LocalJSON.load("payments.json", as: Saved.self)
        let payees = saved?.payees ?? []
        self.payees = payees
        // Payments saved before payee links existed: link the ones whose payee still has the same name and address.
        schedule = (saved?.schedule ?? []).map { s in
            guard s.payeeID == nil, let p = payees.first(where: { $0.name == s.payee && $0.addr == s.addr }) else { return s }
            var linked = s
            linked.payeeID = p.id
            return linked
        }
    }

    /// Soonest first.
    var upcoming: [ScheduledPayment] { schedule.sorted { $0.next < $1.next } }

    /// Amount due on each of the next 7 days, starting today (USD-pegged tokens only). Today also counts what is overdue.
    var next7Days: [Double] {
        let usd = schedule.filter { PaymentsData.usdTokens.contains($0.token) }
        return (0..<7).map { i in
            let d = CalendarData.day(i)
            return usd.reduce(0) { sum, p in
                let on = !p.dates(from: d, to: CalendarData.day(i + 1)).isEmpty || (i == 0 && p.due)
                return sum + (on ? p.amount : 0)
            }
        }
    }

    /// True when a payment in another token (ETH, SOL, NEAR) falls in the next 7 days, so the chart leaves it out.
    var next7LeavesOut: Bool {
        schedule.contains { p in
            !PaymentsData.usdTokens.contains(p.token) && (p.due || !p.dates(from: CalendarData.day(0), to: CalendarData.day(7)).isEmpty)
        }
    }

    /// Scheduled payments as all-day calendar items for the next year.
    var calendarItems: [CalItem] {
        var id = -1
        return schedule.flatMap { p in
            p.dates(from: CalendarData.day(-31), to: CalendarData.day(366)).map { d -> CalItem in
                id -= 1
                return CalItem(id: id, t: "Pay \(p.payee) \(p.amountText)", date: d, event: true, to: "payments", hex: 0x15803D)
            }
        }
    }

    func payee(named name: String) -> Payee? { payees.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func payee(id: UUID?) -> Payee? { id.flatMap { id in payees.first { $0.id == id } } }

    func save(_ p: ScheduledPayment) {
        withAnimation(.snappy) {
            if let i = schedule.firstIndex(where: { $0.id == p.id }) { schedule[i] = p } else { schedule.append(p) }
        }
        persist()
    }

    func togglePause(_ id: UUID) {
        withAnimation(.snappy) { if let i = schedule.firstIndex(where: { $0.id == id }) { schedule[i].paused.toggle() } }
        persist()
    }

    func removePayment(_ id: UUID) { withAnimation(.snappy) { schedule.removeAll { $0.id == id } }; persist() }

    /// Pay now went through: a one-off payment is done and leaves the list; a repeating one moves on one period.
    func markPaid(_ id: UUID) {
        guard let i = schedule.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) {
            switch schedule[i].repeats {
            case .once:
                schedule.remove(at: i)
            case .weekly:
                schedule[i].lastPaid = Date()
                schedule[i].next = CalendarData.add(schedule[i].next, days: 7)
            case .monthly:
                schedule[i].lastPaid = Date()
                schedule[i].next = CalendarData.cal.date(byAdding: .month, value: 1, to: schedule[i].next) ?? CalendarData.add(schedule[i].next, days: 30)
            }
        }
        persist()
    }

    /// Saves a payee, updates every scheduled payment linked to it (so a fixed address fixes the schedule too), and
    /// saves the address in the wallet's address book, which starts its 24-hour hold and makes it usable with
    /// Whitelist only. ENS names stay out of the wallet's list: it only takes exact addresses.
    func save(_ p: Payee) {
        withAnimation(.snappy) {
            if let i = payees.firstIndex(where: { $0.id == p.id }) { payees[i] = p } else { payees.append(p) }
            for i in schedule.indices where schedule[i].payeeID == p.id {
                schedule[i].payee = p.name
                schedule[i].addr = p.addr
            }
        }
        persist()
        if !SnapshotMode.active, let kind = Chain.kind(of: p.addr) {
            WalletsViewModel.shared.addAddress(label: p.name, address: p.addr, kind: kind)
        }
    }

    /// "Usable in Send in 5 h" while the wallet's 24-hour hold on this payee's address runs, else nil.
    func holdText(_ p: Payee) -> String? {
        guard let s = WalletsViewModel.shared.saved(p.addr), s.hold, let added = s.added else { return nil }
        let hours = max(1, Int((added.addingTimeInterval(86_400).timeIntervalSinceNow / 3600).rounded(.up)))
        return "Usable in Send in \(hours) h"
    }

    func removePayee(_ id: UUID) { withAnimation(.snappy) { payees.removeAll { $0.id == id } }; persist() }

    private func persist() { LocalJSON.save(Saved(payees: payees, schedule: schedule), "payments.json") }
}

enum PayFormat {
    static func usd(_ v: Double, _ digits: Int = 0) -> String {
        v.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(digits)))
    }
    /// $0.41 for small amounts, $1,200 otherwise.
    static func amount(_ v: Double) -> String { v < 1 ? usd(v, 2) : usd(v, v.rounded() == v ? 0 : 2) }
}

/// Typed amounts. Commas only count as thousands separators ("1,200.50"); "1,5" is refused rather than read as 15.
enum PayAmount {
    /// The exact decimal string for a positive typed amount ("1,200.50" -> "1200.50", ".5" -> "0.5"), or nil.
    static func exact(_ raw: String) -> String? {
        guard let s = wellFormed(raw), let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), d > 0 else { return nil }
        return s
    }
    static func value(_ raw: String) -> Double? { exact(raw).flatMap { Double($0) } }
    /// Why an amount can't be used, for the line under the field. nil when it is empty, zero or half typed ("0."), or fine.
    static func problem(_ raw: String) -> String? {
        if raw.trimmingCharacters(in: .whitespaces).isEmpty || wellFormed(raw) != nil { return nil }
        return raw.contains(",") && !raw.contains(".") ? "Use a dot for decimals, like 1.5" : "Enter an amount, like 25 or 1,200.50"
    }
    /// Digits, optional thousands commas and one decimal dot, cleaned to "1200.50". nil for anything else.
    private static func wellFormed(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.range(of: #"^(\d{1,3}(,\d{3})+|\d*)(\.\d*)?$"#, options: .regularExpression) != nil else { return nil }
        var s = t.replacingOccurrences(of: ",", with: "")
        if s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix(".") { s = "0" + s }
        return s.isEmpty ? nil : s
    }
    /// A stored amount as a plain decimal string ("2400", "0.005"): no grouping, no exponent.
    static func plain(_ v: Double) -> String {
        v.formatted(.number.grouping(.never).precision(.fractionLength(0...9)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
