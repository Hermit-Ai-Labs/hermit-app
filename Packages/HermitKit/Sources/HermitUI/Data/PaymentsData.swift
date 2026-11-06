import SwiftUI
import Observation

// Payments: the payees you save and the payments you schedule, kept on this device. Nothing here moves money
// yet: paying needs the wallet, and sending from Hermit is not live, so Pay now stays greyed out.

/// Someone you pay: a name and where the money goes (an address or ENS name).
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

    var due: Bool { !paused && next < Date() }
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

    static let tokens = ["USDC", "USDT", "ETH", "SOL"]

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
        payees = saved?.payees ?? []
        schedule = saved?.schedule ?? []
    }

    /// Soonest first.
    var upcoming: [ScheduledPayment] { schedule.sorted { $0.next < $1.next } }

    /// Amount due on each of the next 7 days, starting today (USD-pegged tokens only).
    var next7Days: [Double] {
        (0..<7).map { i in
            let d = CalendarData.day(i)
            return schedule.filter { ["USDC", "USDT"].contains($0.token) }
                .reduce(0) { $0 + ($1.dates(from: d, to: CalendarData.day(i + 1)).isEmpty ? 0 : $1.amount) }
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

    func save(_ p: Payee) {
        withAnimation(.snappy) {
            if let i = payees.firstIndex(where: { $0.id == p.id }) { payees[i] = p } else { payees.append(p) }
        }
        persist()
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
