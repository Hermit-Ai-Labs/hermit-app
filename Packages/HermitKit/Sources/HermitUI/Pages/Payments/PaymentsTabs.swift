import SwiftUI
import HermitCore
import HermitWallet

/// Payments hands the money part to the wallet: Send opens filled in, with its review screen, safety check and Face ID.
/// The network follows the address and the token, so Send never swaps the asset. `onSent` runs only after the
/// approval went through for exactly this payment (same address, token and amount), not when Send was edited.
@MainActor func payViaWallet(_ model: AppModel, address: String, amount: String, token: String, onSent: (@MainActor () -> Void)? = nil) {
    let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let chain = payChain(address: addr, token: token) else {
        model.toast("\(token) can't be sent to that address. Pick another token.")
        return
    }
    let want = Decimal(string: AmountText.clean(amount), locale: Locale(identifier: "en_US_POSIX"))
    var sent: (@MainActor (String, String, String) -> Void)? = nil
    if let onSent {
        sent = { (to: String, amt: String, symbol: String) -> Void in
            let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
            let sameAddress = t == addr || (addr.hasPrefix("0x") && t.caseInsensitiveCompare(addr) == .orderedSame)
            guard sameAddress, symbol == token, let want,
                  Decimal(string: AmountText.clean(amt), locale: Locale(identifier: "en_US_POSIX")) == want else { return }
            onSent()
        }
    }
    WalletsViewModel.shared.sendPrefill = .init(address: addr, amount: amount, token: token, chain: chain, onSent: sent)
    model.open(.wallets, tab: "send")
}

/// The network a payment goes out on: the address picks the family (EVM, Solana, NEAR), then the first network of
/// that family that carries the token, Base first. nil when none does (SOL to a 0x address, ETH to a NEAR account).
@MainActor func payChain(address: String, token: String) -> Chain? {
    let family: ChainKind
    switch PayAddress.kind(address) {
    case .evm, .ens: family = .evm
    case .solana: family = .solana
    case .near: family = .near
    case .none, .invalid: return nil
    }
    let vm = WalletsViewModel.shared
    let pool = [Chain.defaultSend] + (WalletService.mainnetSendsEnabled ? Chain.mainnets : Chain.testnets)
    return pool.first { $0.kind == family && vm.tokens(chain: $0).contains(token) }
}

// MARK: Schedule

struct PaySchedule: View {
    @Environment(AppModel.self) private var model
    let compact: Bool
    @State var open: ScheduledPayment?
    @State var creating = false
    private var store: PaymentsStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if store.schedule.isEmpty {
                EmptyState(symbol: "calendar.badge.clock", title: "No scheduled payments",
                           text: "Schedule rent, a salary or a subscription. Each one shows on your calendar.") {
                    Button { creating = true } label: { Label("Schedule a payment", systemImage: "plus") }.buttonStyle(BlackButton())
                }
            } else {
                if compact {
                    VStack(spacing: 12) { PayNext7Card(); PayStatusCard(fill: false) }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        PayNext7Card().frame(maxHeight: .infinity)
                        PayStatusCard().frame(maxHeight: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    PaySectionTitle("Scheduled")
                    ForEach(Array(store.upcoming.enumerated()), id: \.element.id) { i, p in
                        Button { open = p } label: {
                            HStack(spacing: 12) {
                                PayLogo(name: p.payee, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.payee).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text([p.note, p.repeats.label].filter { !$0.isEmpty }.joined(separator: ", "))
                                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(p.amountText).font(.system(size: 14)).monospacedDigit()
                                    Text(p.whenText).font(.system(size: 12))
                                        .foregroundStyle(p.paused || p.due ? Theme.amber : Theme.faint)
                                }
                            }
                            .padding(.vertical, 11)
                            .opacity(p.paused ? 0.6 : 1)
                        }
                        .buttonStyle(PayRowStyle())
                        .payLine(i > 0)
                        .contextMenu {
                            if !p.paused {
                                Button("Pay now") {
                                    let id = p.id
                                    payViaWallet(model, address: p.addr, amount: p.sendAmount, token: p.token) { PaymentsStore.shared.markPaid(id) }
                                }
                                .disabled(!PayAddress.valid(p.addr) || p.amount <= 0)
                            }
                            Button(p.paused ? "Resume" : "Pause") { store.togglePause(p.id) }
                            Button("Edit") { open = p }
                            Divider()
                            Button("Delete", role: .destructive) { store.removePayment(p.id) }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .sheet(item: $open) { PayScheduleSheet(item: $0) }
        .sheet(isPresented: $creating) { PayScheduleSheet(item: nil) }
    }
}

struct PayNext7Card: View {
    @State var shown = SnapshotMode.active
    private var days: [Double] { PaymentsStore.shared.next7Days }
    private var leavesOut: Bool { PaymentsStore.shared.next7LeavesOut }

    var body: some View {
        let days = self.days
        let mx = max(days.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Next 7 days").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Text(PayFormat.usd(days.reduce(0, +))).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(v > 0 ? Theme.text : Theme.hover)
                            .frame(height: shown ? max(3, v / mx * 52) : 3)
                            .animation(.spring(duration: 0.55, bounce: 0.2).delay(Double(i) * 0.04), value: shown)
                        Text(letter(i)).font(.system(size: 10.5)).foregroundStyle(i == 0 ? Theme.text : Theme.faint)
                    }
                    .frame(maxWidth: .infinity)
                    .help(v > 0 ? "\(PayFormat.amount(v)) on \(weekday(i))" : "Nothing on \(weekday(i))")
                }
            }
            .frame(height: 70, alignment: .bottom)
            .padding(.top, 14)
            if leavesOut {
                Text("USDC and USDT only").font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.top, 8)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
        .onAppear { shown = true }
    }

    private func date(_ i: Int) -> Date { CalendarData.day(i) }
    private func letter(_ i: Int) -> String { String(CalendarData.format(date(i), "EEEEE")) }
    private func weekday(_ i: Int) -> String { i == 0 ? "today" : CalendarData.format(date(i), "EEEE") }
}

/// What is due and how paying works today.
struct PayStatusCard: View {
    var fill = true
    private var store: PaymentsStore { .shared }

    var body: some View {
        let due = store.schedule.filter(\.due)
        VStack(alignment: .leading, spacing: 10) {
            Text("Status").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Text(due.isEmpty ? "Nothing due" : due.count == 1 ? "1 payment due" : "\(due.count) payments due")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(due.isEmpty ? Theme.text : Theme.amber)
            if fill { Spacer(minLength: 0) }
            Text("Scheduled payments show on your calendar. Open one and tap Pay now. Once it's sent, it moves to its next date.")
                .font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading).card()
    }
}

// MARK: Payees

struct PayPayees: View {
    @State var editing: Payee?
    @State var adding = false
    @State var scheduling: Payee?
    private var store: PaymentsStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.payees.isEmpty {
                EmptyState(symbol: "person.crop.circle.badge.plus", title: "No payees yet",
                           text: "Save the people and businesses you pay, with their address or ENS name.") {
                    Button { adding = true } label: { Label("Add payee", systemImage: "plus") }.buttonStyle(BlackButton())
                }
            } else {
                PaySectionTitle(title: "Saved") {
                    Button { adding = true } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                }
                ForEach(Array(store.payees.enumerated()), id: \.element.id) { i, p in
                    Button { editing = p } label: {
                        HStack(spacing: 12) {
                            PayLogo(name: p.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(p.addr).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                                    .lineLimit(1).truncationMode(.middle)
                                if let hold = store.holdText(p) {
                                    Text(hold).font(.system(size: 12)).foregroundStyle(Theme.amber).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(PayRowStyle())
                    .payLine(i > 0)
                    .contextMenu {
                        Button("Schedule a payment") { scheduling = p }
                        Button("Copy address") { PayClipboard.copy(p.addr) }
                        Button("Edit") { editing = p }
                        Divider()
                        Button("Delete", role: .destructive) { store.removePayee(p.id) }
                    }
                }
            }
        }
        .sheet(item: $editing) { PayeeSheet(payee: $0) }
        .sheet(isPresented: $adding) { PayeeSheet(payee: nil) }
        #if DEBUG
        .task { try? await Task.sleep(for: .seconds(1.2)); if DebugLaunch.take("new-payee") { adding = true } }
        #endif
        .sheet(item: $scheduling) { p in
            PayScheduleSheet(item: ScheduledPayment(payee: p.name, addr: p.addr, amount: 0, token: "USDC", note: "",
                                                    next: CalendarData.day(1), repeats: .once, payeeID: p.id), isNew: true)
        }
    }
}

/// Address checks shared by the payee, schedule and transfer forms. The wallet's own checks: an EVM address with a
/// correct EIP-55 checksum when mixed case, a 32-byte base58 Solana key, a valid NEAR account, or an ENS name.
enum PayAddress {
    enum Kind { case none, evm, ens, solana, near, invalid }
    static func kind(_ raw: String) -> Kind {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .none }
        if ENS.looksLikeName(t) { return t.count > 4 && !t.contains(" ") ? .ens : .invalid }
        // NEAR accounts are lowercase; accept "Alice.near" as alice.near (normalized() saves it lowercased).
        let found: ChainKind? = Chain.kind(of: t) ?? (Chain.kind(of: t.lowercased()) == .near ? .near : nil)
        guard let k = found else { return .invalid }
        switch k {
        case .evm: return .evm
        case .solana: return .solana
        case .near: return .near
        }
    }
    static func valid(_ raw: String) -> Bool {
        switch kind(raw) { case .evm, .ens, .solana, .near: true; default: false }
    }
    /// What gets saved: trimmed, and lowercased for ENS names and NEAR accounts (both are lowercase only).
    static func normalized(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind(t) { case .ens, .near: return t.lowercased(); default: return t }
    }
}

// MARK: Transfer

struct PayTransfer: View {
    @Environment(AppModel.self) private var model
    let compact: Bool
    @State var to = ""
    @State var amount = ""
    @State var token = "USDC"
    @FocusState var focus: Bool
    private var store: PaymentsStore { .shared }

    private var saved: Payee? { store.payee(named: to.trimmingCharacters(in: .whitespaces)) }

    private var hint: (String, Color, String)? {
        if let p = saved { return ("Saved payee, \(p.addr)", Theme.green, "checkmark.circle.fill") }
        switch PayAddress.kind(to) {
        case .none: return nil
        case .ens: return ("ENS name", Theme.muted, "at")
        case .evm: return ("New address, double-check it", Theme.amber, "exclamationmark.triangle")
        case .solana: return ("Solana address, new", Theme.amber, "exclamationmark.triangle")
        case .near: return ("NEAR account, new", Theme.amber, "exclamationmark.triangle")
        case .invalid: return ("Enter an address, an ENS name or a saved payee", Theme.red, "xmark.circle")
        }
    }

    private var address: String { saved?.addr ?? PayAddress.normalized(to) }
    /// Set when the address and token can't go together (SOL to a 0x address).
    private var routeProblem: String? {
        guard PayAddress.valid(address), payChain(address: address, token: token) == nil else { return nil }
        return "\(token) can't be sent to this address. Pick another token."
    }
    private var canReview: Bool { PayAddress.valid(address) && PayAmount.exact(amount) != nil && routeProblem == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PayField(label: "To") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if !to.isEmpty { PayLogo(name: to, size: 24).transition(.scale.combined(with: .opacity)) }
                        TextField("Address, ENS or payee", text: $to).textFieldStyle(.plain).focused($focus)
                            .autocorrectionDisabled()
                        if !to.isEmpty {
                            Button { to = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
                                .buttonStyle(.plain).accessibilityLabel("Clear")
                        } else {
                            Button("Paste") {
                                if let s = PayClipboard.paste() { to = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                            }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
                        }
                    }
                    .font(.system(size: 14))
                    .payInputBox(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focus ? Theme.text.opacity(0.35) : .clear))
                    if let h = hint {
                        Label(h.0, systemImage: h.2).font(.system(size: 12)).foregroundStyle(h.1).lineLimit(1).truncationMode(.middle)
                            .transition(.opacity)
                    }
                }
            }
            if !store.payees.isEmpty {
                PayFlow(spacing: 6) {
                    ForEach(store.payees) { c in
                        PayChip(on: to == c.name, action: { to = c.name }) {
                            PayLogo(name: c.name, size: 16)
                            Text(c.name)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                PayField(label: "Amount") {
                    TextField("0", text: $amount).textFieldStyle(.plain).monospacedDigit()
                        .font(.system(size: 14)).payInputBox()
                }
                PayField(label: "Token") {
                    PayMenuField(options: PaymentsData.tokens.map { ($0, $0) }, selection: $token)
                }
                .frame(maxWidth: compact ? 130 : .infinity)
            }
            if let problem = PayAmount.problem(amount) ?? routeProblem {
                Label(problem, systemImage: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.red)
                    .padding(.top, -8).transition(.opacity)
            }
            Button("Review") {
                guard let exact = PayAmount.exact(amount) else { return }
                payViaWallet(model, address: address, amount: exact, token: token)
            }
            .buttonStyle(PayWideButton(kind: .accent))
            .disabled(!canReview)
        }
        .animation(.snappy(duration: 0.25), value: to)
    }
}

// MARK: APIs

struct PayApis: View {
    @State var cat = "All"

    var body: some View {
        let list = PaymentsData.apiCatalog.filter { cat == "All" || $0.cat == cat }
        VStack(alignment: .leading, spacing: 0) {
            Text("Pay-per-use APIs Hermit will be able to buy with USDC. Buying is coming soon.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.bottom, 12)
            PayFlow {
                ForEach(PaymentsData.apiCategories, id: \.self) { c in
                    PayChip(c, on: c == cat) { withAnimation(.snappy) { cat = c } }
                }
            }
            .padding(.bottom, 8)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                HStack(spacing: 12) {
                    PayLogo(name: a.by, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a.by) \(a.name)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(a.price).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Buy") {}.buttonStyle(PayPillButton(kind: .black)).comingSoon()
                }
                .padding(.vertical, 11)
                .payLine(i > 0)
                .transition(.opacity)
            }
        }
    }
}
