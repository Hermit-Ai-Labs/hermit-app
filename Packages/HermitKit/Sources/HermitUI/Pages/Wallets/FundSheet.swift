import SwiftUI
import HermitCore
import HermitWallet

/// What the money is for. Every "Deposit / Add funds" in the app opens FundSheet with one of these.
enum FundGoal: Identifiable, Hashable {
    case wallet                       // just fund the wallet (Wallets → Add funds)
    case hyperliquid                  // margin for Trade
    case token(Chain, String)         // e.g. USDC on Base for an Aave pool, USDC.e on Polygon for Polymarket

    var id: String {
        switch self { case .wallet: "wallet"; case .hyperliquid: "hl"; case .token(let c, let s): "\(c.id)-\(s)" }
    }
    var place: Relay.Place {
        switch self { case .hyperliquid: .hyperliquid; case .token(let c, _): .chain(c); case .wallet: .chain(.base) }
    }
    var symbol: String { switch self { case .token(_, let s): s; default: "USDC" } }
    var title: String {
        switch self {
        case .wallet: "Add funds"
        case .hyperliquid: "Fund Hyperliquid"
        case .token(let c, let s): "Get \(s) on \(c.name)"
        }
    }
    /// The token on the destination chain (nil = native coin, or Hyperliquid USDC).
    var token: Token? { if case .token(let c, let s) = self { return s == c.nativeSymbol ? nil : c.token(s) }; return nil }
}

/// Funding, start to finish, for someone with nothing, with money on another chain, or already set:
/// 1. Source: balances already in the wallet (any chain, any token), or "from an exchange / another wallet".
/// 2. Amount: presets, a live Relay quote (what arrives, fee, time), Review, Face ID.
/// 3. Receive: QR codes per network family, copy, share, an exchange how-to; watches the balance and jumps back
///    to Amount the moment money lands.
struct FundSheet: View {
    let goal: FundGoal
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .source
    @State private var source: Holding?
    @State private var amount = ""
    @State private var quote: Relay.Quote?
    @State private var quoting = false
    @State private var error: String?
    @State private var family: Family = .evm
    @State private var baseline: Set<String> = []
    private var vm: WalletsViewModel { .shared }
    private var hl: HyperliquidStore { .shared }

    enum Stage { case source, amount, receive, anyChain }
    /// Set just before opening: start on "From any chain" (deep link `wallets/fund-any`).
    @MainActor static var startAnyChain = false
    @State private var anyBack: Stage = .source
    enum Family: String, CaseIterable { case evm = "EVM networks", solana = "Solana", near = "NEAR" }

    private var wallet: WalletAccount? { vm.wallets.first }
    /// Balances worth moving, biggest first; the goal's own token on its own chain is left out (it's already there).
    private var sources: [Holding] {
        vm.holdings(wallet: wallet?.id, chain: nil)
            .filter { !$0.chain.isTestnet && Relay.Place.chain($0.chain).relayID != nil && ($0.usd >= 1 || !$0.priced) }
            .filter { h in if case .token(let c, let s) = goal { return !(h.chain == c && h.symbol == s) }; return true }
            .sorted { $0.usd > $1.usd }
    }

    var body: some View {
        Group {
            switch stage {
            case .source: sourceView
            case .amount: amountView
            case .receive: receiveView
            case .anyChain: AnyChainFundView(goal: goal, onBack: { withAnimation(.smooth) { stage = anyBack } })
            }
        }
        .animation(.smooth(duration: 0.25), value: stage)
        .task {
            if vm.wallets.isEmpty { return }
            if Self.startAnyChain { Self.startAnyChain = false; anyBack = .receive; stage = .anyChain; return }
            if !vm.loaded { await vm.refresh() }
            if sources.isEmpty && goal != .wallet { stage = .receive }
            if goal == .wallet { stage = .receive }
        }
    }

    // MARK: 1. Source

    private var sourceView: some View {
        SheetChrome(title: goal.title, subtitle: goalLine) {
            if case .hyperliquid = goal, let a = hl.account {
                DetailLines(lines: [("On Hyperliquid now", "$" + a.withdrawable.tradeGrouped(2))])
            }
            if !sources.isEmpty {
                SectionLabel(text: "From your wallet") { EmptyView() }
                VStack(spacing: 0) {
                    ForEach(sources) { h in
                        Button { pick(h) } label: { holdingRow(h) }.buttonStyle(.plain)
                    }
                }
            }
            SectionLabel(text: sources.isEmpty ? "Your wallet is empty" : "Or add more") { EmptyView() }
            Button { withAnimation(.smooth) { stage = .receive } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode").font(.system(size: 16, weight: .medium)).frame(width: 38, height: 38)
                        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From an exchange or another wallet").font(.system(size: 14, weight: .medium))
                        Text("Show my address and QR code").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            anyChainRow(back: .source)
        }
    }

    /// BTC, Tron USDT, TON… anything NEAR Intents takes: a one-time deposit address that pays out here.
    private func anyChainRow(back: Stage) -> some View {
        Button { anyBack = back; withAnimation(.smooth) { stage = .anyChain } } label: {
            HStack(spacing: 12) {
                LogoMark("near", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("From any chain, via NEAR Intents").font(.system(size: 14, weight: .medium))
                    Text("BTC, ETH, SOL, USDT on Tron and 200 more").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var goalLine: String {
        switch goal {
        case .wallet: "Into your wallet"
        case .hyperliquid: "USDC margin for trading"
        case .token(let c, let s): "\(s) on \(c.name)"
        }
    }

    private func holdingRow(_ h: Holding) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                MarketLogo(key: TradeData.logo(h.symbol), name: h.symbol, size: 34)
                LogoMark(h.chain.logo, size: 15).padding(1.5).background(Theme.bg, in: Circle()).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(h.symbol) on \(h.chain.name)").font(.system(size: 14, weight: .medium))
                Text("\(MoneyFmt.amount(h.amount)) \(h.symbol)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            Spacer()
            Text(h.priced ? MoneyFmt.usd(h.usd, digits: 2) : "—").font(.system(size: 14, weight: .medium)).monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 10).contentShape(Rectangle())
    }

    private func pick(_ h: Holding) {
        source = h; amount = ""; quote = nil; error = nil
        withAnimation(.smooth) { stage = .amount }
    }

    // MARK: 2. Amount

    private var amountView: some View {
        let h = source
        let value = AmountText.value(amount) ?? 0
        return SheetChrome(title: "Move to \(goal.place.name)", subtitle: h.map { "From \($0.symbol) on \($0.chain.name)" },
                           onBack: { withAnimation(.smooth) { stage = .source } }) {
            if let h {
                FormField(label: "Amount (\(h.symbol))", trailing: "\(MoneyFmt.amount(h.amount)) available") { AmountTextField(text: $amount) }
                WrapRow {
                    ForEach([("25%", 0.25), ("50%", 0.5)], id: \.0) { q in
                        SelectChip(title: q.0, on: amount == fractionText(h, q.1)) { amount = fractionText(h, q.1) }
                    }
                    SelectChip(title: "Max", on: amount == h.exact) { amount = h.symbol == h.chain.nativeSymbol ? fractionText(h, 0.97) : h.exact }
                }
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).background(Theme.hover, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You get").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        HStack(spacing: 6) {
                            if quoting { ProgressView().controlSize(.small) }
                            Text(quote.map { "\($0.amountOut) \(goal.symbol)" } ?? "—").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                        }
                        Text("on \(goal.place.name)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    LogoMark(goal.place.logo, size: 30)
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
                if let q = quote {
                    DetailLines(lines: [("Fee", MoneyFmt.usd(q.feeUSD, digits: 2)), ("Arrives", q.seconds <= 60 ? "In under a minute" : "In about \(q.seconds / 60) min"),
                                        ("Route", "Relay")])
                }
                if value > h.amount { Text("Only \(h.exact) \(h.symbol) available.").font(.system(size: 12.5)).foregroundStyle(Theme.red) }
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            }
        } foot: {
            Button("Review") { review() }.buttonStyle(WideButton())
                .disabled(quote == nil || quoting || value <= 0 || value > (h?.amount ?? 0))
        }
        .task(id: "\(h?.id ?? "")|\(amount)") { await requote() }
    }

    private func requote() async {
        quote = nil; error = nil
        guard let h = source, let w = wallet, let v = AmountText.value(amount), v > 0, v <= h.amount else { return }
        let tok = h.symbol == h.chain.nativeSymbol ? nil : h.chain.token(h.symbol)
        guard let amt = try? Units.parse(AmountText.clean(amount), decimals: tok?.decimals ?? h.chain.nativeDecimals) else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        quoting = true; defer { quoting = false }
        let user = h.chain.kind == .solana ? w.record.solanaAddress : w.record.evmAddress
        let recipient: String = {
            if case .token(let c, _) = goal, c.kind == .solana { return w.record.solanaAddress }
            return w.record.evmAddress
        }()
        do {
            let q = try await Relay.quote(from: .chain(h.chain), fromToken: tok, to: goal.place, toToken: goal.token, amount: amt,
                                          user: user, recipient: recipient)
            if !Task.isCancelled { quote = q }
        } catch {
            if !Task.isCancelled { self.error = (error as? WalletError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func review() {
        guard let q = quote, let h = source, let w = wallet else { return }
        let svc = vm.service, wid = w.record.id, dest = goal.place.name, sym = goal.symbol
        let txs = q.steps.reduce(0) { n, s in if case .evm(_, let c) = s { return n + c.count }; return n + 1 }
        ask(Approval(kind: "Move funds", title: "\(amount) \(h.symbol) to \(dest)",
                     lines: [["From", "\(amount) \(h.symbol) on \(h.chain.name)"], ["To", "about \(q.amountOut) \(sym) on \(dest)"],
                             ["Fee", MoneyFmt.usd(q.feeUSD, digits: 2)], ["Arrives", q.seconds <= 60 ? "Under a minute" : "About \(q.seconds / 60) min"],
                             ["Steps", txs > 1 ? "\(txs) transactions, one \(Device.bio) each" : "One transaction"], ["Route", "Relay"]],
                     checks: ["Every step is simulated before it's signed", "Signed on \(Device.here) with your wallet's key"],
                     success: "On its way to \(dest)") {
            try await svc.execute(q, walletID: wid)
        }) {
            Task { try? await Task.sleep(for: .seconds(4)); await vm.refresh(); await hl.refresh() }
        }
    }

    // MARK: 3. Receive

    private var receiveView: some View {
        let evm = wallet?.record.evmAddress ?? "", sol = wallet?.record.solanaAddress ?? "", near = wallet?.record.nearAccount ?? ""
        let addr = family == .evm ? evm : family == .solana ? sol : near
        return SheetChrome(title: goal == .wallet ? "Add funds" : "Add money to your wallet",
                           subtitle: "Send crypto to this address",
                           onBack: goal == .wallet || sources.isEmpty ? nil : { withAnimation(.smooth) { stage = .source } }) {
            Segmented(options: Family.allCases.map { ($0, $0.rawValue) }, selection: $family).frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                AddressQR(text: addr)
                    .frame(width: 190, height: 190)
                    .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
                    .overlay { LogoMark(family == .evm ? "ethereum" : family == .solana ? "solana" : "near", size: 36).padding(3).background(.white, in: Circle()) }
                    .id(addr).transition(.opacity)
                    .opacity(addr.isEmpty ? 0.15 : 1)
                if addr.isEmpty {
                    Text("This wallet has no NEAR account yet. Add it in Wallets (one Face ID).").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                if family == .near && !addr.isEmpty {
                    Text("Your NEAR account. It becomes active with its first NEAR (about 0.01 is enough).").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                if family == .evm {
                    ChainStack(chains: Chain.evmMainnets.filter { $0.id != "robinhood" }, size: 18)
                    Text("Same address on Ethereum, Base, Arbitrum, BNB, Polygon and Monad").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                Text(shortAddr(addr, keep: 8)).font(.system(size: 14, design: .monospaced)).lineLimit(1)
                    .accessibilityLabel(addr)
                HStack(spacing: 8) {
                    Button { Clip.copy(addr); model.toast("Address copied") } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(OutlineButton())
                    ShareLink(item: addr, subject: Text("My wallet address"), message: Text("\(family.rawValue) address")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(OutlineButton())
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Watching for incoming funds. This moves on by itself when they land.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            anyChainRow(back: .receive)
            NoteBox(symbol: "lightbulb", text: tip)
            DisclosureGroup("From an exchange, step by step") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(binanceSteps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18).background(Theme.hover, in: Circle())
                            Text(s).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 13.5, weight: .medium)).tint(Theme.text)
        }
        .task(id: "watch") { await watch() }
    }

    private var tip: String {
        switch goal {
        case .hyperliquid: "Cheapest: send USDC on Arbitrum or Base. Hermit moves it to Hyperliquid for you, usually for a few cents."
        case .token(let c, let s): "Send \(s) on \(c.name) directly, or any coin on any network listed: Hermit can convert it."
        case .wallet: "Pick the right network when you send: USDC on Base or Arbitrum costs cents; Ethereum costs dollars."
        }
    }

    private var binanceSteps: [String] {
        ["In your exchange app, open Withdraw (or Send).", "Choose USDC (or the coin you have).",
         family == .evm ? "Network: Arbitrum One or Base. Paste the address above."
            : family == .solana ? "Network: Solana. Paste the Solana address above." : "Network: NEAR. Paste the NEAR account above (no memo needed).",
         "Withdraw, then come back here. It usually lands in 1–3 minutes."]
    }

    /// Re-reads balances every 8 seconds; when a holding appears or grows, picks it and moves to Amount
    /// (or, for a plain wallet top-up, says it arrived).
    private func watch() async {
        baseline = Set(sources.map { "\($0.id)|\($0.exact)" })
        while !Task.isCancelled && stage == .receive {
            try? await Task.sleep(for: .seconds(8))
            await vm.refresh()
            if let new = sources.first(where: { !baseline.contains("\($0.id)|\($0.exact)") }) {
                #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                #endif
                model.toast("\(MoneyFmt.amount(new.amount)) \(new.symbol) arrived on \(new.chain.name)")
                if goal == .wallet { dismiss(); return }
                pick(new); return
            }
        }
    }
}
