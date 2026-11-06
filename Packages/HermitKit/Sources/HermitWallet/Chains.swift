import Foundation

public enum ChainKind: String, Sendable, Codable { case evm, solana }

/// A token we know the official address of. `address` is a 0x contract (EVM) or a base58 mint (Solana).
public struct Token: Hashable, Sendable, Identifiable {
    public var id: String { "\(chainID):\(symbol)" }
    public let chainID: String
    public let symbol: String
    public let name: String
    public let address: String
    public let decimals: Int
    /// Name for `LogoMark`.
    public var logo: String { symbol.lowercased() }
}

public struct Chain: Hashable, Sendable, Identifiable {
    /// Stable key, e.g. "base", "base-sepolia", "solana-devnet".
    public let id: String
    public let name: String
    public let kind: ChainKind
    /// EIP-155 chain id (EVM only).
    public let chainId: UInt64?
    public let nativeSymbol: String
    public let nativeDecimals: Int
    /// Name for `LogoMark` (testnets use their mainnet's logo).
    public let logo: String
    public let rpc: URL
    let explorer: String
    public let isTestnet: Bool
    /// The mainnet this is a testnet of (nil for mainnets).
    public let mainnetID: String?

    public var tokens: [Token] { TokenTable.all.filter { $0.chainID == id } }
    public func token(_ symbol: String) -> Token? { tokens.first { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame } }

    public func explorerURL(tx: String) -> URL? {
        switch kind {
        case .evm: URL(string: "\(explorer)/tx/\(tx)")
        case .solana: URL(string: "https://explorer.solana.com/tx/\(tx)" + (isTestnet ? "?cluster=devnet" : ""))
        }
    }
    public func explorerURL(address: String) -> URL? {
        switch kind {
        case .evm: URL(string: "\(explorer)/address/\(address)")
        case .solana: URL(string: "https://explorer.solana.com/address/\(address)" + (isTestnet ? "?cluster=devnet" : ""))
        }
    }

    public static func == (a: Chain, b: Chain) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

// Networks. Chain ids and RPCs were checked against each network's docs and with eth_chainId on 2026-10-29.
// Public RPCs are rate limited; swap in a keyed provider before a wide release.
extension Chain {
    static func evm(_ id: String, _ name: String, _ chainId: UInt64, _ sym: String, _ logo: String, _ rpc: String, _ explorer: String,
                    testnetOf: String? = nil) -> Chain {
        Chain(id: id, name: name, kind: .evm, chainId: chainId, nativeSymbol: sym, nativeDecimals: 18, logo: logo, rpc: URL(string: rpc)!,
              explorer: explorer, isTestnet: testnetOf != nil, mainnetID: testnetOf)
    }

    // Ethereum: no official public RPC from the Foundation, so PublicNode's free endpoint.
    public static let ethereum = evm("ethereum", "Ethereum", 1, "ETH", "ethereum", "https://ethereum-rpc.publicnode.com", "https://etherscan.io")
    public static let sepolia = evm("sepolia", "Ethereum Sepolia", 11_155_111, "ETH", "ethereum",
                                    "https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.etherscan.io", testnetOf: "ethereum")
    // Base: docs.base.org/network-information
    public static let base = evm("base", "Base", 8453, "ETH", "base", "https://mainnet.base.org", "https://basescan.org")
    public static let baseSepolia = evm("base-sepolia", "Base Sepolia", 84532, "ETH", "base", "https://sepolia.base.org",
                                        "https://sepolia.basescan.org", testnetOf: "base")
    // BNB Chain: docs.bnbchain.org (BSC JSON-RPC endpoints)
    public static let bnb = evm("bnb", "BNB Chain", 56, "BNB", "bnb", "https://bsc-dataseed.bnbchain.org", "https://bscscan.com")
    public static let bnbTestnet = evm("bnb-testnet", "BNB Chain Testnet", 97, "tBNB", "bnb", "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
                                       "https://testnet.bscscan.com", testnetOf: "bnb")
    // Monad: docs.monad.xyz/developer-essentials/network-information (mainnet 143) and .../testnets (10143)
    public static let monad = evm("monad", "Monad", 143, "MON", "monad", "https://rpc.monad.xyz", "https://monadscan.com")
    public static let monadTestnet = evm("monad-testnet", "Monad Testnet", 10143, "MON", "monad", "https://testnet-rpc.monad.xyz",
                                         "https://testnet.monadscan.com", testnetOf: "monad")
    // Arbitrum One: docs.arbitrum.io (public RPC endpoints)
    public static let arbitrum = evm("arbitrum", "Arbitrum", 42161, "ETH", "arbitrum", "https://arb1.arbitrum.io/rpc", "https://arbiscan.io")
    public static let arbitrumSepolia = evm("arbitrum-sepolia", "Arbitrum Sepolia", 421_614, "ETH", "arbitrum",
                                            "https://sepolia-rollup.arbitrum.io/rpc", "https://sepolia.arbiscan.io", testnetOf: "arbitrum")
    // Robinhood Chain (Arbitrum Orbit, ETH gas): docs.robinhood.com/chain/connecting. No Circle/Tether stablecoins listed yet.
    public static let robinhood = evm("robinhood", "Robinhood Chain", 4663, "ETH", "robinhood", "https://rpc.mainnet.chain.robinhood.com",
                                      "https://robinhoodchain.blockscout.com")
    public static let robinhoodTestnet = evm("robinhood-testnet", "Robinhood Chain Testnet", 46630, "ETH", "robinhood",
                                             "https://rpc.testnet.chain.robinhood.com", "https://explorer.testnet.chain.robinhood.com",
                                             testnetOf: "robinhood")
    // Solana: solana.com/docs/references/clusters
    public static let solana = Chain(id: "solana", name: "Solana", kind: .solana, chainId: nil, nativeSymbol: "SOL", nativeDecimals: 9,
                                     logo: "solana", rpc: URL(string: "https://api.mainnet-beta.solana.com")!, explorer: "", isTestnet: false, mainnetID: nil)
    public static let solanaDevnet = Chain(id: "solana-devnet", name: "Solana Devnet", kind: .solana, chainId: nil, nativeSymbol: "SOL",
                                           nativeDecimals: 9, logo: "solana", rpc: URL(string: "https://api.devnet.solana.com")!, explorer: "",
                                           isTestnet: true, mainnetID: "solana")

    public static let all: [Chain] = [ethereum, base, bnb, monad, arbitrum, robinhood, solana,
                                      sepolia, baseSepolia, bnbTestnet, monadTestnet, arbitrumSepolia, robinhoodTestnet, solanaDevnet]
    public static let mainnets = all.filter { !$0.isTestnet }
    public static let testnets = all.filter(\.isTestnet)
    /// Where a new send starts: Base, or Base Sepolia when the build has mainnet sends off.
    public static var defaultSend: Chain { WalletService.mainnetSendsEnabled ? base : baseSepolia }

    public static func with(id: String) -> Chain? { all.first { $0.id == id } }
    public static func with(chainId: UInt64) -> Chain? { all.first { $0.chainId == chainId } }
}

/// Every stablecoin address in one place, each checked on-chain (symbol and decimals) on 2026-10-29.
///
/// Sources:
/// - USDC: Circle, developers.circle.com/stablecoins/usdc-contract-addresses (native USDC; Circle lists no BNB Chain
///   or Robinhood Chain deployment).
/// - USDT: Tether, tether.to/en/supported-protocols (Ethereum, Solana).
/// - USDT0 (Tether's omnichain USDT on Arbitrum and Monad): docs.usdt0.to/technical-documentation/deployments.
/// - BNB Chain USDC/USDT are Binance-Peg tokens issued by Binance, not Circle/Tether, with 18 decimals
///   (contracts as listed on bscscan.com token pages). Labelled as such in `name`.
public enum TokenTable {
    public static let all: [Token] = [
        // Ethereum (1)
        Token(chainID: "ethereum", symbol: "USDC", name: "USD Coin", address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6),
        Token(chainID: "ethereum", symbol: "USDT", name: "Tether USD", address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6),
        Token(chainID: "sepolia", symbol: "USDC", name: "USD Coin (testnet)", address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", decimals: 6),
        // Base (8453)
        Token(chainID: "base", symbol: "USDC", name: "USD Coin", address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6),
        Token(chainID: "base-sepolia", symbol: "USDC", name: "USD Coin (testnet)", address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e", decimals: 6),
        // BNB Chain (56): Binance-Peg, 18 decimals
        Token(chainID: "bnb", symbol: "USDC", name: "Binance-Peg USD Coin", address: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", decimals: 18),
        Token(chainID: "bnb", symbol: "USDT", name: "Binance-Peg Tether USD", address: "0x55d398326f99059fF775485246999027B3197955", decimals: 18),
        // Monad (143)
        Token(chainID: "monad", symbol: "USDC", name: "USD Coin", address: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", decimals: 6),
        Token(chainID: "monad", symbol: "USDT0", name: "USDT0", address: "0xe7cd86e13AC4309349F30B3435a9d337750fC82D", decimals: 6),
        Token(chainID: "monad-testnet", symbol: "USDC", name: "USD Coin (testnet)", address: "0x534b2f3A21130d7a60830c2Df862319e593943A3", decimals: 6),
        // Arbitrum One (42161)
        Token(chainID: "arbitrum", symbol: "USDC", name: "USD Coin", address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", decimals: 6),
        Token(chainID: "arbitrum", symbol: "USDT0", name: "USDT0", address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", decimals: 6),
        Token(chainID: "arbitrum-sepolia", symbol: "USDC", name: "USD Coin (testnet)", address: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", decimals: 6),
        // Solana (SPL Token program)
        Token(chainID: "solana", symbol: "USDC", name: "USD Coin", address: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", decimals: 6),
        Token(chainID: "solana", symbol: "USDT", name: "Tether USD", address: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", decimals: 6),
        Token(chainID: "solana-devnet", symbol: "USDC", name: "USD Coin (testnet)", address: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU", decimals: 6),
    ]

    /// Dollar-pegged tokens count 1:1 towards the daily limit.
    static let stableSymbols: Set<String> = ["USDC", "USDT", "USDT0"]
}
