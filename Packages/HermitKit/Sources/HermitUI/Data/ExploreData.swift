import SwiftUI
import Observation

// The Explore directory: apps and protocols worth knowing, newest and most used of the past year. The list itself is
// editorial (name, category, chain, what it does). The only figures shown are TVL and its 7-day change from DefiLlama
// (api.llama.fi/protocols), fetched live; apps DefiLlama doesn't track show none.

struct ExploreDapp: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let cat: String
    let chain: String
    var isNew = false
    let desc: String
    /// DefiLlama key: a protocol slug, or "parent#x" to sum every protocol under that parent. Nil when it isn't tracked.
    var llama: String? = nil
}

extension ExploreDapp {
    /// The app's own site, opened in Safari.
    var url: URL? { ExploreData.sites[name].flatMap { URL(string: "https://" + $0) } }
}

enum ExploreData {
    static let sites: [String: String] = [
        "Hyperliquid": "app.hyperliquid.xyz",
        "Aave": "app.aave.com",
        "Pendle": "app.pendle.finance",
        "Ethena": "app.ethena.fi",
        "Jupiter": "jup.ag",
        "Uniswap": "app.uniswap.org",
        "Lido": "stake.lido.fi",
        "Pump.fun": "pump.fun",
        "Morpho": "app.morpho.org",
        "Kamino": "app.kamino.finance",
        "Polymarket": "polymarket.com",
        "Legion": "legion.cc",
        "Lighter": "app.lighter.xyz",
        "trade.xyz": "trade.xyz",
        "Aster": "www.asterdex.com",
        "Paradex": "app.paradex.trade",
        "Extended": "app.extended.exchange",
        "Variational": "variational.io",
        "Kalshi": "kalshi.com",
        "Predict.fun": "predict.fun",
        "Opinion": "opinion.trade",
        "Limitless": "limitless.exchange",
        "Coinbase Sales": "www.coinbase.com",
        "MetaDAO": "metadao.fi",
        "Echo": "echo.xyz",
        "Jupiter Lend": "jup.ag/lend",
        "Curvance": "curvance.com",
        "Kuru": "kuru.io",
        "Aerodrome": "aerodrome.finance",
        "USD.AI": "usd.ai",
        "Falcon": "falcon.finance",
        "Maple": "maple.finance",
        "Plasma": "plasma.to",
        "Kinetiq": "kinetiq.xyz",
        "Infrared": "infrared.finance",
        "Ondo": "ondo.finance",
        "xStocks": "xstocks.com",
        "BUIDL": "securitize.io",
        "Virtuals": "app.virtuals.io",
        "x402": "x402.org",
        "Infinex": "infinex.xyz"
    ]

    static let categories = ["All", "New", "Perps", "DEX", "Lending", "Yield", "Stablecoin", "Staking", "RWA",
                             "Prediction", "Presale", "Launchpad", "AI agents", "Wallet"]

    static let dapps: [ExploreDapp] = [
        .init(name: "Hyperliquid", cat: "Perps", chain: "HyperEVM", desc: "Perps", llama: "parent#hyperliquid"),
        .init(name: "Aave", cat: "Lending", chain: "Multi-chain", desc: "Lending", llama: "parent#aave"),
        .init(name: "Pendle", cat: "Yield", chain: "Multi-chain", desc: "Fixed yield", llama: "parent#pendle"),
        .init(name: "Ethena", cat: "Yield", chain: "Ethereum", desc: "Synthetic dollar", llama: "parent#ethena"),
        .init(name: "Jupiter", cat: "DEX", chain: "Solana", desc: "Swaps", llama: "parent#jupiter"),
        .init(name: "Uniswap", cat: "DEX", chain: "Multi-chain", desc: "Swaps and LP", llama: "parent#uniswap"),
        .init(name: "Lido", cat: "Staking", chain: "Ethereum", desc: "ETH staking", llama: "lido"),
        .init(name: "Pump.fun", cat: "Launchpad", chain: "Solana", desc: "Meme launches"),
        .init(name: "Morpho", cat: "Lending", chain: "Multi-chain", desc: "Lending vaults", llama: "parent#morpho"),
        .init(name: "Kamino", cat: "Yield", chain: "Solana", desc: "Liquidity vaults", llama: "parent#kamino-finance"),
        .init(name: "Polymarket", cat: "Prediction", chain: "Polygon", desc: "Predictions", llama: "parent#polymarket"),
        .init(name: "Legion", cat: "Presale", chain: "Multi-chain", desc: "Token sales"),
        .init(name: "Lighter", cat: "Perps", chain: "Ethereum zk", isNew: true, desc: "Zero-fee zk perps", llama: "parent#lighter"),
        .init(name: "trade.xyz", cat: "Perps", chain: "Hyperliquid", isNew: true, desc: "Stock and gold perps"),
        .init(name: "Aster", cat: "Perps", chain: "BNB", desc: "Multichain perps", llama: "parent#astherus"),
        .init(name: "Paradex", cat: "Perps", chain: "Starknet", desc: "Private perps", llama: "parent#paradex"),
        .init(name: "Extended", cat: "Perps", chain: "Starknet", desc: "Starknet perps", llama: "parent#extended"),
        .init(name: "Variational", cat: "Perps", chain: "Arbitrum", desc: "Zero-fee RFQ perps"),
        .init(name: "Kalshi", cat: "Prediction", chain: "Regulated", desc: "Regulated predictions"),
        .init(name: "Predict.fun", cat: "Prediction", chain: "BNB", isNew: true, desc: "Yield-bearing bets", llama: "predict-fun"),
        .init(name: "Opinion", cat: "Prediction", chain: "BNB", isNew: true, desc: "Macro predictions"),
        .init(name: "Limitless", cat: "Prediction", chain: "Base", desc: "Short-term price markets"),
        .init(name: "Coinbase Sales", cat: "Presale", chain: "Multichain", isNew: true, desc: "Public token sales"),
        .init(name: "MetaDAO", cat: "Presale", chain: "Solana", desc: "Futarchy ICOs"),
        .init(name: "Echo", cat: "Presale", chain: "Multichain", desc: "Token sales"),
        .init(name: "Jupiter Lend", cat: "Lending", chain: "Solana", isNew: true, desc: "Solana lending", llama: "jupiter-lend"),
        .init(name: "Curvance", cat: "Lending", chain: "Monad", isNew: true, desc: "Lend yield assets", llama: "curvance"),
        .init(name: "Kuru", cat: "DEX", chain: "Monad", isNew: true, desc: "Order book DEX"),
        .init(name: "Aerodrome", cat: "DEX", chain: "Base", desc: "Base swaps and LP", llama: "parent#aero-protocol"),
        .init(name: "USD.AI", cat: "Yield", chain: "Arbitrum", isNew: true, desc: "Yield from GPU loans", llama: "usd-ai"),
        .init(name: "Falcon", cat: "Stablecoin", chain: "Ethereum", desc: "Synthetic dollar USDf", llama: "falcon-finance"),
        .init(name: "Maple", cat: "Yield", chain: "Multichain", desc: "Institutional credit yield", llama: "parent#maple-finance"),
        .init(name: "Plasma", cat: "Stablecoin", chain: "Plasma", isNew: true, desc: "Zero-fee USDT chain"),
        .init(name: "Kinetiq", cat: "Staking", chain: "HyperEVM", isNew: true, desc: "HYPE liquid staking", llama: "parent#kinetiq"),
        .init(name: "Infrared", cat: "Staking", chain: "Berachain", desc: "Berachain staking", llama: "infrared-finance"),
        .init(name: "Ondo", cat: "RWA", chain: "Multichain", isNew: true, desc: "Tokenized US stocks", llama: "parent#ondo-finance"),
        .init(name: "xStocks", cat: "RWA", chain: "Solana", desc: "Tokenized stocks", llama: "xstocks"),
        .init(name: "BUIDL", cat: "RWA", chain: "Ethereum", desc: "BlackRock treasury fund", llama: "blackrock-buidl"),
        .init(name: "Virtuals", cat: "AI agents", chain: "Base", desc: "AI agent launchpad"),
        .init(name: "x402", cat: "AI agents", chain: "Base", isNew: true, desc: "Agent payments"),
        .init(name: "Infinex", cat: "Wallet", chain: "20+ chains", isNew: true, desc: "Passkey wallet app"),
    ]
}

/// TVL now and its change over 7 days, in percent.
struct ExploreTVL: Codable, Hashable, Sendable { let tvl: Double; let change7d: Double? }

enum ExploreAPI {
    private struct Raw: Decodable {
        let slug: String?
        let parentProtocol: String?
        let tvl: Double?
        let change_7d: Double?
    }

    /// TVL per directory key. Parents are summed over their protocols; the 7-day change is worked out from each
    /// protocol's own change so the sum stays honest.
    static func tvls(keys: Set<String>) async throws -> [String: ExploreTVL] {
        let rows = try JSONDecoder().decode([Raw].self, from: try await MarketHTTP.data("https://api.llama.fi/protocols"))
        var now: [String: Double] = [:], before: [String: Double] = [:], known: [String: Bool] = [:]
        for r in rows {
            guard let tvl = r.tvl, tvl > 0 else { continue }
            for k in [r.slug, r.parentProtocol].compactMap({ $0 }) where keys.contains(k) {
                now[k, default: 0] += tvl
                if let c = r.change_7d, c > -100 { before[k, default: 0] += tvl / (1 + c / 100); known[k] = known[k] ?? true }
                else { known[k] = false }
            }
        }
        return now.reduce(into: [:]) { out, kv in
            let b = before[kv.key] ?? 0
            out[kv.key] = ExploreTVL(tvl: kv.value, change7d: known[kv.key] == true && b > 0 ? (kv.value / b - 1) * 100 : nil)
        }
    }
}

/// Live TVL for the directory, cached on disk for an hour (the protocols list is ~9 MB).
@MainActor @Observable
final class ExploreStore {
    static let shared = ExploreStore()
    var tvl: [String: ExploreTVL] = [:]
    var state: FeedState = .loading
    private var updated: Date?

    func value(_ d: ExploreDapp) -> ExploreTVL? { d.llama.flatMap { tvl[$0] } }

    func refresh(force: Bool = false) async {
        guard !SnapshotMode.active else { return }
        if !force, tvl.isEmpty, let cached = MarketDiskCache.load("explore-tvl", maxAge: 3600, as: [String: ExploreTVL].self), !cached.isEmpty {
            tvl = cached; state = .ready; updated = Date()
            return
        }
        if !force, let updated, Date().timeIntervalSince(updated) < 900 { return }
        do {
            let t = try await ExploreAPI.tvls(keys: Set(ExploreData.dapps.compactMap(\.llama)))
            tvl = t; state = .ready; updated = Date()
            MarketDiskCache.save("explore-tvl", t)
        } catch { if tvl.isEmpty { state = .failed } }
    }
}

// MARK: Search

extension ExploreData {
    /// Apps whose name is close to `query` even when it's misspelled ("uniswp", "morfo", "aave app"), best first.
    /// The query (and each word of it) is compared with the name and each word of the name by edit distance, allowing
    /// about one typo per three letters; a name that starts with the query counts as a match too.
    static func fuzzy(_ query: String, in list: [ExploreDapp], limit: Int = 6) -> [ExploreDapp] {
        let q = fold(query)
        let queries = ([q.replacingOccurrences(of: " ", with: "")] + q.split(separator: " ").map(String.init).filter { $0.count >= 3 })
            .filter { $0.count >= 2 }
        guard !queries.isEmpty else { return [] }
        let scored: [(ExploreDapp, Int)] = list.compactMap { d in
            let name = fold(d.name)
            let words = [name.replacingOccurrences(of: " ", with: "")] + name.split(separator: " ").map(String.init)
            let best = queries.compactMap { score($0, words) }.min()
            return best.map { (d, $0) }
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    /// The closest any word comes to `q`, or nil when it's further than the typo allowance.
    private static func score(_ q: String, _ words: [String]) -> Int? {
        var best = Int.max
        for w in words {
            if w.hasPrefix(q) { return 0 }
            // Also against the start of the word as long as the query, so "hyperliqu" ~ "hyperliquid".
            best = min(best, distance(q, w), distance(q, String(w.prefix(q.count + 1))))
        }
        return best <= max(1, (q.count + 1) / 3) ? best : nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// A private web search for anything the directory doesn't have, opened in Hermit's browser.
    static func webSearch(_ query: String) -> URL? {
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }
}
