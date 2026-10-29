import SwiftUI

// Wallet models and the demo's mock data (hermit-demo src/data.js, made multichain).
// The screens only use these types; the real engine fills them through `WalletProvider`.

/// How addresses work on a chain. Every EVM chain shares one address; Solana has its own.
enum ChainKind: String, Hashable, Sendable { case evm, solana }

/// A network a wallet can hold money on. One recovery phrase covers all of them.
struct WalletChain: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ChainKind
    /// Name for `LogoMark`.
    let logo: String
    /// The token that pays for gas.
    let gasToken: String
    let evmChainID: Int?

    static let solana = WalletChain(id: "solana", name: "Solana", kind: .solana, logo: "solana", gasToken: "SOL", evmChainID: nil)
    static let ethereum = WalletChain(id: "ethereum", name: "Ethereum", kind: .evm, logo: "ethereum", gasToken: "ETH", evmChainID: 1)
    static let base = WalletChain(id: "base", name: "Base", kind: .evm, logo: "base", gasToken: "ETH", evmChainID: 8453)
    static let bnb = WalletChain(id: "bnb", name: "BNB Chain", kind: .evm, logo: "bnb", gasToken: "BNB", evmChainID: 56)
    static let monad = WalletChain(id: "monad", name: "Monad", kind: .evm, logo: "monad", gasToken: "MON", evmChainID: 143)
    static let arbitrum = WalletChain(id: "arbitrum", name: "Arbitrum", kind: .evm, logo: "arbitrum", gasToken: "ETH", evmChainID: 42161)

    /// The networks Hermit supports, in picker order.
    static let all: [WalletChain] = [.solana, .ethereum, .base, .bnb, .monad, .arbitrum]
    static var evm: [WalletChain] { all.filter { $0.kind == .evm } }
    static func named(_ id: String) -> WalletChain { all.first { $0.id == id } ?? .base }

    var placeholder: String { kind == .solana ? "Solana address or .sol name" : "0x… or ENS name" }

    /// Checks the address format for this chain: 0x + 40 hex (or a .eth name) on EVM, base58 (or .sol) on Solana.
    func accepts(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .evm:
            if s.lowercased().hasSuffix(".eth") { return s.count > 4 && !s.contains(" ") }
            guard s.count == 42, s.hasPrefix("0x") else { return false }
            return s.dropFirst(2).allSatisfy(\.isHexDigit)
        case .solana:
            if s.lowercased().hasSuffix(".sol") { return s.count > 4 && !s.contains(" ") }
            let b58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
            return (32...44).contains(s.count) && s.allSatisfy { b58.contains($0) }
        }
    }

    /// The kind of address this looks like, if any (to flag a wrong network before Review).
    static func kind(of raw: String) -> ChainKind? {
        if WalletChain.base.accepts(raw) { return .evm }
        if WalletChain.solana.accepts(raw) { return .solana }
        return nil
    }
}

/// One wallet. Local wallets come from the recovery phrase on this device (or a hardware wallet);
/// Privy wallets are keyless. Each has an EVM address (shared by every EVM chain) and a Solana address.
struct WalletAccount: Identifiable, Hashable, Sendable {
    enum Custody: String, Hashable, Sendable { case local, privy }
    let id: String
    var name: String
    /// Short description under the name: "Local", "Ledger", "Privy, email".
    var kind: String
    var custody: Custody
    var evmAddress: String?
    var solanaAddress: String?
    /// Where the keys come from: "Recovery phrase, account 1", "Ledger Nano X".
    var source: String

    func address(on chain: WalletChain) -> String? { chain.kind == .evm ? evmAddress : solanaAddress }
    var chains: [WalletChain] { WalletChain.all.filter { address(on: $0) != nil } }
    var shortAddress: String { (evmAddress ?? solanaAddress).map(shortAddr) ?? "" }
    var symbol: String { custody == .privy ? "envelope" : (kind == "Ledger" ? "externaldrive" : "key.horizontal") }
}

/// A token balance in one wallet on one chain.
struct Holding: Identifiable, Hashable, Sendable {
    var id: String { "\(walletID)-\(chain.id)-\(symbol)" }
    let walletID: String
    let chain: WalletChain
    let symbol: String
    let name: String
    var amount: Double
    var price: Double
    var change: Double
    var usd: Double { amount * price }
}

/// Holdings of one token summed across wallets and chains (a Tokens row).
struct TokenGroup: Identifiable, Hashable {
    var id: String { symbol + (chain?.id ?? "") }
    let symbol: String
    let name: String
    let chain: WalletChain?
    let parts: [Holding]
    var amount: Double { parts.reduce(0) { $0 + $1.amount } }
    var usd: Double { parts.reduce(0) { $0 + $1.usd } }
    var price: Double { parts.first?.price ?? 0 }
    var change: Double { parts.first?.change ?? 0 }
    var chains: [WalletChain] { WalletChain.all.filter { c in parts.contains { $0.chain == c } } }
}

struct ActivityItem: Identifiable, Hashable, Sendable {
    let id: String
    let what: String
    /// API, Trade, Network, Earn, Payment, Transfer
    let category: String
    /// Signed dollar amount: positive is money in.
    let usd: Double
    let via: String
    let when: String
    let chain: WalletChain
    let walletID: String
    var tx: String = "0x8f2c…a91d"
}

/// Gas held on one chain.
struct GasTank: Identifiable, Hashable, Sendable {
    var id: String { chain.id }
    let chain: WalletChain
    var amount: Double
    var usd: Double
    var txs: Int
    var level: Double
    var low: Bool { txs < 50 }
}

/// A saved, labelled address. New ones are on a 24-hour hold before they can be used.
struct SavedAddress: Identifiable, Hashable, Sendable {
    var id: String { address + chain.id }
    let label: String
    let address: String
    let chain: WalletChain
    let note: String
    var hold: Bool = false
}

struct DAppPosition: Identifiable, Hashable {
    var id: String { name }
    let name: String, type: String, usd: Double, pnl: Double, chain: WalletChain
}

/// What a single wallet funds (demo LINKS).
struct WalletLinks {
    var projects: [(String, Double)] = []
    var trades: [(String, String, Double)] = []
    var payments: [(String, String, Double, String)] = []
    var defi: [(String, String, Double, Double)] = []
}

struct LinkedAccount: Identifiable, Hashable {
    var id: String { app }
    let app: String, handle: String, on: String, off: String
}

func shortAddr(_ a: String) -> String { a.count > 14 ? "\(a.prefix(6))…\(a.suffix(4))" : a }

/// Dollar and number formatting that does not depend on the device locale (the demo is en-US).
enum MoneyFmt {
    private static let en = Locale(identifier: "en_US")
    static func usd(_ v: Double, digits: Int = 0) -> String {
        let s = abs(v).formatted(.number.precision(.fractionLength(digits)).locale(en))
        return (v < 0 ? "−$" : "$") + s
    }
    /// $1,240 for big amounts, $3.41 for small ones.
    static func usdSmart(_ v: Double) -> String { usd(v, digits: abs(v) >= 100 || v == v.rounded() ? 0 : 2) }
    static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + usd(abs(v), digits: abs(v) >= 100 || v == v.rounded() ? 0 : 2) }
    static func pct(_ v: Double) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + abs(v).formatted(.number.precision(.fractionLength(2)).locale(en)) + "%" }
    static func amount(_ v: Double) -> String {
        if v >= 1_000_000 { return (v / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(en)) + "M" }
        if v >= 1000 { return v.formatted(.number.precision(.fractionLength(0)).locale(en)) }
        if v >= 1 { return v.formatted(.number.precision(.fractionLength(0...2)).locale(en)) }
        return v.formatted(.number.precision(.significantDigits(1...3)).locale(en))
    }
}

/// The demo's mock data, multichain.
enum WalletSeed {
    static let phraseAccounts = "Recovery phrase"

    static let wallets: [WalletAccount] = [
        WalletAccount(id: "main", name: "Main", kind: "Local", custody: .local,
                      evmAddress: "0x7a3F2c91B4e0D8a6F51c3E7b9A2d40E6f1a09c2E", solanaAddress: "7xKpVt3qRw9mN2bH5cJdLfY8sT4uE6gA1zXQm2aR9",
                      source: "Recovery phrase, account 1"),
        WalletAccount(id: "trading", name: "Trading", kind: "Local", custody: .local,
                      evmAddress: "0x51b0e4C29d8F3a176B2e0c94A1f7D3b85e2C77Ad", solanaAddress: "5HtQe8VbPz3RkWn7cYdJ2mFuS9aG4xLh6TqB1oEr8Ckp",
                      source: "Recovery phrase, account 2"),
        WalletAccount(id: "vault", name: "Vault", kind: "Ledger", custody: .local,
                      evmAddress: "0xF09e5B2c11Aa7D3e8C4f92b106dE7a5F3c9213B4", solanaAddress: nil,
                      source: "Ledger Nano X"),
        WalletAccount(id: "sol", name: "Solana", kind: "Privy, email", custody: .privy,
                      evmAddress: "0x3D8c71aE52f0B9d4C17e6a289fB03d5Ea4c1e7F2", solanaAddress: "Gq4Jt8RvB2nXcW6kHm3ZsP9dYfE5aUw7LxTbN1oQe3Fy",
                      source: "Privy, ryan@hermit.app"),
        WalletAccount(id: "farm", name: "Airdrop farm", kind: "Privy, 3 wallets", custody: .privy,
                      evmAddress: "0x1c4dA7e2b83F09c6D25e1A7f4C9b0e3D8a6f52B1", solanaAddress: "3vFbN8cR2tYqK5mWx9HsJ4dPzG7aEu6LgTn1QkBe2Wpd",
                      source: "Privy, passkey"),
    ]

    /// Prices and 24h change for the mock.
    static let prices: [String: (Double, Double, String)] = [
        "USDC": (1, 0, "USD Coin"), "ETH": (3500, 2.41, "Ethereum"), "SOL": (186.6, -1.12, "Solana"),
        "BNB": (600, 0.84, "BNB"), "MON": (0.043, 7.9, "Monad"), "PEPE": (0.00001917, 12.4, "Pepe"),
        "WIF": (0.92, -3.2, "dogwifhat"), "USDT": (1, 0, "Tether"),
    ]

    private static func h(_ w: String, _ c: WalletChain, _ sym: String, _ amt: Double) -> Holding {
        let p = prices[sym] ?? (1, 0, sym)
        return Holding(walletID: w, chain: c, symbol: sym, name: p.2, amount: amt, price: p.0, change: p.1)
    }

    /// Sums to $48,320 like the demo: Main 21,400, Trading 12,400, Vault 7,150, Solana 6,550, Airdrop farm 820.
    static let holdings: [Holding] = [
        h("main", .base, "USDC", 6200), h("main", .arbitrum, "USDC", 4470), h("main", .ethereum, "ETH", 1.4),
        h("main", .ethereum, "PEPE", 84_000_000), h("main", .base, "ETH", 0.42), h("main", .solana, "SOL", 7.02),
        h("main", .bnb, "BNB", 2.1), h("main", .monad, "MON", 4180),
        h("trading", .arbitrum, "USDC", 9400), h("trading", .arbitrum, "ETH", 0.857),
        h("vault", .ethereum, "ETH", 1.77), h("vault", .ethereum, "USDC", 955),
        h("sol", .solana, "USDC", 5000), h("sol", .solana, "SOL", 7.074), h("sol", .solana, "WIF", 250),
        h("farm", .base, "ETH", 0.086), h("farm", .monad, "MON", 5100), h("farm", .bnb, "BNB", 0.5),
    ]

    static let activity: [ActivityItem] = [
        ActivityItem(id: "a1", what: "OpenAI API credits", category: "API", usd: -20, via: "x402", when: "Today 10:12", chain: .base, walletID: "main"),
        ActivityItem(id: "a2", what: "Swap 1,000 USDC to PEPE", category: "Trade", usd: -1000, via: "Uniswap", when: "Today 09:40", chain: .ethereum, walletID: "main"),
        ActivityItem(id: "a3", what: "Gas sponsorship", category: "Network", usd: -1.84, via: "Base", when: "Today 09:40", chain: .base, walletID: "main"),
        ActivityItem(id: "a4", what: "Bought 5,100 MON", category: "Trade", usd: -220, via: "Kuru", when: "Today 08:15", chain: .monad, walletID: "farm"),
        ActivityItem(id: "a5", what: "Pendle PT-USDe yield", category: "Earn", usd: 38.2, via: "Auto-claim", when: "Yesterday", chain: .ethereum, walletID: "vault"),
        ActivityItem(id: "a6", what: "Received 0.5 BNB", category: "Transfer", usd: 300, via: "From Binance", when: "Yesterday", chain: .bnb, walletID: "farm"),
        ActivityItem(id: "a7", what: "Notion subscription", category: "Payment", usd: -10, via: "USDC to bank", when: "Oct 24", chain: .base, walletID: "main"),
        ActivityItem(id: "a8", what: "Perplexity API (pay-per-call)", category: "API", usd: -3.41, via: "x402", when: "Oct 23", chain: .solana, walletID: "sol"),
        ActivityItem(id: "a9", what: "Funding received", category: "Trade", usd: 12.6, via: "Hyperliquid", when: "Oct 23", chain: .arbitrum, walletID: "trading"),
        ActivityItem(id: "a10", what: "Sent to alice.eth", category: "Payment", usd: -1200, via: "USDC on Base", when: "Oct 1", chain: .base, walletID: "main"),
        ActivityItem(id: "a11", what: "Received from Coinbase", category: "Transfer", usd: 5000, via: "USDC on Base", when: "Sep 30", chain: .base, walletID: "main"),
        ActivityItem(id: "a12", what: "Aave USDC interest", category: "Earn", usd: 24.1, via: "Auto-claim", when: "Sep 30", chain: .arbitrum, walletID: "main"),
        ActivityItem(id: "a13", what: "Swap 2 SOL to USDC", category: "Trade", usd: -373, via: "Jupiter", when: "Sep 29", chain: .solana, walletID: "sol"),
    ]

    static let gas: [GasTank] = [
        GasTank(chain: .solana, amount: 0.35, usd: 65, txs: 70000, level: 0.8),
        GasTank(chain: .ethereum, amount: 0.042, usd: 147, txs: 85, level: 0.55),
        GasTank(chain: .base, amount: 0.006, usd: 21, txs: 2100, level: 0.9),
        GasTank(chain: .bnb, amount: 0.05, usd: 30, txs: 1500, level: 0.7),
        GasTank(chain: .monad, amount: 2.3, usd: 0.1, txs: 6, level: 0.05),
        GasTank(chain: .arbitrum, amount: 0.0009, usd: 3, txs: 40, level: 0.12),
    ]

    static let whitelist: [SavedAddress] = [
        SavedAddress(label: "alice.eth", address: "0x2b9F41c8D0e7A3b15c6E9d2F4a8B7c3E1d0f9e04", chain: .base, note: "Designer"),
        SavedAddress(label: "Coinbase deposit", address: "0x7d10Ae92b4C5f83a9E1c6D7b2F5a8e4C0b6d3fa1", chain: .ethereum, note: "Exchange"),
        SavedAddress(label: "Ledger cold storage", address: "0xF09e5B2c11Aa7D3e8C4f92b106dE7a5F3c9213B4", chain: .ethereum, note: "Own wallet"),
        SavedAddress(label: "Binance BNB deposit", address: "0x8e4B2a7C1d9F3e6A0b5C8d2E7f1A4b9C3e6D50c7", chain: .bnb, note: "Exchange"),
        SavedAddress(label: "bob on Solana", address: "9PfQ2tLm7WcRzK4hXv8DnB3eJ6sGuY5wAqTpVx4k", chain: .solana, note: "Friend"),
    ]

    static let dapps: [DAppPosition] = [
        DAppPosition(name: "Hyperliquid", type: "Perps", usd: 12400, pnl: 842, chain: .arbitrum),
        DAppPosition(name: "Pendle", type: "Fixed yield", usd: 6200, pnl: 214, chain: .ethereum),
        DAppPosition(name: "Aave v3", type: "Lending", usd: 5100, pnl: 96, chain: .arbitrum),
        DAppPosition(name: "Ethena", type: "Staked USDe", usd: 3500, pnl: 118, chain: .ethereum),
        DAppPosition(name: "Jupiter", type: "Spot (SOL)", usd: 2630, pnl: -31, chain: .solana),
        DAppPosition(name: "Kuru", type: "Spot (MON)", usd: 220, pnl: 17, chain: .monad),
    ]

    static let links: [String: WalletLinks] = [
        "main": WalletLinks(
            projects: [("Stablecoin yield ladder", 16300), ("Dev: HYPE news bot", 20), ("Presale tracker", 1250)],
            trades: [("SOL", "SOL spot", 178)],
            payments: [("Figma", "Pro plan", 45, "Tomorrow"), ("Vercel", "Pro team", 20, "Oct 30"), ("alice.eth", "Design milestone 2", 1200, "Nov 1"), ("Landlord", "November rent", 2400, "Nov 3")],
            defi: [("Aave", "USDC supply", 5100, 5.6), ("Morpho", "USDC vault", 4000, 7.9)]),
        "trading": WalletLinks(
            projects: [("HYPE perp scripts", 10200), ("Meme auto-trader", 300)],
            trades: [("HYPE", "HYPE-PERP long 3x", 530), ("ETH", "ETH-PERP short 1x", 32)],
            payments: [("Hyperliquid", "Margin top-up if needed", 500, "Conditional")],
            defi: [("Hyperliquid", "HLP vault", 1500, 14.7)]),
        "vault": WalletLinks(defi: [("Pendle", "PT-USDe Dec-26", 6200, 18.4), ("Lido", "stETH", 950, 3.1)]),
        "sol": WalletLinks(projects: [("Meme auto-trader", 300)], trades: [("WIF", "WIF spot", -26), ("SOL", "SOL spot", 178)],
                           defi: [("Jupiter Lend", "USDC lending", 2000, 6.8)]),
        "farm": WalletLinks(projects: [("Airdrop farming S3", 2950)], payments: [("Gas.zip", "Gas refills", 2, "Daily")]),
    ]

    static let accounts: [LinkedAccount] = [
        LinkedAccount(app: "X", handle: "@ryanchi", on: "2,140 followers", off: "Quests and posts"),
        LinkedAccount(app: "Discord", handle: "ryanchi", on: "14 servers", off: "Airdrop roles"),
        LinkedAccount(app: "Telegram", handle: "@ryanchi", on: "Alerts on", off: "Alerts and alpha groups"),
    ]

    static let aumByAsset: [(String, Double, Color)] = [
        ("USDC", 22400, Color(hex: 0x2775CA)), ("ETH", 9950, Color(hex: 0x121212)), ("SOL", 6550, Color(hex: 0x8E73CF)),
        ("HYPE", 6200, Color(hex: 0x4E1F96)), ("Memes", 1900, Color(hex: 0xC9BFE6)), ("Other", 1320, Color(hex: 0xE4E4E2)),
    ]
    static let aumByProject: [(String, Double, Color)] = [
        ("Stablecoin yield ladder", 16300, Color(hex: 0x121212)), ("HYPE perp scripts", 10200, Color(hex: 0x4E1F96)),
        ("Airdrop farming S3", 2950, Color(hex: 0x8E73CF)), ("Presale tracker", 1250, Color(hex: 0xB7A6E8)),
        ("Meme auto-trader", 320, Color(hex: 0xC9BFE6)), ("Not in a project", 17300, Color(hex: 0xE4E4E2)),
    ]
    static let projectColors: [String: Color] = [
        "Dev: HYPE news bot": Color(hex: 0x2563EB), "Stablecoin yield ladder": Color(hex: 0x15803D), "HYPE perp scripts": Color(hex: 0x4E1F96),
        "Airdrop farming S3": Color(hex: 0xC2410C), "Meme auto-trader": Color(hex: 0xA16207), "Presale tracker": Color(hex: 0xBE185D),
    ]

    /// The approval sheet's standard checks (demo baseChecks).
    static func checks(_ extra: [String] = []) -> [String] {
        ["Requested by you, not by a web page or email", "Simulation matches summary", "Contract verified and audited",
         "Exact-amount token approval"] + extra + ["Within daily limit"]
    }

    /// Words for a newly created recovery phrase (demo only; the engine generates real BIP-39 entropy).
    static let demoWords = ["orbit", "velvet", "harbor", "nickel", "salmon", "theory", "lumber", "copper", "drift", "meadow", "cabin", "tiger"]
}
