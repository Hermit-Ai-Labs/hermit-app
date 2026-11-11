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
    static let shared = WalletsViewModel(service: WalletService(vault: WalletsViewModel.runningTests || testWallet ? KeyVault(store: HermitWallet.MemoryStore()) : .makeDefault()))

    /// Simulator screenshots only (scripts): `-hermitTestWallet YES` uses a memory-only vault holding the public BIP-39
    /// test phrase, so wallet screens have real, public addresses. Never in a release build; never touches the real vault.
    nonisolated static var testWallet: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "hermitTestWallet")
        #else
        false
        #endif
    }

    /// Tests and snapshots never touch the real vault.
    nonisolated static var runningTests: Bool { NSClassFromString("XCTestCase") != nil }

    let service: WalletService
    private(set) var wallets: [WalletAccount] = []
    private(set) var holdings: [Holding] = []
    private(set) var whitelist: [SavedAddress] = []
    private(set) var prices: [String: PriceQuote] = [:]
    private(set) var refreshing = false
    private(set) var loaded = false
    private(set) var lastUpdated: Date?
    /// The price feeds have been failing: the prices shown were fetched at `pricesAt` (over 5 min ago). Prices older
    /// than 15 min aren't served at all.
    private(set) var pricesStale = false
    private(set) var pricesAt: Date?
    /// Networks that didn't answer on the last refresh (their balances are unknown, not zero).
    private(set) var unreachable: [Chain] = []
    var whitelistOnly: Bool {
        didSet { UserDefaults.standard.set(whitelistOnly, forKey: "hermit.wallet.whitelistOnly") }
    }
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAgain = false

    init(service: WalletService) {
        self.service = service
        tools = WalletTools(service: service)
        whitelistOnly = UserDefaults.standard.bool(forKey: "hermit.wallet.whitelistOnly")
        #if DEBUG
        // Simulator screenshots only (scripts/phone-shots.sh): `-hermitTestWallet YES` imports the public BIP-39 test phrase
        // ("abandon … about") so wallet screens have real, public addresses to show. Never in a release build.
        if Self.testWallet, service.wallets.isEmpty, !Self.runningTests {
            _ = try? service.importWallet(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", name: "Test wallet")
        }
        #endif
        reloadLocal()
    }

    // MARK: Home API

    var hasWallet: Bool { !wallets.isEmpty }
    /// Anything on a mainnet worth swapping or bridging. Swap and Bridge stay hidden until there is.
    var hasFunds: Bool { holdings.contains { !$0.chain.isTestnet && $0.amount > 0 } }

    /// Set by Payments (Transfer, Pay now) just before opening Send, which reads it once.
    /// `onSent` runs once the send it opens was approved and went through (Payments marks a payment paid with it).
    struct SendPrefill {
        var address: String; var amount: String; var token: String?; var chain: Chain? = nil; var label: String? = nil
        var onSent: (@MainActor (_ to: String, _ amount: String, _ token: String) -> Void)? = nil
        /// When it was set. Send ignores one older than a minute, so a stale payee never fills a later Send.
        var made = Date()
    }
    @ObservationIgnored var sendPrefill: SendPrefill?
    /// A swap the assistant prepared (WalletTools.prepare_swap), waiting for Wallets to open its review.
    @ObservationIgnored var pendingSwap: SwapIntent?
    /// A tab for the one-wallet view to open on ("security"), read once.
    @ObservationIgnored var openTab: String?
    /// The wallet tools the on-device model calls (get_balances, get_quote, prepare_swap). The app sets `presentSwap`.
    let tools: WalletTools

    /// Dollar value of every wallet's mainnet coins. nil when it isn't known: no wallet, balances not loaded yet,
    /// a network didn't answer, or there is no price for something held. Testnet coins count as nothing.
    var totalUSD: Double? {
        guard hasWallet, loaded, unreachable.allSatisfy(\.isTestnet) else { return nil }
        let main = holdings.filter { !$0.chain.isTestnet && $0.amount > 0 }
        guard main.allSatisfy(\.priced) else { return nil }
        return main.reduce(0) { $0 + $1.usd } + extrasUSD(nil)
    }

    // MARK: Money that isn't a coin sitting in the wallet

    /// Aave deposits in dollars, by wallet id (read with the balances).
    private(set) var aaveUSD: [String: Double] = [:]
    /// The Hyperliquid account value, counted for the wallet Trade uses.
    private func hyperliquidUSD(_ walletID: String?) -> Double {
        let hl = HyperliquidStore.shared
        guard let v = hl.account?.accountValue, v > 0, let w = hl.wallet?.id, walletID == nil || walletID == w else { return 0 }
        return v
    }
    /// Hyperliquid plus Aave, for one wallet or all of them.
    func extrasUSD(_ walletID: String?) -> Double {
        hyperliquidUSD(walletID) + aaveUSD.filter { walletID == nil || $0.key == walletID }.values.reduce(0, +)
    }
    /// "Includes $6.00 on Hyperliquid and $1.00 in Aave", or nil when there's nothing beyond the coins.
    func extrasLine(_ walletID: String?) -> String? {
        var parts: [String] = []
        let h = hyperliquidUSD(walletID), a = aaveUSD.filter { walletID == nil || $0.key == walletID }.values.reduce(0, +)
        if h > 0 { parts.append("\(MoneyFmt.usd(h, digits: 2)) on Hyperliquid") }
        if a > 0 { parts.append("\(MoneyFmt.usd(a, digits: 2)) in Aave") }
        return parts.isEmpty ? nil : "Includes " + parts.joined(separator: " and ")
    }

    /// Reloads balances for every wallet on every network, plus prices. Safe to call often: runs one at a time.
    /// A call that lands while a load is running gets one more pass after it, so a send or a new wallet made
    /// mid-load still shows (the running pass read wallets and balances before it).
    func refresh() async {
        if let t = refreshTask { needsAgain = true; await t.value; return }
        let t = Task {
            repeat {
                needsAgain = false
                await load()
            } while needsAgain
        }
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
        async let aave = service.aavePositions(wallets: wallets.map(\.record))
        async let hlDone: () = HyperliquidStore.shared.refresh()
        var hs: [Holding] = [], failed = Set<Chain>()
        for w in wallets {
            let r = await service.fetchBalances(for: w.record, chains: Chain.all)
            failed.formUnion(r.failed)
            for (_, bs) in r.balances { hs += bs.map { holding($0, wallet: w.id) } }
            // Keep the last known numbers for a network that didn't answer this time.
            for c in r.failed { hs += holdings.filter { $0.walletID == w.id && $0.chain == c } }
        }
        let q = await quotes
        let stale = await PriceFeed.shared.stale
        let fetchedAt = await PriceFeed.shared.updated
        let positions = await aave
        _ = await hlDone
        var byWallet: [String: Double] = [:]
        for p in positions.positions {
            let amount = Double(p.text) ?? 0
            let price = q[p.token.symbol]?.usd ?? (["USDC", "USDT", "DAI", "USDC.e", "USDS"].contains(p.token.symbol) ? 1 : 0)
            byWallet[p.walletID.uuidString, default: 0] += amount * price
        }
        withAnimation(.smooth) {
            aaveUSD = byWallet
            prices = q
            pricesStale = stale
            pricesAt = fetchedAt
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
        holdings.filter { walletID == nil || $0.walletID == walletID }.reduce(0) { $0 + $1.usd } + extrasUSD(walletID)
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
        wallets.first { $0.evmAddress?.caseInsensitiveCompare(address) == .orderedSame || $0.solanaAddress == address
            || ($0.record.nearAccount != nil && $0.record.nearAccount == address.lowercased()) }
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
        DappPermissions.shared.disconnect(walletID: u)
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
        // From this wallet, without changing which wallet is selected (chat's tools read the selected one).
        let native = token.caseInsensitiveCompare(chain.nativeSymbol) == .orderedSame
        let tok: Token? = native ? nil : chain.token(token)
        guard native || tok != nil else { throw WalletError.unknownToken }
        // Sheets pass text AmountText already cleaned; the assistant writes English numbers. Either way a comma never
        // just disappears ("1,5" is refused, not read as 15).
        guard let typed = AmountText.normalize(amount, decimalSeparator: "."), !typed.isEmpty else { throw WalletError.invalidAmount(amount) }
        let value = try Units.parse(typed, decimals: tok?.decimals ?? chain.nativeDecimals)
        let dest = to.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whitelist only covers every send, the assistant's included, not just the Send sheet.
        if let reason = whitelistBlock(dest) { throw WalletError.blocked(reason) }
        return try await service.prepareSend(walletID: u, chain: chain, to: dest, value: value, token: tok)
    }

    /// Why Whitelist only stops a send to this address, or nil when it may go: your own wallets, and saved addresses
    /// past their 24-hour hold.
    func whitelistBlock(_ address: String) -> String? {
        guard whitelistOnly, ownWallet(for: address) == nil else { return nil }
        guard let s = saved(address) else { return "Whitelist only is on and this address isn't saved. Save it first, or turn off Whitelist only." }
        return s.hold ? "\(s.label) unlocks 24 hours after it was saved. Whitelist only is on." : nil
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
        // Only passed checks get a tick; a warning shows as a warning above Approve, never as a passed check.
        let checks = p.checks.filter { $0.status == .pass }.map(\.title)
        let warnings = p.checks.filter { $0.status == .warn }.map { "\($0.title): \($0.detail)" }
        return Approval(kind: own != nil ? "Transfer between your wallets" : "Send on \(p.chain.name)",
                        title: "Send \(p.amountText) \(p.symbol)", lines: lines, checks: checks,
                        success: "Sent \(p.amountText) \(p.symbol)", warnings: warnings,
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

/// Turns a typed amount into the exact decimal string the engine parses ("1,000.50" -> "1000.50", and "1,5" -> "1.5"
/// where the region writes a comma for decimals). A comma is never just dropped, so a number can't grow ten or a
/// thousand times: it is the decimal mark where the region says so, a thousands mark only in a clear "1,234" shape,
/// and anything else is refused.
enum AmountText {
    /// ASCII digits and at most one ".", "" for blank text, or nil when the text isn't a clear amount.
    /// `decimalSeparator` is the region's decimal mark ("," in France, Germany, Brazil; "." in the US).
    static func normalize(_ raw: String, decimalSeparator: String? = Locale.current.decimalSeparator) -> String? {
        var s = ""
        for ch in raw {
            if ch.isWhitespace { continue }
            if ch == "." || ch == "," || (ch.isASCII && ch.isNumber) { s.append(ch); continue }
            // Digits from an Arabic or Devanagari keyboard.
            if let d = ch.wholeNumberValue, ch.unicodeScalars.count == 1,
               ch.unicodeScalars.first?.properties.numericType == .decimal { s += String(d); continue }
            return nil
        }
        if s.isEmpty { return "" }
        let commaIsDecimal = decimalSeparator == ","
        let commas = s.filter { $0 == "," }.count, dots = s.filter { $0 == "." }.count
        var decimal: Character?, group: Character?
        if commas == 0 && dots == 0 {
            return s
        } else if commas > 0 && dots > 0 {
            // Both: the last one is the decimal mark ("1,234.56", "1.234,56"), the other only groups thousands.
            guard let c = s.lastIndex(of: ","), let d = s.lastIndex(of: ".") else { return nil }
            decimal = c > d ? "," : "."
            group = c > d ? "." : ","
        } else if dots > 0 {
            // A lone "." is a decimal point (the app writes amounts that way too). Repeated, it can only group
            // thousands, and only where the region groups with "." ("1.000.000" in Germany).
            if dots == 1 { decimal = "." } else if commaIsDecimal { group = "." } else { return nil }
        } else {
            // A lone "," is the decimal mark where the region says so. Otherwise it must group thousands, which the
            // shape check below enforces: "1,000" is a thousand, "1,5" is refused.
            if commas == 1 && commaIsDecimal { decimal = "," } else if !commaIsDecimal { group = "," } else { return nil }
        }
        var whole = Substring(s), frac: Substring?
        if let decimal {
            let parts = s.split(separator: decimal, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            whole = parts[0]; frac = parts[1]
        }
        if let group {
            let groups = whole.split(separator: group, omittingEmptySubsequences: false)
            guard groups.count >= 2, (1...3).contains(groups[0].count), groups[0].first != "0",
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            whole = Substring(groups.joined())
        }
        return frac.map { "\(whole).\($0)" } ?? String(whole)
    }

    /// What the engine parses: "" (which it rejects) when the text isn't a clear amount.
    static func clean(_ s: String) -> String { normalize(s) ?? "" }
    /// Strict, like Trade's: "inf", "nan", "1e3", "0x10" and unclear commas are nil (Double() takes some of them).
    static func value(_ s: String) -> Double? { normalize(s).flatMap { TradeAmount.value($0) } }
}
