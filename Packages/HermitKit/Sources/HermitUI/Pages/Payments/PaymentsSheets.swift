import SwiftUI
import HermitCore

/// Sheet chrome shared by the three pages: header with a close button, a body, a footer.
/// A dialog on the Mac, a bottom sheet with a grabber on iPhone.
struct PaySheet<Header: View, Content: View, Foot: View>: View {
    var width: CGFloat = 440
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var foot: () -> Foot
    @Environment(\.dismiss) var dismiss
    @State private var contentHeight: CGFloat = 300
    @State private var headHeight: CGFloat = 56
    @State private var footHeight: CGFloat = 72

    private var fitted: CGFloat { ceil(headHeight + contentHeight + footHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                header().frame(maxWidth: .infinity, alignment: .leading)
                PayIconButton(symbol: "xmark", label: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 22).padding(.trailing, 14).padding(.top, SheetMetricsTop.value).padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }
            #if os(iOS)
            // The form scrolls on iPhone, so a tall one never squeezes the title off the top of a short sheet.
            ScrollView {
                paySheetContent(content)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            #else
            paySheetContent(content)
            #endif
            HStack(spacing: 10) { foot() }
                #if os(iOS)
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 20)
                #else
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 22)
                #endif
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footHeight = $0 }
        }
        #if os(macOS)
        .background(SheetPaper())
        .frame(width: width)
        #else
        // Fill the whole sheet in paper, not just the content, so no band of the system sheet colour shows below.
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .bottom)
        // Exactly as tall as the form, header and button row; a form taller than the screen opens full height and scrolls.
        .presentationDetents([.height(min(fitted - SheetMetrics.bottomInset, SheetMetrics.maxHeight))])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .glassSheetBackground()
        #endif
    }
}

private func paySheetContent<C: View>(_ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 14) { content() }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
}

struct PaySheetTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 18, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
}

extension PaySheet where Header == PaySheetTitle {
    init(title: String, width: CGFloat = 440, @ViewBuilder content: @escaping () -> Content, @ViewBuilder foot: @escaping () -> Foot) {
        self.init(width: width, header: { PaySheetTitle(text: title) }, content: content, foot: foot)
    }
}

/// New or existing scheduled payment: payee, address, amount, token, date, repeat and a note.
/// Pay now opens the wallet's Send, filled in; once that send is approved, the payment moves to its next date.
struct PayScheduleSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var f: ScheduledPayment
    @State var amount: String
    @State var picking = false
    let isNew: Bool
    private var store: PaymentsStore { .shared }

    init(item: ScheduledPayment?, isNew: Bool? = nil) {
        let p = item ?? ScheduledPayment(payee: "", addr: "", amount: 0, token: "USDC", note: "", next: CalendarData.day(1), repeats: .monthly)
        _f = State(initialValue: p)
        _amount = State(initialValue: p.exact ?? (p.amount > 0 ? PayAmount.plain(p.amount) : ""))
        self.isNew = isNew ?? (item == nil)
    }

    private var addr: String { PayAddress.normalized(f.addr) }
    /// The address and token can go out together on some network (not SOL to a 0x address).
    private var routable: Bool { payChain(address: addr, token: f.token) != nil }
    private var valid: Bool {
        !f.payee.trimmingCharacters(in: .whitespaces).isEmpty && PayAddress.valid(f.addr) && PayAmount.exact(amount) != nil && routable
    }
    /// The saved payee this payment follows. Typing another name unlinks it, so a payee is never renamed from here.
    private var linked: Payee? {
        let name = f.payee.trimmingCharacters(in: .whitespaces)
        return store.payee(id: f.payeeID).flatMap { $0.name.caseInsensitiveCompare(name) == .orderedSame ? $0 : nil }
    }
    /// Under the address: what saving does to a linked payee, or a warning when the name is a payee with another address.
    private var payeeNote: (String, Color)? {
        let name = f.payee.trimmingCharacters(in: .whitespaces)
        guard PayAddress.valid(f.addr), !name.isEmpty else { return nil }
        if let l = linked {
            if l.addr == addr { return nil }
            return ("Saving also updates \(l.name) in Payees", Theme.muted)
        }
        if let other = store.payee(named: name), other.addr != addr { return ("Not the address saved for \(other.name)", Theme.amber) }
        return nil
    }

    var body: some View {
        PaySheet(title: isNew ? "Schedule a payment" : f.payee) {
            PayField(label: "Pay") {
                HStack(spacing: 8) {
                    TextField("Name", text: $f.payee).textFieldStyle(.plain).font(.system(size: 14))
                    if !store.payees.isEmpty {
                        Menu {
                            ForEach(store.payees) { p in Button(p.name) { f.payee = p.name; f.addr = p.addr; f.payeeID = p.id } }
                        } label: {
                            Image(systemName: "person.crop.circle").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Saved payees")
                    }
                }
                .payInputBox()
            }
            PayField(label: "Address or ENS") {
                TextField("0x…, name.eth, Solana or NEAR", text: $f.addr).textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced)).autocorrectionDisabled().payInputBox()
            }
            if !f.addr.isEmpty && !PayAddress.valid(f.addr) {
                Label("That doesn't look like an address", systemImage: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.red)
            } else if let n = payeeNote {
                Text(n.0).font(.system(size: 12)).foregroundStyle(n.1)
            }
            HStack(alignment: .top, spacing: 12) {
                PayField(label: "Amount") {
                    TextField("0", text: $amount).textFieldStyle(.plain).monospacedDigit().font(.system(size: 14)).payInputBox()
                }
                PayField(label: "Token") { PayMenuField(options: PaymentsData.tokens.map { ($0, $0) }, selection: $f.token) }
            }
            if let problem = PayAmount.problem(amount) {
                Label(problem, systemImage: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.red)
            } else if PayAddress.valid(f.addr) && !routable {
                Label("\(f.token) can't be sent to this address. Pick another token.", systemImage: "xmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            HStack(alignment: .top, spacing: 12) {
                PayField(label: "Date") {
                    Button { picking = true } label: {
                        HStack {
                            Text(CalendarData.format(f.next, "EEE, MMM d")).font(.system(size: 14)).foregroundStyle(Theme.text)
                            Spacer(minLength: 6)
                            Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                        .payInputBox().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $picking) {
                        DatePicker("Date", selection: $f.next, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.graphical)
                            .frame(width: 280).padding(12)
                            .presentationCompactAdaptation(.popover)
                            .onChange(of: f.next) { _, _ in picking = false }
                    }
                }
                PayField(label: "Repeat") { PayMenuField(options: PayRepeat.allCases.map { ($0, $0.label) }, selection: $f.repeats) }
            }
            PayField(label: "Note") {
                TextField("Optional, e.g. November rent", text: $f.note).textFieldStyle(.plain).font(.system(size: 14)).payInputBox()
            }
            if !isNew {
                HStack(spacing: 10) {
                    Button("Pay now") {
                        guard let amt = PayAmount.exact(amount) else { return }
                        dismiss()
                        let addr = self.addr, token = f.token, id = f.id
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            payViaWallet(model, address: addr, amount: amt, token: token) { PaymentsStore.shared.markPaid(id) }
                        }
                    }
                    .buttonStyle(PayPillButton(kind: .accent))
                    .disabled(!PayAddress.valid(f.addr) || PayAmount.exact(amount) == nil || !routable)
                    Text("Opens Send with this filled in.").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
            }
        } foot: {
            if !isNew {
                Button {
                    store.removePayment(f.id); dismiss(); model.toast("Payment deleted")
                } label: { Image(systemName: "trash").font(.system(size: 14)) }
                .buttonStyle(PayWideButton(kind: .plain)).frame(width: 52)
                .accessibilityLabel("Delete")
                Button(f.paused ? "Resume" : "Pause") {
                    store.togglePause(f.id); f.paused.toggle()
                    model.toast(f.paused ? "Paused" : "Resumed")
                }
                .buttonStyle(PayWideButton(kind: .plain)).frame(width: 110)
            }
            Button(isNew ? "Schedule" : "Save", action: save)
                .buttonStyle(PayWideButton(kind: .black))
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        guard valid, let exact = PayAmount.exact(amount), let v = Double(exact) else { return }
        var p = f
        p.payee = p.payee.trimmingCharacters(in: .whitespaces)
        p.addr = addr
        p.amount = v
        p.exact = exact
        p.next = CalendarData.cal.startOfDay(for: p.next)
        if let l = linked {
            // One payee, one address: an address fixed here also fixes the payee and its other payments.
            if l.addr != p.addr { store.save(Payee(id: l.id, name: l.name, addr: p.addr)) }
        } else if let same = store.payee(named: p.payee) {
            // Same name, other address: kept as a one-off so the saved payee is not changed behind your back.
            p.payeeID = same.addr == p.addr ? same.id : nil
        } else {
            let payee = Payee(name: p.payee, addr: p.addr)
            store.save(payee)
            p.payeeID = payee.id
        }
        store.save(p)
        dismiss()
        model.toast(isNew ? "Scheduled for \(CalendarData.format(p.next, "MMM d"))" : "Saved")
    }
}

/// Add or edit a payee: a name and an address or ENS name.
struct PayeeSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var p: Payee
    let isNew: Bool
    private var store: PaymentsStore { .shared }

    init(payee: Payee?) {
        _p = State(initialValue: payee ?? Payee(name: "", addr: ""))
        isNew = payee == nil
    }

    private var valid: Bool { !p.name.trimmingCharacters(in: .whitespaces).isEmpty && PayAddress.valid(p.addr) }
    /// Scheduled payments that follow this payee.
    private var linkedCount: Int { isNew ? 0 : store.schedule.filter { $0.payeeID == p.id }.count }
    private var savedNote: String {
        PayAddress.kind(p.addr) == .ens
            ? "Saved on this device."
            : "Saved on this device and in your wallet's saved addresses. A new address works in Send 24 hours after you add it."
    }

    var body: some View {
        PaySheet(title: isNew ? "Add payee" : p.name) {
            PayField(label: "Name") {
                TextField("e.g. Landlord", text: $p.name).textFieldStyle(.plain).font(.system(size: 14)).payInputBox()
            }
            PayField(label: "Address or ENS") {
                TextField("0x…, name.eth, Solana or NEAR", text: $p.addr).textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced)).autocorrectionDisabled().payInputBox()
            }
            if !p.addr.isEmpty && !PayAddress.valid(p.addr) {
                Label("That doesn't look like an address", systemImage: "xmark.circle").font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            if linkedCount > 0 {
                Text(linkedCount == 1 ? "1 scheduled payment uses this payee and follows your changes."
                     : "\(linkedCount) scheduled payments use this payee and follow your changes.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Text(savedNote).font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        } foot: {
            if !isNew {
                Button { store.removePayee(p.id); dismiss(); model.toast("Payee deleted") } label: {
                    Image(systemName: "trash").font(.system(size: 14))
                }
                .buttonStyle(PayWideButton(kind: .plain)).frame(width: 52)
                .accessibilityLabel("Delete")
            }
            Button(isNew ? "Add" : "Save") {
                var x = p
                x.name = x.name.trimmingCharacters(in: .whitespaces); x.addr = PayAddress.normalized(x.addr)
                store.save(x); dismiss(); model.toast(isNew ? "\(x.name) added" : "Saved")
            }
            .buttonStyle(PayWideButton(kind: .black)).disabled(!valid).keyboardShortcut(.defaultAction)
        }
    }
}

/// "Explore more services" with a search button, opening a searchable list. Picking an item asks Hermit.
struct PayExploreMore: View {
    let label: String
    let items: [PayMoreItem]
    @State var open = false

    var body: some View {
        HStack(spacing: 8) {
            Button { open = true } label: { Text("Explore more \(label)").frame(maxWidth: .infinity) }
                .buttonStyle(PayExploreButton())
            Button { open = true } label: { Image(systemName: "magnifyingglass").frame(width: 18) }
                .buttonStyle(PayExploreButton())
                .accessibilityLabel("Search \(label)")
        }
        .sheet(isPresented: $open) { PayExploreSheet(label: label, items: items) }
    }
}

private struct PayExploreButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).frame(height: 42)
            .background(configuration.isPressed ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PayExploreSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let label: String
    let items: [PayMoreItem]
    @State var q = ""
    @FocusState var focused: Bool

    var body: some View {
        let list = items.filter { q.isEmpty || "\($0.name) \($0.sub) \($0.tag ?? "")".localizedCaseInsensitiveContains(q) }
        PaySheet(width: 520) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint).font(.system(size: 13))
                TextField("Search \(label)", text: $q).textFieldStyle(.plain).focused($focused)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12).frame(height: 38)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        } content: {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        Button {
                            dismiss(); model.send("Tell me about \(item.name)")
                        } label: {
                            HStack(spacing: 12) {
                                PayLogo(name: item.logo, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text(item.sub).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let tag = item.tag { Text(tag).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(PayRowStyle())
                        .payLine(i > 0)
                    }
                    if list.isEmpty {
                        Text("No results").foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.horizontal, -10)
            .frame(height: SnapshotMode.active ? nil : 420)
        } foot: { EmptyView() }
        .onAppear { focused = true }
    }
}

/// Space above a sheet's title, clear of the grab handle (30 on iPhone, 16 on the Mac).
enum SheetMetricsTop {
    #if os(iOS)
    static let value: CGFloat = 30
    #else
    static let value: CGFloat = 16
    #endif
}
