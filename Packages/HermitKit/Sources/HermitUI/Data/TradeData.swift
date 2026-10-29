import SwiftUI
import HermitCore

// Mock data for Trade, ported from hermit-demo/src/data.js and pages/Trade.jsx.

enum TradeData {
    // MARK: Deterministic random (Park-Miller, same as data.js `rng`) so charts look the same every launch.
    struct RNG {
        var s: Int64
        init(_ seed: Int) { s = Int64(seed) }
        mutating func next() -> Double { s = (s * 16807) % 2147483647; return Double(s - 1) / 2147483646 }
    }

    /// data.js `candles(n, start, vol, seed, drift)`.
    static func candles(_ n: Int, _ start: Double, _ vol: Double, _ seed: Int, _ drift: Double = 0.02) -> [Candle] {
        var r = RNG(seed), o = start
        return (0..<n).map { _ in
            let c = o * (1 + (r.next() - 0.5 + drift) * vol)
            let h = max(o, c) * (1 + r.next() * vol * 0.4)
            let l = min(o, c) * (1 - r.next() * vol * 0.4)
            defer { o = c }
            return Candle(o: o, h: h, l: l, c: c)
        }
    }

    // MARK: Markets

    struct Perp: Identifiable, Hashable {
        var id: String { sym }
        let sym: String, px: Double, ch: Double, fund: Double, oi: String
        var venue: String? = nil
        var vol: String { ["BTC": "$4.2B", "ETH": "$2.1B", "SOL": "$880M", "HYPE": "$1.3B", "TSLA": "$240M", "GOLD": "$96M"][sym] ?? "—" }
        var dp: Int { px < 100 ? 2 : 0 }
    }
    static let perps: [Perp] = [
        Perp(sym: "BTC", px: 114280, ch: 1.8, fund: 0.0012, oi: "$3.1B"),
        Perp(sym: "ETH", px: 3498, ch: 2.4, fund: 0.0019, oi: "$1.7B"),
        Perp(sym: "SOL", px: 186.6, ch: -1.1, fund: -0.0004, oi: "$612M"),
        Perp(sym: "HYPE", px: 24.06, ch: 5.8, fund: 0.0031, oi: "$904M"),
        Perp(sym: "TSLA", px: 412.5, ch: 3.1, fund: 0.0008, oi: "$620M", venue: "trade.xyz"),
        Perp(sym: "GOLD", px: 2748, ch: 0.4, fund: 0.0002, oi: "$310M", venue: "trade.xyz"),
    ]
    static let venues = ["Hyperliquid", "Lighter", "Aster", "Paradex", "Extended", "trade.xyz"]
    /// Timeframe -> (volatility, seed offset).
    static let timeframes: [(String, Double, Int)] = [("15m", 0.012, 3), ("1H", 0.022, 5), ("4H", 0.045, 9), ("1D", 0.09, 13)]

    struct Spot: Identifiable, Hashable { var id: String { sym }; let sym, name: String; let px, ch: Double }
    static let spot: [Spot] = [
        Spot(sym: "ETH", name: "Ethereum", px: 3498, ch: 2.4),
        Spot(sym: "BTC", name: "Bitcoin", px: 114280, ch: 1.8),
        Spot(sym: "SOL", name: "Solana", px: 186.6, ch: -1.1),
        Spot(sym: "HYPE", name: "Hyperliquid", px: 24.06, ch: 5.8),
    ]

    struct Meme: Identifiable, Hashable {
        var id: String { sym }
        let sym, mc: String; let px, ch: Double; let holders, age: String
        enum Score { case pass, warn, fail }
        let score: Score
        var label: String { switch score { case .pass: "Safe"; case .warn: "Caution"; case .fail: "Risky" } }
        var color: Color { switch score { case .pass: Theme.green; case .warn: Theme.amber; case .fail: Theme.red } }
    }
    static let memes: [Meme] = [
        Meme(sym: "PENGU", mc: "$2.1B", px: 0.0334, ch: 18.2, holders: "712k", age: "11mo", score: .pass),
        Meme(sym: "PEPE", mc: "$8.0B", px: 0.0000191, ch: 12.4, holders: "421k", age: "2y", score: .pass),
        Meme(sym: "WIF", mc: "$1.4B", px: 1.42, ch: -3.2, holders: "201k", age: "1.9y", score: .pass),
        Meme(sym: "GIGA", mc: "$312M", px: 0.031, ch: 41.0, holders: "58k", age: "1.2y", score: .warn),
        Meme(sym: "HERM", mc: "$4.2M", px: 0.0042, ch: 212.0, holders: "1.9k", age: "6h", score: .fail),
    ]

    struct Prediction: Identifiable, Hashable { var id: String { q }; let q, venue: String; let yes: Int; let vol, ends: String }
    static let predictions: [Prediction] = [
        Prediction(q: "Fed cuts rates in December?", venue: "Kalshi", yes: 62, vol: "$48M", ends: "Dec 10"),
        Prediction(q: "BTC above $120k on Dec 31?", venue: "Polymarket", yes: 41, vol: "$22M", ends: "Dec 31"),
        Prediction(q: "ETH ETF staking inflows over $1B in November?", venue: "Opinion", yes: 55, vol: "$3.1M", ends: "Nov 30"),
        Prediction(q: "HYPE in the top 10 by market cap this year?", venue: "Predict.fun", yes: 33, vol: "$1.2M", ends: "Dec 31"),
        Prediction(q: "SOL above $200 this Friday?", venue: "Limitless", yes: 28, vol: "$0.4M", ends: "Fri"),
    ]

    // MARK: Positions, orders, history

    struct Position: Identifiable, Hashable {
        var id: String { title + when }
        let sym, title, side: String
        let entry, mark: Double
        let liq: Double?
        let tp: Double?
        var sl: Double?
        let pnl: Double
        let by, when: String
    }
    static let positionsSeed: [Position] = [
        Position(sym: "HYPE", title: "HYPE-PERP", side: "Long 3x", entry: 22.41, mark: 24.06, liq: 15.68, tp: 27.5, sl: 21, pnl: 530, by: "Agent", when: "Oct 24"),
        Position(sym: "ETH", title: "ETH-PERP", side: "Short 1x", entry: 3520, mark: 3498, liq: nil, tp: nil, sl: 3650, pnl: 32, by: "Agent", when: "Oct 25"),
        Position(sym: "SOL", title: "SOL", side: "Spot", entry: 172.4, mark: 186.6, liq: nil, tp: 220, sl: 160, pnl: 178, by: "You", when: "Oct 2"),
    ]

    struct Order: Identifiable, Hashable { var id: String { what }; let sym, what, px, by, when: String }
    static let ordersSeed: [Order] = [
        Order(sym: "HYPE", what: "Limit buy 120 HYPE", px: "$22.80", by: "Agent", when: "Oct 26"),
        Order(sym: "BTC", what: "Stop sell 0.02 BTC", px: "$108,500", by: "You", when: "Oct 21"),
    ]

    struct Fill: Identifiable, Hashable { var id: String { what }; let sym, what, px: String; let pnl: Double?; let when: String }
    static let fills: [Fill] = [
        Fill(sym: "HYPE", what: "Bought 210 HYPE", px: "$22.41", pnl: nil, when: "Oct 24"),
        Fill(sym: "ETH", what: "Sold 0.6 ETH short", px: "$3,520", pnl: nil, when: "Oct 25"),
        Fill(sym: "SOL", what: "Closed SOL long", px: "$191.20", pnl: 212, when: "Oct 19"),
        Fill(sym: "BTC", what: "Closed BTC short", px: "$111,900", pnl: -64, when: "Oct 15"),
    ]

    // MARK: Strategies (also used by Earn's arbitrage bots)

    struct Step: Hashable { let t, d: String; var guardStep = false }
    struct Strategy: Identifiable, Hashable {
        let id, name, sym: String
        var running: Bool
        let capital, pnl: Double
        let win, source: String
        let steps: [Step]
        let trades: [(String, String, String)]
        static func == (a: Strategy, b: Strategy) -> Bool { a.id == b.id && a.running == b.running }
        func hash(into h: inout Hasher) { h.combine(id) }
        var fromChat: Bool { source == "From chat" }
    }
    static let strategies: [Strategy] = [
        Strategy(id: "arb", name: "HYPE funding arb", sym: "HYPE", running: true, capital: 5200, pnl: 1204, win: "78%", source: "From HYPE perp scripts",
                 steps: [Step(t: "Watch", d: "Every 60s"), Step(t: "Trigger", d: "Funding > 0.03%/h"), Step(t: "Spot + short", d: "Same size"), Step(t: "Hazard scan", d: "Every order", guardStep: true), Step(t: "Exit", d: "Funding < 0.01%")],
                 trades: [("Opened hedge 2,600 HYPE", "2h ago", "+$12.60"), ("Closed hedge", "Oct 24", "+$41.20"), ("Opened hedge 2,400 HYPE", "Oct 23", "+$38.90")]),
        Strategy(id: "breakout", name: "ETH breakout", sym: "ETH", running: true, capital: 3000, pnl: 286, win: "54%", source: "From chat",
                 steps: [Step(t: "Watch 4H", d: "Range high"), Step(t: "Breakout", d: "Close above + volume"), Step(t: "Long 3x", d: "TP +6%, SL −2%"), Step(t: "Hazard scan", d: "Every order", guardStep: true)],
                 trades: [("Long ETH 3x", "Oct 25", "+$182"), ("Stopped out", "Oct 21", "−$64")]),
        Strategy(id: "dca", name: "Weekly ETH DCA", sym: "ETH", running: true, capital: 2000, pnl: 96, win: "—", source: "From chat",
                 steps: [Step(t: "Every Monday", d: "09:00"), Step(t: "Swap 500 USDC", d: "Best route"), Step(t: "Hazard scan", d: "Every order", guardStep: true), Step(t: "Hold", d: "Vault wallet")],
                 trades: [("Bought 0.143 ETH", "Oct 20", ""), ("Bought 0.146 ETH", "Oct 13", "")]),
        Strategy(id: "sniper", name: "Meme sniper", sym: "PENGU", running: false, capital: 300, pnl: -118, win: "31%", source: "From Meme auto-trader",
                 steps: [Step(t: "New pair", d: "Liquidity > $200k"), Step(t: "Holder check", d: "Bubble map"), Step(t: "Hazard scan", d: "Every order", guardStep: true), Step(t: "Buy $100", d: "Sell at 2x")],
                 trades: [("Sold GIGA", "Oct 18", "−$42"), ("Skipped HERM: dev cluster 61%", "Oct 17", "")]),
    ]

    /// Explore more markets (stocks, gold, majors, memes, new tokens).
    static let moreMarkets: [TradeExploreItem] = [
        ("TSLA", "Tesla", "Stock perps on trade.xyz"), ("GOLD", "Gold", "Perps on trade.xyz"), ("NVDA", "Nvidia", "Tokenized on Ondo"),
        ("MON", "Monad", "Spot on Kuru"), ("LIT", "Lighter", "Spot and perps"), ("ASTER", "Aster", "Spot and perps"), ("XPL", "Plasma", "Spot"),
        ("KHYPE", "Kinetiq HYPE", "Spot"), ("BTC", "Bitcoin", "Spot and perps"), ("ETH", "Ethereum", "Spot and perps"), ("SOL", "Solana", "Spot and perps"),
        ("HYPE", "Hyperliquid", "Spot and perps"), ("PEPE", "Pepe", "Meme"), ("WIF", "dogwifhat", "Meme"), ("PENGU", "Pudgy Penguins", "Meme"),
        ("BNB", "BNB", "Perps"), ("XRP", "XRP", "Perps"), ("DOGE", "Dogecoin", "Perps"), ("SUI", "Sui", "Perps"), ("TIA", "Celestia", "Perps"),
        ("JUP", "Jupiter", "Spot"), ("ENA", "Ethena", "Spot and perps"),
    ].map { TradeExploreItem(name: $0.1, logo: $0.0, sub: $0.2, metric: $0.0) }

    static let balance: Double = 14010
}

/// Live state for Trade and Earn that survives tab and page switches: positions added by approvals,
/// cancelled orders, paused strategies. Approved money moves apply their change here.
@MainActor @Observable
final class TradeEarnStore {
    static let shared = TradeEarnStore()
    var positions = TradeData.positionsSeed
    var orders = TradeData.ordersSeed
    var paused: Set<String> = ["sniper"]
    var earnPositions = EarnData.positionsSeed

    /// What to do once the approval sheet with this success text goes through.
    private var pending: (success: String, toast: String?, apply: () -> Void)?

    /// Open the approval sheet and remember what changes on screen once it is approved.
    func approve(_ model: AppModel, _ a: Approval, toast: String? = nil, apply: @escaping () -> Void = {}) {
        pending = (a.success, toast, apply)
        model.approval = a
    }

    /// Called when the approval sheet closes. Approved sheets leave their success line in the conversation.
    func approvalClosed(_ model: AppModel) {
        guard let p = pending else { return }
        pending = nil
        guard model.messages.last?.text == p.success + "." else { return }
        withAnimation(.smooth(duration: 0.35)) { p.apply() }
        model.toast(p.toast ?? p.success)
    }
}

