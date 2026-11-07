import SwiftUI
import HermitCore
import HermitWallet

/// Swap on one network, or bridge to another (same sheet, pick a different "To" network). Quotes come from LI.FI and
/// refresh as you type; Review shows what you get, the minimum after slippage, the route and fees, then Face ID signs
/// the approve (if needed) and the swap.
struct SwapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    @State private var walletID: String
    @State private var fromChain: Chain
    @State private var toChain: Chain
    @State private var fromSym: String
    @State private var toSym: String
    @State private var amount = ""
    @State private var quote: LiFi.Quote?
    @State private var quoting = false
    @State private var error: String?

    static let chains: [Chain] = Chain.mainnets.filter { $0.kind == .evm }

    init(vm: WalletsViewModel, fromID: String, bridge: Bool, token: String? = nil, chain: Chain? = nil) {
        self.vm = vm
        _walletID = State(initialValue: vm.wallet(fromID)?.id ?? vm.firstWalletID ?? "")
        let from = chain.flatMap { $0.kind == .evm ? $0 : nil } ?? .base
        _fromChain = State(initialValue: from)
        _toChain = State(initialValue: bridge ? (from == .arbitrum ? .base : .arbitrum) : from)
        _fromSym = State(initialValue: token ?? "USDC")
        _toSym = State(initialValue: token == from.nativeSymbol ? "USDC" : from.nativeSymbol)
    }

    private func symbols(_ c: Chain) -> [String] { [c.nativeSymbol] + c.tokens.map(\.symbol) }
    private func token(_ s: String, _ c: Chain) -> Token? { s == c.nativeSymbol ? nil : c.token(s) }
    private var held: Holding? { vm.holding(fromSym, wallet: walletID, chain: fromChain) }
    private var value: Double { AmountText.value(amount) ?? 0 }
    private var bridging: Bool { fromChain != toChain }
    private var quoteKey: String { "\(walletID)|\(fromChain.id)|\(fromSym)|\(toChain.id)|\(toSym)|\(amount)" }

    var body: some View {
        SheetChrome(title: bridging ? "Bridge" : "Swap", subtitle: bridging ? "\(fromChain.name) to \(toChain.name)" : "On \(fromChain.name)") {
            box("From", trailing: "\(held?.exact ?? "0") available") {
                HStack(spacing: 8) {
                    AmountTextField(text: $amount)
                    MenuField(selection: $fromSym, options: symbols(fromChain), title: { $0 }, logo: { $0 }).frame(maxWidth: 120)
                }
                MenuField(selection: $fromChain, options: Self.chains, title: { $0.name }, logo: { $0.logo })
            }
            WrapRow {
                ForEach([("25%", 0.25), ("50%", 0.5)], id: \.0) { q in
                    SelectChip(title: q.0, on: amount == fractionText(held, q.1) && (held?.amount ?? 0) > 0) { amount = fractionText(held, q.1) }
                }
                SelectChip(title: "Max", on: amount == (held?.exact ?? "") && (held?.amount ?? 0) > 0) { amount = held?.exact ?? "0" }
                Spacer(minLength: 0)
                Button { flip() } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(PressStyle()).frame(width: 30, height: 30).background(Theme.hover, in: Circle()).accessibilityLabel("Swap direction")
            }
            box("To", trailing: quote.map { "min. " + Units.format($0.toAmountMin, decimals: $0.toDecimals, maxFraction: 6) }) {
                HStack(spacing: 8) {
                    Group {
                        if quoting { ProgressView().controlSize(.small) }
                        else { Text(quote.map { Units.format($0.toAmount, decimals: $0.toDecimals, maxFraction: 6) } ?? "0") }
                    }
                    .font(.system(size: 14)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).modifier(FieldBox())
                    MenuField(selection: $toSym, options: symbols(toChain), title: { $0 }, logo: { $0 }).frame(maxWidth: 120)
                }
                MenuField(selection: $toChain, options: Self.chains, title: { $0.name }, logo: { $0.logo })
            }
            if let q = quote {
                DetailLines(lines: [("Route", q.tool), ("Fees", MoneyFmt.usd(q.feeUSD + q.gasUSD, digits: 2) + " incl. network"),
                                    ("Time", q.seconds < 60 ? "Under a minute" : "About \(q.seconds / 60) min")])
            }
            if value > (held?.amount ?? 0), value > 0 {
                Text("Only \(held?.exact ?? "0") \(fromSym) on \(fromChain.name).").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button("Review") { review() }
                .buttonStyle(WideButton())
                .disabled(quote == nil || quoting || value <= 0 || value > (held?.amount ?? 0))
        }
        .onChange(of: fromChain) { _, c in if !symbols(c).contains(fromSym) { fromSym = c.nativeSymbol } }
        .onChange(of: toChain) { _, c in if !symbols(c).contains(toSym) { toSym = c.nativeSymbol } }
        .task(id: quoteKey) { await requote() }
    }

    private func box<C: View>(_ label: String, trailing: String? = nil, @ViewBuilder _ c: @escaping () -> C) -> some View {
        FormField(label: label, trailing: trailing) { VStack(spacing: 8) { c() } }
    }

    private func flip() {
        let (c, s) = (fromChain, fromSym)
        fromChain = toChain; fromSym = toSym; toChain = c; toSym = s; amount = ""
    }

    private func requote() async {
        quote = nil; error = nil
        let tok = token(fromSym, fromChain)
        guard value > 0, !(fromChain == toChain && fromSym == toSym), let w = vm.wallet(walletID), let addr = w.evmAddress,
              let amt = try? Units.parse(amount, decimals: tok?.decimals ?? 18) else { return }
        try? await Task.sleep(for: .milliseconds(450))   // wait for typing to settle
        guard !Task.isCancelled else { return }
        quoting = true; defer { quoting = false }
        do {
            let q = try await LiFi.quote(from: fromChain, to: toChain, fromToken: tok, toToken: token(toSym, toChain), amount: amt, address: addr)
            if !Task.isCancelled { quote = q }
        } catch {
            if !Task.isCancelled { self.error = (error as? WalletError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func review() {
        guard let q = quote, let w = vm.wallet(walletID), let owner = EVMAddress(w.record.evmAddress) else { return }
        let fromTok = token(fromSym, fromChain), chain = fromChain, svc = vm.service, wid = w.record.id
        let out = Units.format(q.toAmount, decimals: q.toDecimals, maxFraction: 6), min = Units.format(q.toAmountMin, decimals: q.toDecimals, maxFraction: 6)
        Task {
            let allowance: UInt128
            if let t = fromTok, let spender = q.approvalAddress {
                allowance = (try? await svc.allowance(chain: chain, token: EVMAddress(t.address)!, owner: owner, spender: spender)) ?? 0
            } else { allowance = .max }
            let calls = LiFi.calls(q, token: fromTok, allowance: allowance)
            ask(Approval(kind: bridging ? "Bridge" : "Swap on \(chain.name)",
                         title: "\(amount) \(fromSym) to \(toSym)",
                         lines: [["You pay", "\(amount) \(fromSym) on \(fromChain.name)"], ["You get", "about \(out) \(toSym) on \(toChain.name)"],
                                 ["At least", "\(min) \(toSym) (0.5% slippage)"], ["Route", q.tool],
                                 ["Fees", MoneyFmt.usd(q.feeUSD + q.gasUSD, digits: 2)],
                                 ["Steps", calls.count == 2 ? "Allow, then swap (two Face ID prompts)" : "One transaction"]],
                         checks: ["Each step is simulated before it's signed", "Signed on this phone with your wallet's key"],
                         success: bridging ? "Bridge sent. Funds arrive on \(toChain.name) shortly." : "Swapped \(fromSym) to \(toSym)") {
                try await svc.executeCalls(walletID: wid, chain: chain, calls).last ?? ""
            }) { Task { await vm.refresh() } }
        }
    }
}
