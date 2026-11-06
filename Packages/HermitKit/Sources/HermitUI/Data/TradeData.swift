import SwiftUI
import Foundation

// Live market data for Trade (and the funding rates in Earn > Arbitrage). All of it comes from public, keyless APIs:
//   Hyperliquid  perps: mark price, 24h change, volume, open interest, funding, candles, order book, trades.
//                trade.xyz stock and gold perps live on Hyperliquid too (the "xyz" dex).
//   Binance      spot and meme tickers and candles (data-api.binance.vision when api.binance.com is blocked).
//   CoinGecko    spot fallback when neither Binance host answers.
//   Polymarket   prediction markets (gamma API).
// Nothing is made up: when a fetch fails the screen says so and shows "—" with a retry.

enum TradeData {
    // MARK: Markets we feature (the rest of Hyperliquid's perps are one search away)

    static let featuredPerps = ["BTC", "ETH", "SOL", "HYPE", "xyz:TSLA", "xyz:GOLD"]

    /// Spot and meme tokens: symbol, name, Binance pair, CoinGecko id.
    struct Token: Hashable, Sendable { let sym, name, pair, gecko: String }
    static let spotTokens: [Token] = [
        Token(sym: "BTC", name: "Bitcoin", pair: "BTCUSDT", gecko: "bitcoin"),
        Token(sym: "ETH", name: "Ethereum", pair: "ETHUSDT", gecko: "ethereum"),
        Token(sym: "SOL", name: "Solana", pair: "SOLUSDT", gecko: "solana"),
        Token(sym: "BNB", name: "BNB", pair: "BNBUSDT", gecko: "binancecoin"),
        Token(sym: "HYPE", name: "Hyperliquid", pair: "HYPEUSDT", gecko: "hyperliquid"),
        Token(sym: "XRP", name: "XRP", pair: "XRPUSDT", gecko: "ripple"),
    ]
    static let memeTokens: [Token] = [
        Token(sym: "PEPE", name: "Pepe", pair: "PEPEUSDT", gecko: "pepe"),
        Token(sym: "WIF", name: "dogwifhat", pair: "WIFUSDT", gecko: "dogwifcoin"),
        Token(sym: "PENGU", name: "Pudgy Penguins", pair: "PENGUUSDT", gecko: "pudgy-penguins"),
        Token(sym: "BONK", name: "Bonk", pair: "BONKUSDT", gecko: "bonk"),
        Token(sym: "DOGE", name: "Dogecoin", pair: "DOGEUSDT", gecko: "dogecoin"),
        Token(sym: "SHIB", name: "Shiba Inu", pair: "SHIBUSDT", gecko: "shiba-inu"),
    ]

    /// Symbols whose LogoMark is the token's real logo. Anything else gets a neutral letter, never a lookalike.
    static let tokenLogos: Set<String> = ["BTC", "ETH", "SOL", "HYPE", "BNB", "XRP", "DOGE", "SUI", "TIA", "PEPE", "WIF", "PENGU",
                                          "USDC", "USDT", "USDE", "ENA", "JUP", "MON", "LIT", "XPL", "ASTER", "TSLA", "NVDA", "GOLD"]
    static func logo(_ sym: String) -> String? { tokenLogos.contains(sym.uppercased()) ? sym : nil }

    /// Chart timeframes: label, interval (same spelling on Hyperliquid and Binance), seconds per candle.
    static let timeframes: [(String, String, Double)] = [("15m", "15m", 900), ("1H", "1h", 3600), ("4H", "4h", 14400), ("1D", "1d", 86400)]

    // MARK: Models

    struct Perp: Identifiable, Hashable, Sendable {
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

    struct Prediction: Identifiable, Hashable, Sendable {
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
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func data(_ url: String, json body: String? = nil) async throws -> Data {
        guard let u = URL(string: url) else { throw MarketError.shape }
        var r = URLRequest(url: u)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpMethod = "POST"
            r.httpBody = Data(body.utf8)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw MarketError.http(code) }
        return d
    }

    static func json(_ url: String, json body: String? = nil) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await data(url, json: body))
    }

    /// Numbers arrive as strings (Hyperliquid, Binance) or numbers (CoinGecko).
    static func num(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// The calls themselves. Each throws on failure so the screen can show an honest error.
enum TradeAPI {
    private static let hl = "https://api.hyperliquid.xyz/info"
    private static let binanceHosts = ["https://api.binance.com", "https://data-api.binance.vision"]

    // MARK: Hyperliquid

    /// Every live perp on Hyperliquid's main dex plus trade.xyz.
    static func perps() async throws -> [TradeData.Perp] {
        async let main = perps(dex: nil)
        async let xyz = try? perps(dex: "xyz")
        return try await main + (await xyz ?? [])
    }

    private static func perps(dex: String?) async throws -> [TradeData.Perp] {
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

    // MARK: Binance, CoinGecko fallback

    /// Tickers by symbol, plus which source answered.
    static func tickers(_ tokens: [TradeData.Token]) async throws -> ([String: TradeData.Ticker], String) {
        let syms = "[" + tokens.map { "\"\($0.pair)\"" }.joined(separator: ",") + "]"
        let q = syms.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? syms
        for host in binanceHosts {
            guard let rows = try? await MarketHTTP.json("\(host)/api/v3/ticker/24hr?symbols=\(q)") as? [[String: Any]] else { continue }
            var out: [String: TradeData.Ticker] = [:]
            for r in rows {
                guard let pair = r["symbol"] as? String, let t = tokens.first(where: { $0.pair == pair }),
                      let px = MarketHTTP.num(r["lastPrice"]) else { continue }
                out[t.sym] = TradeData.Ticker(px: px, ch: MarketHTTP.num(r["priceChangePercent"]) ?? 0, vol: MarketHTTP.num(r["quoteVolume"]) ?? 0,
                                              high: MarketHTTP.num(r["highPrice"]) ?? px, low: MarketHTTP.num(r["lowPrice"]) ?? px)
            }
            if !out.isEmpty { return (out, "Binance") }
        }
        let ids = tokens.map(\.gecko).joined(separator: ",")
        guard let rows = try await MarketHTTP.json("https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=\(ids)") as? [[String: Any]] else { throw MarketError.shape }
        var out: [String: TradeData.Ticker] = [:]
        for r in rows {
            guard let id = r["id"] as? String, let t = tokens.first(where: { $0.gecko == id }), let px = MarketHTTP.num(r["current_price"]) else { continue }
            out[t.sym] = TradeData.Ticker(px: px, ch: MarketHTTP.num(r["price_change_percentage_24h"]) ?? 0, vol: MarketHTTP.num(r["total_volume"]) ?? 0,
                                          high: MarketHTTP.num(r["high_24h"]) ?? px, low: MarketHTTP.num(r["low_24h"]) ?? px)
        }
        guard !out.isEmpty else { throw MarketError.shape }
        return (out, "CoinGecko")
    }

    static func spotCandles(_ t: TradeData.Token, interval: String = "1h", count: Int = 60) async throws -> [Candle] {
        for host in binanceHosts {
            guard let rows = try? await MarketHTTP.json("\(host)/api/v3/klines?symbol=\(t.pair)&interval=\(interval)&limit=\(count)") as? [[Any]] else { continue }
            let out = rows.compactMap { r -> Candle? in
                guard r.count > 4, let o = MarketHTTP.num(r[1]), let h = MarketHTTP.num(r[2]), let l = MarketHTTP.num(r[3]), let c = MarketHTTP.num(r[4]) else { return nil }
                return Candle(o: o, h: h, l: l, c: c)
            }
            if !out.isEmpty { return out }
        }
        // CoinGecko's OHLC: 30-minute candles for the last day.
        guard let rows = try await MarketHTTP.json("https://api.coingecko.com/api/v3/coins/\(t.gecko)/ohlc?vs_currency=usd&days=1") as? [[Any]] else { throw MarketError.shape }
        let out = rows.compactMap { r -> Candle? in
            guard r.count > 4, let o = MarketHTTP.num(r[1]), let h = MarketHTTP.num(r[2]), let l = MarketHTTP.num(r[3]), let c = MarketHTTP.num(r[4]) else { return nil }
            return Candle(o: o, h: h, l: l, c: c)
        }
        guard !out.isEmpty else { throw MarketError.shape }
        return Array(out.suffix(count))
    }

    // MARK: Polymarket

    /// The busiest open two-outcome markets that haven't been decided yet.
    static func predictions(limit: Int = 8) async throws -> [TradeData.Prediction] {
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
        return Array(out.prefix(limit))
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
    var tickers: [String: TradeData.Ticker] = [:]
    var minis: [String: [Candle]] = [:]
    var tickerState: FeedState = .loading
    var tickerSource = "Binance"
    var predictions: [TradeData.Prediction] = []
    var predState: FeedState = .loading

    func refreshPerps() async {
        guard !SnapshotMode.active else { return }
        do { let list = try await TradeAPI.perps(); perps = Dictionary(list.map { ($0.coin, $0) }, uniquingKeysWith: { a, _ in a }); perpState = .ready }
        catch { if perps.isEmpty { perpState = .failed } }
    }

    /// Spot and meme tickers in one call, then the small row candles.
    func refreshTickers() async {
        guard !SnapshotMode.active else { return }
        let all = TradeData.spotTokens + TradeData.memeTokens
        do {
            let (t, src) = try await TradeAPI.tickers(all)
            tickers = t; tickerSource = src; tickerState = .ready
        } catch { if tickers.isEmpty { tickerState = .failed } }
        guard tickerState == .ready else { return }
        let got = await withTaskGroup(of: (String, [Candle]?).self) { g in
            for tk in all { g.addTask { (tk.sym, try? await TradeAPI.spotCandles(tk, interval: "1h", count: 24)) } }
            var out: [String: [Candle]] = [:]
            for await (s, c) in g { if let c { out[s] = c } }
            return out
        }
        minis.merge(got) { _, new in new }
    }

    func refreshPredictions() async {
        guard !SnapshotMode.active else { return }
        do { predictions = try await TradeAPI.predictions(); predState = .ready }
        catch { if predictions.isEmpty { predState = .failed } }
    }
}

extension View {
    /// Runs `work` now and again every `seconds` while the view is on screen (the task stops when it goes away).
    /// Skipped in snapshot tests, which can't reach the network.
    func marketPoll<ID: Equatable>(every seconds: Double, id: ID, _ work: @escaping @MainActor () async -> Void) -> some View {
        task(id: id) {
            guard !SnapshotMode.active else { return }
            while !Task.isCancelled {
                await work()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
    func marketPoll(every seconds: Double, _ work: @escaping @MainActor () async -> Void) -> some View {
        marketPoll(every: seconds, id: 0, work)
    }
}
