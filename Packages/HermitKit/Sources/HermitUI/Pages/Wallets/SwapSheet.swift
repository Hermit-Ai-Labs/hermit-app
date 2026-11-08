import SwiftUI
import HermitCore
import HermitWallet

/// Swap or bridge any token Hermit holds on any of its chains (EVM, Solana, NEAR) to any token NEAR Intents lists on
/// another, Bitcoin and Hyperliquid included. Quotes come from NEAR Intents (1Click) and Relay at the same time; the
/// bigger output wins and the route is named. An Intents swap is one plain transfer to a one-time deposit address
/// (through the approval sheet), then live status until it lands, or is refunded.
///
/// `preview` is "Try a quote": dry quotes only, no funds needed, nothing can be signed.
struct SwapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    let preview: Bool
    let origin: ActionOrigin
    @State private var walletID: String
    @State private var fromChain: Chain
    @State private var to: IntentsPlace
    @State private var fromSym: String
    @State private var toSym: String
    @State private var amount = ""
    @State private var btcAddress = ""
    @State private var confidential = false
    @State private var tokens: [IntentsToken] = []
    @State private var intents: IntentsQuote?
    @State private var relay: Relay.Quote?
    @State private var intentsError: String?
    @State private var relayError: String?
    @State private var quoting = false
    @State private var reviewing = false
    @State private var error: String?
    @State private var addingNear = false

    static let chains: [Chain] = Chain.mainnets.filter { IntentsPlace.chain($0).blockchain != nil || Relay.Place.chain($0).relayID != nil }
    static let places: [IntentsPlace] = IntentsPlace.all

    init(vm: WalletsViewModel, fromID: String, bridge: Bool, token: String? = nil, chain: Chain? = nil, preview: Bool = false,
         intent: SwapIntent? = nil) {
        self.vm = vm
        self.preview = preview
        origin = intent?.origin ?? .user
        _walletID = State(initialValue: vm.wallet(fromID)?.id ?? vm.firstWalletID ?? "")
        // Opened plainly (Swap or Bridge button): start from the biggest balance the wallet can actually swap, not an
        // empty USDC on Base.
        let wid = vm.wallet(fromID)?.id ?? vm.firstWalletID ?? ""
        let biggest = (intent == nil && token == nil && chain == nil && !preview)
            ? vm.holdings(wallet: wid, chain: nil)
                .filter { h in !h.chain.isTestnet && h.amount > 0 && Self.chains.contains(h.chain)
                    && (h.symbol == h.chain.nativeSymbol || h.chain.token(h.symbol) != nil) }
                .max { ($0.usd, $0.amount) < ($1.usd, $1.amount) }
            : nil
        let from = intent?.from ?? chain.flatMap { Self.chains.contains($0) ? $0 : nil } ?? biggest?.chain ?? .base
        let fromSymbol = intent?.fromSymbol ?? token ?? biggest?.symbol ?? "USDC"
        let toChain: Chain = bridge ? (from == .arbitrum ? .base : .arbitrum) : from
        _fromChain = State(initialValue: from)
        _to = State(initialValue: intent?.to ?? (preview ? .chain(.near) : .chain(toChain)))
        _fromSym = State(initialValue: fromSymbol)
        let plainTo: String = bridge
            ? (fromSymbol != from.nativeSymbol && toChain.token(fromSymbol) != nil ? fromSymbol : toChain.nativeSymbol)
            : (fromSymbol == from.nativeSymbol ? "USDC" : from.nativeSymbol)
        _toSym = State(initialValue: intent?.toSymbol ?? (preview ? "NEAR" : plainTo))
        _amount = State(initialValue: intent?.amount ?? (preview ? "10" : ""))
    }

    // MARK: Derived

    private var wallet: WalletAccount? { vm.wallet(walletID) }
    private func fromSymbols(_ c: Chain) -> [String] { [c.nativeSymbol] + c.tokens.map(\.symbol).filter { $0 != "wNEAR" } }
    private var toSymbols: [String] {
        let s = IntentsAssets.symbols(at: to, in: tokens)
        return s.isEmpty ? (to.chain.map(fromSymbols) ?? ["USDC"]) : s
    }
    private func token(_ s: String, _ c: Chain) -> Token? { s == c.nativeSymbol ? nil : c.token(s) }
    private var held: Holding? { vm.holding(fromSym, wallet: walletID, chain: fromChain) }
    private var value: Double { AmountText.value(amount) ?? 0 }
    private var bridging: Bool { to.chain != fromChain }
    private var needsNear: Bool { (fromChain.kind == .near || to.chain?.kind == .near) && wallet?.record.nearAccount == nil }
    private var btcValid: Bool { BitcoinAddress.looksValid(btcAddress) }
    private var overBalance: Bool { !preview && value > (held?.amount ?? 0) }
    private var quoteKey: String { "\(walletID)|\(fromChain.id)|\(fromSym)|\(to.id)|\(toSym)|\(amount)|\(btcAddress)|\(confidential)|\(tokens.count)" }

    enum Route { case intents, relay }
    /// The bigger output wins; Intents when only it quoted.
    private var best: Route? {
        switch (intents, relay) {
        case (nil, nil): return nil
        case (_?, nil): return .intents
        case (nil, _?): return .relay
        case (let i?, let r?): return (Double(i.amountOutFormatted) ?? 0) >= (Double(r.amountOut) ?? 0) ? .intents : .relay
        }
    }
    private var outText: String {
        switch best {
        case .intents?: IntentsFmt.amount(intents!.amountOutFormatted)
        case .relay?: IntentsFmt.amount(relay!.amountOut)
        case nil: "0"
        }
    }

    // MARK: Body

    var body: some View {
        SheetChrome(title: preview ? "Try a quote" : bridging ? "Bridge" : "Swap",
                    subtitle: preview ? "Live NEAR Intents prices, no funds needed" : bridging ? "\(fromChain.name) to \(to.name)" : "On \(fromChain.name)") {
            box("From", trailing: preview ? "Preview" : "\(held.map { MoneyFmt.amount($0.amount) } ?? "0") available") {
                HStack(spacing: 8) {
                    AmountTextField(text: $amount)
                    MenuField(selection: $fromSym, options: fromSymbols(fromChain), title: { $0 }, logo: { $0 }).frame(maxWidth: 120)
                }
                MenuField(selection: $fromChain, options: Self.chains, title: { $0.name }, logo: { $0.logo })
            }
            if !preview {
                WrapRow {
                    ForEach([("25%", 0.25), ("50%", 0.5)], id: \.0) { q in
                        SelectChip(title: q.0, on: amount == fractionText(held, q.1) && (held?.amount ?? 0) > 0) { amount = fractionText(held, q.1) }
                    }
                    SelectChip(title: "Max", on: amount == (held?.exact ?? "") && (held?.amount ?? 0) > 0) { amount = held?.exact ?? "0" }
                    Spacer(minLength: 0)
                    flipButton
                }
            }
            box("To") {
                HStack(spacing: 8) {
                    Group {
                        if quoting { ProgressView().controlSize(.small) } else { Text(outText) }
                    }
                    .font(.system(size: 14)).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading).modifier(FieldBox())
                    MenuField(selection: $toSym, options: toSymbols, title: { $0 }, logo: { $0 }).frame(maxWidth: 120)
                }
                MenuField(selection: $to, options: Self.places, title: { $0.name }, logo: { $0.logo })
            }
            if to == .bitcoin {
                FormField(label: "Your Bitcoin address") { BoxedTextField(placeholder: "bc1…", text: $btcAddress, mono: true) }
                if !btcAddress.isEmpty && !btcValid {
                    Label("That doesn't look like a Bitcoin address", systemImage: "exclamationmark.circle").font(.system(size: 12.5)).foregroundStyle(Theme.red)
                }
            }
            if case .hyperliquid = to {
                NoteBox(symbol: "info.circle", text: "Lands as USDC in your Hyperliquid perps balance (your wallet's EVM address).")
            }
            if needsNear { nearPrompt }
            routeDetails
            if overBalance && value > 0 {
                Text("Only \(held?.exact ?? "0") \(fromSym) on \(fromChain.name).").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            if preview {
                if vm.hasFunds {
                    // Money is already here: go from the preview to the real swap.
                    Button("Swap from your wallet") { model.open(.wallets, tab: "swap") }.buttonStyle(WideButton())
                } else {
                    Button("Add funds to swap") { model.fundGoal = .wallet }.buttonStyle(WideButton())
                }
            } else {
                Button { review() } label: {
                    HStack(spacing: 6) {
                        if reviewing { ProgressView().controlSize(.small).tint(.white) }
                        Text(reviewing ? "Getting a live quote" : "Review")
                    }
                }
                .buttonStyle(WideButton())
                .disabled(best == nil || quoting || reviewing || value <= 0 || overBalance || (to == .bitcoin && !btcValid))
            }
        }
        .onChange(of: fromChain) { _, c in if !fromSymbols(c).contains(fromSym) { fromSym = c.nativeSymbol } }
        .onChange(of: to) { _, _ in if !toSymbols.contains(toSym) { toSym = toSymbols.first ?? "USDC" } }
        .onChange(of: tokens.count) { _, _ in if !toSymbols.contains(toSym) { toSym = toSymbols.first ?? toSym } }
        .task { await loadTokens() }
        .task(id: quoteKey) { await requote() }
    }

    private var flipButton: some View {
        Button { flip() } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold)) }
            .buttonStyle(PressStyle()).frame(width: 30, height: 30).background(Theme.hover, in: Circle()).accessibilityLabel("Swap direction")
            .disabled(to.chain == nil)
    }

    /// The winning route's numbers, plus what the other one offered.
    private func routeLines(_ b: Route) -> [(String, String)] {
        var lines: [(String, String)] = []
        let other: String?
        switch b {
        case .intents:
            if let q = intents {
                lines = [("Route", "via NEAR Intents"),
                         ("You get at least", "\(IntentsFmt.amount(Units.format(q.minAmountOut, decimals: decimalsOut))) \(toSym)"),
                         ("Cost", costText(q)), ("Time", IntentsFmt.seconds(q.seconds))]
            }
            other = relay.map { "Relay: \(IntentsFmt.amount($0.amountOut)) \(toSym)" } ?? relayError.map { _ in "Relay: no route" }
        case .relay:
            if let r = relay {
                lines = [("Route", "via Relay"), ("Fees", MoneyFmt.usd(r.feeUSD, digits: 2) + " incl. network"), ("Time", IntentsFmt.seconds(r.seconds))]
            }
            other = intents.map { "NEAR Intents: \(IntentsFmt.amount($0.amountOutFormatted)) \(toSym)" }
        }
        if let other { lines.append(("Also checked", other)) }
        return lines
    }

    @ViewBuilder private var routeDetails: some View {
        if let b = best {
            DetailLines(lines: routeLines(b))
            if b == .intents { confidentialRow }
        } else if !quoting, value > 0, let e = intentsError ?? relayError, !needsNear {
            Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var decimalsOut: Int { IntentsAssets.token(toSym, at: to, in: tokens, hermitToken: to.chain?.token(toSym))?.decimals ?? 6 }

    private func costText(_ q: IntentsQuote) -> String {
        var s = q.costUSD.map { MoneyFmt.usd($0, digits: 2) } ?? "Included"
        if q.appFeeBps > 0 { s += ", incl. \(Double(q.appFeeBps) / 100)% API fee" }
        return s
    }

    @ViewBuilder private var confidentialRow: some View {
        let ok = OneClick.configuredJWT != nil
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Confidential swap").font(.system(size: 13.5, weight: .medium))
                Text(ok ? "Deposit and payout can't be linked on chain." : "Needs a 1Click partner key (Wallets, Security).")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle("Confidential swap", isOn: $confidential).labelsHidden().toggleStyle(.switch).tint(Theme.accent).disabled(!ok)
        }
        .opacity(ok ? 1 : 0.7)
    }

    private var nearPrompt: some View {
        HStack(spacing: 12) {
            LogoMark("near", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a NEAR account").font(.system(size: 13.5, weight: .medium))
                Text("Made from your recovery phrase. One Face ID.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(addingNear ? "Adding" : "Add") { addNear() }.buttonStyle(OutlineButton()).disabled(addingNear)
        }
        .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private func box<C: View>(_ label: String, trailing: String? = nil, @ViewBuilder _ c: @escaping () -> C) -> some View {
        FormField(label: label, trailing: trailing) { VStack(spacing: 8) { c() } }
    }

    private func flip() {
        guard let c = to.chain else { return }
        let s = fromSym
        fromSym = toSymbols.contains(toSym) && fromSymbols(c).contains(toSym) ? toSym : c.nativeSymbol
        toSym = s; amount = ""
        let f = fromChain; fromChain = c; to = .chain(f)
    }

    private func addNear() {
        guard let id = wallet?.record.id else { return }
        addingNear = true
        Task {
            defer { addingNear = false }
            do { _ = try await vm.service.addNearAccount(id); vm.reloadLocal(); model.toast("NEAR account added") }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    // MARK: Quotes

    private func loadTokens() async {
        do { tokens = try await OneClick().tokens() } catch { intentsError = (error as? LocalizedError)?.errorDescription ?? "NEAR Intents didn't answer." }
    }

    private var recipient: String? { to == .bitcoin ? (btcValid ? btcAddress.trimmingCharacters(in: .whitespaces) : IntentsAssets.dryQuoteBitcoinRecipient) : nil }

    private func requote() async {
        intents = nil; relay = nil; intentsError = nil; relayError = nil; error = nil
        let tok = token(fromSym, fromChain)
        guard value > 0, !tokens.isEmpty, !(to.chain == fromChain && fromSym == toSym), let w = wallet, !needsNear,
              let amt = try? Units.parse(AmountText.clean(amount), decimals: tok?.decimals ?? fromChain.nativeDecimals), amt > 0 else { return }
        try? await Task.sleep(for: .milliseconds(450))   // let typing settle
        guard !Task.isCancelled else { return }
        quoting = true; defer { quoting = false }
        let svc = vm.service, wid = w.record.id
        let (fc, tp, ts, rcpt, conf, list) = (fromChain, to, toSym, recipient, confidential, tokens)
        let request = Result { try svc.intentsRequest(walletID: wid, from: fc, fromToken: tok, to: tp, toSymbol: ts, amount: amt, recipient: rcpt,
                                                      dry: true, confidential: conf, tokens: list) }
        let user = w.record.address(on: fc), relayRecipient = tp.chain.map { w.record.address(on: $0) } ?? w.record.evmAddress
        // Both quotes at once, each in its own task with plain values. (`async let x = { … }()` here freed the captured
        // strings before Relay's request was encoded: a crash in the JSON writer on the second quote.)
        let relayDest: Relay.Place? = conf ? nil : Self.relayPlace(tp).flatMap { d in
            Relay.Place.chain(fc).relayID != nil && d.relayID != nil ? d : nil
        }
        let tt = tp.chain.flatMap { c in ts == c.nativeSymbol ? nil : c.token(ts) }
        let relayKnowsToken = tp.chain == nil || ts == tp.chain!.nativeSymbol || tt != nil   // Relay only knows Hermit's tokens
        let intentsTask = Task { () -> Result<IntentsQuote, Error> in
            do { return .success(try await OneClick().quote(try request.get())) } catch { return .failure(error) }
        }
        let relayTask = Task { () -> Result<Relay.Quote, Error>? in
            guard let dest = relayDest, relayKnowsToken else { return nil }
            do {
                return .success(try await Relay.quote(from: .chain(fc), fromToken: tok, to: dest, toToken: tt, amount: amt,
                                                      user: user, recipient: relayRecipient))
            } catch { return .failure(error) }
        }
        let (i, r) = await withTaskCancellationHandler {
            (await intentsTask.value, await relayTask.value)
        } onCancel: {
            intentsTask.cancel(); relayTask.cancel()
        }
        guard !Task.isCancelled else { return }
        withAnimation(.smooth(duration: 0.2)) {
            switch i { case .success(let q): intents = q; case .failure(let e): intentsError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }
            switch r { case .success(let q)?: relay = q; case .failure(let e)?: relayError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription; case nil: break }
        }
    }

    nonisolated private static func relayPlace(_ p: IntentsPlace) -> Relay.Place? {
        switch p { case .chain(let c): .chain(c); case .hyperliquid: .hyperliquid; case .bitcoin: nil }
    }

    // MARK: Review

    private func review() {
        guard let b = best, let w = wallet else { return }
        if b == .relay, let q = relay { reviewRelay(q, w); return }
        let svc = vm.service, wid = w.record.id, tok = token(fromSym, fromChain)
        let (fc, tp, ts, rcpt, conf, list, origin, amountText, fs) = (fromChain, to, toSym, recipient, confidential, tokens, origin, amount, fromSym)
        guard let dryOut = intents?.amountOut, let amt = try? Units.parse(AmountText.clean(amount), decimals: tok?.decimals ?? fromChain.nativeDecimals) else { return }
        reviewing = true; error = nil
        Task {
            defer { reviewing = false }
            do {
                let req = try svc.intentsRequest(walletID: wid, from: fc, fromToken: tok, to: tp, toSymbol: ts, amount: amt, recipient: rcpt,
                                                 dry: false, confidential: conf, tokens: list)
                let q = try await OneClick().quote(req)
                // The live quote must still be close to what was shown (1%).
                guard q.amountOut >= dryOut - dryOut / 100 else { throw WalletError.blocked("The price moved since the preview. Check the new amount and try again.") }
                let payee: (address: String, kind: ChainKind)? = tp == .bitcoin ? (q.request.recipient, .evm) : nil
                let (p, verdict) = try await svc.prepareIntentsDeposit(walletID: wid, from: fc, fromToken: tok, quote: q, payee: payee, origin: origin)
                guard p.canSend else { throw WalletError.blocked(p.blockingReason ?? "Blocked by the hazard scan.") }
                let out = IntentsFmt.amount(q.amountOutFormatted)
                var lines: [[String]] = [["You pay", "\(amountText) \(fs) on \(fc.name)"], ["You get", "about \(out) \(ts) on \(tp.name)"],
                                         ["Route", "NEAR Intents (1Click)"], ["Deposit to", shortAddr(q.depositAddress ?? "")],
                                         ["Cost", costText(q)], ["Network fee", "up to \(p.feeText)"], ["Time", IntentsFmt.seconds(q.seconds)],
                                         ["Refunds to", shortAddr(q.request.refundTo)]]
                if tp == .bitcoin { lines.insert(["BTC to", shortAddr(q.request.recipient)], at: 2) }
                if conf { lines.append(["Privacy", "Confidential"]) }
                if origin == .agent { lines.insert(["Prepared by", "Hermit assistant"], at: 0) }
                let checks = ["Requested by \(origin == .agent ? "the assistant, approved by you" : "you")"] + verdict.passed
                    + p.checks.filter { $0.status == .pass }.map(\.title)
                let warns = verdict.warnings + p.checks.filter { $0.status == .warn }.map { "\($0.title): \($0.detail)" }
                let from = "\(amountText) \(fs) on \(fc.name)", toText = "about \(out) \(ts) on \(tp.name)"
                ask(Approval(kind: bridging ? "Bridge via NEAR Intents" : "Swap via NEAR Intents", title: "\(amountText) \(fs) to \(ts)",
                             lines: lines, checks: checks, success: "Deposit sent. Tracking the swap.", warnings: warns) {
                    try await svc.executeIntentsDeposit(p, quote: q, from: from, to: toText, toPlace: tp)
                }) {
                    let addr = q.depositAddress ?? ""
                    Task { try? await Task.sleep(for: .milliseconds(550)); IntentsActivity.shared.show(addr); await vm.refresh() }
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func reviewRelay(_ q: Relay.Quote, _ w: WalletAccount) {
        let svc = vm.service, wid = w.record.id
        let txs = q.steps.reduce(0) { n, s in if case .evm(_, let c) = s { return n + c.count }; return n + 1 }
        let verdict = svc.policy.evaluate(usd: q.amountOutUSD.map { $0 + q.feeUSD }, payee: nil, origin: origin)
        if verdict.decision == .block { error = verdict.blocks.joined(separator: " "); return }
        ask(Approval(kind: bridging ? "Bridge" : "Swap on \(fromChain.name)",
                     title: "\(amount) \(fromSym) to \(toSym)",
                     lines: [["You pay", "\(amount) \(fromSym) on \(fromChain.name)"], ["You get", "about \(IntentsFmt.amount(q.amountOut)) \(toSym) on \(to.name)"],
                             ["Fee", MoneyFmt.usd(q.feeUSD, digits: 2)], ["Time", IntentsFmt.seconds(q.seconds)],
                             ["Steps", txs > 1 ? "\(txs) transactions, one \(Device.bio) each" : "One transaction"], ["Route", "Relay"]],
                     checks: ["Every step is simulated before it's signed", "Signed on \(Device.here) with your wallet's key"] + verdict.passed,
                     success: bridging ? "On its way to \(to.name)" : "Swapped \(fromSym) to \(toSym)", warnings: verdict.warnings) {
            try await svc.execute(q, walletID: wid)
        }) { Task { try? await Task.sleep(for: .seconds(3)); await vm.refresh() } }
    }
}

/// A format check for a Bitcoin address the user types (bech32 bc1…, or legacy 1… / 3…). 1Click validates it too.
enum BitcoinAddress {
    static func looksValid(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("bc1") {
            let body = s.lowercased().dropFirst(3)
            return (11...87).contains(body.count) && body.allSatisfy { "qpzry9x8gf2tvdw0s3jn54khce6mua7l".contains($0) } && (s == s.lowercased() || s == s.uppercased())
        }
        guard let f = s.first, f == "1" || f == "3", (26...35).contains(s.count), let b = Base58.decode(s), b.count == 25 else { return false }
        return Array(Hash.sha256(Hash.sha256(Array(b[0..<21]))).prefix(4)) == Array(b[21...])
    }
}
