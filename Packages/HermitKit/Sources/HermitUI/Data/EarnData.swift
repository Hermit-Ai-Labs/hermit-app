import SwiftUI
import Foundation

// Real yields for Earn, from DefiLlama's public yields API (yields.llama.fi, no key). The full pool list is ~11 MB, so we
// keep only stablecoin and major-asset pools on the chains Hermit supports, and cache that short list on disk for an hour.

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
    }

    /// One day of a pool's history.
    struct Point: Sendable { let date: Date; let apy: Double }

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
    }
    private struct Envelope: Decodable { let data: [Raw] }

    /// Stablecoin and major-asset pools on our chains, single-asset, at least $10M deep, biggest first.
    static func pools() async throws -> [EarnData.Pool] {
        let d = try await MarketHTTP.data("https://yields.llama.fi/pools")
        let rows = try JSONDecoder().decode(Envelope.self, from: d).data
        let chains = Set(EarnData.chains.map(\.llama))
        let out = rows.compactMap { r -> EarnData.Pool? in
            guard let pool = r.pool, let chain = r.chain, chains.contains(chain), let project = r.project, let symbol = r.symbol,
                  let tvl = r.tvlUsd, tvl >= 10_000_000, let apy = r.apy, apy >= 0.1, apy < 100, r.outlier != true,
                  r.exposure == "single" else { return nil }
            let stable = r.stablecoin == true
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

    func refresh(force: Bool = false) async {
        guard !SnapshotMode.active else { return }
        if !force, pools.isEmpty, let cached = MarketDiskCache.load("yields", maxAge: 3600, as: [EarnData.Pool].self), !cached.isEmpty {
            pools = cached; state = .ready; updated = Date()
            return
        }
        if !force, let updated, Date().timeIntervalSince(updated) < 600 { return }
        if pools.isEmpty { state = .loading }
        do {
            let p = try await EarnAPI.pools()
            pools = p; state = .ready; updated = Date()
            MarketDiskCache.save("yields", p)
        } catch { if pools.isEmpty { state = .failed } }
    }

    func loadHistory(_ pool: String) async -> Bool {
        guard !SnapshotMode.active else { return history[pool] != nil }
        if history[pool] != nil { return true }
        guard let h = try? await EarnAPI.history(pool), !h.isEmpty else { return false }
        history[pool] = h
        return true
    }
}
