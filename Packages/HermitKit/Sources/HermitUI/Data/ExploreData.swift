import SwiftUI
import Observation

// DApps from hermit-demo/src/data.js (dapps): the newest and most popular apps of the past year.

struct ExploreDapp: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let cat: String
    let tvl: String
    let chain: String
    let conn: Bool
    let hot: Bool
    var isNew = false
    let desc: String
}

enum ExploreData {
    static let categories = ["All", "New", "Perps", "DEX", "Lending", "Yield", "Stablecoin", "Staking", "RWA",
                             "Prediction", "Presale", "Launchpad", "AI agents", "Wallet"]

    static let dapps: [ExploreDapp] = [
        .init(name: "Hyperliquid", cat: "Perps", tvl: "$5.1B", chain: "HyperEVM", conn: true, hot: true, desc: "Perps"),
        .init(name: "Aave", cat: "Lending", tvl: "$38.2B", chain: "Multi-chain", conn: true, hot: false, desc: "Lending"),
        .init(name: "Pendle", cat: "Yield", tvl: "$6.4B", chain: "Multi-chain", conn: true, hot: true, desc: "Fixed yield"),
        .init(name: "Ethena", cat: "Yield", tvl: "$11.8B", chain: "Ethereum", conn: true, hot: false, desc: "Synthetic dollar"),
        .init(name: "Jupiter", cat: "DEX", tvl: "$2.9B", chain: "Solana", conn: true, hot: false, desc: "Swaps"),
        .init(name: "Uniswap", cat: "DEX", tvl: "$5.6B", chain: "Multi-chain", conn: false, hot: false, desc: "Swaps and LP"),
        .init(name: "Lido", cat: "Staking", tvl: "$27.5B", chain: "Ethereum", conn: false, hot: false, desc: "ETH staking"),
        .init(name: "Pump.fun", cat: "Launchpad", tvl: "$0.4B", chain: "Solana", conn: false, hot: true, desc: "Meme launches"),
        .init(name: "Morpho", cat: "Lending", tvl: "$9.3B", chain: "Multi-chain", conn: false, hot: true, desc: "Lending vaults"),
        .init(name: "Kamino", cat: "Yield", tvl: "$2.2B", chain: "Solana", conn: false, hot: false, desc: "Liquidity vaults"),
        .init(name: "Polymarket", cat: "Prediction", tvl: "$0.6B", chain: "Polygon", conn: false, hot: true, desc: "Predictions"),
        .init(name: "Legion", cat: "Presale", tvl: "n/a", chain: "Multi-chain", conn: false, hot: true, desc: "Token sales"),
        .init(name: "Lighter", cat: "Perps", tvl: "$1.4B OI", chain: "Ethereum zk", conn: false, hot: true, isNew: true, desc: "Zero-fee zk perps"),
        .init(name: "trade.xyz", cat: "Perps", tvl: "$4B OI", chain: "Hyperliquid", conn: false, hot: true, isNew: true, desc: "Stock and gold perps"),
        .init(name: "Aster", cat: "Perps", tvl: "15% share", chain: "BNB", conn: false, hot: false, desc: "Multichain perps"),
        .init(name: "Paradex", cat: "Perps", tvl: "$289M / day", chain: "Starknet", conn: false, hot: false, desc: "Private perps"),
        .init(name: "Extended", cat: "Perps", tvl: "$6.4B / mo", chain: "Starknet", conn: false, hot: false, desc: "Starknet perps"),
        .init(name: "Variational", cat: "Perps", tvl: "$16B / mo", chain: "Arbitrum", conn: false, hot: false, desc: "Zero-fee RFQ perps"),
        .init(name: "Kalshi", cat: "Prediction", tvl: "$5.4B / mo", chain: "Regulated", conn: false, hot: true, desc: "Regulated predictions"),
        .init(name: "Predict.fun", cat: "Prediction", tvl: "$579M / mo", chain: "BNB", conn: false, hot: false, isNew: true, desc: "Yield-bearing bets"),
        .init(name: "Opinion", cat: "Prediction", tvl: "$376M / mo", chain: "BNB", conn: false, hot: false, isNew: true, desc: "Macro predictions"),
        .init(name: "Limitless", cat: "Prediction", tvl: "$205M / mo", chain: "Base", conn: false, hot: false, desc: "Short-term price markets"),
        .init(name: "Coinbase Sales", cat: "Presale", tvl: "$188M sale", chain: "Multichain", conn: false, hot: true, isNew: true, desc: "Public token sales"),
        .init(name: "MetaDAO", cat: "Presale", tvl: "$100M+ raised", chain: "Solana", conn: false, hot: false, desc: "Futarchy ICOs"),
        .init(name: "Echo", cat: "Presale", tvl: "n/a", chain: "Multichain", conn: false, hot: false, desc: "Token sales"),
        .init(name: "Jupiter Lend", cat: "Lending", tvl: "$2.6B", chain: "Solana", conn: false, hot: false, isNew: true, desc: "Solana lending"),
        .init(name: "Curvance", cat: "Lending", tvl: "$75M", chain: "Monad", conn: false, hot: false, isNew: true, desc: "Lend yield assets"),
        .init(name: "Kuru", cat: "DEX", tvl: "$380M / mo", chain: "Monad", conn: false, hot: false, isNew: true, desc: "Order book DEX"),
        .init(name: "Aerodrome", cat: "DEX", tvl: "$9.5B / mo", chain: "Base", conn: false, hot: false, desc: "Base swaps and LP"),
        .init(name: "USD.AI", cat: "Yield", tvl: "$491M", chain: "Arbitrum", conn: false, hot: true, isNew: true, desc: "Yield from GPU loans"),
        .init(name: "Falcon", cat: "Stablecoin", tvl: "$1.8B", chain: "Ethereum", conn: false, hot: false, desc: "Synthetic dollar USDf"),
        .init(name: "Maple", cat: "Yield", tvl: "n/a", chain: "Multichain", conn: false, hot: false, desc: "Institutional credit yield"),
        .init(name: "Plasma", cat: "Stablecoin", tvl: "$5.7B", chain: "Plasma", conn: false, hot: false, isNew: true, desc: "Zero-fee USDT chain"),
        .init(name: "Kinetiq", cat: "Staking", tvl: "$1.0B", chain: "HyperEVM", conn: false, hot: false, isNew: true, desc: "HYPE liquid staking"),
        .init(name: "Infrared", cat: "Staking", tvl: "$1.5B", chain: "Berachain", conn: false, hot: false, desc: "Berachain staking"),
        .init(name: "Ondo", cat: "RWA", tvl: "$1B", chain: "Multichain", conn: false, hot: true, isNew: true, desc: "Tokenized US stocks"),
        .init(name: "xStocks", cat: "RWA", tvl: "$700M", chain: "Solana", conn: false, hot: false, desc: "Tokenized stocks"),
        .init(name: "BUIDL", cat: "RWA", tvl: "$2.8B", chain: "Ethereum", conn: false, hot: false, desc: "BlackRock treasury fund"),
        .init(name: "Virtuals", cat: "AI agents", tvl: "$621M", chain: "Base", conn: false, hot: true, desc: "AI agent launchpad"),
        .init(name: "x402", cat: "AI agents", tvl: "100M+ payments", chain: "Base", conn: true, hot: false, isNew: true, desc: "Agent payments"),
        .init(name: "Infinex", cat: "Wallet", tvl: "n/a", chain: "20+ chains", conn: false, hot: false, isNew: true, desc: "Passkey wallet app"),
    ]
}

/// Which DApps are connected. Shared so the state survives page changes.
@MainActor @Observable
final class ExploreStore {
    static let shared = ExploreStore()
    var connected: Set<String> = Set(ExploreData.dapps.filter(\.conn).map(\.name))
    var connecting: Set<String> = []
}
