import SwiftUI
import Observation
import HermitCore

// The seam between the wallet screens and the wallet engine.
//
// `WalletProvider` is shaped like HermitCore's chain-agnostic WalletService: chains with a kind (.evm / .solana),
// accounts with one address per chain kind, balances per account, and a two-step send (prepare a quote, then
// execute it after the approval sheet passed). `MockWalletProvider` runs the demo today; to go live, write a small
// adapter `final class EngineWalletProvider: WalletProvider` over WalletService and pass it to `WalletsViewModel`.

/// A send the engine has simulated and priced. Shown in the approval sheet, then executed.
struct SendQuote: Identifiable, Hashable, Sendable {
    let id: String
    let fromWalletID: String
    let chain: WalletChain
    let to: String
    let amount: Double
    let token: String
    let usd: Double
    let fee: String
    let arrives: String
}

enum WalletError: LocalizedError {
    case insufficient(String), badAddress(WalletChain), badPhrase
    var errorDescription: String? {
        switch self {
        case .insufficient(let t): "Not enough \(t) in this wallet"
        case .badAddress(let c): "Not a valid \(c.name) address"
        case .badPhrase: "Use 12 or 24 words from your recovery phrase"
        }
    }
}

@MainActor
protocol WalletProvider: AnyObject {
    var chains: [WalletChain] { get }
    func loadWallets() async throws -> [WalletAccount]
    func balances(for wallet: WalletAccount) async throws -> [Holding]
    func activity(for wallet: WalletAccount) async throws -> [ActivityItem]
    func gas() async throws -> [GasTank]
    /// Validates the address for the chain, checks the balance, simulates, and prices the fee.
    func prepareSend(from wallet: WalletAccount, chain: WalletChain, to: String, amount: Double, token: String) async throws -> SendQuote
    /// Signs and broadcasts a quote (after Face ID / Touch ID). Returns the transaction hash.
    func execute(_ quote: SendQuote) async throws -> String
    /// Next account from the recovery phrase on this device (creates the phrase on first use; its words are returned once).
    func createLocalWallet(name: String) async throws -> (WalletAccount, [String]?)
    func importWallet(phrase: [String], name: String) async throws -> WalletAccount
    func connectHardwareWallet() async throws -> WalletAccount
    func createKeylessWallet(method: String) async throws -> WalletAccount
}

/// Everything the wallet screens show, and the money moves they start. Shared so balances survive page changes.
@MainActor @Observable
final class WalletsViewModel {
    static let shared = WalletsViewModel(provider: MockWalletProvider())

    let provider: WalletProvider
    var wallets: [WalletAccount] = []
    var holdings: [Holding] = []
    var activity: [ActivityItem] = []
    var gas: [GasTank] = []
    var whitelist: [SavedAddress] = WalletSeed.whitelist
    var whitelistOnly = true
    var autoTopUp = true
    var linked: Set<String> = ["X"]
    private(set) var loaded = false

    init(provider: WalletProvider) {
        self.provider = provider
        // The mock answers instantly; fill synchronously so the first frame (and snapshots) has data.
        if let mock = provider as? MockWalletProvider {
            wallets = mock.store.wallets; holdings = mock.store.holdings; activity = mock.store.activity; gas = mock.store.gas; loaded = true
        }
    }

    var chains: [WalletChain] { provider.chains }

    func refresh() async {
        guard let ws = try? await provider.loadWallets() else { return }
        var hs: [Holding] = [], acts: [ActivityItem] = []
        for w in ws {
            hs += (try? await provider.balances(for: w)) ?? []
            acts += (try? await provider.activity(for: w)) ?? []
        }
        let g = (try? await provider.gas()) ?? gas
        withAnimation(.smooth) {
            wallets = ws; holdings = hs; gas = g
            var seen = Set<String>(); activity = acts.filter { seen.insert($0.id).inserted }
            loaded = true
        }
    }

    // MARK: Reading

    func wallet(_ id: String?) -> WalletAccount? { wallets.first { $0.id == id } }
    func total(_ walletID: String? = nil) -> Double {
        holdings.filter { walletID == nil || $0.walletID == walletID }.reduce(0) { $0 + $1.usd }
    }
    func holdings(wallet: String?, chain: WalletChain?) -> [Holding] {
        holdings.filter { (wallet == nil || $0.walletID == wallet) && (chain == nil || $0.chain == chain) && $0.usd >= 0.01 }
    }
    /// Tokens rows. With a chain picked, one row per token on that chain; otherwise one row per token across chains.
    func tokenGroups(wallet: String?, chain: WalletChain?) -> [TokenGroup] {
        let hs = holdings(wallet: wallet, chain: chain)
        let groups = Dictionary(grouping: hs, by: \.symbol).map { sym, parts in
            TokenGroup(symbol: sym, name: parts[0].name, chain: chain, parts: parts)
        }
        return groups.sorted { $0.usd > $1.usd }
    }
    func balance(of token: String, wallet: String, chain: WalletChain) -> Double {
        holdings.first { $0.walletID == wallet && $0.chain == chain && $0.symbol == token }?.amount ?? 0
    }
    func activity(wallet: String?, chain: WalletChain?) -> [ActivityItem] {
        activity.filter { (wallet == nil || $0.walletID == wallet) && (chain == nil || $0.chain == chain) }
    }
    /// Tokens a wallet can send on a chain (always offers the gas token and USDC).
    func tokens(wallet: String, chain: WalletChain) -> [String] {
        var t = holdings(wallet: wallet, chain: chain).sorted { $0.usd > $1.usd }.map(\.symbol)
        for s in ["USDC", chain.gasToken] where !t.contains(s) { t.append(s) }
        return t
    }
    func price(_ token: String) -> Double { WalletSeed.prices[token]?.0 ?? 1 }
    func saved(_ address: String) -> SavedAddress? {
        whitelist.first { $0.address.caseInsensitiveCompare(address.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }
    /// Your own wallet that owns this address, if any.
    func ownWallet(for address: String) -> WalletAccount? {
        wallets.first { $0.evmAddress?.caseInsensitiveCompare(address) == .orderedSame || $0.solanaAddress == address }
    }

    // MARK: Money moves. Each builds the approval sheet and the work to run once it is approved.

    func approval(for q: SendQuote, label: String?) -> Approval {
        let from = wallet(q.fromWalletID)?.name ?? "Wallet"
        let own = ownWallet(for: q.to)
        let toText = own.map { "\($0.name) (\(shortAddr(q.to)))" } ?? label.map { "\($0) (\(shortAddr(q.to)))" } ?? shortAddr(q.to)
        var extra: [String] = []
        if own != nil { extra.append("Destination is your own wallet") }
        else if label != nil { extra.append("Address is on your whitelist") }
        else { extra.append("New address, double-checked") }
        extra.append("Address format matches \(q.chain.name)")
        return Approval(kind: own != nil ? "Internal transfer" : "Send",
                        title: "Send \(MoneyFmt.amount(q.amount)) \(q.token)",
                        lines: [["From", from], ["To", toText], ["Network", q.chain.name],
                                ["Amount", "\(MoneyFmt.amount(q.amount)) \(q.token) (\(MoneyFmt.usdSmart(q.usd)))"],
                                ["Fee", q.fee], ["Arrives", q.arrives]],
                        checks: WalletSeed.checks(extra),
                        success: own != nil ? "Moved to \(own!.name)" : "Sent to \(label ?? shortAddr(q.to))",
                        receipt: .receipt(title: "Sent \(MoneyFmt.amount(q.amount)) \(q.token)",
                                          rows: [["To", toText], ["Network", q.chain.name], ["Fee", q.fee]]))
    }

    func execute(_ q: SendQuote) async {
        _ = try? await provider.execute(q)
        await refresh()
    }

    /// Bridge between chains. Mock only for now: moves the balance and logs it.
    func bridge(wallet: String, token: String, amount: Double, from: WalletChain, to: WalletChain, route: String) {
        let px = price(token)
        withAnimation(.smooth) {
            adjust(wallet, from, token, -amount)
            adjust(wallet, to, token, amount * 0.999)
            activity.insert(ActivityItem(id: UUID().uuidString, what: "Bridged \(MoneyFmt.amount(amount)) \(token) to \(to.name)", category: "Transfer",
                                         usd: -(amount * px * 0.001), via: route, when: "Just now", chain: from, walletID: wallet), at: 0)
        }
        sync()
    }

    func refillGas(_ chain: WalletChain, usd: Double, payWith token: String?, fromWallet: String) {
        withAnimation(.smooth(duration: 0.6)) {
            if let i = gas.firstIndex(where: { $0.chain == chain }) {
                var g = gas[i]
                let perUsd = Double(g.txs) / max(g.usd, 0.1)
                g.usd += usd; g.amount += usd / price(chain.gasToken)
                g.txs = Int((g.usd * max(perUsd, 20)).rounded()); g.level = min(0.95, g.level + 0.6)
                gas[i] = g
            }
            if let token { adjust(fromWallet, chain, token, -usd) }
            activity.insert(ActivityItem(id: UUID().uuidString, what: "\(chain.name) gas top-up", category: "Network", usd: -usd,
                                         via: token.map { "Swap from \($0)" } ?? "From \(wallet(fromWallet)?.name ?? "wallet")",
                                         when: "Just now", chain: chain, walletID: fromWallet), at: 0)
        }
        sync()
    }

    func drainGas(_ chain: WalletChain, usd: Double, toUSDC: Bool) {
        withAnimation(.smooth(duration: 0.6)) {
            if let i = gas.firstIndex(where: { $0.chain == chain }) {
                var g = gas[i]
                let perUsd = Double(g.txs) / max(g.usd, 0.1), left = max(0, g.usd - usd)
                g.amount = max(0, g.amount - usd / price(chain.gasToken)); g.level = max(0.03, g.level * left / max(g.usd, 0.1))
                g.txs = Int((left * perUsd).rounded()); g.usd = left
                gas[i] = g
            }
            if toUSDC { adjust("main", chain, "USDC", usd) }
        }
        sync()
    }

    func addAddress(label: String, address: String, chain: WalletChain) {
        withAnimation(.smooth) { whitelist.append(SavedAddress(label: label, address: address, chain: chain, note: "Added today", hold: true)) }
    }

    func add(_ w: WalletAccount) {
        withAnimation(.smooth) { if !wallets.contains(w) { wallets.append(w) } }
    }

    /// Keeps the mock engine in step with changes it does not model itself (bridges, gas).
    private func sync() {
        guard let m = provider as? MockWalletProvider else { return }
        m.store.holdings = holdings; m.store.gas = gas; m.store.activity = activity
    }

    private func adjust(_ wallet: String, _ chain: WalletChain, _ token: String, _ delta: Double) {
        if let i = holdings.firstIndex(where: { $0.walletID == wallet && $0.chain == chain && $0.symbol == token }) {
            holdings[i].amount = max(0, holdings[i].amount + delta)
        } else if delta > 0 {
            let p = WalletSeed.prices[token] ?? (1, 0, token)
            holdings.append(Holding(walletID: wallet, chain: chain, symbol: token, name: p.2, amount: delta, price: p.0, change: p.1))
        }
    }
}

/// Demo engine: the demo's data, kept in memory, with real address checks.
@MainActor
final class MockWalletProvider: WalletProvider {
    struct Store { var wallets = WalletSeed.wallets; var holdings = WalletSeed.holdings; var activity = WalletSeed.activity; var gas = WalletSeed.gas }
    var store = Store()
    private var accountIndex = 2

    var chains: [WalletChain] { WalletChain.all }
    func loadWallets() async throws -> [WalletAccount] { store.wallets }
    func balances(for wallet: WalletAccount) async throws -> [Holding] { store.holdings.filter { $0.walletID == wallet.id } }
    func activity(for wallet: WalletAccount) async throws -> [ActivityItem] { store.activity.filter { $0.walletID == wallet.id } }
    func gas() async throws -> [GasTank] { store.gas }

    func prepareSend(from wallet: WalletAccount, chain: WalletChain, to: String, amount: Double, token: String) async throws -> SendQuote {
        guard chain.accepts(to) else { throw WalletError.badAddress(chain) }
        let have = store.holdings.first { $0.walletID == wallet.id && $0.chain == chain && $0.symbol == token }?.amount ?? 0
        guard have >= amount else { throw WalletError.insufficient(token) }
        let px = WalletSeed.prices[token]?.0 ?? 1
        let fee: String = switch chain.id { case "ethereum": "$1.20"; case "bnb": "$0.05"; case "solana": "$0.001"; default: "$0.01" }
        let arrives = chain == .ethereum ? "About 1 min" : chain == .solana ? "Under a second" : "Seconds"
        return SendQuote(id: UUID().uuidString, fromWalletID: wallet.id, chain: chain, to: to, amount: amount, token: token,
                         usd: amount * px, fee: fee, arrives: arrives)
    }

    func execute(_ q: SendQuote) async throws -> String {
        try? await Task.sleep(for: .milliseconds(150))
        func adjust(_ w: String, _ d: Double) {
            if let i = store.holdings.firstIndex(where: { $0.walletID == w && $0.chain == q.chain && $0.symbol == q.token }) {
                store.holdings[i].amount = max(0, store.holdings[i].amount + d)
            } else if d > 0, let p = WalletSeed.prices[q.token] {
                store.holdings.append(Holding(walletID: w, chain: q.chain, symbol: q.token, name: p.2, amount: d, price: p.0, change: p.1))
            }
        }
        adjust(q.fromWalletID, -q.amount)
        let own = store.wallets.first { $0.evmAddress?.caseInsensitiveCompare(q.to) == .orderedSame || $0.solanaAddress == q.to }
        if let own { adjust(own.id, q.amount) }
        let hash = q.chain.kind == .solana ? "5vGk…" + String(UUID().uuidString.prefix(4)) : "0x" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased() + "…" + String(UUID().uuidString.suffix(4)).lowercased()
        store.activity.insert(ActivityItem(id: UUID().uuidString, what: own.map { "Moved \(MoneyFmt.amount(q.amount)) \(q.token) to \($0.name)" } ?? "Sent \(MoneyFmt.amount(q.amount)) \(q.token) to \(shortAddr(q.to))",
                                           category: own == nil ? "Payment" : "Transfer", usd: own == nil ? -q.usd : 0, via: "\(q.token) on \(q.chain.name)",
                                           when: "Just now", chain: q.chain, walletID: q.fromWalletID, tx: hash), at: 0)
        return hash
    }

    func createLocalWallet(name: String) async throws -> (WalletAccount, [String]?) {
        accountIndex += 1
        let w = WalletAccount(id: "w\(Int(Date().timeIntervalSince1970))", name: name, kind: "Local", custody: .local,
                              evmAddress: Self.randomEVM(), solanaAddress: Self.randomSolana(), source: "Recovery phrase, account \(accountIndex)")
        store.wallets.append(w)
        return (w, nil)
    }
    func importWallet(phrase: [String], name: String) async throws -> WalletAccount {
        guard [12, 24].contains(phrase.count) else { throw WalletError.badPhrase }
        let w = WalletAccount(id: "w\(Int(Date().timeIntervalSince1970))", name: name, kind: "Local", custody: .local,
                              evmAddress: Self.randomEVM(), solanaAddress: Self.randomSolana(), source: "Imported phrase, account 1")
        store.wallets.append(w); return w
    }
    func connectHardwareWallet() async throws -> WalletAccount {
        try? await Task.sleep(for: .milliseconds(1400))
        let w = WalletAccount(id: "w\(Int(Date().timeIntervalSince1970))", name: "Ledger 2", kind: "Ledger", custody: .local,
                              evmAddress: Self.randomEVM(), solanaAddress: Self.randomSolana(), source: "Ledger Nano X")
        store.wallets.append(w); return w
    }
    func createKeylessWallet(method: String) async throws -> WalletAccount {
        try? await Task.sleep(for: .milliseconds(700))
        let w = WalletAccount(id: "w\(Int(Date().timeIntervalSince1970))", name: "Privy wallet", kind: "Privy, \(method.lowercased())", custody: .privy,
                              evmAddress: Self.randomEVM(), solanaAddress: Self.randomSolana(), source: "Privy, \(method.lowercased())")
        store.wallets.append(w); return w
    }

    static func randomEVM() -> String { "0x" + String((0..<40).map { _ in "0123456789abcdefABCDEF".randomElement()! }) }
    static func randomSolana() -> String { String((0..<44).map { _ in "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".randomElement()! }) }
}
