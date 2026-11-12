import SwiftUI
import Foundation

// Live market data for Trade (and the funding rates in Earn > Arbitrage). All of it comes from public, keyless APIs:
//   Hyperliquid  perps: mark price, 24h change, volume, open interest, funding, candles, order book, trades.
//                trade.xyz stock and gold perps live on Hyperliquid too (the "xyz" dex).
//   Jupiter      Solana spot and meme tokens (SolanaSwap.swift).
//   Polymarket   prediction markets (gamma API).
// Nothing is made up: when a fetch fails the screen says so and shows "—" with a retry.

enum TradeData {
    // MARK: Markets we feature (the rest of Hyperliquid's perps are one search away)

    static let featuredPerps = ["BTC", "ETH", "SOL", "HYPE", "xyz:TSLA", "xyz:GOLD"]

    /// Symbols whose LogoMark is the token's real logo. Anything else gets a neutral letter, never a lookalike.
    static let tokenLogos: Set<String> = ["BTC", "ETH", "SOL", "HYPE", "BNB", "XRP", "DOGE", "SUI", "TIA", "PEPE", "WIF", "PENGU",
                                          "USDC", "USDT", "USDE", "ENA", "JUP", "MON", "LIT", "XPL", "ASTER", "TSLA", "NVDA", "GOLD"]
    static func logo(_ sym: String) -> String? { tokenLogos.contains(sym.uppercased()) ? sym : nil }
    /// Solana mints whose bundled logo is theirs for sure. Any other token, even one that calls itself USDC or WIF,
    /// shows its own icon from Jupiter, so a look-alike never wears the real logo.
    static let knownMintLogos: [String: String] = [
        "So11111111111111111111111111111111111111112": "SOL", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": "USDC",
        "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": "USDT", "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN": "JUP",
        "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm": "WIF", "2zMMhcVQEXDtdE6vsFS7S7D5oUodfJHE8vd1gnBouauv": "PENGU",
    ]
    static func logo(mint: String) -> String? { knownMintLogos[mint] }

    /// Chart timeframes: label, interval (Hyperliquid's spelling), seconds per candle.
    static let timeframes: [(String, String, Double)] = [("15m", "15m", 900), ("1H", "1h", 3600), ("4H", "4h", 14400), ("1D", "1d", 86400)]

    // MARK: Models

    struct Perp: Identifiable, Hashable, Sendable, Codable {
        var id: String { coin }
        let coin: String
        let px, prev, funding, oi, vol: Double
        let maxLev: Int
        var sym: String { coin.split(separator: ":").last.map(String.init) ?? coin }
        var venue: String { coin.hasPrefix("xyz:") ? "trade.xyz" : "Hyperliquid" }
        /// 24h change in percent, from the price a day ago.
        var ch: Double { prev > 0 ? (px / prev - 1) * 100 : 0 }
        var oiUSD: Double { oi * px }
        /// Funding per hour, in percent.
        var fundPct: Double { funding * 100 }
        /// Hourly funding annualized, in percent (what a cash-and-carry earns while it holds).
        var fundAPR: Double { funding * 24 * 365 * 100 }
    }

    struct Ticker: Hashable, Sendable { let px, ch, vol, high, low: Double }

    struct BookLevel: Hashable, Sendable { let px, sz: Double }
    struct Book: Sendable { let bids, asks: [BookLevel] }
    struct Print: Hashable, Sendable { let px, sz: Double; let buy: Bool; let time: Date }

    struct Prediction: Identifiable, Hashable, Sendable, Codable {
        let id, q, slug: String
        let outcomes: [String]
        let prices: [Double]
        let vol24: Double
        let ends: Date?
    }

    /// Explore more: every listed Hyperliquid perp, by volume. Picking one asks Hermit about it.
    @MainActor static var moreMarkets: [TradeExploreItem] {
        MarketFeed.shared.perps.values.sorted { $0.vol > $1.vol }.map {
            TradeExploreItem(name: $0.sym, logo: $0.sym, sub: "\($0.venue) perp, \($0.vol.tradeCompactUSD) volume", metric: "$" + $0.px.tradePx)
        }
    }
}

// MARK: Networking

enum MarketError: LocalizedError {
    case http(Int), shape
    var errorDescription: String? {
        switch self { case .http(let c): "The server answered \(c)"; case .shape: "Unexpected response" }
    }
}

/// Thin URLSession helpers. Everything is async and off the main actor; callers publish results on it.
enum MarketHTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Seconds without a byte before giving up (not a cap on a whole download). One retry follows, so a dead
        // endpoint frees the screen in about 20 s instead of a minute.
        c.timeoutIntervalForRequest = 10
        // Live prices ask for a fresh copy per request (`fresh`); big lists revalidate (ETag) against this disk cache.
        c.requestCachePolicy = .useProtocolCachePolicy
        c.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 60 << 20, directory: nil)
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// `fresh: false` lets a big list that rarely changes (Jupiter's token list) come from the local cache when the
    /// server says it's still current. Prices, books and accounts keep the default: always a new copy.
    static func data(_ url: String, json body: String? = nil, fresh: Bool = true) async throws -> Data {
        guard let u = URL(string: url) else { throw MarketError.shape }
        var r = URLRequest(url: u)
        if fresh { r.cachePolicy = .reloadIgnoringLocalCacheData }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpMethod = "POST"
            r.httpBody = Data(body.utf8)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Every call here only reads, so a timeout, a dropped connection or a busy gateway is tried once more.
        var retried = false
        while true {
            do {
                let (d, resp) = try await session.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if [502, 503, 504].contains(code), !retried {
                    retried = true
                    try await Task.sleep(for: .milliseconds(500))
                    continue
                }
                guard (200..<300).contains(code) else { throw MarketError.http(code) }
                return d
            } catch let e as URLError where !retried && transient(e) {
                retried = true
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Worth one more try. Offline isn't: the second try would fail the same way.
    private static func transient(_ e: URLError) -> Bool {
        let codes: [URLError.Code] = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
        return codes.contains(e.code)
    }

    static func json(_ url: String, json body: String? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await data(url, json: body))
    }

    /// Numbers arrive as strings (Hyperliquid) or numbers (Polymarket).
    static func num(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// The calls themselves. Each throws on failure so the screen can show an honest error.
enum TradeAPI {
    private static let hl = "https://api.hyperliquid.xyz/info"

    // MARK: Hyperliquid

    /// Every live perp on Hyperliquid's main dex plus trade.xyz.
    static func perps() async throws -> [TradeData.Perp] {
        async let main = perps(dex: nil)
        async let xyz = try? perps(dex: "xyz")
        return try await main + (await xyz ?? [])
    }

    static func perps(dex: String?) async throws -> [TradeData.Perp] {
        let body = dex.map { #"{"type":"metaAndAssetCtxs","dex":"\#($0)"}"# } ?? #"{"type":"metaAndAssetCtxs"}"#
        guard let arr = try await MarketHTTP.json(hl, json: body) as? [Any], arr.count == 2,
              let meta = arr[0] as? [String: Any], let universe = meta["universe"] as? [[String: Any]],
              let ctxs = arr[1] as? [[String: Any]] else { throw MarketError.shape }
        return zip(universe, ctxs).compactMap { u, c in
            guard let name = u["name"] as? String, (u["isDelisted"] as? Bool) != true,
                  let px = MarketHTTP.num(c["markPx"]), px > 0 else { return nil }
            return TradeData.Perp(coin: name, px: px, prev: MarketHTTP.num(c["prevDayPx"]) ?? 0, funding: MarketHTTP.num(c["funding"]) ?? 0,
                                  oi: MarketHTTP.num(c["openInterest"]) ?? 0, vol: MarketHTTP.num(c["dayNtlVlm"]) ?? 0,
                                  maxLev: (u["maxLeverage"] as? Int) ?? 10)
        }
    }

    static func perpCandles(_ coin: String, interval: String, seconds: Double, count: Int = 60) async throws -> [Candle] {
        let now = Date().timeIntervalSince1970
        let start = Int64((now - seconds * Double(count)) * 1000)
        let body = #"{"type":"candleSnapshot","req":{"coin":"\#(coin)","interval":"\#(interval)","startTime":\#(start)}}"#
        guard let rows = try await MarketHTTP.json(hl, json: body) as? [[String: Any]] else { throw MarketError.shape }
        let out = rows.compactMap { r -> Candle? in
            guard let o = MarketHTTP.num(r["o"]), let h = MarketHTTP.num(r["h"]), let l = MarketHTTP.num(r["l"]), let c = MarketHTTP.num(r["c"]) else { return nil }
            return Candle(o: o, h: h, l: l, c: c)
        }
        guard !out.isEmpty else { throw MarketError.shape }
        return Array(out.suffix(count))
    }

    static func book(_ coin: String) async throws -> TradeData.Book {
        guard let d = try await MarketHTTP.json(hl, json: #"{"type":"l2Book","coin":"\#(coin)"}"#) as? [String: Any],
              let levels = d["levels"] as? [[[String: Any]]], levels.count == 2 else { throw MarketError.shape }
        func side(_ l: [[String: Any]]) -> [TradeData.BookLevel] {
            l.compactMap { x in MarketHTTP.num(x["px"]).flatMap { p in MarketHTTP.num(x["sz"]).map { TradeData.BookLevel(px: p, sz: $0) } } }
        }
        return TradeData.Book(bids: side(levels[0]), asks: side(levels[1]))
    }

    static func prints(_ coin: String) async throws -> [TradeData.Print] {
        guard let rows = try await MarketHTTP.json(hl, json: #"{"type":"recentTrades","coin":"\#(coin)"}"#) as? [[String: Any]] else { throw MarketError.shape }
        return rows.compactMap { r in
            guard let p = MarketHTTP.num(r["px"]), let s = MarketHTTP.num(r["sz"]), let t = MarketHTTP.num(r["time"]) else { return nil }
            return TradeData.Print(px: p, sz: s, buy: (r["side"] as? String) == "B", time: Date(timeIntervalSince1970: t / 1000))
        }
        .sorted { $0.time > $1.time }
    }

    // MARK: Polymarket

    /// The busiest open two-outcome markets that haven't been decided yet. One-night sports lines ("Spread: ...",
    /// "Heat vs. Jazz") are left out while there are enough other markets to show.
    static func predictions(limit: Int = 12) async throws -> [TradeData.Prediction] {
        guard let rows = try await MarketHTTP.json("https://gamma-api.polymarket.com/markets?active=true&closed=false&order=volume24hr&ascending=false&limit=40") as? [[String: Any]]
        else { throw MarketError.shape }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func list(_ v: Any?) -> [String] {
            guard let s = v as? String, let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return [] }
            return a.map { "\($0)" }
        }
        let now = Date()
        let out: [TradeData.Prediction] = rows.compactMap { r in
            guard let q = r["question"] as? String, let id = (r["id"] as? String) ?? (r["id"] as? NSNumber)?.stringValue else { return nil }
            let outcomes = list(r["outcomes"]), prices = list(r["outcomePrices"]).compactMap(Double.init)
            let ends = (r["endDate"] as? String).flatMap { iso.date(from: $0) ?? isoFrac.date(from: $0) }
            guard outcomes.count == 2, prices.count == 2, prices.allSatisfy({ $0 > 0.01 && $0 < 0.99 }) else { return nil }
            if let ends, ends < now { return nil }
            return TradeData.Prediction(id: id, q: q, slug: r["slug"] as? String ?? "", outcomes: outcomes, prices: prices,
                                        vol24: MarketHTTP.num(r["volume24hr"]) ?? 0, ends: ends)
        }
        guard !rows.isEmpty else { throw MarketError.shape }
        let notSports = out.filter { !$0.q.hasPrefix("Spread:") && !$0.q.contains(" vs. ") && !$0.q.contains(" vs ") }
        return Array((notSports.count >= 6 ? notSports : out).prefix(limit))
    }
}

// MARK: Shared live state

enum FeedState: Equatable { case loading, ready, failed }

/// Prices shared by Trade and Earn so switching tabs doesn't refetch everything. Views poll it while they're on screen.
/// Snapshot tests never hit the network: they leave it loading, or fill it with a test fixture.
@MainActor @Observable
final class MarketFeed {
    static let shared = MarketFeed()

    var perps: [String: TradeData.Perp] = [:]
    var perpState: FeedState = .loading
    /// When the perp prices last arrived, and how many polls in a row have failed since. Two misses or a minute
    /// without news and the screens stop calling the prices live.
    var perpsUpdated: Date?
    var perpFailures = 0
    var perpsStale: Bool { perpFailures >= 2 || (perpsUpdated.map { Date().timeIntervalSince($0) > 60 } ?? false) }
    /// The prices on screen are the copy saved at the last launch, not yet replaced by a live one.
    var perpsSaved = false
    /// Spot tickers and row candles. Nothing fetches them since Spot and Memes moved to Jupiter; the snapshot fixture
    /// still fills them.
    var tickers: [String: TradeData.Ticker] = [:]
    var minis: [String: [Candle]] = [:]
    var tickerState: FeedState = .loading
    var predictions: [TradeData.Prediction] = []
    var predState: FeedState = .loading
    /// When the odds on screen arrived (the saved copy's date until the first live answer).
    var predsUpdated: Date?

    /// The last prices and markets show at once, with their real age, so no screen opens empty on a slow network.
    /// They are stale from the start (`perpsUpdated` is when they were fetched), so a market order still waits for
    /// a live price.
    init() {
        let store = SnapshotStore.live
        if let s = store.load("perps", as: [TradeData.Perp].self) {
            perps = Dictionary(s.value.map { ($0.coin, $0) }, uniquingKeysWith: { a, _ in a })
            perpState = .ready; perpsUpdated = s.saved; perpsSaved = true
        }
        if let s = store.load("predictions", as: [TradeData.Prediction].self, maxAge: 86_400) {
            predictions = s.value.filter { ($0.ends ?? .distantFuture) > Date() }
            predState = .ready; predsUpdated = s.saved
        }
    }

    func refreshPerps() async {
        guard !SnapshotMode.active else { return }
        // Both dexes at once. The main list shows as soon as it's in; trade.xyz joins when it answers.
        async let xyzList = try? TradeAPI.perps(dex: "xyz")
        let main: [TradeData.Perp]
        do {
            main = try await TradeAPI.perps(dex: nil)
        } catch {
            perpFailures += 1
            if perps.isEmpty { perpState = .failed }
            _ = await xyzList
            return
        }
        let mainNow = Dictionary(main.map { ($0.coin, $0) }, uniquingKeysWith: { a, _ in a })
        // Until trade.xyz answers, its markets keep their prices only when those are live (under a minute old), never
        // a saved copy: a market order reads them as current.
        let xyzLive = !perpsSaved && (perpsUpdated.map { Date().timeIntervalSince($0) < 60 } ?? false)
        perps = mainNow.merging(xyzLive ? perps.filter { $0.key.hasPrefix("xyz:") } : [:], uniquingKeysWith: { a, _ in a })
        perpState = .ready
        perpsUpdated = Date(); perpFailures = 0; perpsSaved = false
        // As before: trade.xyz markets that didn't answer this time drop out rather than show an old price as live.
        let xyz = await xyzList ?? []
        perps = mainNow.merging(xyz.map { ($0.coin, $0) }, uniquingKeysWith: { a, _ in a })
        SnapshotStore.live.save(Array(perps.values), "perps")
    }

    func refreshPredictions() async {
        guard !SnapshotMode.active else { return }
        do {
            predictions = try await TradeAPI.predictions(); predState = .ready; predsUpdated = Date()
            SnapshotStore.live.save(predictions, "predictions")
        }
        catch { if predictions.isEmpty { predState = .failed } }
    }
}

extension View {
    /// Runs `work` now and again every `seconds` while the view is on screen (the task stops when it goes away).
    /// Paused while the app is in the background. Skipped in snapshot tests, which can't reach the network.
    func marketPoll<ID: Equatable>(every seconds: Double, id: ID, _ work: @escaping @MainActor () async -> Void) -> some View {
        modifier(MarketPoll(seconds: seconds, id: id, work: { await work(); return true }))
    }
    func marketPoll(every seconds: Double, _ work: @escaping @MainActor () async -> Void) -> some View {
        marketPoll(every: seconds, id: 0, work)
    }
    /// The same, for work that says whether it got through: after a failure it waits twice as long each time (up to a
    /// minute), so an offline or rate-limited feed isn't hammered.
    func marketPollBackingOff<ID: Equatable>(every seconds: Double, id: ID, _ work: @escaping @MainActor () async -> Bool) -> some View {
        modifier(MarketPoll(seconds: seconds, id: id, work: work))
    }
}

private struct MarketPoll<ID: Equatable>: ViewModifier {
    let seconds: Double
    let id: ID
    let work: @MainActor () async -> Bool
    @Environment(\.scenePhase) private var phase

    struct Key: Equatable { let id: ID; let paused: Bool }

    func body(content: Content) -> some View {
        content.task(id: Key(id: id, paused: phase == .background)) {
            guard !SnapshotMode.active, phase != .background else { return }
            var wait = seconds
            while !Task.isCancelled {
                let ok = await work()
                wait = ok ? seconds : min(wait * 2, max(seconds, 60))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }
}
