import SwiftUI
import Foundation
import HermitWallet

// Real yields for Earn, from DefiLlama's public yields API (yields.llama.fi, no key). The full pool list is ~11 MB, so we
// keep only stablecoin and major-asset pools on the chains Hermit supports, decode it off the main actor, and cache that
// short list on disk: it shows at once (up to 6 hours old) and is fetched again when it's over an hour old.

enum EarnData {
    /// DefiLlama chain names we keep, and how we show them.
    static let chains: [(llama: String, name: String)] = [("Ethereum", "Ethereum"), ("Base", "Base"), ("Arbitrum", "Arbitrum"), ("BSC", "BNB Chain"), ("Solana", "Solana")]
    static func chainName(_ llama: String) -> String { chains.first { $0.llama == llama }?.name ?? llama }
    /// Mixed-case token symbols, keyed by the capitals DefiLlama uses.
    static let symbolCase: [String: String] = [
        "STETH": "stETH", "WSTETH": "wstETH", "WEETH": "weETH", "EETH": "eETH", "WBETH": "wBETH", "CBETH": "cbETH", "RETH": "rETH",
        "METH": "mETH", "EZETH": "ezETH", "RSETH": "rsETH", "OSETH": "osETH", "SFRXETH": "sfrxETH", "FRXETH": "frxETH", "LSETH": "LsETH",
        "ETHX": "ETHx", "CBBTC": "cbBTC", "TBTC": "tBTC", "SOLVBTC": "SolvBTC", "JITOSOL": "JitoSOL", "MSOL": "mSOL", "JUPSOL": "jupSOL",
        "BBSOL": "bbSOL", "INF": "INF", "SUSDE": "sUSDe", "USDE": "USDe", "SUSDS": "sUSDS", "SDAI": "sDAI", "SYRUPUSDC": "syrupUSDC",
        "SYRUPUSDT": "syrupUSDT", "SLISBNB": "slisBNB", "ASBNB": "asBNB", "USDC.E": "USDC.e", "SAVUSD": "savUSD", "SUSDA": "sUSDa",
    ]
    /// Non-stablecoin pools are kept when the symbol holds one of these.
    static let majors = ["ETH", "BTC", "SOL", "BNB"]

    /// Where each protocol's app lives, so any pool can be opened inside Hermit's browser with the wallet connected.
    static let projectSites: [String: String] = [
        "aave-v3": "app.aave.com", "aave-v4": "app.aave.com", "morpho-blue": "app.morpho.org", "pendle-v2": "app.pendle.finance",
        "ethena-usde": "app.ethena.fi", "lido": "stake.lido.fi", "jupiter-lend": "jup.ag/lend", "jupiter-staked-sol": "jup.ag/stake",
        "kamino-lend": "app.kamino.finance", "maple": "app.maple.finance", "falcon-finance": "app.falcon.finance",
        "ether.fi-stake": "app.ether.fi/eeth", "ether.fi-liquid": "app.ether.fi/liquid", "symbiotic": "app.symbiotic.fi",
        "ondo-yield-assets": "ondo.finance", "uniswap-v3": "app.uniswap.org/positions", "aerodrome-slipstream": "aerodrome.finance/liquidity",
        "aerodrome-v1": "aerodrome.finance/liquidity", "sky-lending": "app.sky.money", "spark-savings": "app.spark.fi", "sparklend": "app.spark.fi",
        "compound-v3": "app.compound.finance", "rocket-pool": "stake.rocketpool.net", "jito-liquid-staking": "jito.network/staking",
        "marinade-liquid-staking": "app.marinade.finance", "euler-v2": "app.euler.finance", "fluid-lending": "fluid.io/lending",
        "kelp": "kelpdao.xyz/restake", "renzo": "app.renzoprotocol.com/restake", "venus-core-pool": "app.venus.io", "lista-lending": "lista.org",
        "lista-liquid-staking": "lista.org", "yearn-finance": "yearn.fi", "meth-protocol": "meth.mantle.xyz", "usual-usd0": "app.usual.money",
        "midas-rwa": "midas.app", "frax-ether": "app.frax.finance", "frax": "app.frax.finance", "stader": "staderlabs.com",
        "liquid-collective": "liquidcollective.io", "lombard-lbtc": "lombard.finance", "curve-llamalend": "lend.curve.fi",
    ]
    static func site(for project: String) -> URL? { projectSites[project].flatMap { URL(string: "https://" + $0) } }

    /// DefiLlama project slug -> name we show, and the LogoMark key when we have that project's real logo.
    static let projects: [String: (name: String, logo: String?)] = [
        "aave-v3": ("Aave V3", "Aave"), "aave-v4": ("Aave V4", "Aave"), "morpho-blue": ("Morpho", "Morpho"), "pendle-v2": ("Pendle", "Pendle"),
        "ethena-usde": ("Ethena", "Ethena"), "lido": ("Lido", "Lido"), "jupiter-lend": ("Jupiter Lend", "Jupiter Lend"),
        "jupiter-staked-sol": ("Jupiter", "Jupiter"), "kamino-lend": ("Kamino", "Kamino"), "maple": ("Maple", "Maple"),
        "falcon-finance": ("Falcon", "Falcon"), "usd-ai": ("USD.AI", "USD.AI"), "ether.fi-stake": ("ether.fi", "ether.fi"),
        "ether.fi-liquid": ("ether.fi Liquid", "ether.fi"), "blackrock-buidl": ("BlackRock BUIDL", "BUIDL"), "symbiotic": ("Symbiotic", "Symbiotic"),
        "ondo-yield-assets": ("Ondo", "Ondo"), "coinbase-wrapped-staked-eth": ("Coinbase cbETH", "Coinbase"), "uniswap-v3": ("Uniswap V3", "Uniswap"),
        "aerodrome-slipstream": ("Aerodrome", "Aerodrome"), "aerodrome-v1": ("Aerodrome", "Aerodrome"),
        "sky-lending": ("Sky", nil), "spark-savings": ("Spark Savings", nil), "sparklend": ("SparkLend", nil), "compound-v3": ("Compound V3", nil),
        "rocket-pool": ("Rocket Pool", nil), "jito-liquid-staking": ("Jito", nil), "binance-staked-eth": ("Binance wBETH", nil),
        "binance-staked-sol": ("Binance BNSOL", nil), "marinade-liquid-staking": ("Marinade", nil), "euler-v2": ("Euler", nil),
        "fluid-lending": ("Fluid", nil), "kelp": ("Kelp", nil), "renzo": ("Renzo", nil), "venus-core-pool": ("Venus", nil),
        "lista-lending": ("Lista", nil), "lista-liquid-staking": ("Lista", nil), "yearn-finance": ("Yearn", nil), "meth-protocol": ("Mantle mETH", nil),
        "usual-usd0": ("Usual", nil), "midas-rwa": ("Midas", nil), "frax-ether": ("Frax", nil), "frax": ("Frax", nil), "stader": ("Stader", nil),
        "liquid-collective": ("Liquid Collective", nil), "lombard-lbtc": ("Lombard", nil), "curve-llamalend": ("Curve LlamaLend", nil),
    ]

    struct Pool: Codable, Identifiable, Hashable, Sendable {
        var id: String { pool }
        let pool, chain, project, symbol: String
        let tvlUsd, apy: Double
        let apyBase, apyReward, apyMean30d: Double?
        let stablecoin: Bool
        let ilRisk, exposure, poolMeta: String?

        var name: String {
            EarnData.projects[project]?.name
                ?? project.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        var logo: String? { EarnData.projects[project]?.logo }
        /// The token as people write it: DefiLlama sends symbols in capitals ("STETH"), we show "stETH".
        var shownSymbol: String { EarnData.symbolCase[symbol.uppercased()] ?? symbol }
        /// "Aave V3 USDC"; "Binance wBETH" rather than "Binance wBETH WBETH" when the name already says the token.
        var title: String { name.lowercased().contains(symbol.lowercased()) ? name : "\(name) \(shownSymbol)" }
        var chainName: String { EarnData.chainName(chain) }
        /// Aave's main market, the one Hermit deposits into. DefiLlama also lists Umbrella (staked aTokens that can be
        /// slashed), the Horizon RWA market and Prime instances under aave-v3; those carry a poolMeta and other rates.
        var isAaveMain: Bool { project == "aave-v3" && (poolMeta ?? "").isEmpty }
        /// What a deposit earns by itself: the base APY. Reward tokens (Merkl and the like) aren't collected by Hermit.
        var depositAPY: Double { apyBase ?? max(0, apy - (apyReward ?? 0)) }
    }

    /// One day of a pool's history.
    struct Point: Sendable, Codable { let date: Date; let apy: Double }

    static let filters: [(String, (Pool) -> Bool)] = [
        ("All", { _ in true }),
        ("Stablecoins", { $0.stablecoin }),
        ("ETH", { $0.symbol.uppercased().contains("ETH") }),
        ("BTC", { $0.symbol.uppercased().contains("BTC") }),
        ("SOL", { $0.symbol.uppercased().contains("SOL") }),
    ]

    /// Every kind of opportunity Hermit can talk you through (Explore more). A directory, no figures.
    static let catalog: [TradeExploreItem] = {
        let groups: [(String, [(String, String, String)])] = [
            ("Yield", [("Stablecoin savings", "Sky sUSDS, Spark", "USDC"), ("Stablecoin lending", "Aave, Morpho, Compound", "Aave"),
                       ("Tokenized treasuries", "Ondo USDY, BlackRock BUIDL", "Ondo"), ("Liquid staking", "Lido, Jito", "Lido"),
                       ("Synthetic dollar", "Ethena sUSDe", "Ethena"), ("Restaking", "EigenLayer, ether.fi", "EigenLayer"),
                       ("Fixed yield", "Pendle PT", "Pendle"), ("Perp LP vaults", "Hyperliquid HLP, GMX", "Hyperliquid"),
                       ("Concentrated LP", "Uniswap, Aerodrome, Meteora", "Uniswap"), ("Options vaults", "Derive", "Derive"),
                       ("Lending loops", "Morpho + Pendle loops", "Morpho"), ("Validator nodes", "ETH validators, DePIN", "ETH")]),
            ("Trading", [("Perps", "Hyperliquid, GMX, Jupiter", "Hyperliquid"), ("Spot DCA", "Jupiter, CoW Swap", "Jupiter"),
                         ("Copy trading", "Hyperliquid vaults", "Hyperliquid"), ("Prediction markets", "Polymarket, Kalshi", "Polymarket"),
                         ("Rate trading", "Pendle Boros", "Pendle"), ("Meme launches", "Pump.fun, LetsBonk, Zora", "Pump.fun")]),
            ("Arbitrage", [("Cash and carry", "Long spot, short perp", "HYPE"), ("Cross-venue funding", "Hyperliquid vs Binance", "Hyperliquid"),
                           ("DEX price gaps", "Uniswap, Aerodrome, Jupiter", "Uniswap"), ("Stablecoin depeg", "Curve, issuer redemptions", "USDC"),
                           ("Prediction market gaps", "Polymarket vs Kalshi", "Polymarket"), ("Liquidations", "Aave, Morpho", "Aave")]),
            ("Airdrops", [("Points programs", "Symbiotic, ether.fi", "Symbiotic"), ("Retro farming", "New chains and bridges", "Monad"),
                          ("Token sales", "Legion, Echo, MetaDAO", "Legion"), ("Launchpad whitelists", "Legion Score, Kaito", "Kaito"),
                          ("Attention mining", "Kaito, Galxe", "Kaito"), ("Bug bounties", "Immunefi, Code4rena", "Immunefi")]),
        ]
        return groups.flatMap { g in g.1.map { TradeExploreItem(name: $0.0, logo: $0.2, sub: $0.1, tag: g.0, logoKnown: true) } }
    }()
}

// MARK: Fetching

enum EarnAPI {
    /// Lenient row: DefiLlama leaves fields null now and then, so everything is optional until we filter.
    private struct Raw: Decodable {
        let pool, chain, project, symbol: String?
        let tvlUsd, apy, apyBase, apyReward, apyMean30d: Double?
        let stablecoin, outlier: Bool?
        let ilRisk, exposure, poolMeta: String?
        let underlyingTokens: [String?]?
    }
    private struct Envelope: Decodable { let data: [Raw] }

    /// Stablecoin and major-asset pools on our chains, single-asset, biggest first. The 11 MB decode runs off the main actor.
    static func pools() async throws -> [EarnData.Pool] {
        let d = try await MarketHTTP.data("https://yields.llama.fi/pools", fresh: false)
        return try await Task.detached(priority: .utility) { try EarnAPI.parse(d) }.value
    }

    /// The filter behind `pools()`: at least $10M deep, or $1M for the Aave main-market pools Hermit deposits into
    /// (Arbitrum USDT0 is about $5M). An Aave row whose underlying token isn't the one Hermit would send is dropped, so a
    /// bridged USDC row never stands in for native USDC.
    static func parse(_ d: Data) throws -> [EarnData.Pool] {
        let rows = try JSONDecoder().decode(Envelope.self, from: d).data
        let chains = Set(EarnData.chains.map(\.llama))
        // Chain id ("base") -> the tokens Hermit can supply to Aave there.
        let aave: [String: [Token]] = Dictionary(Chain.mainnets.map { ($0.id, AaveV3.tokens(on: $0)) }, uniquingKeysWith: { a, _ in a })
        let out = rows.compactMap { r -> EarnData.Pool? in
            guard let pool = r.pool, let chain = r.chain, chains.contains(chain), let project = r.project, let raw = r.symbol else { return nil }
            // DefiLlama writes Arbitrum's USDT0 as "USD₮0".
            let symbol = raw.replacingOccurrences(of: "₮", with: "T")
            let main = project == "aave-v3" && (r.poolMeta ?? "").isEmpty
            let token: Token? = main ? aave[chain.lowercased()]?.first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) : nil
            if let token, let u = r.underlyingTokens?.first ?? nil, u.lowercased() != token.address.lowercased() { return nil }
            guard let tvl = r.tvlUsd, tvl >= (token != nil ? 1_000_000 : 10_000_000), let apy = r.apy, apy >= 0.1, apy < 100,
                  r.outlier != true, r.exposure == "single" else { return nil }
            let stable = r.stablecoin == true || token != nil
            guard stable || EarnData.majors.contains(where: { symbol.uppercased().contains($0) }) else { return nil }
            return EarnData.Pool(pool: pool, chain: chain, project: project, symbol: symbol, tvlUsd: tvl, apy: apy, apyBase: r.apyBase,
                                 apyReward: r.apyReward, apyMean30d: r.apyMean30d, stablecoin: stable, ilRisk: r.ilRisk, exposure: r.exposure, poolMeta: r.poolMeta)
        }
        let sorted = out.sorted { $0.tvlUsd > $1.tvlUsd }
        // The biggest pools are nearly all on Ethereum; keep the ones Hermit can deposit into (Aave v3 on Base and
        // Arbitrum) and the main Solana lenders too, whatever their size.
        let keep: Set<String> = ["aave-v3", "kamino-lend", "jupiter-lend", "morpho-blue", "compound-v3", "fluid-lending"]
        var list = Array(sorted.prefix(120))
        for p in sorted.dropFirst(120) where keep.contains(p.project) && !list.contains(where: { $0.pool == p.pool }) { list.append(p) }
        return list.sorted { $0.tvlUsd > $1.tvlUsd }
    }

    private struct ChartRow: Decodable { let timestamp: String; let apy: Double? }
    private struct ChartEnvelope: Decodable { let data: [ChartRow] }

    /// Daily APY for the last 90 days.
    static func history(_ pool: String) async throws -> [EarnData.Point] {
        let d = try await MarketHTTP.data("https://yields.llama.fi/chart/\(pool)")
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = try JSONDecoder().decode(ChartEnvelope.self, from: d).data
        return rows.suffix(90).compactMap { r in
            guard let a = r.apy, let t = iso.date(from: r.timestamp) ?? ISO8601DateFormatter().date(from: r.timestamp) else { return nil }
            return EarnData.Point(date: t, apy: a)
        }
    }
}

/// Small JSON cache in the app's Caches folder, so big lists aren't refetched on every visit.
enum MarketDiskCache {
    private static func url(_ name: String) -> URL { URL.cachesDirectory.appending(path: "hermit-\(name).json") }

    static func load<T: Decodable>(_ name: String, maxAge: TimeInterval, as: T.Type) -> T? {
        let u = url(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path), let m = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(m) < maxAge, let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    /// When a cached list was saved, so a list shown from disk keeps its real age.
    static func saved(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(name).path))?[.modificationDate] as? Date
    }

    static func save<T: Encodable>(_ name: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        try? d.write(to: url(name), options: .atomic)
    }
}

/// Earn's live state: the pool list and each opened pool's history.
@MainActor @Observable
final class YieldsFeed {
    static let shared = YieldsFeed()
    var pools: [EarnData.Pool] = []
    var state: FeedState = .loading
    var updated: Date?
    var history: [String: [EarnData.Point]] = [:]
    /// Pools whose history was read this session (a saved one may be showing for the others).
    @ObservationIgnored private var historyRead: Set<String> = []
    /// The fetch under way, so Savings, DeFi and the assistant asking at once share one 11 MB download.
    @ObservationIgnored private var fetching: Task<[EarnData.Pool], Error>?

    func refresh(force: Bool = false) async {
        guard !SnapshotMode.active else { return }
        // The last list shows at once, up to 3 days old (the screens say how old once it's past an hour); it's fetched
        // again once it's an hour old.
        if pools.isEmpty, let cached = MarketDiskCache.load("yields", maxAge: 3 * 86_400, as: [EarnData.Pool].self), !cached.isEmpty {
            pools = cached; state = .ready; updated = MarketDiskCache.saved("yields")
        }
        if !force, let updated, Date().timeIntervalSince(updated) < 3600 { return }
        if pools.isEmpty { state = .loading }
        let task = fetching ?? Task { try await EarnAPI.pools() }
        fetching = task
        do {
            let p = try await task.value
            fetching = nil
            pools = p; state = .ready; updated = Date()
            MarketDiskCache.save("yields", p)
        } catch { fetching = nil; if pools.isEmpty { state = .failed } }
    }

    func loadHistory(_ pool: String) async -> Bool {
        guard !SnapshotMode.active else { return history[pool] != nil }
        if historyRead.contains(pool) { return true }
        // Daily points: last time's chart draws at once, then the new one replaces it.
        if history[pool] == nil, let s = SnapshotStore.live.load("yield-history-" + pool, as: [EarnData.Point].self, maxAge: 3 * 86_400) {
            history[pool] = s.value
        }
        guard let h = try? await EarnAPI.history(pool), !h.isEmpty else { return history[pool] != nil }
        history[pool] = h
        historyRead.insert(pool)
        SnapshotStore.live.save(h, "yield-history-" + pool)
        return true
    }

    /// " Updated 3 h ago." once the list on screen is older than its hourly refresh (a saved copy, or DefiLlama is
    /// down); nothing while it's fresh.
    var ageNote: String {
        guard let updated, Date().timeIntervalSince(updated) > 3600 else { return "" }
        return " Updated \(Freshness.ago(updated))."
    }
}
