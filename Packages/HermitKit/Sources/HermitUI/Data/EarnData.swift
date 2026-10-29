import SwiftUI

// Mock data for Earn, ported from hermit-demo/src/data.js and pages/Earn.jsx.

enum EarnData {
    enum Risk: String { case low = "Low", medium = "Medium", high = "High"
        var color: Color { switch self { case .low: Theme.green; case .medium: Theme.amber; case .high: Theme.red } }
    }

    struct Opp: Identifiable, Hashable {
        var id: String { proto + name }
        let name, proto, asset: String
        let apy: Double
        let tvl: String
        let risk: Risk
        let type, chain: String
        var isNew = false
    }
    static let opps: [Opp] = [
        Opp(name: "PT-USDe", proto: "Pendle", asset: "USDe", apy: 18.4, tvl: "$1.2B", risk: .medium, type: "Fixed", chain: "Ethereum"),
        Opp(name: "sUSDe", proto: "Ethena", asset: "USDe", apy: 11.2, tvl: "$5.3B", risk: .medium, type: "Variable", chain: "Ethereum"),
        Opp(name: "HLP vault", proto: "Hyperliquid", asset: "USDC", apy: 14.7, tvl: "$410M", risk: .medium, type: "Market-making", chain: "HyperEVM"),
        Opp(name: "USDC vault", proto: "Morpho", asset: "USDC", apy: 7.9, tvl: "$1.6B", risk: .low, type: "Lending", chain: "Base"),
        Opp(name: "USDC supply", proto: "Aave v3", asset: "USDC", apy: 5.6, tvl: "$4.1B", risk: .low, type: "Lending", chain: "Arbitrum"),
        Opp(name: "stETH", proto: "Lido", asset: "ETH", apy: 3.1, tvl: "$27B", risk: .low, type: "Staking", chain: "Ethereum"),
        Opp(name: "JLP", proto: "Jupiter", asset: "Basket", apy: 32.5, tvl: "$1.4B", risk: .high, type: "LP", chain: "Solana"),
        Opp(name: "staking", proto: "Hyperliquid", asset: "HYPE", apy: 2.4, tvl: "$9B", risk: .low, type: "Staking", chain: "HyperEVM"),
        Opp(name: "kHYPE", proto: "Kinetiq", asset: "HYPE", apy: 2.9, tvl: "$1.0B", risk: .low, type: "Staking", chain: "HyperEVM", isNew: true),
        Opp(name: "sUSDai", proto: "USD.AI", asset: "USDC", apy: 12.4, tvl: "$491M", risk: .medium, type: "Credit", chain: "Arbitrum", isNew: true),
        Opp(name: "sUSDf", proto: "Falcon", asset: "USDf", apy: 9.0, tvl: "$1.8B", risk: .medium, type: "Variable", chain: "Ethereum"),
        Opp(name: "syrupUSDC", proto: "Maple", asset: "USDC", apy: 8.6, tvl: "$1.5B", risk: .medium, type: "Credit", chain: "Ethereum"),
        Opp(name: "USDC lending", proto: "Jupiter Lend", asset: "USDC", apy: 6.8, tvl: "$2.6B", risk: .low, type: "Lending", chain: "Solana", isNew: true),
        Opp(name: "USDC market", proto: "Curvance", asset: "USDC", apy: 9.6, tvl: "$75M", risk: .medium, type: "Lending", chain: "Monad", isNew: true),
        Opp(name: "iBERA", proto: "Infrared", asset: "BERA", apy: 11.8, tvl: "$1.5B", risk: .medium, type: "Staking", chain: "Berachain"),
        Opp(name: "USDY", proto: "Ondo", asset: "USDC", apy: 4.2, tvl: "$1B", risk: .low, type: "Treasuries", chain: "Multichain"),
    ]

    static let filters: [(String, (Opp) -> Bool)] = [
        ("All", { _ in true }),
        ("Stables", { ["USDC", "USDe", "USDf"].contains($0.asset) }),
        ("ETH", { $0.asset == "ETH" }),
        ("Low risk", { $0.risk == .low }),
    ]

    /// Public stats shown when an opportunity is expanded.
    struct Detail {
        var histLabel = "APY, last 90 days"
        let hist: [Double]
        let avg: String
        var stats: [(String, String)]? = nil
        var dd = "", tvl = "", age = "", audits = "", exit = "", fee = ""
        let note: String
        var pairs: [(String, String)] {
            stats ?? [("Max drawdown", dd), ("TVL", tvl), ("Live for", age), ("Withdraw", exit), ("Audits", audits), ("Fees", fee)]
        }
        /// A few points smoothed into a 90-day series (Earn.jsx `expand`).
        var series: [Double] {
            var out: [Double] = []
            for i in 0..<(hist.count - 1) {
                for k in 0..<30 {
                    let t = Double(k) / 30
                    out.append(hist[i] + (hist[i + 1] - hist[i]) * t + sin(Double(i * 30 + k) / 3) * 0.4)
                }
            }
            return out
        }
    }
    static let details: [String: Detail] = [
        "PT-USDe": Detail(hist: [16.1, 18.9, 17.2, 18.4], avg: "17.6%", dd: "−1.2%", tvl: "$1.2B", age: "2.4 yrs", audits: "Ackee, Dedaub", exit: "At maturity or sell PT", fee: "None", note: "Fixed rate. Price can dip before maturity if USDe wobbles."),
        "sUSDe": Detail(hist: [27, 9.5, 14.1, 11.2], avg: "12.8%", dd: "−0.4%", tvl: "$5.3B", age: "2.6 yrs", audits: "Spearbit, Pashov", exit: "7-day cooldown", fee: "None", note: "Yield follows perp funding and drops when markets cool."),
        "HLP vault": Detail(hist: [22, 11, 18, 14.7], avg: "15.9%", dd: "−6.8%", tvl: "$410M", age: "2.8 yrs", audits: "Zellic", exit: "4-day lockup", fee: "None", note: "Market-making vault. Lost 6.8% in one bad week in 2025."),
        "USDC vault": Detail(hist: [6.8, 7.4, 8.2, 7.9], avg: "7.5%", dd: "0%", tvl: "$1.6B", age: "2.1 yrs", audits: "Spearbit, Cantina", exit: "Anytime", fee: "10% of yield", note: "Curated lending. No losses since launch."),
        "USDC supply": Detail(hist: [4.2, 5.1, 6.3, 5.6], avg: "5.4%", dd: "0%", tvl: "$4.1B", age: "3.5 yrs", audits: "9 firms", exit: "Anytime", fee: "None", note: "The longest-running lending market. Lowest risk here."),
        "kHYPE": Detail(hist: [2.6, 2.8, 3.0, 2.9], avg: "2.8%", dd: "Tracks HYPE", tvl: "$1.0B", age: "1.1 yrs", audits: "Spearbit", exit: "Swap or 7-day unstake", fee: "10% of rewards", note: "About 80% of all HYPE staking. Rewards paid in HYPE."),
        "sUSDai": Detail(hist: [9.8, 11.5, 13.1, 12.4], avg: "11.7%", dd: "0%", tvl: "$491M", age: "0.9 yrs", audits: "Sherlock", exit: "30-day queue", fee: "None", note: "Lends against GPUs. Newer, with credit risk on the borrowers."),
        "sUSDf": Detail(hist: [10.2, 9.4, 8.8, 9.0], avg: "9.3%", dd: "−0.6%", tvl: "$1.8B", age: "1.4 yrs", audits: "Zellic, Pashov", exit: "7-day cooldown", fee: "None", note: "Overcollateralized dollar. Yield from basis and staking."),
        "syrupUSDC": Detail(hist: [8.1, 8.9, 8.4, 8.6], avg: "8.5%", dd: "0%", tvl: "$1.5B", age: "1.8 yrs", audits: "Spearbit, Three Sigma", exit: "Queue, days", fee: "In rate", note: "Loans to trading firms. Overcollateralized, but still credit risk."),
        "USDC lending": Detail(hist: [5.9, 6.4, 7.2, 6.8], avg: "6.6%", dd: "0%", tvl: "$2.6B", age: "0.8 yrs", audits: "Fluid, OtterSec", exit: "Anytime", fee: "None", note: "Built on Fluid. The biggest Solana lender by borrows."),
        "USDC market": Detail(hist: [12.5, 10.8, 9.1, 9.6], avg: "10.5%", dd: "0%", tvl: "$75M", age: "0.9 yrs", audits: "Trail of Bits", exit: "Anytime", fee: "None", note: "Leading Monad lender. Small TVL, so rates move fast."),
        "iBERA": Detail(hist: [18, 14, 12.5, 11.8], avg: "14.1%", dd: "Tracks BERA", tvl: "$1.5B", age: "1.7 yrs", audits: "Spearbit", exit: "Swap or unstake", fee: "5% of rewards", note: "Berachain TVL is down about 70% from its peak."),
        "USDY": Detail(hist: [4.4, 4.3, 4.2, 4.2], avg: "4.3%", dd: "0%", tvl: "$1B", age: "2.6 yrs", audits: "Code4rena, Cyfrin", exit: "Daily redemption", fee: "In rate", note: "Backed by short-term US treasuries."),
        "stETH": Detail(hist: [3.4, 3.2, 3.0, 3.1], avg: "3.2%", dd: "−7% vs ETH (2022)", tvl: "$27B", age: "5 yrs", audits: "15+ firms", exit: "Queue, 1 to 5 days", fee: "10% of rewards", note: "Tracks ETH price. Depegged briefly in 2022."),
        "JLP": Detail(hist: [55, 28, 41, 32.5], avg: "38.1%", dd: "−22%", tvl: "$1.4B", age: "2.7 yrs", audits: "OtterSec, Offside", exit: "Anytime", fee: "Mint/burn fee", note: "Holds SOL, ETH and BTC. Falls when crypto falls."),
        "staking": Detail(hist: [2.6, 2.5, 2.4, 2.4], avg: "2.5%", dd: "Tracks HYPE", tvl: "$9B", age: "1.6 yrs", audits: "Zellic", exit: "7-day unstake", fee: "Validator fee", note: "Rewards are paid in HYPE, so the value moves with its price."),
        "SOL funding arb": Detail(hist: [18, 26, 15, 21.4], avg: "19.8%", dd: "−1.1%", tvl: "Capacity $2M", age: "Live 41 days", audits: "Hyperliquid", exit: "Anytime", fee: "Trading fees", note: "Turns negative when funding flips. Exits on its own."),
        "PT-USDe basis": Detail(hist: [8.1, 10.4, 9.2, 9.8], avg: "9.4%", dd: "−0.9%", tvl: "Capacity $5M", age: "Live 22 days", audits: "Pendle, Aave", exit: "At maturity", fee: "Borrow interest", note: "Earns the gap between fixed yield and borrow cost."),
        "ETH CEX–DEX spread": Detail(hist: [4.8, 7.1, 5.5, 6.2], avg: "5.9%", dd: "−0.3%", tvl: "Capacity $500k", age: "Live 63 days", audits: "Uniswap", exit: "Anytime", fee: "Gas", note: "Small, steady trades. Competes with MEV bots."),
    ]

    struct Position: Identifiable, Hashable {
        let id = UUID()
        let proto, name: String
        let usd, apy: Double
        let by, when: String
        var note: String? = nil
    }
    static let positionsSeed: [Position] = [
        Position(proto: "Pendle", name: "PT-USDe Dec-26", usd: 6200, apy: 18.4, by: "Agent", when: "Oct 22"),
        Position(proto: "Aave", name: "USDC supply", usd: 5100, apy: 5.6, by: "Agent", when: "Oct 9"),
        Position(proto: "Ethena", name: "sUSDe", usd: 3500, apy: 11.2, by: "You", when: "Sep 30"),
    ]

    static var arbStrategies: [TradeData.Strategy] {
        [TradeData.strategies[0],
         TradeData.Strategy(id: "loop", name: "sUSDe / USDC loop", sym: "USDe", running: true, capital: 4000, pnl: 162, win: "—", source: "From chat",
                            steps: [.init(t: "Supply sUSDe", d: "Aave"), .init(t: "Borrow USDC", d: "70% LTV"), .init(t: "Buy sUSDe", d: "Repeat 2x"), .init(t: "Hazard scan", d: "Health > 1.3", guardStep: true), .init(t: "Unwind", d: "If spread < 3%")],
                            trades: [("Rebalanced loop", "Oct 24", ""), ("Opened 2x loop", "Oct 15", "")]),
         TradeData.Strategy(id: "dex", name: "Stablecoin DEX spread", sym: "USDC", running: true, capital: 1500, pnl: 58, win: "91%", source: "From Yield ladder",
                            steps: [.init(t: "Scan", d: "6 DEXs, every block"), .init(t: "Spread > 0.15%", d: "After gas"), .init(t: "Buy + sell", d: "One transaction"), .init(t: "Hazard scan", d: "Simulate first", guardStep: true)],
                            trades: [("USDC→USDT→USDC", "1h ago", "+$2.10"), ("USDC→DAI→USDC", "5h ago", "+$1.40")])]
    }

    struct ArbOpp: Identifiable { var id: String { name }; let name, sym: String; let apr: Double; let note: String }
    static let arbOpps: [ArbOpp] = [
        ArbOpp(name: "SOL funding arb", sym: "SOL", apr: 21.4, note: "Funding 0.024%/h"),
        ArbOpp(name: "PT-USDe basis", sym: "USDe", apr: 9.8, note: "18.4% fixed vs 8.6% borrow"),
        ArbOpp(name: "ETH CEX–DEX spread", sym: "ETH", apr: 6.2, note: "0.08% avg spread"),
    ]

    struct Airdrop: Identifiable { var id: String { name }; let name: String; let done, total: Int; let pts, est: String; let wallets: Int; let funds, loss: Double; let status, from: String }
    static let airdrops: [Airdrop] = [
        Airdrop(name: "Monad", done: 3, total: 7, pts: "1,000", est: "$400–1,200", wallets: 3, funds: 450, loss: 6, status: "Farming", from: "From chat"),
        Airdrop(name: "MegaETH", done: 5, total: 6, pts: "8,400", est: "$300–900", wallets: 3, funds: 1800, loss: 9, status: "Farming", from: "From Airdrops S3"),
        Airdrop(name: "Berachain", done: 4, total: 4, pts: "4,800", est: "Claim Nov 4", wallets: 2, funds: 700, loss: 3, status: "Claimable soon", from: "From Airdrops S3"),
    ]

    struct AirdropOpp: Identifiable { var id: String { name }; let name, logo, note, est: String; let d: Detail }
    static let airdropOpps: [AirdropOpp] = [
        AirdropOpp(name: "Hyperliquid S3", logo: "Hyperliquid", note: "Volume and HLP", est: "$200–800",
                   d: Detail(histLabel: "Points per week, all users (M)", hist: [12, 18, 15, 21], avg: "16.5M", stats: [("Est. value", "$200–800"), ("Cost", "~$40 in fees"), ("Ends", "Dec 31"), ("Sybil checks", "Strict")], note: "Rewards real volume. Wash trading gets filtered out.")),
        AirdropOpp(name: "Polymarket", logo: "Polymarket", note: "Weekly predictions", est: "Unknown",
                   d: Detail(histLabel: "Weekly volume ($M)", hist: [1800, 2600, 2100, 2400], avg: "$2.2B", stats: [("Est. value", "Unknown"), ("Cost", "Your bets"), ("Ends", "Not announced"), ("Sybil checks", "Unknown")], note: "No token is confirmed. Activity is the only signal.")),
        AirdropOpp(name: "Kamino season 4", logo: "Kamino", note: "Supply on Solana", est: "$100–400",
                   d: Detail(histLabel: "Points per week (M)", hist: [5, 7, 6, 8], avg: "6.5M", stats: [("Est. value", "$100–400"), ("Cost", "Gas only"), ("Ends", "Jan 15"), ("Sybil checks", "Moderate")], note: "Earn yield and points at the same time. Low effort.")),
    ]

    static let pointTasks: [(String, String, String)] = [
        ("tag", "Label wallets", "+120"), ("ladybug", "Report bugs", "Up to 2,000"), ("shield.lefthalf.filled", "Red-team the agent", "Up to 5,000"),
    ]

    struct Vault: Identifiable { var id: String { addr }; let proto, name, addr, apy: String }
    static let sampleVaults: [Vault] = [
        Vault(proto: "Morpho", name: "Gauntlet USDC Prime", addr: "0x9c4e…a71b", apy: "24.1%"),
        Vault(proto: "Pendle", name: "sUSDe Dec 26 loop", addr: "0x3f81…02cd", apy: "31.6%"),
        Vault(proto: "Hyperliquid", name: "HLP vault", addr: "0xdfc2…7a10", apy: "18.4%"),
        Vault(proto: "Ethena", name: "USDe basis vault", addr: "0x77a0…e14f", apy: "12.9%"),
    ]

    /// Every kind of opportunity Hermit can find or act on (Explore more).
    static let catalog: [TradeExploreItem] = {
        let groups: [(String, [(String, String, String, String)])] = [
            ("Yield", [("Stablecoin savings", "Sky sUSDS, Spark", "USDC", "~3.5%"), ("Stablecoin lending", "Aave, Morpho, Compound", "Aave", "3.5–9%"),
                       ("Tokenized treasuries", "Ondo USDY, BlackRock BUIDL", "Ondo", "3.5–4.7%"), ("Liquid staking", "Lido, Jito", "Lido", "2.5–8%"),
                       ("Synthetic dollar", "Ethena sUSDe", "Ethena", "Varies"), ("Restaking", "EigenLayer, ether.fi", "EigenLayer", "2–5% + points"),
                       ("Fixed yield", "Pendle PT", "Pendle", "5–20%"), ("Perp LP vaults", "Hyperliquid HLP, GMX", "Hyperliquid", "10–20%"),
                       ("Concentrated LP", "Uniswap, Aerodrome, Meteora", "Uniswap", "5–50%"), ("Options vaults", "Derive", "Derive", "5–20%"),
                       ("Lending loops", "Morpho + Pendle loops", "Morpho", "Up to ~25%"), ("Validator nodes", "ETH validators, DePIN", "ETH", "~3%")]),
            ("Trading", [("Perps", "Hyperliquid, GMX, Jupiter", "Hyperliquid", "Unbounded"), ("Spot DCA", "Jupiter, CoW Swap", "Jupiter", "Market"),
                         ("Copy trading", "Hyperliquid vaults", "Hyperliquid", "Varies"), ("Prediction markets", "Polymarket, Kalshi", "Polymarket", "Event odds"),
                         ("Rate trading", "Pendle Boros", "Pendle", "Rate based"), ("Meme launches", "Pump.fun, LetsBonk, Zora", "Pump.fun", "Extreme")]),
            ("Arbitrage", [("Cash and carry", "Long spot, short perp", "HYPE", "5–15%"), ("Cross-venue funding", "Hyperliquid vs Binance", "Hyperliquid", "Small spreads"),
                           ("DEX price gaps", "Uniswap, Aerodrome, Jupiter", "Uniswap", "bps per trade"), ("Stablecoin depeg", "Curve, issuer redemptions", "USDC", "On events"),
                           ("Prediction market gaps", "Polymarket vs Kalshi", "Polymarket", "Few %"), ("Liquidations", "Aave, Morpho", "Aave", "5–10% bonus")]),
            ("Airdrops", [("Points programs", "Symbiotic, ether.fi", "Symbiotic", "Unknown"), ("Retro farming", "New chains and bridges", "Monad", "Varies"),
                          ("Token sales", "Legion, Echo, MetaDAO", "Legion", "Varies"), ("Launchpad whitelists", "Legion Score, Kaito", "Kaito", "Varies"),
                          ("Attention mining", "Kaito, Galxe", "Kaito", "Points"), ("Bug bounties", "Immunefi, Code4rena", "Immunefi", "Bounties"),
                          ("AI data for points", "Label data, red-team agents", "Hermit", "Points")]),
        ]
        return groups.flatMap { g in g.1.map { TradeExploreItem(name: $0.0, logo: $0.2, sub: $0.1, metric: $0.3, tag: g.0) } }
    }()
}
