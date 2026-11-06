import SwiftUI
import HermitCore
import HermitWallet

// Wallet models for the screens. Everything here is filled from the wallet engine (HermitWallet's WalletService):
// wallets from the on-device vault, balances from public RPCs, prices from CoinGecko, activity from sends made here.

/// The networks the screens use are HermitWallet's `Chain`s. These are the bits only the UI needs.
extension Chain {
    /// The coin that pays for gas.
    var gasToken: String { nativeSymbol }
    var placeholder: String { kind == .solana ? "Solana address" : "0x… address or ENS name" }
    /// Sends from the app are testnet-only until the signer has had its security review.
    var sendsEnabled: Bool { isTestnet }

    /// Real format check: a 0x address (or an ENS name) on EVM, a 32-byte base58 key on Solana.
    func accepts(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .evm: return EVMAddress(s) != nil || ENS.looksLikeName(s)
        case .solana: return SolanaPublicKey(s) != nil
        }
    }

    /// The kind of address this looks like, if any (to flag a wrong network before Review).
    static func kind(of raw: String) -> ChainKind? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if EVMAddress(s) != nil { return .evm }
        if SolanaPublicKey(s) != nil { return .solana }
        return nil
    }

    static var evmMainnets: [Chain] { mainnets.filter { $0.kind == .evm } }
}

/// One wallet on this device: one recovery phrase, one EVM address for every EVM chain and one Solana address.
struct WalletAccount: Identifiable, Hashable, Sendable {
    /// Local wallets live on this device. Keyless (Privy) wallets aren't available yet; the UI shows them greyed.
    enum Custody: String, Hashable, Sendable { case local, privy }
    let record: WalletRecord
    var id: String { record.id.uuidString }
    var name: String { record.name }
    var custody: Custody { .local }
    var evmAddress: String? { record.evmAddress }
    var solanaAddress: String? { record.solanaAddress }
    var backedUp: Bool { record.backedUp }
    var kind: String { "Local" }
    /// Where the keys come from.
    var source: String { "Recovery phrase, \(record.wordCount) words" }
    var protection: String { record.protection.label }

    func address(on chain: Chain) -> String? { record.address(on: chain) }
    var chains: [Chain] { Chain.all }
    var shortAddress: String { shortAddr(record.evmAddress) }
    var symbol: String { "key.horizontal" }
}

/// A token balance in one wallet on one chain.
struct Holding: Identifiable, Hashable, Sendable {
    var id: String { "\(walletID)-\(chain.id)-\(symbol)" }
    let walletID: String
    let chain: Chain
    let symbol: String
    let name: String
    /// Exact amount, as the chain reports it.
    let exact: String
    var amount: Double
    /// nil when there is no price: testnet coins, or the price source didn't answer.
    var price: Double?
    var change: Double?
    var usd: Double { amount * (price ?? 0) }
    var priced: Bool { price != nil }
}

/// Holdings of one token summed across wallets and chains (a Tokens row). Testnet coins are their own rows.
struct TokenGroup: Identifiable, Hashable {
    var id: String { symbol + (testnet ? "-test" : "") + (chain?.id ?? "") }
    let symbol: String
    let name: String
    let chain: Chain?
    let testnet: Bool
    let parts: [Holding]
    var amount: Double { parts.reduce(0) { $0 + $1.amount } }
    var usd: Double { parts.reduce(0) { $0 + $1.usd } }
    var price: Double? { parts.first?.price }
    var change: Double? { parts.first?.change }
    var priced: Bool { price != nil }
    var chains: [Chain] { Chain.all.filter { c in parts.contains { $0.chain == c } } }
}

/// A send made from this device (the engine's send log).
struct ActivityItem: Identifiable, Hashable, Sendable {
    let entry: SendLog.Entry
    let chain: Chain
    var id: String { entry.hash }
    var walletID: String { entry.walletID.uuidString }
    var what: String { "Sent \(entry.amount) \(entry.symbol) to \(entry.label ?? shortAddr(entry.recipient))" }
    var via: String { "\(entry.symbol) on \(chain.name)" }
    var amountText: String { "−\(entry.amount) \(entry.symbol)" }
    var when: String { entry.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
    var tx: String { entry.hash }
    var explorer: URL? { chain.explorerURL(tx: entry.hash) }

    static func == (a: Self, b: Self) -> Bool { a.entry.hash == b.entry.hash }
    func hash(into h: inout Hasher) { h.combine(entry.hash) }
}

/// Gas (the native coin) held on one chain, summed across the wallets in view.
struct GasTank: Identifiable, Hashable, Sendable {
    var id: String { chain.id }
    let chain: Chain
    var amount: Double
    var usd: Double?
    var low: Bool { amount == 0 }
}

/// A saved, labelled address (the engine's address book). New ones are on a 24-hour hold before they can be used.
struct SavedAddress: Identifiable, Hashable, Sendable {
    var id: String { kind.rawValue + address }
    let label: String
    let address: String
    let kind: ChainKind
    let added: Date?
    let payments: Int
    var hold: Bool { payments == 0 && (added.map { Date().timeIntervalSince($0) < 86_400 } ?? false) }
    var networkName: String { kind == .evm ? "EVM networks" : "Solana" }
}

func shortAddr(_ a: String) -> String { a.count > 14 ? "\(a.prefix(6))…\(a.suffix(4))" : a }

/// Dollar and number formatting that does not depend on the device locale.
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
        if v == 0 { return "0" }
        if v >= 1_000_000 { return (v / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(en)) + "M" }
        if v >= 1000 { return v.formatted(.number.precision(.fractionLength(0)).locale(en)) }
        if v >= 1 { return v.formatted(.number.precision(.fractionLength(0...2)).locale(en)) }
        return v.formatted(.number.precision(.significantDigits(1...3)).locale(en))
    }
    /// "$1,240" when there is a price, "Testnet" or "No price" when there isn't.
    static func value(_ h: Holding) -> String { h.priced ? usd(h.usd, digits: h.usd < 10 ? 2 : 0) : (h.chain.isTestnet ? "Testnet" : "No price") }
}

/// Shared approval-sheet check list (kept for pages outside Wallets that build their own approvals).
enum WalletSeed {
    static func checks(_ extra: [String] = []) -> [String] { Approval.checks(extra) }
}
