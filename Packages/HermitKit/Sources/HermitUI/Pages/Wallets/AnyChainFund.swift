import SwiftUI
import HermitCore
import HermitWallet

/// Add funds from any chain NEAR Intents supports: the user picks what they'll send (BTC, ETH, SOL, USDT on Tron, …),
/// Hermit asks 1Click for a real quote with a one-time deposit address, shows it as a QR code, and follows the deposit
/// until it lands as USDC in the wallet (on Base) or in Hyperliquid perps. Sent from an exchange or any other wallet;
/// nothing is signed in Hermit.
struct AnyChainFundView: View {
    let goal: FundGoal
    var onBack: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var tokens: [IntentsToken] = []
    @State private var source: String = "nep141:btc.omft.near"
    @State private var amount = ""
    @State private var refund = ""
    @State private var quote: IntentsQuote?
    @State private var busy = false
    @State private var error: String?
    private var vm: WalletsViewModel { .shared }
    private var act: IntentsActivity { .shared }

    private var wallet: WalletAccount? { vm.wallets.first }
    private var src: IntentsToken? { tokens.first { $0.assetId == source } }
    private var dest: (place: IntentsPlace, symbol: String) {
        switch goal {
        case .hyperliquid: (.hyperliquid, "USDC")
        case .token(let c, let s): (.chain(c), s)
        case .wallet: (.chain(.base), "USDC")
        }
    }
    /// Hermit's own address on the source chain, where refunds go when it has one.
    private var ownRefund: String? {
        guard let s = src, let w = wallet?.record else { return nil }
        if s.blockchain == "sol" { return w.solanaAddress }
        if s.blockchain == "near" { return w.nearAccount }
        if Self.evmCodes.contains(s.blockchain) { return w.evmAddress }
        return nil
    }
    private var refundAddress: String { ownRefund ?? refund.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var value: Double { AmountText.value(amount) ?? 0 }

    static let evmCodes: Set<String> = ["eth", "base", "arb", "bsc", "pol", "op", "avax", "gnosis", "monad", "bera", "scroll", "hood",
                                        "xlayer", "plasma", "abs"]
    static let chainNames: [String: String] = [
        "eth": "Ethereum", "base": "Base", "arb": "Arbitrum", "bsc": "BNB Chain", "pol": "Polygon", "op": "Optimism", "avax": "Avalanche",
        "gnosis": "Gnosis", "sol": "Solana", "near": "NEAR", "btc": "Bitcoin", "tron": "Tron", "ton": "TON", "sui": "Sui", "aptos": "Aptos",
        "doge": "Dogecoin", "xrp": "XRP Ledger", "ltc": "Litecoin", "bch": "Bitcoin Cash", "zec": "Zcash", "stellar": "Stellar",
        "cardano": "Cardano", "monad": "Monad", "bera": "Berachain", "scroll": "Scroll", "hood": "Robinhood Chain", "starknet": "Starknet",
        "dash": "Dash", "hypercore": "Hyperliquid", "plasma": "Plasma", "xlayer": "X Layer",
    ]
    /// What people most often hold on an exchange, first.
    static let popular = ["nep141:btc.omft.near", "nep141:eth.omft.near", "nep141:sol.omft.near",
                          "nep141:eth-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.omft.near",
                          "nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near",
                          "nep141:arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near",
                          "nep141:tron-d28a265909efecdcee7c5028585214ea0b96f015.omft.near", "nep141:wrap.near"]

    private var options: [IntentsToken] {
        let skip: Set<String> = ["hypercore"]
        let rest = tokens.filter { !Self.popular.contains($0.assetId) && !skip.contains($0.blockchain) }
            .sorted { ($0.symbol, $0.blockchain) < ($1.symbol, $1.blockchain) }
        return Self.popular.compactMap { id in tokens.first { $0.assetId == id } } + rest
    }
    private func label(_ t: IntentsToken) -> String {
        "\(t.assetId == IntentsAssets.wrappedNear ? "NEAR" : t.symbol) on \(Self.chainNames[t.blockchain] ?? t.blockchain.uppercased())"
    }

    var body: some View {
        SheetChrome(title: quote == nil ? "Add funds from any chain" : "Send to this address",
                    subtitle: "Arrives as \(dest.symbol) on \(dest.place.name)", onBack: quote == nil ? onBack : { withAnimation(.smooth) { quote = nil } }) {
            if let q = quote, let addr = q.depositAddress { depositView(q, addr) } else { form }
        } foot: {
            if quote == nil {
                Button { getAddress() } label: {
                    HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Asking NEAR Intents" : "Get deposit address") }
                }
                .buttonStyle(WideButton()).disabled(busy || src == nil || value <= 0 || refundAddress.isEmpty || wallet == nil)
            }
        }
        .task { do { tokens = try await OneClick().tokens() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "NEAR Intents didn't answer." } }
    }

    @ViewBuilder private var form: some View {
        if tokens.isEmpty && error == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading what NEAR Intents accepts").font(.system(size: 13)).foregroundStyle(Theme.muted) }
        } else if !tokens.isEmpty {
            FormField(label: "You send") {
                MenuField(selection: $source, options: options.map(\.assetId), title: { id in tokens.first { $0.assetId == id }.map(label) ?? id },
                          logo: { id in tokens.first { $0.assetId == id }.map { $0.assetId == IntentsAssets.wrappedNear ? "near" : $0.symbol } })
            }
            FormField(label: "About how much", trailing: src?.price.map { p in value > 0 ? "≈ \(MoneyFmt.usd(value * p, digits: 2))" : "1 = \(MoneyFmt.usdSmart(p))" }) {
                AmountTextField(text: $amount)
            }
            if ownRefund == nil, let s = src {
                FormField(label: "Your \(Self.chainNames[s.blockchain] ?? s.blockchain) address for refunds") {
                    BoxedTextField(placeholder: "Refund address", text: $refund, mono: true)
                }
            } else if let r = ownRefund {
                DetailLines(lines: [("Refunds go to", "This wallet, \(shortAddr(r))")])
            }
            NoteBox(symbol: "info.circle", text: "NEAR Intents gives you a one-time address on that chain. Send from any exchange or wallet; solvers swap it and pay out to your own \(dest.place.name) address.")
        }
        if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder private func depositView(_ q: IntentsQuote, _ addr: String) -> some View {
        let s = src
        let state = act.state(addr)
        VStack(spacing: 12) {
            AddressQR(text: addr)
                .frame(width: 180, height: 180)
                .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
                .overlay { LogoMark(s.map { $0.assetId == IntentsAssets.wrappedNear ? "near" : $0.symbol } ?? "", size: 34).padding(3).background(.white, in: Circle()) }
            Text(shortAddr(addr, keep: 9)).font(.system(size: 14, design: .monospaced)).lineLimit(1).accessibilityLabel(addr)
            HStack(spacing: 8) {
                Button { Clip.copy(addr); model.toast("Deposit address copied") } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(OutlineButton())
                ShareLink(item: addr) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(OutlineButton())
            }
        }
        .frame(maxWidth: .infinity)
        if let memo = q.depositMemo {
            Button { Clip.copy(memo); model.toast("Memo copied") } label: {
                Label("Memo required: \(memo)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amber)
            }.buttonStyle(.plain)
        }
        DetailLines(lines: [
            ("Send", "\(q.request.swapType == .flexInput ? "from \(Units.format(q.minAmountIn, decimals: s?.decimals ?? 8))" : "exactly \(q.amountInFormatted)") \(s.map(label) ?? "")"),
            ("You get about", "\(IntentsFmt.amount(q.amountOutFormatted)) \(dest.symbol) on \(dest.place.name)"),
            ("Address valid until", q.deadline?.formatted(date: .omitted, time: .shortened) ?? "the quote deadline"),
            ("Route", "NEAR Intents (1Click)"),
        ])
        IntentsProgress(swap: act.swaps.first { $0.depositAddress == addr }, state: state, external: true)
        if !(q.signatureValid) {
            NoteBox(symbol: "exclamationmark.triangle", text: "This quote's 1Click signature didn't check out on this phone. It came straight from 1Click over HTTPS.", tint: Theme.amber)
        }
    }

    private func getAddress() {
        guard let s = src, let w = wallet?.record else { return }
        busy = true; error = nil
        let place = dest.place, sym = dest.symbol, refundTo = refundAddress, list = tokens
        let recipient: String? = {
            switch place { case .chain(let c): let a = w.address(on: c); return a.isEmpty ? nil : a; case .hyperliquid: return w.evmAddress; case .bitcoin: return nil }
        }()
        Task {
            defer { busy = false }
            do {
                guard let rcpt = recipient else { throw WalletError.blocked("Add a NEAR account to this wallet first.") }
                guard let d = IntentsAssets.token(sym, at: place, in: list, hermitToken: place.chain?.token(sym)) else {
                    throw WalletError.blocked("NEAR Intents doesn't list \(sym) on \(place.name).")
                }
                let amt = try Units.parse(String(format: "%.\(min(s.decimals, 10))f", value), decimals: s.decimals)
                var req = IntentsQuoteRequest(dry: false, swapType: .flexInput, originAsset: s.assetId, destinationAsset: d.assetId, amount: amt,
                                              recipient: rcpt, refundTo: refundTo, deadline: Date().addingTimeInterval(2 * 3600))
                let q: IntentsQuote
                do { q = try await OneClick().quote(req) } catch let e as OneClickError where e.message.contains("swapType") {
                    req.swapType = .exactInput   // Hyperliquid USDC takes EXACT_INPUT / EXACT_OUTPUT only
                    q = try await OneClick().quote(req)
                }
                guard let addr = q.depositAddress else { throw WalletError.badResponse("1Click returned no deposit address") }
                WalletService.intentsLedger.upsert(TrackedSwap(depositAddress: addr, depositMemo: q.depositMemo, walletID: w.id,
                                                               from: "\(q.amountInFormatted) \(label(s))", to: "about \(IntentsFmt.amount(q.amountOutFormatted)) \(sym)",
                                                               fromChainID: nil, toPlaceName: place.name, deadline: q.deadline, external: true))
                act.reload(); act.track(addr)
                withAnimation(.smooth) { quote = q }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
