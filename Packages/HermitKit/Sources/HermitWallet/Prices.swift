import Foundation

/// A USD price with its 24-hour change, from CoinGecko's free `simple/price` endpoint (no key).
public struct PriceQuote: Equatable, Sendable {
    public let usd: Double
    /// Percent, e.g. 1.5 for +1.5%.
    public let change24h: Double?
}

/// USD prices for the coins the wallet holds. Mainnet symbols only: testnet coins have no price and get none.
/// On any failure the answer is simply missing, never a guess.
public actor PriceFeed {
    public static let shared = PriceFeed()

    /// Symbol -> CoinGecko id. USDT0 is Tether's omnichain USDT, priced as USDT.
    public static let ids: [String: String] = [
        "ETH": "ethereum", "BNB": "binancecoin", "SOL": "solana", "MON": "monad",
        "USDC": "usd-coin", "USDT": "tether", "USDT0": "tether", "NEAR": "near", "wNEAR": "near",
    ]

    let session: URLSession
    let maxAge: TimeInterval
    private var cache: [String: PriceQuote] = [:]
    private var fetched: Date?

    public init(session: URLSession = .shared, maxAge: TimeInterval = 60) { self.session = session; self.maxAge = maxAge }

    /// The latest quotes, refetched when older than `maxAge`. Symbols CoinGecko didn't answer for are left out.
    public func quotes() async -> [String: PriceQuote] {
        if let f = fetched, Date().timeIntervalSince(f) < maxAge, !cache.isEmpty { return cache }
        let ids = Set(Self.ids.values).sorted().joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd&include_24hr_change=true") else {
            return cache
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONDecoder().decode([String: [String: Double?]].self, from: data) else {
            return cache // keep what we had; callers show "no price" if this is empty
        }
        var out: [String: PriceQuote] = [:]
        for (sym, id) in Self.ids {
            if let q = json[id], let usd = q["usd"] ?? nil, usd > 0 { out[sym] = PriceQuote(usd: usd, change24h: q["usd_24h_change"] ?? nil) }
        }
        if !out.isEmpty { cache = out; fetched = Date() }
        return cache
    }
}
