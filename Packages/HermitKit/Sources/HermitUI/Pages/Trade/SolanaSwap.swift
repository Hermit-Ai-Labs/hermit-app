import SwiftUI
import Observation
import HermitWallet

/// Every token Jupiter marks verified on Solana, with live price, 24h change and liquidity: the Spot and Memes lists.
@MainActor @Observable
final class JupiterTokens {
    static let shared = JupiterTokens()
    struct Row: Identifiable, Codable, Hashable, Sendable {
        let id: String            // mint
        let symbol, name: String
        let decimals: Int
        let icon: String?
        let price: Double
        let change24h: Double
        let liquidity: Double
        let volume24h: Double
        let tags: [String]
        /// What Jupiter's search said about a token found there (verified or not, its audit). nil for the verified list.
        var check: TokenCheck? = nil
        var isMeme: Bool { tags.contains("meme") }
        var isStable: Bool { tags.contains("stable") }
        /// Tokenised stocks, pre-IPO tickers, staking and lending receipts: verified, but not the coins Spot is for.
        var isWrapper: Bool { tags.contains { JupiterTokens.notSpot.contains($0) } }
        var verified: Bool { check?.verified ?? true }
        var token: Jupiter.Token { Jupiter.Token(mint: id, symbol: symbol, name: name, decimals: decimals, verified: verified) }
    }

    /// One token from Jupiter's search: what a holding needs to be named, and the full row when it has a price.
    struct Found: Sendable {
        let id, symbol, name: String
        let decimals: Int
        let icon: String?
        let verified: Bool
        let row: Row?
    }

    nonisolated static let notSpot: Set<String> = ["stocks", "xstocks", "rwa", "ondo", "prestocks", "pre-ipo", "lst", "jup-lend-earn", "stable", "yb",
                                       "internal", "duplicate"]
    nonisolated private static let cacheName = "jupiter-verified"
    private(set) var rows: [Row] = MarketDiskCache.load(JupiterTokens.cacheName, maxAge: 3600, as: [Row].self) ?? []
    private(set) var state: FeedState = .loading
    /// When the prices on screen came from Jupiter: the last good download, or the saved copy's date.
    private(set) var updated: Date? = JupiterTokens.savedDate()
    /// The last refresh failed (often Jupiter's rate limit), so the prices are older than they look.
    private(set) var lastFailed = false
    @ObservationIgnored private var last = Date.distantPast
    @ObservationIgnored private var loading = false

    /// Spot: the big, liquid coins (not memes, stablecoins, tokenised stocks or receipts), by 24h volume. Memes: the meme
    /// tag, by 24h volume. A search looks through every verified token; "$wif" and "wif" both find $WIF.
    func list(memes: Bool, search: String) -> [Row] {
        let q = Self.plain(search.trimmingCharacters(in: .whitespaces)).lowercased()
        var base = rows.filter { memes ? $0.isMeme : (!$0.isMeme && !$0.isWrapper) }
        if !q.isEmpty {
            let mint = search.trimmingCharacters(in: .whitespaces)
            base = rows.filter { $0.id == mint || Self.plain($0.symbol).lowercased().contains(q) || $0.name.lowercased().contains(q) }
            // Symbols that start with the search first, then by volume.
            return Array(base.sorted { a, b in
                let pa = Self.plain(a.symbol).lowercased().hasPrefix(q), pb = Self.plain(b.symbol).lowercased().hasPrefix(q)
                return pa != pb ? pa : a.volume24h > b.volume24h
            }.prefix(40))
        }
        return Array(base.sorted { $0.volume24h > $1.volume24h }.prefix(60))
    }

    nonisolated static func plain(_ s: String) -> String { s.hasPrefix("$") ? String(s.dropFirst()) : s }

    /// Base58, the length of a Solana address: what a pasted mint looks like.
    nonisolated static func looksLikeMint(_ s: String) -> Bool {
        let b58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return (32...44).contains(s.count) && s.allSatisfy { b58.contains($0) }
    }

    /// The list is about 5 MB and Jupiter's free API rate-limits hard, so it's fetched at most every `minAge` seconds
    /// (`force` for Retry), revalidated against the local cache, and never twice at once.
    func refresh(force: Bool = false, minAge: TimeInterval = 600) async {
        guard !loading, force || Date().timeIntervalSince(last) > minAge else { return }
        loading = true; defer { loading = false }
        do {
            let d = try await MarketHTTP.data("https://lite-api.jup.ag/tokens/v2/tag?query=verified", fresh: false)
            guard let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw MarketError.shape }
            let parsed: [Row] = list.compactMap { Self.row($0, minLiquidity: 50_000) }
            withAnimation(.smooth) { rows = parsed; state = .ready }
            MarketDiskCache.save(Self.cacheName, parsed)
            last = Date(); updated = last; lastFailed = false
        } catch {
            state = rows.isEmpty ? .failed : .ready
            lastFailed = true
        }
    }

    /// Jupiter's search over every Solana token, verified or not: a name, a symbol, a mint, or several mints joined by
    /// commas (up to about 40 at once). Each result carries its audit (`TokenCheck`). Throws when Jupiter answers with
    /// anything but a list (its rate limit, usually), so the screen can say so instead of "nothing found".
    nonisolated static func search(_ query: String) async throws -> [Found] {
        var c = URLComponents(string: "https://lite-api.jup.ag/tokens/v2/search")
        c?.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = c?.url?.absoluteString else { throw MarketError.shape }
        let d = try await MarketHTTP.data(url)
        guard let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw MarketError.shape }
        return list.compactMap { t -> Found? in
            guard let id = t["id"] as? String, let sym = t["symbol"] as? String, let dec = t["decimals"] as? Int else { return nil }
            let check = TokenCheck(t, liquidity: t["liquidity"] as? Double ?? 0)
            var r = row(t, minLiquidity: 0)
            r?.check = check
            return Found(id: id, symbol: sym, name: t["name"] as? String ?? sym, decimals: dec, icon: t["icon"] as? String,
                         verified: check.verified, row: r)
        }
    }

    nonisolated private static func row(_ t: [String: Any], minLiquidity: Double) -> Row? {
        guard let id = t["id"] as? String, let sym = t["symbol"] as? String, let dec = t["decimals"] as? Int,
              let price = t["usdPrice"] as? Double, price > 0 else { return nil }
        let liq = t["liquidity"] as? Double ?? 0
        guard liq >= minLiquidity else { return nil }
        let s = t["stats24h"] as? [String: Any] ?? [:]
        return Row(id: id, symbol: sym, name: t["name"] as? String ?? sym, decimals: dec, icon: t["icon"] as? String, price: price,
                   change24h: s["priceChange"] as? Double ?? 0, liquidity: liq,
                   volume24h: (s["buyVolume"] as? Double ?? 0) + (s["sellVolume"] as? Double ?? 0), tags: t["tags"] as? [String] ?? [])
    }

    /// The saved list's date (MarketDiskCache keeps it as hermit-<name>.json in Caches), so a cold start says how old it is.
    nonisolated private static func savedDate() -> Date? {
        let path = URL.cachesDirectory.appending(path: "hermit-\(cacheName).json").path
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(m) < 3600 else { return nil }
        return m
    }
}

/// What Jupiter's search says about one token: verified or not, and its audit (mint and freeze authority, how much the
/// top holders own, how old it is). Search results show it as tags, the swap box and the review as warnings, and
/// `refusal` keeps Hermit from buying the worst ones at all.
struct TokenCheck: Codable, Hashable, Sendable {
    let verified: Bool
    /// Still enabled (or Jupiter didn't say it's off): the creator can mint more, or freeze holders' tokens.
    let mintAuthority: Bool
    let freezeAuthority: Bool
    /// Percent of the supply the top holders own.
    let topHolders: Double?
    /// When its first pool opened (else when the token was made).
    let created: Date?
    let liquidity: Double

    /// Below this Hermit won't open a review to buy; below `lowLiquidity` it warns.
    static let minLiquidity = 5_000.0, lowLiquidity = 50_000.0

    init(_ t: [String: Any], liquidity: Double) {
        let a = t["audit"] as? [String: Any]
        verified = (t["isVerified"] as? Bool) == true || ((t["tags"] as? [String]) ?? []).contains("verified")
        mintAuthority = (a?["mintAuthorityDisabled"] as? Bool) != true
        freezeAuthority = (a?["freezeAuthorityDisabled"] as? Bool) != true
        topHolders = a?["topHoldersPercentage"] as? Double
        let when = ((t["firstPool"] as? [String: Any])?["createdAt"] as? String) ?? (t["createdAt"] as? String)
        created = when.flatMap(Self.date)
        self.liquidity = liquidity
    }

    /// "2026-11-10T11:45:47Z", with or without fractions of a second (Jupiter sends both, up to nanoseconds).
    private static func date(_ s: String) -> Date? {
        guard s.count >= 19 else { return nil }
        return ISO8601DateFormatter().date(from: String(s.prefix(19)) + "Z")
    }

    private var ageDays: Double? { created.map { Date().timeIntervalSince($0) / 86_400 } }

    /// Why Hermit won't buy it, or nil. A verified token with a freeze authority (USDC has one) only gets a warning.
    var refusal: String? {
        if liquidity < Self.minLiquidity {
            return "Only \(liquidity.tradeCompactUSD) of liquidity, under Hermit's $5K minimum, so Hermit won't buy it."
        }
        if !verified && freezeAuthority {
            return "Its creator can freeze holders' tokens so they can't be sold, so Hermit won't buy it."
        }
        return nil
    }

    /// Plain warnings, most serious first. Not verified comes first.
    var warnings: [String] {
        var w: [String] = []
        if !verified { w.append("Not on Jupiter's verified list. Anyone can make a token with any name.") }
        if freezeAuthority { w.append("Its creator can freeze holders' tokens.") }
        if mintAuthority { w.append("Its creator can still mint more of it.") }
        if liquidity < Self.lowLiquidity { w.append("Only \(liquidity.tradeCompactUSD) of liquidity: trades move its price a lot.") }
        if let top = topHolders, top >= 50 { w.append("The top holders own \(Int(top.rounded()))% of it.") }
        if let d = ageDays, d < 7 { w.append(d < 1 ? "Less than a day old." : "Only \(Int(d)) days old.") }
        return w
    }

    /// Short tags for a search row: (text, serious).
    var tags: [(String, Bool)] {
        var t: [(String, Bool)] = []
        if !verified { t.append(("Unverified", true)) }
        if freezeAuthority { t.append(("Freeze on", !verified)) }
        if mintAuthority { t.append(("Mint on", false)) }
        if liquidity < Self.lowLiquidity { t.append(("Low liquidity", liquidity < Self.minLiquidity)) }
        if let top = topHolders, top >= 50 { t.append(("Top holders \(Int(top.rounded()))%", false)) }
        if let d = ageDays, d < 7 { t.append(("New", false)) }
        return t
    }
}

/// Spot and Memes on Solana: pick any token (Jupiter's verified list, or any token Jupiter's search finds), pay in USDC
/// or SOL from the wallet, see Jupiter's live quote, Swap. What you hold shows under the buy box, with Sell.
/// The review and Touch ID / Face ID are the same as every other money action; Hermit signs and sends it itself.
struct SolanaSwapScreen: View {
    let memes: Bool
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var sel: JupiterTokens.Row?
    @State private var payUSDC = true
    @State private var amtText = "10"
    @State private var quote: Jupiter.Quote?
    @State private var quoting = false
    @State private var quoteError: String?
    @State private var width: CGFloat = 900
    /// Jupiter's search over every token, for `remoteFor` (the query those results answer).
    @State private var remote: [JupiterTokens.Row] = []
    @State private var remoteFor = ""
    @State private var remoteLoading = false
    @State private var remoteFailed = false
    @State private var searchTick = 0
    /// Sell for USDC (else SOL).
    @State private var sellUSDC = true
    /// The buy or sell that just went through, shown in the swap box for a few seconds.
    @State private var done: SolanaHoldings.Done?
    @State private var seenDone: UUID?
    @FocusState private var searching: Bool
    private var store: JupiterTokens { .shared }
    private var holdings: SolanaHoldings { .shared }
    private var vm: WalletsViewModel { .shared }

    private var amt: Double { TradeAmount.value(amtText) ?? 0 }
    private var solPrice: Double { TradeBuy.solPrice() ?? 0 }
    private var usdcHeld: Double { vm.wallets.first.map { vm.balance(of: "USDC", wallet: $0.id, chain: .solana) } ?? 0 }
    private var solHeld: Double { vm.wallets.first.map { vm.balance(of: "SOL", wallet: $0.id, chain: .solana) } ?? 0 }
    /// What can be spent: all the USDC, or the SOL less what the fee and a new token account's rent need.
    private var spendable: Double { payUSDC ? usdcHeld : max(0, solHeld - TradeBuy.solReserve) }
    /// Paying with USDC still needs a little SOL for the fee.
    private var needsFeeSOL: Bool { payUSDC && solHeld < TradeBuy.solForFees }
    /// What the amount typed is worth, in dollars.
    private var usd: Double { payUSDC ? amt : amt * solPrice }
    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let list = merged(store.list(memes: memes, search: search))
        Group {
            if width >= 680 {
                HStack(alignment: .top, spacing: 28) { tokenList(list).frame(maxWidth: .infinity); swapBox.frame(width: 320) }
            } else {
                VStack(spacing: 20) { if sel != nil || done != nil { swapBox }; tokenList(list) }
            }
        }
        .tradeWidth($width)
        .task { await store.refresh(); pickFirst() }
        .onChange(of: store.rows.count) { _, _ in pickFirst() }
        .task(id: "\(sel?.id ?? "")|\(payUSDC)|\(amtText)") { await requote() }
        .task(id: "\(search)|\(searchTick)") { await searchJupiter() }
        // The list is big and shares Jupiter's rate limit with quotes, so it refreshes every 5 minutes at most.
        .marketPoll(every: 300) { await store.refresh(minAge: 240) }
        // What the wallet holds, for the position card and the holdings strip.
        .marketPoll(every: 30) { await holdings.refresh() }
        .onAppear { seenDone = holdings.lastDone?.id }
        // A buy or sell finished: show it once its review has closed.
        .onChange(of: holdings.lastDone?.id) { _, _ in showDone() }
        .onChange(of: model.approval == nil) { _, _ in showDone() }
        .task(id: done?.id) {
            guard done != nil else { return }
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { done = nil }
        }
    }

    private func pickFirst() {
        if sel == nil { sel = store.list(memes: memes, search: search).first }
    }

    /// The verified matches first, then whatever else Jupiter's search found: verified ones, then the rest by liquidity.
    private func merged(_ found: [JupiterTokens.Row]) -> [JupiterTokens.Row] {
        guard query.count >= 2, remoteFor == query else { return found }
        let have = Set(found.map(\.id))
        let extra = remote.filter { !have.contains($0.id) }.sorted { a, b in
            a.verified != b.verified ? a.verified : a.liquidity > b.liquidity
        }
        return found + extra
    }

    private func showDone() {
        guard model.approval == nil, let d = holdings.lastDone, d.id != seenDone, Date().timeIntervalSince(d.date) < 30 else { return }
        seenDone = d.id
        if sel?.id != d.mint, let r = row(for: d.mint) { sel = r }
        withAnimation(.smooth) { done = d }
    }

    private func row(for mint: String) -> JupiterTokens.Row? {
        store.rows.first { $0.id == mint } ?? remote.first { $0.id == mint } ?? holdings.rows[mint]
    }

    // MARK: Token list

    private func tokenList(_ list: [JupiterTokens.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                TextField(memes ? "Search any Solana meme, or paste a mint" : "Search any Solana token, or paste a mint", text: $search)
                    .textFieldStyle(.plain).focused($searching).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }
            .font(.system(size: 14)).padding(.horizontal, 12).frame(height: 36)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searching ? Theme.text.opacity(0.25) : .clear))
            .padding(.bottom, 10)
            holdingsStrip
            if store.rows.isEmpty && query.count < 2 {
                MarketStatus(kind: store.state == .failed ? .failed("Couldn't reach Jupiter") : .loading("Loading Solana tokens from Jupiter")) { Task { await store.refresh(force: true) } }
            } else if list.isEmpty {
                if query.count >= 2 && (remoteLoading || remoteFor != query) {
                    MarketStatus(kind: .loading("Searching every Solana token on Jupiter"))
                } else if query.count >= 2 && remoteFailed {
                    MarketStatus(kind: .failed("Couldn't search Jupiter just now")) { searchTick += 1 }
                } else {
                    MarketStatus(kind: .empty(query.count >= 2 ? "No Solana token matches" : "No verified token with enough liquidity matches"))
                }
            }
            TradeRows(data: list) { r in row(r) }
            if !list.isEmpty && query.count >= 2 {
                if remoteLoading { MarketStatus(kind: .loading("Searching the rest of Solana")) }
                else if remoteFailed && remoteFor == query {
                    MarketStatus(kind: .failed("Only verified tokens shown. Couldn't search the rest just now.")) { searchTick += 1 }
                }
            }
            if !store.rows.isEmpty {
                TimelineView(.everyMinute) { _ in
                    MarketSource(text: (query.count >= 2
                        ? "Verified tokens first, then the rest of Jupiter's search. Unverified ones are marked, with what their audit says. "
                        : "Jupiter's verified list, \(memes ? "meme coins" : "the liquid coins"), by 24h volume. ") + freshness)
                }
                .padding(.top, 8)
            }
        }
    }

    /// How old the prices are, said plainly; a failed refresh says so instead of passing old prices off as live.
    private var freshness: String {
        let when = store.updated.map { "Prices from Jupiter, updated \($0.formatted(.relative(presentation: .named)))." } ?? "Prices from Jupiter, saved earlier."
        return when + (store.lastFailed ? " Couldn't refresh just now." : "")
    }

    private func row(_ r: JupiterTokens.Row) -> some View {
        Button { withAnimation(.snappy) { sel = r } } label: {
            HStack(spacing: 12) {
                MarketLogo(key: TradeData.logo(mint: r.id), name: r.symbol, size: 32, remote: r.icon.flatMap(URL.init))
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    Text("\(r.name), \(r.liquidity.tradeCompactUSD) liquidity").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    if let c = r.check, !c.tags.isEmpty {
                        TradeFlow(spacing: 4, lineSpacing: 4) {
                            ForEach(c.tags, id: \.0) { t in SpotTag(text: t.0, serious: t.1) }
                        }
                        .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("$" + r.price.tradePx).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    Text((r.change24h >= 0 ? "+" : "") + String(format: "%.1f%%", r.change24h)).font(.system(size: 12.5))
                        .foregroundStyle(r.change24h >= 0 ? Theme.green : Theme.red)
                }
                .monospacedDigit()
            }
            .padding(.vertical, 10).contentShape(Rectangle())
            .background(sel?.id == r.id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// "Your holdings": the tokens the wallet holds with a value, a tap away. Hidden while searching.
    @ViewBuilder private var holdingsStrip: some View {
        let held = Array(holdings.items.filter { $0.id != Jupiter.usdcMint && ($0.value ?? 0) >= 0.01 }.prefix(8))
        if search.isEmpty && !held.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your holdings").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TradeFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(held) { h in
                        Button { select(h) } label: {
                            HStack(spacing: 6) {
                                MarketLogo(key: TradeData.logo(mint: h.id), name: h.symbol, size: 18, remote: h.icon.flatMap(URL.init))
                                Text(h.symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(MoneyFmt.usdSmart(h.value ?? 0)).font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(sel?.id == h.id ? Theme.hover : Theme.bg, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.border))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel("\(h.symbol), \(MoneyFmt.usdSmart(h.value ?? 0))")
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// Opens a held token in the swap box: from the verified list, the search results, or Jupiter's search for its mint.
    private func select(_ h: SolanaHoldings.Holding) {
        if let r = row(for: h.id) { withAnimation(.snappy) { sel = r }; return }
        Task {
            let found = try? await JupiterTokens.search(h.id)
            if let r = found?.first(where: { $0.id == h.id })?.row { withAnimation(.snappy) { sel = r } }
            else { model.toast("Jupiter has no price for \(h.symbol) right now", kind: .info) }
        }
    }

    // MARK: Swap box

    @ViewBuilder private var swapBox: some View {
        if let d = done {
            SpotDoneView(done: d).transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if let t = sel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MarketLogo(key: TradeData.logo(mint: t.id), name: t.symbol, size: 34, remote: t.icon.flatMap(URL.init))
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Buy \(t.symbol)").font(.system(size: 16, weight: .semibold))
                            if !t.verified { SpotTag(text: "Unverified", serious: true) }
                        }
                        Text(t.name).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("You pay").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(payUSDC ? "\(MoneyFmt.amount(usdcHeld)) USDC available" : "\(MoneyFmt.amount(solHeld)) SOL available")
                            .font(.system(size: 12)).foregroundStyle(Theme.hint).monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        TextField("0", text: $amtText).textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                            // Tall enough for the 24 pt digits: the Mac sized the field for its default font and cut them in half.
                            .lineLimit(1).frame(height: 34)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Segmented(options: [(true, "USDC"), (false, "SOL")], selection: $payUSDC)
                    }
                    HStack(spacing: 6) {
                        ForEach([("25%", 0.25), ("50%", 0.5), ("Max", 1.0)], id: \.0) { p in
                            Button(p.0) {
                                // Rounded down, so Max never asks for more than is there.
                                let f = pow(10.0, 4.0)
                                amtText = TradeAmount.text((spendable * p.1 * f).rounded(.down) / f)
                            }
                            .buttonStyle(TradeSmallButton())
                        }
                        Spacer()
                        if usd > 0 { Text("≈ " + MoneyFmt.usd(usd, digits: 2)).font(.system(size: 12)).foregroundStyle(Theme.hint) }
                    }
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("You get, about").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        if quoting { ProgressView().controlSize(.small) }
                        Text(quote.map { "\($0.outFormatted) \(t.symbol)" } ?? "—").font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(quote == nil ? Theme.faint : Theme.text).contentTransition(.numericText())
                    }
                    if let q = quote {
                        let impact = q.shownImpactPercent
                        Text("Price impact \(String(format: "%.2f", impact))%, slippage up to \(Double(q.slippageBps) / 100)%"
                             + (q.route.isEmpty ? "" : ", via \(q.route.prefix(2).joined(separator: ", "))")
                             + (impact > TradeBuy.maxImpact ? ". Too much to send: try a smaller amount." : ""))
                            .font(.system(size: 12))
                            .foregroundStyle(impact > TradeBuy.maxImpact ? Theme.red : impact > 2 ? Theme.amber : Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                if let e = quoteError { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
                if let c = t.check, !c.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(c.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if let why = t.check?.refusal {
                    Text(why).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    TradeBuy.buyOnSolana(token: t.token, payUSDC: payUSDC, amount: amt, exact: amtText, check: t.check, model: model)
                } label: { Text("Swap").frame(maxWidth: .infinity) }
                    .buttonStyle(TradeBlockButton(color: Theme.text))
                    .disabled(quote == nil || quoting || amt <= 0 || amt > spendable || needsFeeSOL
                              || (quote?.shownImpactPercent ?? 0) > TradeBuy.maxImpact || t.check?.refusal != nil)
                if amt > spendable || needsFeeSOL {
                    HStack(spacing: 8) {
                        Text(needsFeeSOL ? "Add a little SOL on Solana for the network fee."
                             : payUSDC || amt > solHeld ? "Not enough \(payUSDC ? "USDC" : "SOL") on Solana."
                             : "Keep about \(TradeAmount.text(TradeBuy.solReserve, maxFraction: 2)) SOL for fees.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Add funds") { model.fundGoal = .token(.solana, payUSDC && !needsFeeSOL ? "USDC" : "SOL") }.buttonStyle(TradeSmallButton())
                    }
                }
                Text(t.verified
                     ? "Through Jupiter's API, into your own wallet. You approve on the review screen."
                     : "Through Jupiter's API, into your own wallet. This token isn't verified: the review shows its full mint so you can check it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
                positionCard(t)
            }
        } else {
            Text("Pick a token to buy.").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
        }
    }

    /// What the wallet holds of this token: amount, value, average cost and P&L when Hermit recorded the buys, and Sell.
    @ViewBuilder private func positionCard(_ t: JupiterTokens.Row) -> some View {
        if let h = holdings.holding(t.id) {
            let p = holdings.position(h)
            let outIsSOL = !sellUSDC || h.id == Jupiter.usdcMint
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your position").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    Spacer()
                    if h.id != Jupiter.usdcMint {
                        Text("Sell for").font(.system(size: 12)).foregroundStyle(Theme.hint)
                        Segmented(options: [(true, "USDC"), (false, "SOL")], selection: $sellUSDC)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("\(h.amountText) \(h.symbol)").font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text(h.value.map { MoneyFmt.usd($0, digits: 2) } ?? "No price").font(.system(size: 14, weight: .medium)).monospacedDigit()
                        .foregroundStyle(h.value == nil ? Theme.faint : Theme.text).contentTransition(.numericText())
                }
                HStack(alignment: .firstTextBaseline) {
                    if let a = p?.average { Text("Avg cost $" + a.tradePx).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit() }
                    Spacer(minLength: 8)
                    if let pnl = p?.pnl {
                        Text(MoneyFmt.signed(pnl) + (p?.pct.map { " (" + MoneyFmt.pct($0) + ")" } ?? ""))
                            .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(pnl >= 0 ? Theme.green : Theme.red).contentTransition(.numericText())
                    } else {
                        Text(p == nil ? "No cost recorded in Hermit" : "Some came from outside Hermit")
                            .font(.system(size: 12)).foregroundStyle(Theme.hint)
                    }
                }
                if h.frozen {
                    Text("The token's issuer froze this account, so it can't be sold.").font(.system(size: 12)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    ForEach([("Sell 25%", 25), ("Sell 50%", 50), ("Sell max", 100)], id: \.1) { s in
                        Button(s.0) { TradeBuy.sellOnSolana(h, percent: s.1, toUSDC: !outIsSOL, model: model) }
                            .buttonStyle(TradeSmallButton())
                    }
                    Spacer(minLength: 0)
                }
                .disabled(h.frozen)
            }
            .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .transition(.opacity)
        }
    }

    private func requote() async {
        quote = nil; quoteError = nil
        guard let t = sel, amt > 0 else { return }
        let pay: Jupiter.Token = payUSDC ? Jupiter.usdc : Jupiter.sol
        // Exact base units from the text; junk, too many decimals or an absurd size never reach Jupiter (or a UInt64 trap).
        guard let base = TradeAmount.baseUnits(text: amtText, decimals: pay.decimals) else {
            quoteError = "Check the amount: up to \(pay.decimals) decimals for \(pay.symbol)."; return
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        quoting = true; defer { quoting = false }
        do {
            let q = try await Jupiter.quote(from: pay, to: t.token, amount: base)
            if !Task.isCancelled { quote = q }
        } catch {
            if !Task.isCancelled { quoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    /// Two or more characters: Jupiter's search over every Solana token, 350 ms after the last keystroke (a new keystroke
    /// cancels it). A pasted mint goes straight to it.
    private func searchJupiter() async {
        let q = query
        guard q.count >= 2 else { remote = []; remoteFor = ""; remoteFailed = false; remoteLoading = false; return }
        if !JupiterTokens.looksLikeMint(q) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        remoteLoading = true
        do {
            let found = try await JupiterTokens.search(JupiterTokens.plain(q))
            guard !Task.isCancelled else { return }
            remote = found.compactMap(\.row); remoteFor = q; remoteFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            remote = []; remoteFor = q; remoteFailed = true
        }
        remoteLoading = false
    }
}

/// A small tag on a search row: "Unverified", "Freeze on", "Low liquidity". Serious ones are red, the rest amber.
struct SpotTag: View {
    let text: String
    var serious = false
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
            .foregroundStyle(serious ? Theme.red : Theme.amber)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((serious ? Theme.red : Theme.amber).opacity(0.09), in: Capsule())
    }
}
