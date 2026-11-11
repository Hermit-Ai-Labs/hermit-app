import Foundation

/// A USD price with its 24-hour change, from CoinGecko's free `simple/price` endpoint (no key).
public struct PriceQuote: Equatable, Sendable {
    public let usd: Double
    /// Percent, e.g. 1.5 for +1.5%. nil when the price came from 1Click, which gives none.
    public let change24h: Double?
}

/// USD prices for the coins the wallet holds. Mainnet symbols only: testnet coins have no price and get none.
/// CoinGecko first; when it fails or rate-limits, the prices in 1Click's token list. On any failure the answer is
/// simply missing, never a guess, and prices older than `staleAfter` are never served as live.
public actor PriceFeed {
    public static let shared = PriceFeed()

    /// Symbol -> CoinGecko id. USDT0 is Tether's omnichain USDT, priced as USDT; USDC.e is bridged USDC.
    public static let ids: [String: String] = [
        "ETH": "ethereum", "BNB": "binancecoin", "SOL": "solana", "MON": "monad", "POL": "polygon-ecosystem-token",
        "USDC": "usd-coin", "USDC.e": "usd-coin", "USDT": "tether", "USDT0": "tether", "NEAR": "near", "wNEAR": "near",
    ]

    /// Where each symbol is listed in 1Click's tokens (the chain whose native coin or token it is). wNEAR is priced as NEAR.
    static let intentsChains: [String: Chain] = [
        "ETH": .ethereum, "BNB": .bnb, "SOL": .solana, "MON": .monad, "POL": .polygon, "NEAR": .near,
        "USDC": .ethereum, "USDT": .ethereum, "USDT0": .arbitrum, "USDC.e": .polygon,
    ]

    /// Cached prices are dropped after this long without a successful fetch.
    public static let staleAfter: TimeInterval = 15 * 60

    let session: URLSession
    let maxAge: TimeInterval
    let oneClick: OneClick
    private var cache: [String: PriceQuote] = [:]
    private var fetched: Date?

    public init(session: URLSession = .shared, maxAge: TimeInterval = 60, oneClick: OneClick = OneClick()) {
        self.session = session; self.maxAge = maxAge; self.oneClick = oneClick
    }

    /// When the prices `quotes()` serves were fetched. nil before the first success.
    public var updated: Date? { fetched }
    /// True when the last good prices are more than five minutes old (the feeds have been failing), so the UI can say so.
    public var stale: Bool { fetched.map { Date().timeIntervalSince($0) > 5 * 60 } ?? true }

    /// The latest quotes, refetched when older than `maxAge`. Symbols neither source answered for are left out.
    public func quotes() async -> [String: PriceQuote] {
        if let f = fetched, Date().timeIntervalSince(f) < maxAge, !cache.isEmpty { return cache }
        var out = await coinGecko()
        if out.count < Self.ids.count, let list = try? await oneClick.tokens() {
            for (sym, q) in Self.quotes(fromIntents: list) where out[sym] == nil { out[sym] = q }
        }
        if !out.isEmpty { cache = out; fetched = Date(); return cache }
        // Nothing answered: keep what we had while it's recent; callers show "no price" once it's empty.
        if let f = fetched, Date().timeIntervalSince(f) < Self.staleAfter { return cache }
        cache = [:]
        return [:]
    }

    func coinGecko() async -> [String: PriceQuote] {
        let ids = Set(Self.ids.values).sorted().joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd&include_24hr_change=true") else {
            return [:]
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode([String: [String: Double?]].self, from: data) else {
            return [:]
        }
        var out: [String: PriceQuote] = [:]
        for (sym, id) in Self.ids {
            if let q = json[id], let usd = q["usd"] ?? nil, usd > 0 { out[sym] = PriceQuote(usd: usd, change24h: q["usd_24h_change"] ?? nil) }
        }
        return out
    }

    /// Prices from 1Click's token list for the symbols the wallet knows, matched by chain and contract (not by symbol
    /// alone, so a look-alike token elsewhere can't set a price).
    static func quotes(fromIntents list: [IntentsToken]) -> [String: PriceQuote] {
        var out: [String: PriceQuote] = [:]
        for (sym, chain) in intentsChains {
            guard let t = IntentsAssets.token(sym, at: .chain(chain), in: list), let usd = t.price, usd.isFinite, usd > 0 else { continue }
            out[sym] = PriceQuote(usd: usd, change24h: nil)
        }
        if let near = out["NEAR"] { out["wNEAR"] = near }
        return out
    }
}
