import SwiftUI
import HermitCore
import HermitWallet

/// Add funds from any chain NEAR Intents supports: the user picks what they'll send (BTC, ETH, SOL, USDT on Tron, …),
/// Hermit asks 1Click for a real quote with a one-time deposit address, shows it as a QR code, and follows the deposit
/// until it lands in the wallet as whatever you pick under "You get" (NEAR, USDC, ETH or SOL, on the network you
/// choose; USDC on Base by default) or as USDC in Hyperliquid perps. Start over hides the address and asks for a new one; the
/// old one stays tracked, since money sent to it still swaps. Sent from an exchange or any other wallet; nothing is signed in Hermit.
struct AnyChainFundView: View {
    let goal: FundGoal
    var onBack: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var tokens: [IntentsToken] = []
    @State private var source: String = "nep141:btc.omft.near"
    @State private var amount = ""
    @State private var refund = ""
    @State private var quote: IntentsQuote?
    /// The user read the unsigned-quote warning and said they checked the quote with 1Click. Reset with every new quote.
    @State private var checkedUnsigned = false
    @State private var busy = false
    @State private var error: String?
    /// Counts copies, for the haptic.
    @State private var copies = 0
    @State private var target = Target(chain: .base, symbol: "USDC")
    @Environment(\.dismiss) private var dismiss

    /// What a plain top-up can arrive as.
    struct Target: Hashable { let chain: Chain; let symbol: String }
    static let targets: [Target] = [
        Target(chain: .near, symbol: "NEAR"), Target(chain: .base, symbol: "USDC"), Target(chain: .arbitrum, symbol: "USDC"),
        Target(chain: .solana, symbol: "USDC"), Target(chain: .base, symbol: "ETH"), Target(chain: .arbitrum, symbol: "ETH"),
        Target(chain: .ethereum, symbol: "ETH"), Target(chain: .solana, symbol: "SOL"),
    ]
    private var vm: WalletsViewModel { .shared }
    private var act: IntentsActivity { .shared }

    private var wallet: WalletAccount? { vm.wallets.first }
    private var src: IntentsToken? { tokens.first { $0.assetId == source } }
    private var dest: (place: IntentsPlace, symbol: String) {
        switch goal {
        case .hyperliquid: (.hyperliquid, "USDC")
        case .token(let c, let s): (.chain(c), s)
        case .wallet: (.chain(target.chain), target.symbol)
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
                    subtitle: "Arrives as \(dest.symbol) on \(dest.place.name)", onBack: quote == nil ? onBack : { withAnimation(.smooth) { quote = nil; checkedUnsigned = false } }) {
            if let q = quote, let addr = q.depositAddress { depositView(q, addr) } else { form }
        } foot: {
            if let q = quote, let addr = q.depositAddress {
                let waiting = (act.state(addr)?.status ?? .pendingDeposit) == .pendingDeposit
                if waiting {
                    Button("Start over") { startOver(addr) }.buttonStyle(WideButton(kind: .plain))
                }
                // An unsigned quote: no "I've sent it" until the user says they checked it with 1Click.
                if !waiting || q.signatureValid || checkedUnsigned {
                    Button(waiting ? "I've sent it" : "Done") { dismiss() }.buttonStyle(WideButton())
                }
            }
            if quote == nil {
                Button { getAddress() } label: {
                    HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Asking NEAR Intents" : "Get deposit address") }
                }
                .buttonStyle(WideButton()).disabled(busy || src == nil || value <= 0 || refundAddress.isEmpty || wallet == nil)
            }
        }
        .task { do { tokens = try await OneClick().tokens() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "NEAR Intents didn't answer." } }
        .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: copies)
    }

    @ViewBuilder private var form: some View {
        if tokens.isEmpty && error == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading what NEAR Intents accepts").font(.system(size: 13)).foregroundStyle(Theme.muted) }
        } else if !tokens.isEmpty {
            FormField(label: "You send") {
                MenuField(selection: $source, options: options.map(\.assetId), title: { id in tokens.first { $0.assetId == id }.map(label) ?? id },
                          logo: { id in tokens.first { $0.assetId == id }.map { $0.assetId == IntentsAssets.wrappedNear ? "near" : $0.symbol } })
            }
            if goal == .wallet {
                FormField(label: "You get") {
                    MenuField(selection: $target, options: Self.targets, title: { "\($0.symbol) on \($0.chain.name)" }, logo: { $0.symbol })
                }
            }
            // A price of 0 means 1Click has none for this token: show nothing rather than "≈ $0.00".
            FormField(label: "About how much", trailing: src?.price.flatMap { $0 > 0 ? $0 : nil }.map { p in value > 0 ? "≈ \(MoneyFmt.usd(value * p, digits: 2))" : "1 = \(MoneyFmt.usdSmart(p))" }) {
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
            if !vm.holdings(wallet: wallet?.id, chain: nil).isEmpty {
                HStack(spacing: 10) {
                    Text("Coins already in Hermit? Swap them instead, no deposit address needed.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Open Swap") { openSwap() }.buttonStyle(OutlineButton())
                }
            }
        }
        if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder private func depositView(_ q: IntentsQuote, _ addr: String) -> some View {
        let s = src
        let state = act.state(addr)
        let unsignedNote = "This quote's 1Click signature didn't check out on \(Device.here), so nothing proves this address came from 1Click. Check the amount and the address with 1Click before you send."
        if !q.signatureValid && !checkedUnsigned {
            // Nothing proves the address is 1Click's: the warning comes first, and the address only after the user checked.
            NoteBox(symbol: "exclamationmark.triangle", text: unsignedNote, tint: Theme.amber)
            Button("I've checked it") { withAnimation(.smooth) { checkedUnsigned = true } }.buttonStyle(OutlineButton())
        } else {
            VStack(spacing: 12) {
                AddressQR(text: addr)
                    .frame(width: 180, height: 180)
                    .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
                    .overlay { LogoMark(s.map { $0.assetId == IntentsAssets.wrappedNear ? "near" : $0.symbol } ?? "", size: 34).padding(3).background(.white, in: Circle()) }
                Text(shortAddr(addr, keep: 9)).font(.system(size: 14, design: .monospaced)).lineLimit(1).accessibilityLabel(addr)
                HStack(spacing: 8) {
                    Button { Clip.copy(addr); copies += 1; model.toast("Deposit address copied") } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(OutlineButton())
                    ShareLink(item: addr) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(OutlineButton())
                }
            }
            .frame(maxWidth: .infinity)
            if let memo = q.depositMemo {
                Button { Clip.copy(memo); model.toast("Memo copied") } label: {
                    Label("Memo required: \(memo)", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amber)
                }.buttonStyle(.plain)
            }
        }
        DetailLines(lines: [
            ("Send", "\(q.request.swapType == .flexInput ? "from \(Units.format(q.minAmountIn, decimals: s?.decimals ?? 8))" : "exactly \(q.amountInFormatted)") \(s.map(label) ?? "")"),
            ("You get about", "\(IntentsFmt.amount(q.amountOutFormatted)) \(dest.symbol) on \(dest.place.name)"),
            ("Address valid until", q.deadline?.formatted(date: .omitted, time: .shortened) ?? "the quote deadline"),
            ("Route", "NEAR Intents (1Click)"),
        ])
        IntentsProgress(swap: act.swaps.first { $0.depositAddress == addr }, state: state, external: true)
        if !q.signatureValid && checkedUnsigned {
            NoteBox(symbol: "exclamationmark.triangle", text: unsignedNote, tint: Theme.amber)
        }
    }

    /// Back to the form for a new address. The old one is only hidden, never forgotten: Hermit can't know nothing was
    /// sent to it, and anything that was still swaps, so it stays tracked and in Activity. Unused, it expires on its own.
    private func startOver(_ addr: String) {
        act.hide(addr)
        withAnimation(.smooth) { quote = nil; checkedUnsigned = false }
        model.toast("Address hidden. If you already sent funds, they still arrive and show in Activity.")
    }

    private func openSwap() {
        dismiss()
        model.fundGoal = nil
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); model.open(.wallets, tab: "swap") }
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
                checkedUnsigned = false
                withAnimation(.smooth) { quote = q }
            } catch {
                // A route minimum is said in the token the user sends.
                self.error = (error as? OneClickError)?.minimumText(decimals: s.decimals, symbol: s.symbol)
                    ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
