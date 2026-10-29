import SwiftUI
import Observation

// Mock data for Payments, ported from hermit-demo/src/data.js (payments, liveSchedule, next7Days,
// contacts, bills, myApis, apiCatalog).

struct PayScheduleItem: Identifiable, Hashable {
    var id: String { to + what }
    let to: String
    let what: String
    let when: String
    var amt: Double
    let rail: String
    var live = false
}

struct PayPending: Identifiable, Hashable {
    var id: String { to }
    let to: String
    let what: String
    let amt: Double
    let due: String
    let method: String
}

struct PayContact: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let addr: String
}

struct PayBill: Identifiable, Hashable {
    var id: String { to + what }
    let to: String
    let what: String
    let amt: Double
    let due: String
    let bank: String
}

struct PayApi: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let plan: String
    var used: Double
    var cap: Double
    let calls: String
}

struct PayCatalogItem: Identifiable, Hashable {
    var id: String { by + name }
    let name: String
    let by: String
    let price: String
    let cat: String
}

struct PayRecent: Identifiable, Hashable {
    let id = UUID()
    let to: String
    let amount: String
    let when: String
}

enum PaymentsData {
    static let liveSchedule: [PayScheduleItem] = [
        .init(to: "Perplexity", what: "Per call", when: "Now", amt: 0.41, rail: "x402", live: true),
        .init(to: "OpenAI", what: "API top-up", when: "In 2 days", amt: 20, rail: "x402"),
        .init(to: "Figma", what: "Pro plan", when: "Tomorrow", amt: 45, rail: "Bank"),
        .init(to: "Vercel", what: "Pro team", when: "Oct 30", amt: 20, rail: "Bank"),
        .init(to: "Hyperliquid", what: "Margin top-up", when: "If needed", amt: 500, rail: "USDC"),
    ]
    /// Money due on each of the next 7 days, starting today.
    static let next7Days: [Double] = [0.4, 45, 0, 20, 20, 0, 0]

    /// Payments above the auto-pay limit, waiting for the user.
    static let pending: [PayPending] = [
        .init(to: "alice.eth", what: "Design milestone 2", amt: 1200, due: "Nov 1", method: "USDC"),
        .init(to: "Landlord", what: "November rent", amt: 2400, due: "Nov 3", method: "USDC → bank"),
    ]

    static let contacts: [PayContact] = [
        .init(name: "alice.eth", addr: "0x2b9…e04"),
        .init(name: "bob.base.eth", addr: "0x91c…7aa"),
        .init(name: "Mom", addr: "mom@gmail.com"),
    ]
    /// Your other wallets (Main is the one paying).
    static let ownWallets = ["Trading", "Vault"]

    static let bills: [PayBill] = [
        .init(to: "Figma", what: "Pro plan", amt: 45, due: "Tomorrow", bank: "Figma, Inc."),
        .init(to: "Vercel", what: "Pro team", amt: 20, due: "Oct 30", bank: "Vercel Inc."),
        .init(to: "Landlord", what: "November rent", amt: 2400, due: "Nov 3", bank: "Chase 4821"),
        .init(to: "Notion", what: "Plus plan", amt: 10, due: "Nov 24", bank: "Notion Labs"),
    ]

    static let myApis: [PayApi] = [
        .init(name: "OpenAI", plan: "GPT-5", used: 16.6, cap: 100, calls: "6,640 calls"),
        .init(name: "Perplexity", plan: "Sonar", used: 7.8, cap: 50, calls: "1,560 calls"),
    ]

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

    static let recent: [PayRecent] = [
        .init(to: "alice.eth", amount: "1,200 USDC", when: "Oct 1"),
        .init(to: "My Vault", amount: "0.5 ETH", when: "Sep 28"),
        .init(to: "Mom", amount: "200 USDC", when: "Sep 20"),
    ]

    static let tokens = ["USDC", "ETH", "SOL", "HYPE"]

    /// "Explore more services" at the bottom of Schedule and APIs.
    static var moreServices: [PayMoreItem] {
        apiCatalog.map { PayMoreItem(name: "\($0.by) \($0.name)", logo: $0.by, sub: $0.price, tag: $0.cat) } + [
            PayMoreItem(name: "Pay a freelancer", logo: "USDC", sub: "Send USDC to anyone"),
            PayMoreItem(name: "Mobile top-up", logo: "USDC", sub: "150 countries"),
            PayMoreItem(name: "Gift cards", logo: "USDC", sub: "Amazon, Apple, Steam"),
            PayMoreItem(name: "Subscriptions", logo: "USDC", sub: "Netflix, Spotify, Notion"),
        ]
    }
}

struct PayMoreItem: Identifiable, Hashable {
    var id: String { name + (tag ?? "") }
    let name: String
    let logo: String
    let sub: String
    var tag: String? = nil
}

/// Payments state that outlives the page (switching pages keeps what you paid, paused or bought).
@MainActor @Observable
final class PaymentsStore {
    static let shared = PaymentsStore()

    var balance: Double = 8200
    var schedule = PaymentsData.liveSchedule
    var paused: Set<String> = []
    var pending = PaymentsData.pending
    var bills = PaymentsData.bills
    var paidBills: Set<String> = []
    var mine = PaymentsData.myApis
    var recent = PaymentsData.recent
    var paysFrom = "USDC on Base"

    func togglePause(_ id: String) {
        withAnimation(.snappy) {
            if paused.contains(id) { paused.remove(id) } else { paused.insert(id) }
            return
        }
    }

    func spend(_ usd: Double) { withAnimation(.snappy) { balance = max(0, balance - usd) } }
}

enum PayFormat {
    static func usd(_ v: Double, _ digits: Int = 0) -> String {
        v.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(digits)))
    }
    /// $0.41 for small amounts, $1,200 otherwise.
    static func amount(_ v: Double) -> String { v < 1 ? usd(v, 2) : usd(v, v.rounded() == v ? 0 : 2) }
}
