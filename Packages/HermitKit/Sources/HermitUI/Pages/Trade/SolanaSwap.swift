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
        var isMeme: Bool { tags.contains("meme") }
        var isStable: Bool { tags.contains("stable") }
        /// Tokenised stocks, pre-IPO tickers, staking and lending receipts: verified, but not the coins Spot is for.
        var isWrapper: Bool { tags.contains { JupiterTokens.notSpot.contains($0) } }
        var token: Jupiter.Token { Jupiter.Token(mint: id, symbol: symbol, name: name, decimals: decimals, verified: true) }
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

    private static func plain(_ s: String) -> String { s.hasPrefix("$") ? String(s.dropFirst()) : s }

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

    /// One pasted mint that isn't on the list (too little liquidity for it, usually): shown only if Jupiter marks it verified.
    func lookUp(mint: String) async -> Row? {
        var c = URLComponents(string: "https://lite-api.jup.ag/tokens/v2/search")
        c?.queryItems = [URLQueryItem(name: "query", value: mint)]
        guard let url = c?.url?.absoluteString, let d = try? await MarketHTTP.data(url),
              let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]],
              let t = list.first(where: { $0["id"] as? String == mint }),
              (t["isVerified"] as? Bool) == true || ((t["tags"] as? [String]) ?? []).contains("verified") else { return nil }
        return Self.row(t, minLiquidity: 0)
    }

    private static func row(_ t: [String: Any], minLiquidity: Double) -> Row? {
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

/// Spot and Memes on Solana: pick any verified token, pay in USDC or SOL from the wallet, see Jupiter's live quote, Swap.
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
    /// A pasted mint that isn't on the list, looked up on its own; `checkedMint` is the last one asked about.
    @State private var pasted: JupiterTokens.Row?
    @State private var checkedMint = ""
    @FocusState private var searching: Bool
    private var store: JupiterTokens { .shared }
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

    var body: some View {
        let found = store.list(memes: memes, search: search)
        let list = found.isEmpty ? (pasted.map { [$0] } ?? []) : found
        Group {
            if width >= 680 {
                HStack(alignment: .top, spacing: 28) { tokenList(list).frame(maxWidth: .infinity); swapBox.frame(width: 320) }
            } else {
                VStack(spacing: 20) { if sel != nil { swapBox }; tokenList(list) }
            }
        }
        .tradeWidth($width)
        .task { await store.refresh(); pickFirst() }
        .onChange(of: store.rows.count) { _, _ in pickFirst() }
        .task(id: "\(sel?.id ?? "")|\(payUSDC)|\(amtText)") { await requote() }
        .task(id: search) { await lookUpMint() }
        // The list is big and shares Jupiter's rate limit with quotes, so it refreshes every 5 minutes at most.
        .marketPoll(every: 300) { await store.refresh(minAge: 240) }
    }

    private func pickFirst() {
        if sel == nil { sel = store.list(memes: memes, search: search).first }
    }

    // MARK: Token list

    private func tokenList(_ list: [JupiterTokens.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                TextField(memes ? "Search verified memes, or paste a mint" : "Search Jupiter-verified tokens, or paste a mint", text: $search)
                    .textFieldStyle(.plain).focused($searching).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain) }
            }
            .font(.system(size: 14)).padding(.horizontal, 12).frame(height: 36)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searching ? Theme.text.opacity(0.25) : .clear))
            .padding(.bottom, 10)
            if store.rows.isEmpty {
                MarketStatus(kind: store.state == .failed ? .failed("Couldn't reach Jupiter") : .loading("Loading Solana tokens from Jupiter")) { Task { await store.refresh(force: true) } }
            } else if list.isEmpty {
                let mint = search.trimmingCharacters(in: .whitespaces)
                MarketStatus(kind: .empty(JupiterTokens.looksLikeMint(mint)
                    ? (checkedMint == mint ? "That mint isn't a Jupiter-verified token" : "Looking up that mint")
                    : "No verified token with enough liquidity matches"))
            }
            TradeRows(data: list) { r in row(r) }
            if !store.rows.isEmpty {
                TimelineView(.everyMinute) { _ in
                    MarketSource(text: "Jupiter's verified list, \(memes ? "meme coins" : "the liquid coins"), by 24h volume. " + freshness)
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

    // MARK: Swap box

    @ViewBuilder private var swapBox: some View {
        if let t = sel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MarketLogo(key: TradeData.logo(mint: t.id), name: t.symbol, size: 34, remote: t.icon.flatMap(URL.init))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Buy \(t.symbol)").font(.system(size: 16, weight: .semibold))
                        Text(t.name).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("You pay").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(payUSDC ? "\(MoneyFmt.amount(usdcHeld)) USDC available" : "\(MoneyFmt.amount(solHeld)) SOL available")
                            .font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit()
                    }
                    HStack(spacing: 8) {
                        TextField("0", text: $amtText).textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).monospacedDigit()
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
                        if usd > 0 { Text("≈ " + MoneyFmt.usd(usd, digits: 2)).font(.system(size: 12)).foregroundStyle(Theme.faint) }
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
                Button {
                    TradeBuy.buyOnSolana(token: t.token, payUSDC: payUSDC, amount: amt, exact: amtText, model: model)
                } label: { Text("Swap").frame(maxWidth: .infinity) }
                    .buttonStyle(TradeBlockButton(color: Theme.text))
                    .disabled(quote == nil || quoting || amt <= 0 || amt > spendable || needsFeeSOL
                              || (quote?.shownImpactPercent ?? 0) > TradeBuy.maxImpact)
                if amt > spendable || needsFeeSOL {
                    HStack(spacing: 8) {
                        Text(needsFeeSOL ? "Add a little SOL on Solana for the network fee."
                             : payUSDC || amt > solHeld ? "Not enough \(payUSDC ? "USDC" : "SOL") on Solana."
                             : "Keep about \(TradeAmount.text(TradeBuy.solReserve, maxFraction: 2)) SOL for fees.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Add funds") { model.fundGoal = .token(.solana, payUSDC && !needsFeeSOL ? "USDC" : "SOL") }.buttonStyle(TradeSmallButton())
                    }
                }
                Text("Through Jupiter's API, into your own wallet. Only tokens on Jupiter's verified list. You approve on the review screen.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Pick a token to buy.").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
        }
    }

    private func requote() async {
        quote = nil; quoteError = nil
        guard let t = sel, amt > 0 else { return }
        let pay: Jupiter.Token = payUSDC ? .usdc : .sol
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

    /// A pasted mint that isn't on the list: ask Jupiter about that one token.
    private func lookUpMint() async {
        let mint = search.trimmingCharacters(in: .whitespaces)
        if pasted?.id != mint { pasted = nil }
        guard JupiterTokens.looksLikeMint(mint), !store.rows.contains(where: { $0.id == mint }), checkedMint != mint else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let r = await store.lookUp(mint: mint)
        guard !Task.isCancelled else { return }
        pasted = r; checkedMint = mint
    }
}
