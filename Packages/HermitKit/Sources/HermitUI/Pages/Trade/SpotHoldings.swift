import SwiftUI
import Observation
import HermitCore
import HermitWallet

// What the wallet holds on Solana, beyond SOL: every SPL token (classic and Token-2022), named and priced by Jupiter,
// with the cost Hermit recorded when it bought, so each one shows its value and P&L. Spot, Memes and Trade > Positions
// read it; TradeBuy writes to the cost book when a buy or sell goes through.

// MARK: Cost book

/// One buy or sell Hermit made on Solana.
struct SpotTrade: Codable, Hashable, Sendable {
    let walletID: String
    let mint: String
    let symbol: String
    /// Tokens bought or sold, in base units (exact), as text.
    let tokens: String
    let decimals: Int
    /// Dollars paid for a buy, or brought in by a sell (USDC as is, SOL at its price then).
    let usd: Double
    let sell: Bool
    let date: Date
    let tx: String
}

/// Hermit's record of what it paid for each Solana token, on this device (Application Support/Hermit/spot-book.json).
/// Average cost: a buy adds its tokens and dollars; a sell takes away the same share of the cost as of the tokens.
@MainActor
final class SpotBook {
    static let shared = SpotBook()
    private let file = "spot-book.json"
    private(set) var trades: [SpotTrade] = []

    private init() { trades = LocalJSON.load(file, as: [SpotTrade].self) ?? [] }

    func record(_ t: SpotTrade) {
        guard !trades.contains(where: { $0.tx == t.tx && $0.mint == t.mint }) else { return }
        trades.append(t)
        trades = Array(trades.suffix(2000))
        LocalJSON.save(trades, file)
    }

    struct Basis: Equatable {
        /// Tokens the book still counts as held, and what they cost in all.
        let tokens: Double
        let cost: Double
        var average: Double { tokens > 0 ? cost / tokens : 0 }
    }

    func basis(mint: String, walletID: String) -> Basis? {
        var qty = 0.0, cost = 0.0
        for t in trades.filter({ $0.mint == mint && $0.walletID == walletID }).sorted(by: { $0.date < $1.date }) {
            let n = Double(Units.format(UInt128(t.tokens) ?? 0, decimals: t.decimals)) ?? 0
            guard n > 0 else { continue }
            if t.sell {
                guard qty > 0 else { continue }
                let out = min(n, qty)
                cost -= cost * out / qty
                qty -= out
            } else {
                qty += n
                cost += t.usd
            }
        }
        return qty > 0 ? Basis(tokens: qty, cost: max(0, cost)) : nil
    }
}

// MARK: Holdings

@MainActor @Observable
final class SolanaHoldings {
    static let shared = SolanaHoldings()

    struct Holding: Identifiable, Hashable, Sendable {
        let id: String            // mint
        let symbol: String
        let name: String
        let decimals: Int
        let icon: String?
        /// Every account the wallet has for this mint, summed, in base units.
        let amount: UInt128
        let price: Double?
        let verified: Bool
        /// One of its accounts is frozen by the token's issuer: it can't be sold.
        let frozen: Bool
        var tokens: Double { Double(Units.format(amount, decimals: decimals)) ?? 0 }
        var value: Double? { price.map { $0 * tokens } }
        var amountText: String { MoneyFmt.amount(tokens) }
        var token: Jupiter.Token { Jupiter.Token(mint: id, symbol: symbol, name: name, decimals: decimals, verified: verified) }
    }

    /// Cost and P&L for one holding. `cost` and `pnl` are nil when some of it didn't come through Hermit (sent in, or
    /// bought elsewhere), so the book can't say what all of it cost; `average` is still what Hermit's own buys cost.
    struct Position: Equatable {
        let average: Double?
        let cost: Double?
        let pnl: Double?
        let pct: Double?
    }

    /// A buy or sell that just went through: what the swap box's success moment shows.
    struct Done: Equatable, Identifiable {
        let id = UUID()
        let mint: String
        let symbol: String
        /// What came in, in `gotSymbol`: the token for a buy, USDC or SOL for a sell.
        let got: Double
        let gotSymbol: String
        let sell: Bool
        /// The second line: "≈ $10.00 in USDC", "Sold 223.08 PUMP".
        let detail: String
        let date = Date()
    }

    /// Name, symbol and logo for a mint, from Jupiter. Kept on disk; `found: false` is a mint Jupiter didn't know, asked
    /// again after a day.
    struct Meta: Codable, Sendable {
        let symbol: String
        let name: String
        let icon: String?
        let verified: Bool
        let found: Bool
        let checked: Date
    }

    private(set) var items: [Holding] = []
    private(set) var state: FeedState = .loading
    private(set) var updated: Date?
    /// The last refresh failed, so what shows is older than it looks.
    private(set) var lastFailed = false
    /// Prices couldn't be read on the last refresh; the ones shown are from the refresh before.
    private(set) var pricesOld = false
    private(set) var lastDone: Done?
    /// Goes up when the cost book changes, so P&L is worked out again.
    private(set) var bookVersion = 0
    /// Full Jupiter rows for held tokens that aren't on the verified list, so Spot can open them.
    private(set) var rows: [String: JupiterTokens.Row] = [:]
    @ObservationIgnored private var meta: [String: Meta] = MarketDiskCache.load(SolanaHoldings.metaName, maxAge: 30 * 86_400, as: [String: Meta].self) ?? [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var last = Date.distantPast
    @ObservationIgnored private var owner = ""
    nonisolated private static let metaName = "spot-meta"

    private var wallet: WalletAccount? { WalletsViewModel.shared.wallets.first }
    var hasWallet: Bool { !(wallet?.record.solanaAddress ?? "").isEmpty }

    func holding(_ mint: String) -> Holding? { items.first { $0.id == mint } }

    /// Holdings with a price, by value, then the ones without.
    var priced: [Holding] { items.filter { $0.value != nil } }
    var unpriced: [Holding] { items.filter { $0.value == nil } }
    var totalValue: Double { items.compactMap(\.value).reduce(0, +) }

    func position(_ h: Holding) -> Position? {
        _ = bookVersion
        guard let w = wallet, let b = SpotBook.shared.basis(mint: h.id, walletID: w.id) else { return nil }
        let avg = b.average
        // The book covers what's held (2% slack for rounding and fees): its average cost is the cost of all of it.
        guard b.tokens >= h.tokens * 0.98, let value = h.value else { return Position(average: avg, cost: nil, pnl: nil, pct: nil) }
        let cost = avg * h.tokens
        let pnl = value - cost
        return Position(average: avg, cost: cost, pnl: pnl, pct: cost > 0 ? pnl / cost * 100 : nil)
    }

    /// Reads at most every 10 seconds unless forced, and never two reads at once: a caller that arrives during one
    /// waits for it.
    func refresh(force: Bool = false) async {
        if let t = task {
            await t.value
            if !force { return }
        }
        while let t = task { await t.value }
        guard force || Date().timeIntervalSince(last) > 10 else { return }
        let t = Task { await self.load(); self.task = nil }
        task = t
        await t.value
    }

    /// A buy or sell went through: into the book, the success moment, and a fresh read of the balances (again a few
    /// seconds later, for a node that's a little behind).
    func finished(_ trade: SpotTrade?, done: Done) {
        if let trade { SpotBook.shared.record(trade); bookVersion += 1 }
        lastDone = done
        Task {
            await refresh(force: true)
            try? await Task.sleep(for: .seconds(4))
            await refresh(force: true)
        }
    }

    private func load() async {
        let me = wallet?.record.solanaAddress ?? ""
        guard !me.isEmpty, !SnapshotMode.active else { items = []; rows = [:]; owner = me; state = .ready; return }
        if me != owner { items = []; rows = [:]; state = .loading; owner = me }
        do {
            let raw = try await Self.readAccounts(owner: me)
            let mints = raw.keys.sorted()
            await fillMeta(mints)
            let prices = await Self.prices(mints)
            guard (wallet?.record.solanaAddress ?? "") == me else { return }
            let listed = Dictionary(JupiterTokens.shared.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let before = Dictionary(items.map { ($0.id, $0.price) }, uniquingKeysWith: { a, _ in a })
            let built: [Holding] = mints.compactMap { m in
                guard let r = raw[m] else { return nil }
                let l = listed[m], md = meta[m]
                // A failed price read keeps the last price Hermit had; a token Jupiter has no price for shows none.
                let price: Double?
                if let prices { price = prices[m] ?? l?.price } else { price = (before[m] ?? nil) ?? l?.price }
                return Holding(id: m, symbol: l?.symbol ?? md?.symbol ?? String(m.prefix(4)) + "…", name: l?.name ?? md?.name ?? "Unknown token",
                               decimals: r.decimals, icon: l?.icon ?? md?.icon, amount: r.amount, price: price.flatMap { $0 > 0 ? $0 : nil },
                               verified: l != nil || md?.verified == true, frozen: r.frozen)
            }
            let sorted = built.sorted { a, b in
                switch (a.value, b.value) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.symbol < b.symbol
                }
            }
            withAnimation(.smooth) { items = sorted; state = .ready }
            pricesOld = prices == nil && !mints.isEmpty
            updated = Date(); lastFailed = false
        } catch {
            lastFailed = true
            if items.isEmpty { state = .failed }
        }
        last = Date()
    }

    /// Names and logos for mints Hermit hasn't seen: the verified list when it has them, else Jupiter's search, 40
    /// mints a call, at most 120 per refresh (a wallet full of airdropped spam fills in over a few refreshes).
    private func fillMeta(_ mints: [String]) async {
        let listed = Set(JupiterTokens.shared.rows.map(\.id))
        let unknown = mints.filter { m in
            guard !listed.contains(m) else { return false }
            guard let md = meta[m] else { return true }
            return (!md.found && Date().timeIntervalSince(md.checked) > 86_400) || (md.found && !md.verified && rows[m] == nil && Date().timeIntervalSince(md.checked) > 600)
        }
        guard !unknown.isEmpty else { return }
        var changed = false
        for start in stride(from: 0, to: min(unknown.count, 120), by: 40) {
            let chunk = Array(unknown[start..<min(start + 40, unknown.count, 120)])
            guard let found = try? await JupiterTokens.search(chunk.joined(separator: ",")) else { break }
            for f in found where chunk.contains(f.id) {
                meta[f.id] = Meta(symbol: f.symbol, name: f.name, icon: f.icon, verified: f.verified, found: true, checked: Date())
                if let r = f.row { rows[f.id] = r }
            }
            for m in chunk where !found.contains(where: { $0.id == m }) {
                meta[m] = Meta(symbol: String(m.prefix(4)) + "…", name: "Unknown token", icon: nil, verified: false, found: false, checked: Date())
            }
            changed = true
        }
        if changed { MarketDiskCache.save(Self.metaName, meta) }
    }

    // MARK: Reading the chain

    struct Account: Sendable {
        var amount: UInt128
        let decimals: Int
        var frozen: Bool
    }

    /// Every token account the owner has, under both token programs (two calls in all), summed per mint. Zero balances
    /// and wrapped SOL (that's SOL, shown with the wallet's SOL) are left out.
    nonisolated static func readAccounts(owner: String) async throws -> [String: Account] {
        let rpc = JSONRPCClient(url: Chain.solana.rpc)
        func accounts(_ program: String) async throws -> [JSON] {
            try await rpc.call("getTokenAccountsByOwner", [.string(owner), ["programId": .string(program)],
                                                           ["encoding": "jsonParsed", "commitment": "confirmed"]])["value"]?.array ?? []
        }
        async let classic = accounts(SolanaPrograms.token)
        async let token2022 = accounts(SolanaPrograms.token2022)
        let all = try await classic + token2022
        var out: [String: Account] = [:]
        for acc in all {
            guard let info = acc["account"]?["data"]?["parsed"]?["info"], let mint = info["mint"]?.string,
                  info["isNative"]?.bool != true, mint != SolanaPrograms.wsol,
                  let s = info["tokenAmount"]?["amount"]?.string, let v = UInt128(s), v > 0,
                  let dec = info["tokenAmount"]?["decimals"]?.int else { continue }
            let frozen = info["state"]?.string == "frozen"
            if var a = out[mint] { a.amount += v; a.frozen = a.frozen || frozen; out[mint] = a }
            else { out[mint] = Account(amount: v, decimals: dec, frozen: frozen) }
        }
        return out
    }

    /// Dollar prices from Jupiter's price API, 50 mints a call. nil when no call got through.
    nonisolated static func prices(_ mints: [String]) async -> [String: Double]? {
        guard !mints.isEmpty else { return [:] }
        var out: [String: Double] = [:], ok = false
        for start in stride(from: 0, to: mints.count, by: 50) {
            let ids = mints[start..<min(start + 50, mints.count)].joined(separator: ",")
            guard let d = try? await MarketHTTP.data("https://lite-api.jup.ag/price/v3?ids=\(ids)"),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            ok = true
            for (k, v) in j { if let p = (v as? [String: Any])?["usdPrice"] as? Double, p > 0 { out[k] = p } }
        }
        return ok ? out : nil
    }

    /// The owner's balance of one mint (every account), in base units. nil when the node didn't answer.
    nonisolated static func balance(owner: String, mint: String) async -> UInt128? {
        guard let o = SolanaPublicKey(owner), let m = SolanaPublicKey(mint) else { return nil }
        return try? await SolanaClient(url: Chain.solana.rpc).tokenBalance(owner: o, mint: m)
    }

    /// What a confirmed swap added to the owner's balance of `mint`, compared with `before`. Read up to three times
    /// (a node can be a moment behind); nil when it couldn't be measured.
    nonisolated static func received(owner: String, mint: String, before: UInt128?) async -> UInt128? {
        guard let before else { return nil }
        for i in 0..<3 {
            if i > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            if let now = await balance(owner: owner, mint: mint), now > before { return now - before }
        }
        return nil
    }
}

// MARK: The success moment

/// A buy or sell went through: a green ring draws itself, the check pops in, "+223.08 PUMP" counts up, with the coin
/// sound (as when money arrives on Receive). Reduce Motion shows it all at once.
struct SpotDoneView: View {
    let done: SolanaHoldings.Done
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var check = false
    @State private var shown = 0.0

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.green.opacity(0.10)).frame(width: 96, height: 96).scaleEffect(check ? 1 : 0.6).opacity(check ? 1 : 0)
                Circle().trim(from: 0, to: ring).stroke(Theme.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 72, height: 72)
                Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.green)
                    .scaleEffect(check ? 1 : 0.2).opacity(check ? 1 : 0)
            }
            .frame(height: 100)
            VStack(spacing: 4) {
                Text("+\(MoneyFmt.amount(shown)) \(done.gotSymbol)")
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText(value: shown))
                Text(done.detail).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done.sell ? "Sold" : "Bought"). Plus \(MoneyFmt.amount(done.got)) \(done.gotSymbol)")
        .task {
            CoinSound.play()
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #elseif os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            #endif
            if reduceMotion || SnapshotMode.active { ring = 1; check = true; shown = done.got; return }
            withAnimation(.smooth(duration: 0.45)) { ring = 1 }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.bouncy) { check = true }
            // Count up in 10 steps over about half a second.
            for i in 1...10 {
                try? await Task.sleep(for: .milliseconds(45))
                withAnimation(.snappy(duration: 0.12)) { shown = done.got * Double(i) / 10 }
            }
        }
    }
}

// MARK: Trade > Positions

/// Every Solana token the wallet holds, for Trade > Positions (under its "Solana tokens" heading): logo, name, amount,
/// value and P&L, priced ones first. A tap opens the detail sheet (amount, value, cost, P&L, Sell 25/50/100%, Solscan).
struct SpotHoldingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var open: SolanaHoldings.Holding? = nil
    @State private var showUnpriced = false
    private var store: SolanaHoldings { .shared }

    init() {}

    var body: some View {
        // Trade > Positions puts this under its own "Solana tokens" heading, so it has none of its own.
        VStack(alignment: .leading, spacing: 0) {
            if !store.hasWallet {
                MarketStatus(kind: .empty("Create a wallet to hold Solana tokens."))
            } else if store.items.isEmpty {
                switch store.state {
                case .loading: MarketStatus(kind: .loading("Reading your Solana tokens"))
                case .failed: MarketStatus(kind: .failed("Couldn't reach Solana")) { Task { await store.refresh(force: true) } }
                case .ready: TradeEmpty(icon: "circle.hexagongrid", title: "No Solana tokens", note: "Buy one on Spot or Memes. It shows here with its value and P&L.")
                }
            } else {
                HStack(spacing: 8) {
                    Text("Worth").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    Text(MoneyFmt.usd(store.totalValue, digits: 2)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Button { Task { await store.refresh(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle()).accessibilityLabel("Refresh Solana tokens")
                }
                .padding(.bottom, 2)
            }
            TradeRows(data: store.priced) { h in row(h) }
            let rest = store.unpriced
            if !rest.isEmpty {
                Button {
                    withAnimation(.smooth) { showUnpriced.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showUnpriced ? "Hide tokens with no price" : "\(rest.count) more with no price")
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(showUnpriced ? 180 : 0))
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showUnpriced { TradeRows(data: rest) { h in row(h) }.transition(.opacity) }
            }
            if store.hasWallet && !store.items.isEmpty {
                MarketSource(text: "Balances from Solana, prices from Jupiter. P&L counts what you bought in Hermit."
                             + (store.lastFailed ? " Couldn't refresh just now." : store.pricesOld ? " Couldn't refresh prices just now." : ""))
                    .padding(.top, 8)
            }
        }
        .marketPoll(every: 30) { await store.refresh() }
        .sheet(item: $open) { h in SpotHoldingSheet(mint: h.id, fallback: h).environment(model).tint(Theme.text) }
    }

    private func row(_ h: SolanaHoldings.Holding) -> some View {
        let p = store.position(h)
        return Button { open = h } label: {
            HStack(spacing: 12) {
                MarketLogo(key: TradeData.logo(mint: h.id), name: h.symbol, size: 32, remote: h.icon.flatMap(URL.init))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(h.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        if !h.verified { SpotTag(text: "Unverified", serious: true) }
                    }
                    Text("\(h.amountText) \(h.symbol)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(h.value.map { MoneyFmt.usd($0, digits: 2) } ?? "No price").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(h.value == nil ? Theme.faint : Theme.text).contentTransition(.numericText())
                    if let pnl = p?.pnl {
                        Text(MoneyFmt.signed(pnl) + (p?.pct.map { " (" + MoneyFmt.pct($0) + ")" } ?? "")).font(.system(size: 12.5))
                            .foregroundStyle(pnl >= 0 ? Theme.green : Theme.red).contentTransition(.numericText())
                    } else {
                        Text("No cost recorded").font(.system(size: 12)).foregroundStyle(Theme.hint)
                    }
                }
                .monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One Solana token the wallet holds: amount, value, cost and P&L, Sell 25/50/100% for USDC or SOL, and Solscan.
struct SpotHoldingSheet: View {
    let mint: String
    /// Shown if the token is gone from the list (sold in full) while the sheet is open.
    let fallback: SolanaHoldings.Holding
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var toUSDC = true
    private var store: SolanaHoldings { .shared }

    var body: some View {
        let live = store.holding(mint)
        let h = live ?? fallback
        let p = live.flatMap { store.position($0) }
        let value = live == nil ? "$0" : h.value.map { MoneyFmt.usd($0, digits: 2) } ?? "—"
        let cost = p?.cost.map { MoneyFmt.usd($0, digits: 2) } ?? "—"
        let pnlText: String = p?.pnl.map { MoneyFmt.signed($0) + (p?.pct.map { " (" + MoneyFmt.pct($0) + ")" } ?? "") } ?? "—"
        let pnlColor: Color = p?.pnl == nil ? Theme.text : (p?.pnl ?? 0) >= 0 ? Theme.green : Theme.red
        let avg = p?.average.map { "$" + $0.tradePx } ?? "—"
        SheetChrome(title: h.name, subtitle: h.symbol) {
            HStack(spacing: 12) {
                MarketLogo(key: TradeData.logo(mint: h.id), name: h.symbol, size: 40, remote: h.icon.flatMap(URL.init))
                VStack(alignment: .leading, spacing: 2) {
                    Text(live == nil ? "None left" : "\(h.amountText) \(h.symbol)").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(h.price.map { "$" + $0.tradePx + " each" } ?? "No price from Jupiter").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                if !h.verified { SpotTag(text: "Unverified", serious: true) }
            }
            TradeStats(items: [("Value", value, Theme.text), ("Cost", cost, Theme.text), ("P&L", pnlText, pnlColor), ("Avg cost", avg, Theme.text)])
            if p == nil || p?.cost == nil {
                Text(p == nil ? "Hermit has no record of buying this, so it can't show a cost or P&L."
                     : "Some of it came from outside Hermit, so the P&L can't cover all of it. Average cost is what Hermit's buys paid.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
            }
            if live != nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Sell").font(.system(size: 13, weight: .medium))
                        Spacer()
                        if h.id != Jupiter.usdcMint {
                            Text("Get").font(.system(size: 12)).foregroundStyle(Theme.hint)
                            Segmented(options: [(true, "USDC"), (false, "SOL")], selection: $toUSDC)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach([("25%", 25), ("50%", 50), ("100%", 100)], id: \.1) { s in
                            Button { sell(h, percent: s.1) } label: { Text(s.0).frame(maxWidth: .infinity) }
                                .buttonStyle(TradeSmallButton(height: 34))
                        }
                    }
                    .disabled(h.frozen)
                    if h.frozen {
                        Text("The token's issuer froze this account, so it can't be sold.").font(.system(size: 12.5)).foregroundStyle(Theme.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Through Jupiter, with the usual review and Face ID or Touch ID.").font(.system(size: 12)).foregroundStyle(Theme.hint)
                    }
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Mint").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                AddressText(value: h.id, font: .system(size: 13))
            }
            Button {
                if let u = URL(string: "https://solscan.io/token/\(h.id)") { openURL(u) }
            } label: {
                Label("View on Solscan", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(WideButton(kind: .plain))
        }
    }

    /// The approval sheet can't open over this one: close it first, then start the sale.
    private func sell(_ h: SolanaHoldings.Holding, percent: Int) {
        let usdc = toUSDC
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            TradeBuy.sellOnSolana(h, percent: percent, toUSDC: usdc, model: model)
        }
    }
}
