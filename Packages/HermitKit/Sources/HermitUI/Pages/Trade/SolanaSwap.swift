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
        var token: Jupiter.Token { Jupiter.Token(mint: id, symbol: symbol, name: name, decimals: decimals, verified: true) }
    }
    private(set) var rows: [Row] = MarketDiskCache.load("jupiter-verified", maxAge: 3600, as: [Row].self) ?? []
    private(set) var state: FeedState = .loading
    @ObservationIgnored private var last = Date.distantPast

    /// Spot: the big, liquid coins (not memes, not stablecoins), by 24h volume. Memes: the meme tag, by 24h volume.
    func list(memes: Bool, search: String) -> [Row] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var base = rows.filter { memes ? $0.isMeme : (!$0.isMeme && !$0.isStable) }
        if !q.isEmpty {
            base = rows.filter { $0.symbol.lowercased().hasPrefix(q) || $0.name.lowercased().contains(q) || $0.id == search }
        }
        return Array(base.sorted { $0.volume24h > $1.volume24h }.prefix(q.isEmpty ? 60 : 40))
    }

    func refresh(force: Bool = false) async {
        guard force || Date().timeIntervalSince(last) > 600 else { return }
        do {
            let d = try await MarketHTTP.data("https://lite-api.jup.ag/tokens/v2/tag?query=verified")
            guard let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw MarketError.shape }
            let parsed: [Row] = list.compactMap { t in
                guard let id = t["id"] as? String, let sym = t["symbol"] as? String, let dec = t["decimals"] as? Int,
                      let price = t["usdPrice"] as? Double, let liq = t["liquidity"] as? Double, liq >= 50_000 else { return nil }
                let s = t["stats24h"] as? [String: Any] ?? [:]
                return Row(id: id, symbol: sym, name: t["name"] as? String ?? sym, decimals: dec, icon: t["icon"] as? String, price: price,
                           change24h: s["priceChange"] as? Double ?? 0, liquidity: liq,
                           volume24h: (s["buyVolume"] as? Double ?? 0) + (s["sellVolume"] as? Double ?? 0), tags: t["tags"] as? [String] ?? [])
            }
            withAnimation(.smooth) { rows = parsed; state = .ready }
            MarketDiskCache.save("jupiter-verified", parsed)
            last = Date()
        } catch {
            state = rows.isEmpty ? .failed : .ready
        }
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
    @FocusState private var searching: Bool
    private var store: JupiterTokens { .shared }
    private var vm: WalletsViewModel { .shared }

    private var amt: Double { Double(amtText.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private var solPrice: Double { vm.price("SOL") ?? store.rows.first { $0.symbol == "SOL" }?.price ?? 0 }
    private var usdcHeld: Double { vm.wallets.first.map { vm.balance(of: "USDC", wallet: $0.id, chain: .solana) } ?? 0 }
    private var solHeld: Double { vm.wallets.first.map { vm.balance(of: "SOL", wallet: $0.id, chain: .solana) } ?? 0 }
    /// What the amount typed is worth, in dollars.
    private var usd: Double { payUSDC ? amt : amt * solPrice }

    var body: some View {
        let list = store.list(memes: memes, search: search)
        Group {
            if width >= 680 {
                HStack(alignment: .top, spacing: 28) { tokenList(list).frame(maxWidth: .infinity); swapBox.frame(width: 320) }
            } else {
                VStack(spacing: 20) { if sel != nil { swapBox }; tokenList(list) }
            }
        }
        .tradeWidth($width)
        .task { await store.refresh(); if sel == nil { sel = list.first } }
        .task(id: "\(sel?.id ?? "")|\(payUSDC)|\(amtText)") { await requote() }
        .marketPoll(every: 120) { await store.refresh(force: true) }
    }

    // MARK: Token list

    private func tokenList(_ list: [JupiterTokens.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                TextField(memes ? "Search memes, or paste a mint" : "Search any Solana token, or paste a mint", text: $search)
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
                MarketStatus(kind: .empty("No verified token matches"))
            }
            TradeRows(data: list) { r in row(r) }
            if !store.rows.isEmpty {
                MarketSource(text: "Jupiter's verified list, \(memes ? "meme coins" : "the liquid coins"), by 24h volume. Prices live from Jupiter.").padding(.top, 8)
            }
        }
    }

    private func row(_ r: JupiterTokens.Row) -> some View {
        Button { withAnimation(.snappy) { sel = r } } label: {
            HStack(spacing: 12) {
                MarketLogo(key: TradeData.logo(r.symbol), name: r.symbol, size: 32, remote: r.icon.flatMap(URL.init))
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
                    MarketLogo(key: TradeData.logo(t.symbol), name: t.symbol, size: 34, remote: t.icon.flatMap(URL.init))
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
                                let held = payUSDC ? usdcHeld : max(0, solHeld - 0.004)
                                amtText = (held * p.1).formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
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
                        Text("Price impact \(String(format: "%.2f", q.priceImpactPct))%, slippage up to \(Double(q.slippageBps) / 100)%"
                             + (q.route.isEmpty ? "" : ", via \(q.route.prefix(2).joined(separator: ", "))"))
                            .font(.system(size: 12)).foregroundStyle(q.priceImpactPct > 2 ? Theme.amber : Theme.faint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                if let e = quoteError { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
                Button {
                    TradeBuy.buyOnSolana(token: t.token, payUSDC: payUSDC, amount: amt, model: model)
                } label: { Text("Swap").frame(maxWidth: .infinity) }
                    .buttonStyle(TradeBlockButton(color: Theme.text))
                    .disabled(quote == nil || quoting || amt <= 0 || amt > (payUSDC ? usdcHeld : solHeld))
                if amt > (payUSDC ? usdcHeld : solHeld) {
                    HStack(spacing: 8) {
                        Text("Not enough \(payUSDC ? "USDC" : "SOL") on Solana.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Button("Add funds") { model.fundGoal = .token(.solana, payUSDC ? "USDC" : "SOL") }.buttonStyle(TradeSmallButton())
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
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        quoting = true; defer { quoting = false }
        let pay: Jupiter.Token = payUSDC ? .usdc : .sol
        let base = UInt64((amt * pow(10, Double(pay.decimals))).rounded())
        do {
            let q = try await Jupiter.quote(from: pay, to: t.token, amount: base)
            if !Task.isCancelled { quote = q }
        } catch {
            if !Task.isCancelled { quoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}
