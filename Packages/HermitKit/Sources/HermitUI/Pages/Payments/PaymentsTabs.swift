import SwiftUI
import UniformTypeIdentifiers
import HermitCore

// MARK: Schedule

struct PaySchedule: View {
    let compact: Bool
    @State var open: PayScheduleItem?
    private var store: PaymentsStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if compact {
                VStack(spacing: 12) { PayNext7Card(); PaysFromCard(fill: false) }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    PayNext7Card().frame(maxHeight: .infinity)
                    PaysFromCard().frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                PaySectionTitle(title: "Live schedule") { PayLiveTag(text: "Running") }
                ForEach(Array(store.schedule.enumerated()), id: \.element.id) { i, p in
                    let paused = store.paused.contains(p.id)
                    Button { open = p } label: {
                        HStack(spacing: 12) {
                            PayLogo(name: p.to, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.to).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text("\(p.what) with \(p.rail)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(PayFormat.amount(p.amt)).font(.system(size: 14)).monospacedDigit().contentTransition(.numericText())
                                HStack(spacing: 5) {
                                    if p.live && !paused { PayPulseDot(size: 5) }
                                    Text(paused ? "Paused" : p.when)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(paused ? Theme.amber : p.live ? Theme.green : Theme.faint)
                            }
                        }
                        .padding(.vertical, 11)
                        .opacity(paused ? 0.6 : 1)
                    }
                    .buttonStyle(PayRowStyle())
                    .payLine(i > 0)
                    .contextMenu {
                        Button(paused ? "Resume" : "Pause") { store.togglePause(p.id) }
                        Button("Edit") { open = p }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if store.schedule.isEmpty {
                    Text("Nothing scheduled.").font(.system(size: 13.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
                }
            }
        }
        .sheet(item: $open) { PayScheduleSheet(item: $0) }
    }
}

struct PayNext7Card: View {
    @State var shown = SnapshotMode.active
    private let days = PaymentsData.next7Days

    var body: some View {
        let mx = days.max() ?? 1
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

struct PaysFromCard: View {
    @Environment(AppModel.self) var model
    var fill = true
    private var store: PaymentsStore { .shared }
    private let sources: [(String, String, String)] = [("USDC on Base", "USDC", "base"), ("USDC on Solana", "USDC", "solana"), ("USDT on Arbitrum", "USDT", "arbitrum")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pays from").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Menu {
                    ForEach(sources, id: \.0) { s in
                        Button {
                            withAnimation(.snappy) { store.paysFrom = s.0 }
                            model.toast("Payments now use \(s.0)")
                        } label: {
                            if store.paysFrom == s.0 { Label(s.0, systemImage: "checkmark") } else { Text(s.0) }
                        }
                    }
                } label: {
                    Text("Change").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            HStack(spacing: 12) {
                let src = sources.first { $0.0 == store.paysFrom } ?? sources[0]
                ZStack(alignment: .bottomTrailing) {
                    LogoMark(src.1, size: 30)
                    LogoMark(src.2, size: 14).overlay(Circle().strokeBorder(.white, lineWidth: 1.5)).offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.paysFrom).font(.system(size: 14, weight: .medium))
                    Text("\(PayFormat.usd(store.balance)) available").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .monospacedDigit().contentTransition(.numericText())
                }
            }
            if fill { Spacer(minLength: 0) }
            Text("Auto-pays up to $100. Anything bigger waits for you.").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading).card()
    }
}

// MARK: Approvals

struct PayApprovals: View {
    @Environment(AppModel.self) var model
    private var store: PaymentsStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Above your $100 auto-pay limit, so Hermit waits for you.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.bottom, 10)
            ForEach(Array(store.pending.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 12) {
                    PayLogo(name: p.to, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.to).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(p.what).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(PayFormat.usd(p.amt)).font(.system(size: 14)).monospacedDigit()
                        Text(p.due).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    Button("Review") { review(p) }.buttonStyle(PayPillButton(kind: .accent))
                }
                .padding(.vertical, 12)
                .payLine(i > 0)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .trailing))))
            }
            if store.pending.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.green)
                    Text("Nothing waiting for you").font(.system(size: 14, weight: .medium))
                    Text("Payments over $100 will show up here.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
                .transition(.opacity)
            }
        }
    }

    private func review(_ p: PayPending) {
        PayApprovalHook.shared.request(Approval(
            kind: "Payment", title: "Pay \(p.to) \(PayFormat.usd(p.amt))",
            lines: [["For", p.what], ["Amount", PayFormat.usd(p.amt, 2)], ["Method", p.method], ["Due", p.due]],
            checks: PayChecks.base(["Recipient matches saved payee"]), success: "Paid \(p.to)",
            receipt: .receipt(title: "Paid \(p.to)", rows: [["For", p.what], ["Amount", PayFormat.usd(p.amt, 2)], ["Method", p.method]])
        ), model: model) {
            withAnimation(.snappy) { store.pending.removeAll { $0.id == p.id } }
            store.spend(p.amt)
        }
    }
}

// MARK: Transfer

struct PayTransfer: View {
    @Environment(AppModel.self) var model
    let compact: Bool
    @State var to = ""
    @State var amount = ""
    @State var token = "USDC"
    @FocusState var focus: Bool
    private var store: PaymentsStore { .shared }

    private enum Kind { case none, contact(String), own, ens, email, address, solana, invalid }

    private var kind: Kind {
        let t = to.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .none }
        if let c = PaymentsData.contacts.first(where: { $0.name.caseInsensitiveCompare(t) == .orderedSame }) { return .contact(c.addr) }
        if t.hasPrefix("My ") { return .own }
        if t.lowercased().hasSuffix(".eth") && t.count > 4 { return .ens }
        if t.contains("@"), t.split(separator: "@").last?.contains(".") == true { return .email }
        if t.hasPrefix("0x") { return t.count == 42 && t.dropFirst(2).allSatisfy(\.isHexDigit) ? .address : .invalid }
        if (32...44).contains(t.count), t.allSatisfy({ $0.isLetter || $0.isNumber }) { return .solana }
        return .invalid
    }

    private var hint: (String, Color, String)? {
        switch kind {
        case .none: nil
        case .contact(let a): ("Saved contact, \(a)", Theme.green, "checkmark.circle.fill")
        case .own: ("Your wallet", Theme.green, "checkmark.circle.fill")
        case .ens: ("ENS name, resolves to 0x4f1…c2d", Theme.muted, "at")
        case .email: ("Email. They get a link to claim it.", Theme.muted, "envelope")
        case .address: ("New address, double-check it", Theme.amber, "exclamationmark.triangle")
        case .solana: ("Solana address, new", Theme.amber, "exclamationmark.triangle")
        case .invalid: ("Enter an address, ENS name or email", Theme.red, "xmark.circle")
        }
    }

    private var valid: Bool {
        if case .none = kind { return false }
        if case .invalid = kind { return false }
        return (Double(amount) ?? 0) > 0
    }

    private var saved: Bool {
        switch kind { case .contact, .own: true; default: false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PayField(label: "To") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if !to.isEmpty { PayLogo(name: to, size: 24).transition(.scale.combined(with: .opacity)) }
                        TextField("Address, ENS or email", text: $to).textFieldStyle(.plain).focused($focus)
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
                        Label(h.0, systemImage: h.2).font(.system(size: 12)).foregroundStyle(h.1)
                            .transition(.opacity)
                    }
                }
            }
            PayFlow(spacing: 6) {
                ForEach(PaymentsData.contacts) { c in
                    PayChip(on: to == c.name, action: { to = c.name }) {
                        PayLogo(name: c.name, size: 16)
                        Text(c.name)
                    }
                }
                ForEach(PaymentsData.ownWallets, id: \.self) { w in
                    PayChip("My \(w)", on: to == "My \(w)") { to = "My \(w)" }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                PayField(label: "Amount") {
                    HStack {
                        TextField("0", text: $amount).textFieldStyle(.plain).monospacedDigit()
                        Button("Max") { amount = token == "USDC" ? String(Int(store.balance)) : token == "ETH" ? "2.4" : token == "SOL" ? "41" : "180" }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    }
                    .font(.system(size: 14)).payInputBox()
                }
                PayField(label: "Token") {
                    Menu {
                        ForEach(PaymentsData.tokens, id: \.self) { t in
                            Button { token = t } label: { if t == token { Label(t, systemImage: "checkmark") } else { Text(t) } }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            LogoMark(token, size: 20)
                            Text(token).font(.system(size: 14)).foregroundStyle(Theme.text)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                        .payInputBox().contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                }
                .frame(maxWidth: compact ? 130 : .infinity)
            }
            Button("Review") { send() }
                .buttonStyle(PayWideButton(kind: .accent))
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)

            VStack(alignment: .leading, spacing: 0) {
                PaySectionTitle("Recent")
                ForEach(Array(store.recent.enumerated()), id: \.element.id) { i, r in
                    Button { withAnimation(.snappy) { to = r.to } } label: {
                        HStack(spacing: 12) {
                            PayLogo(name: r.to, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.to).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(r.when).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            Text(r.amount).font(.system(size: 14)).monospacedDigit()
                        }
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(PayRowStyle())
                    .payLine(i > 0)
                }
            }
            .padding(.top, 14)
        }
        .animation(.snappy(duration: 0.25), value: to)
    }

    private func send() {
        guard valid else { return }
        let dest = to.trimmingCharacters(in: .whitespaces), amt = amount, tok = token, ok = saved
        PayApprovalHook.shared.request(Approval(
            kind: "Transfer", title: "Send \(amt) \(tok)",
            lines: [["To", dest], ["Amount", "\(amt) \(tok)"], ["From", "Main"], ["Fee", "$0.01"]],
            checks: PayChecks.base([ok ? "Saved contact" : "New address, double-check it"]), success: "Sent to \(dest)",
            receipt: .receipt(title: "Sent \(amt) \(tok)", rows: [["To", dest], ["From", "Main"], ["Fee", "$0.01"]])
        ), model: model) {
            withAnimation(.snappy) {
                store.recent.insert(PayRecent(to: dest, amount: "\(amt) \(tok)", when: "Just now"), at: 0)
            }
            if tok == "USDC" { store.spend(Double(amt) ?? 0) }
            to = ""; amount = ""
        }
    }
}

// MARK: Bills

struct PayBills: View {
    @Environment(AppModel.self) var model
    @State var importing = false
    private var store: PaymentsStore { .shared }
    private let inbox = "ryan@bills.hermit.app"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { importing = true } label: { tile("Upload invoice", "arrow.up.doc") }
                    .buttonStyle(PressStyle())
                Button { PayClipboard.copy(inbox); model.toast("Copied \(inbox)") } label: { tile("Forward email", "envelope") }
                    .buttonStyle(PressStyle())
                    .help("Forward bills to \(inbox)")
            }
            .padding(.bottom, 26)
            PaySectionTitle("Upcoming")
            ForEach(Array(store.bills.enumerated()), id: \.element.id) { i, b in
                let paid = store.paidBills.contains(b.id)
                HStack(spacing: 12) {
                    PayLogo(name: b.to, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.to).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(b.what).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(PayFormat.usd(b.amt)).font(.system(size: 14)).monospacedDigit()
                        Text(paid ? "Paid" : b.due).font(.system(size: 12)).foregroundStyle(paid ? Theme.green : Theme.faint)
                    }
                    ZStack {
                        if paid {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.green)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            Button("Pay") { pay(b) }.buttonStyle(PayPillButton(kind: .outline)).transition(.opacity)
                        }
                    }
                    .frame(width: 52)
                }
                .padding(.vertical, 12)
                .payLine(i > 0)
            }
            Text("Paid from USDC. The payee gets dollars in their bank.")
                .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 16)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
            if case .success(let url) = result {
                model.send("Pay this invoice: \(url.lastPathComponent)")
            }
        }
    }

    private func tile(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15))
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.text)
        .padding(18).frame(maxWidth: .infinity).card()
        .contentShape(Rectangle())
    }

    private func pay(_ b: PayBill) {
        PayApprovalHook.shared.request(Approval(
            kind: "Bill payment", title: "Pay \(b.to) \(PayFormat.usd(b.amt))",
            lines: [["To", b.bank], ["Amount", PayFormat.usd(b.amt, 2)], ["Route", "USDC to bank via Bridge"], ["Arrives", "1 business day"]],
            checks: PayChecks.base(["Bank details unchanged"]), success: "Paid \(b.to)",
            receipt: .receipt(title: "Paid \(b.to)", rows: [["To", b.bank], ["Amount", PayFormat.usd(b.amt, 2)], ["Arrives", "1 business day"]])
        ), model: model) {
            _ = withAnimation(.bouncy) { store.paidBills.insert(b.id) }
            store.spend(b.amt)
        }
    }
}

// MARK: APIs

struct PayApis: View {
    @Environment(AppModel.self) var model
    @State var cat = "All"
    @State var shown = SnapshotMode.active
    private var store: PaymentsStore { .shared }

    var body: some View {
        let list = PaymentsData.apiCatalog.filter { cat == "All" || $0.cat == cat }
        VStack(alignment: .leading, spacing: 0) {
            PaySectionTitle("Yours this month")
            ForEach(Array(store.mine.enumerated()), id: \.element.id) { i, a in
                HStack(alignment: .top, spacing: 12) {
                    PayLogo(name: a.name, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("\(a.name) \(a.plan)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(PayFormat.amount(a.used)) of \(PayFormat.usd(a.cap))").font(.system(size: 12.5)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hover)
                                Capsule().fill(a.used / a.cap > 0.8 ? Theme.amber : Theme.text)
                                    .frame(width: shown ? max(4, g.size.width * min(1, a.used / a.cap)) : 0)
                            }
                        }
                        .frame(height: 4).padding(.top, 8)
                        Text(a.calls).font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 5)
                    }
                    Menu {
                        Button("Raise cap to \(PayFormat.usd(a.cap * 2))") {
                            withAnimation(.snappy) { if let j = store.mine.firstIndex(where: { $0.id == a.id }) { store.mine[j].cap *= 2 } }
                            model.toast("\(a.name) cap is now \(PayFormat.usd(a.cap * 2)) a month")
                        }
                        Button("Ask about usage") { model.send("How am I using \(a.name) \(a.plan) this month?") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                .padding(.vertical, 12)
                .payLine(i > 0)
            }

            PaySectionTitle("Marketplace").padding(.top, 30)
            PayFlow {
                ForEach(PaymentsData.apiCategories, id: \.self) { c in
                    PayChip(c, on: c == cat) { withAnimation(.snappy) { cat = c } }
                }
            }
            .padding(.bottom, 8)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                let owned = store.mine.contains { $0.name == a.by }
                HStack(spacing: 12) {
                    PayLogo(name: a.by, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(a.by) \(a.name)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Text(a.price).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if owned {
                        Text("Active").font(.system(size: 12.5)).foregroundStyle(Theme.faint).transition(.opacity)
                    } else {
                        Button("Buy") { buy(a) }.buttonStyle(PayPillButton(kind: .black)).transition(.opacity)
                    }
                }
                .padding(.vertical, 11)
                .payLine(i > 0)
                .transition(.opacity)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.1).delay(0.1)) { shown = true } }
    }

    private func buy(_ a: PayCatalogItem) {
        PayApprovalHook.shared.request(Approval(
            kind: "API purchase", title: "\(a.by) \(a.name)",
            lines: [["Price", a.price], ["Pay with", "USDC via x402"], ["Monthly cap", "$50"], ["Key", "Stored in local vault"]],
            checks: PayChecks.base(["Seller matches registry"]), success: "\(a.by) connected"
        ), model: model) {
            withAnimation(.snappy) { store.mine.append(PayApi(name: a.by, plan: a.name, used: 0, cap: 50, calls: "Just added")) }
        }
    }
}
