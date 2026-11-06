import SwiftUI
import Observation
import HermitCore
import HermitWallet

/// Everything the wallet screens (and Home) show, read from the wallet engine. Shared so balances survive page changes.
///
/// For Home: `hasWallet`, `totalUSD` (nil until it is known: no wallet, not loaded yet, or no price), `refresh()`,
/// `refreshing`, `lastUpdated`.
@MainActor @Observable
final class WalletsViewModel {
    static let shared = WalletsViewModel(service: WalletService(vault: WalletsViewModel.runningTests ? KeyVault(store: HermitWallet.MemoryStore()) : .makeDefault()))

    /// Tests and snapshots never touch the real vault.
    nonisolated static var runningTests: Bool { NSClassFromString("XCTestCase") != nil }

    let service: WalletService
    private(set) var wallets: [WalletAccount] = []
    private(set) var holdings: [Holding] = []
    private(set) var activity: [ActivityItem] = []
    private(set) var whitelist: [SavedAddress] = []
    private(set) var prices: [String: PriceQuote] = [:]
    private(set) var refreshing = false
    private(set) var loaded = false
    private(set) var lastUpdated: Date?
    /// Networks that didn't answer on the last refresh (their balances are unknown, not zero).
    private(set) var unreachable: [Chain] = []
    var whitelistOnly: Bool {
        didSet { UserDefaults.standard.set(whitelistOnly, forKey: "hermit.wallet.whitelistOnly") }
    }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(service: WalletService) {
        self.service = service
        whitelistOnly = UserDefaults.standard.bool(forKey: "hermit.wallet.whitelistOnly")
        reloadLocal()
    }

    // MARK: Home API

    var hasWallet: Bool { !wallets.isEmpty }

    /// Dollar value of every wallet's mainnet coins. nil when it isn't known: no wallet, balances not loaded yet,
    /// a network didn't answer, or there is no price for something held. Testnet coins count as nothing.
    var totalUSD: Double? {
        guard hasWallet, loaded, unreachable.allSatisfy(\.isTestnet) else { return nil }
        let main = holdings.filter { !$0.chain.isTestnet && $0.amount > 0 }
        guard main.allSatisfy(\.priced) else { return nil }
        return main.reduce(0) { $0 + $1.usd }
    }

    /// Reloads balances for every wallet on every network, plus prices. Safe to call often: runs one at a time.
    func refresh() async {
        if let t = refreshTask { await t.value; return }
        let t = Task { await load() }
        refreshTask = t
        await t.value
        refreshTask = nil
    }

    private func load() async {
        reloadLocal()
        guard hasWallet else { holdings = []; loaded = true; return }
        refreshing = true
        defer { refreshing = false }
        async let quotes = PriceFeed.shared.quotes()
        var hs: [Holding] = [], failed = Set<Chain>()
        for w in wallets {
            let r = await service.fetchBalances(for: w.record, chains: Chain.all)
            failed.formUnion(r.failed)
            for (_, bs) in r.balances { hs += bs.map { holding($0, wallet: w.id) } }
            // Keep the last known numbers for a network that didn't answer this time.
            for c in r.failed { hs += holdings.filter { $0.walletID == w.id && $0.chain == c } }
        }
        let q = await quotes
        withAnimation(.smooth) {
            prices = q
            holdings = hs.map { h in var h = h; applyPrice(&h); return h }
            unreachable = Chain.all.filter { failed.contains($0) }
            loaded = true
            lastUpdated = Date()
        }
    }

    private func holding(_ b: Balance, wallet: String) -> Holding {
        let exact = Units.format(b.amount, decimals: b.decimals)
        return Holding(walletID: wallet, chain: b.chain, symbol: b.symbol, name: b.token?.name ?? b.chain.name,
                       exact: exact, amount: Double(exact) ?? 0, price: nil, change: nil)
    }

    private func applyPrice(_ h: inout Holding) {
        guard !h.chain.isTestnet, let q = prices[h.symbol] else { h.price = nil; h.change = nil; return }
        h.price = q.usd; h.change = q.change24h
    }

    /// Wallets, saved addresses and the send log: all local, no network.
    func reloadLocal() {
        wallets = service.wallets.map(WalletAccount.init(record:))
        let ids = Set(wallets.map(\.id))
        activity = service.sendLog.entries.compactMap { e in e.chain.map { ActivityItem(entry: e, chain: $0) } }.filter { ids.contains($0.walletID) }
        whitelist = service.addressBook.entries.compactMap { e in
            e.label.map { SavedAddress(label: $0, address: e.address, kind: e.chainKind, added: e.added, payments: e.payments) }
        }
        holdings.removeAll { !ids.contains($0.walletID) }
    }

    // MARK: Reading

    func wallet(_ id: String?) -> WalletAccount? { wallets.first { $0.id == id } }
    var firstWalletID: String? { wallets.first?.id }

    /// Mainnet dollars for one wallet or all of them.
    func total(_ walletID: String? = nil) -> Double {
        holdings.filter { walletID == nil || $0.walletID == walletID }.reduce(0) { $0 + $1.usd }
    }
    func holdings(wallet: String?, chain: Chain?) -> [Holding] {
        holdings.filter { (wallet == nil || $0.walletID == wallet) && (chain == nil || $0.chain == chain) && $0.amount > 0 }
    }
    /// Tokens rows. With a chain picked, one row per token on that chain; otherwise one row per token across chains
    /// (mainnet and testnet kept apart).
    func tokenGroups(wallet: String?, chain: Chain?) -> [TokenGroup] {
        let hs = holdings(wallet: wallet, chain: chain)
        let groups = Dictionary(grouping: hs) { "\($0.symbol)|\($0.chain.isTestnet)" }.map { _, parts in
            TokenGroup(symbol: parts[0].symbol, name: parts[0].name, chain: chain, testnet: parts[0].chain.isTestnet, parts: parts)
        }
        return groups.sorted { ($0.testnet ? 1 : 0, -$0.usd, $0.symbol) < ($1.testnet ? 1 : 0, -$1.usd, $1.symbol) }
    }
    func holding(_ token: String, wallet: String, chain: Chain) -> Holding? {
        holdings.first { $0.walletID == wallet && $0.chain == chain && $0.symbol == token }
    }
    func balance(of token: String, wallet: String, chain: Chain) -> Double { holding(token, wallet: wallet, chain: chain)?.amount ?? 0 }
    func activity(wallet: String?, chain: Chain?) -> [ActivityItem] {
        activity.filter { (wallet == nil || $0.walletID == wallet) && (chain == nil || $0.chain == chain) }
    }
    /// Gas (native coin) per network for one wallet or all.
    func gas(wallet: String?) -> [GasTank] {
        Chain.all.map { c in
            let hs = holdings.filter { (wallet == nil || $0.walletID == wallet) && $0.chain == c && $0.symbol == c.nativeSymbol }
            let amt = hs.reduce(0) { $0 + $1.amount }
            return GasTank(chain: c, amount: amt, usd: hs.allSatisfy(\.priced) && !hs.isEmpty ? hs.reduce(0) { $0 + $1.usd } : nil)
        }
    }
    /// Tokens the engine can send on a chain: the native coin and the stablecoins it knows the contracts of.
    func tokens(chain: Chain) -> [String] { [chain.nativeSymbol] + chain.tokens.map(\.symbol) }
    func price(_ token: String) -> Double? { prices[token]?.usd }
    func saved(_ address: String) -> SavedAddress? {
        let a = address.trimmingCharacters(in: .whitespaces)
        return whitelist.first { $0.kind == .evm ? $0.address.caseInsensitiveCompare(a) == .orderedSame : $0.address == a }
    }
    /// Your own wallet that owns this address, if any.
    func ownWallet(for address: String) -> WalletAccount? {
        wallets.first { $0.evmAddress?.caseInsensitiveCompare(address) == .orderedSame || $0.solanaAddress == address }
    }

    // MARK: Wallets

    /// Creates a wallet and returns its recovery phrase words, to show once.
    func createWallet(name: String) throws -> (WalletAccount, [String]) {
        let r = try service.createWalletWithPhrase(name: name)
        reloadLocal()
        Task { await refresh() }
        return (WalletAccount(record: r.record), r.phrase.split(separator: " ").map(String.init))
    }

    func importWallet(words: [String], name: String) throws -> WalletAccount {
        let r = try service.importWallet(phrase: words.joined(separator: " "), name: name)
        reloadLocal()
        Task { await refresh() }
        return WalletAccount(record: r)
    }

    /// Asks for Touch ID / Face ID, then returns the words.
    func recoveryPhrase(_ id: String) async throws -> [String] {
        guard let u = UUID(uuidString: id) else { return [] }
        return try await service.exportPhrase(u).split(separator: " ").map(String.init)
    }

    func markBackedUp(_ id: String) {
        guard let u = UUID(uuidString: id) else { return }
        try? service.markBackedUp(u)
        reloadLocal()
    }

    func deleteWallet(_ id: String) throws {
        guard let u = UUID(uuidString: id) else { return }
        try service.deleteWallet(u)
        withAnimation(.smooth) { reloadLocal() }
    }

    func addAddress(label: String, address: String, kind: ChainKind) {
        service.addressBook.setLabel(label, for: address, kind: kind)
        withAnimation(.smooth) { reloadLocal() }
    }

    func removeAddress(_ s: SavedAddress) {
        service.addressBook.remove(s.address, kind: s.kind)
        withAnimation(.smooth) { reloadLocal() }
    }

    // MARK: Sends

    /// Simulates and checks a send (no signing). Throws for mainnet while sends are testnet-only.
    func prepareSend(from walletID: String, chain: Chain, to: String, amount: String, token: String) async throws -> PreparedSend {
        guard let u = UUID(uuidString: walletID) else { throw WalletError.vault("Pick a wallet.") }
        service.selectedWalletID = u
        return try await service.prepareSend(chain: chain, to: to.trimmingCharacters(in: .whitespacesAndNewlines), amount: amount, token: token)
    }

    /// The approval sheet for a prepared send. Approve unlocks the key (Touch ID / Face ID), signs, sends and waits.
    func approval(for p: PreparedSend) throws -> Approval {
        guard p.canSend else { throw WalletError.blocked(p.blockingReason ?? "Blocked by the hazard scan.") }
        let svc = service, vm = self
        let from = wallets.first { $0.record.id == p.walletID }?.name ?? "Wallet"
        let own = ownWallet(for: p.recipient)
        var lines = p.lines
        lines.insert(["From", from], at: 0)
        if let own, let i = lines.firstIndex(where: { $0.first == "To" }) { lines[i] = ["To", "\(own.name) (\(shortAddr(p.recipient)))"] }
        let checks = p.checks.map { $0.status == .warn ? "\($0.title): \($0.detail)" : $0.title }
        return Approval(kind: own != nil ? "Transfer between your wallets" : "Send on \(p.chain.name)",
                        title: "Send \(p.amountText) \(p.symbol)", lines: lines, checks: checks,
                        success: "Sent \(p.amountText) \(p.symbol)",
                        perform: {
                            let r = try await svc.execute(p)
                            await vm.afterSend()
                            return r.hash
                        })
    }

    func afterSend() async {
        reloadLocal()
        await refresh()
    }
}

/// Turns a typed amount into the exact decimal string the engine parses ("1,000.50" -> "1000.50").
enum AmountText {
    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
    }
    static func value(_ s: String) -> Double? { Double(clean(s)) }
}
