import SwiftUI
import HermitCore

/// Shown wherever a pay button is greyed out.
/// Payments hands the money part to the wallet: Send opens filled in, with its review screen, safety check and Face ID.
@MainActor func payViaWallet(_ model: AppModel, address: String, amount: String, token: String) {
    WalletsViewModel.shared.sendPrefill = .init(address: address, amount: amount, token: token)
    model.open(.wallets, tab: "send")
}

// MARK: Schedule

struct PaySchedule: View {
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
            Text("Scheduled payments show on your calendar. Open one and tap Pay now to send it from your wallet.")
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
                                                    next: CalendarData.day(1), repeats: .once), isNew: true)
        }
    }
}

/// Address checks shared by the payee and transfer forms.
enum PayAddress {
    enum Kind { case none, evm, ens, solana, invalid }
    static func kind(_ raw: String) -> Kind {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .none }
        if t.lowercased().hasSuffix(".eth") && t.count > 4 && !t.contains(" ") { return .ens }
        if t.hasPrefix("0x") { return t.count == 42 && t.dropFirst(2).allSatisfy(\.isHexDigit) ? .evm : .invalid }
        let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        if (32...44).contains(t.count), t.allSatisfy({ base58.contains($0) }) { return .solana }
        return .invalid
    }
    static func valid(_ raw: String) -> Bool {
        switch kind(raw) { case .evm, .ens, .solana: true; default: false }
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
        case .invalid: return ("Enter an address, an ENS name or a saved payee", Theme.red, "xmark.circle")
        }
    }

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
            Button("Review") {
                let addr = saved?.addr ?? to.trimmingCharacters(in: .whitespacesAndNewlines)
                payViaWallet(model, address: addr, amount: amount, token: token)
            }
            .buttonStyle(PayWideButton(kind: .accent))
            .disabled(to.trimmingCharacters(in: .whitespaces).isEmpty || (saved == nil && PayAddress.kind(to) == .invalid))
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
