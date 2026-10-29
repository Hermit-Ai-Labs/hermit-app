import SwiftUI
import HermitCore

/// Exchange-style send: from wallet, network, address (paste or scan), a whitelist of saved addresses,
/// add address with a 24-hour hold, and Whitelist only. Address format is checked per network before Review.
struct WalletSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @Bindable var vm: WalletsViewModel
    @State private var fromID: String
    @State private var chain: WalletChain
    @State private var token: String
    @State private var address = ""
    @State private var amount: Double = 200
    @State private var adding = false
    @State private var error: String?
    @State private var busy = false
    // Add address form
    @State private var newLabel = ""
    @State private var newChain: WalletChain = .base
    @State private var newAddress = ""

    init(vm: WalletsViewModel, fromID: String, chain: WalletChain?, token: String?) {
        self.vm = vm
        let w = vm.wallet(fromID) ?? vm.wallets.first
        let c = chain ?? (w?.chains.contains(.base) == true ? .base : (w?.chains.first ?? .base))
        _fromID = State(initialValue: w?.id ?? "main")
        _chain = State(initialValue: c)
        _token = State(initialValue: token ?? "USDC")
        _amount = State(initialValue: token == nil || token == "USDC" ? 200 : max(0.01, ((vm.balance(of: token!, wallet: w?.id ?? "", chain: c)) / 2 * 100).rounded() / 100))
    }

    private var wallet: WalletAccount? { vm.wallet(fromID) }
    private var saved: SavedAddress? { vm.saved(address) }
    private var valid: Bool { chain.accepts(address) }
    private var kindMismatch: Bool { !valid && WalletChain.kind(of: address).map { $0 != chain.kind } == true }
    private var wrongNet: Bool { (saved.map { $0.chain != chain }) ?? false }
    private var blocked: Bool { vm.whitelistOnly && (saved == nil || saved!.hold) }
    private var available: Double { vm.balance(of: token, wallet: fromID, chain: chain) }
    private var canReview: Bool { valid && amount > 0 && amount <= available && !blocked && !wrongNet && !busy }

    var body: some View {
        if adding { addAddress } else { form }
    }

    // MARK: Send form

    private var form: some View {
        SheetChrome(title: "Send") {
            HStack(spacing: 10) {
                FormField(label: "From") {
                    MenuField(selection: $fromID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 },
                              symbol: { vm.wallet($0)?.symbol })
                }
                FormField(label: "Network") {
                    MenuField(selection: $chain, options: wallet?.chains ?? WalletChain.all, title: \.name, logo: { $0.logo })
                }
            }
            FormField(label: "Address") {
                HStack(spacing: 8) {
                    TextField(chain.placeholder, text: $address)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("Paste") { paste() }.buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                    Button { scan() } label: { Image(systemName: "qrcode.viewfinder").font(.system(size: 15)).foregroundStyle(Theme.text) }
                        .buttonStyle(PressStyle()).help("Scan QR code").accessibilityLabel("Scan QR code")
                }
                .modifier(FieldBox())
            }
            if !address.isEmpty { status.transition(.opacity.combined(with: .offset(y: -4))) }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Whitelist") {
                    HStack(spacing: 8) {
                        Text("Whitelist only").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Toggle("Whitelist only", isOn: $vm.whitelistOnly).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.text)
                    }
                }
                ForEach(vm.whitelist) { w in
                    SelectRow(title: w.label, subtitle: "\(shortAddr(w.address)), \(w.chain.name)", mono: true,
                              on: address == w.address, action: { pick(w) }) {
                        LogoMark(w.chain.logo, size: 26)
                    } trailing: {
                        if w.hold { PillTag(text: "24h hold", color: Theme.amber) }
                        else { Image(systemName: "checkmark.shield.fill").font(.system(size: 14)).foregroundStyle(Theme.green) }
                    }
                    .opacity(w.hold ? 0.65 : 1)
                }
                SelectRow(title: "Add address", subtitle: "Save a label, network and address", action: { withAnimation(.smooth) { adding = true } }) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }

            HStack(spacing: 10) {
                FormField(label: "Amount") { AmountField(value: $amount) }
                FormField(label: "Asset", trailing: "\(MoneyFmt.amount(available)) left") {
                    MenuField(selection: $token, options: vm.tokens(wallet: fromID, chain: chain), title: { $0 }, logo: { $0 })
                }
            }
            WrapRow {
                ForEach(quick, id: \.0) { q in SelectChip(title: q.0, on: amount == q.1) { amount = q.1 } }
            }
            if amount > available {
                Text("Only \(MoneyFmt.amount(available)) \(token) in \(wallet?.name ?? "this wallet") on \(chain.name).")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.red)
            } else if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
        } foot: {
            Button { review() } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text("Review")
                }
            }
            .buttonStyle(WideButton())
            .disabled(!canReview)
            .keyboardShortcut(.defaultAction)
        }
        .animation(.smooth(duration: 0.25), value: address)
        .onChange(of: fromID) { _, _ in
            if let w = wallet, !w.chains.contains(chain) { chain = w.chains.first ?? .base }
        }
        .onChange(of: chain) { _, c in
            if !vm.tokens(wallet: fromID, chain: c).contains(token) { token = "USDC" }
        }
    }

    private var quick: [(String, Double)] {
        let stable = ["USDC", "USDT"].contains(token)
        var q: [(String, Double)] = stable ? [("100", 100), ("500", 500), ("1,000", 1000)]
            : [("25%", (available * 0.25 * 1e6).rounded() / 1e6), ("50%", (available * 0.5 * 1e6).rounded() / 1e6)]
        q.append(("Max", available))
        return q
    }

    @ViewBuilder private var status: some View {
        let (icon, text, color): (String, String, Color) = {
            if let s = saved, !wrongNet, !s.hold { return ("checkmark.shield.fill", "Whitelisted: \(s.label)", Theme.green) }
            if let s = saved, wrongNet { return ("exclamationmark.triangle.fill", "This address is saved for \(s.chain.name), not \(chain.name)", Theme.red) }
            if saved?.hold == true { return ("clock", "Unlocks 24 hours after it was added", Theme.amber) }
            if kindMismatch { return ("exclamationmark.triangle.fill", chain.kind == .solana ? "That is an EVM address. Pick an EVM network or paste a Solana address." : "That is a Solana address. Pick Solana or paste a 0x address.", Theme.red) }
            if !valid { return ("exclamationmark.circle", "Not a valid \(chain.name) address", Theme.red) }
            if let own = vm.ownWallet(for: address) { return ("person.crop.circle.badge.checkmark", "Your own wallet: \(own.name)", Theme.green) }
            if vm.whitelistOnly { return ("lock.fill", "Not on your whitelist. Add it first, or turn off Whitelist only.", Theme.red) }
            return ("info.circle", "New address. Double-check before sending.", Theme.muted)
        }()
        Label(text, systemImage: icon).font(.system(size: 12.5)).foregroundStyle(color).padding(.top, -6)
    }

    private func paste() {
        if let s = Clip.paste()?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count < 80 { address = s }
        else { address = chain == .solana ? "9PfQ2tLm7WcRzK4hXv8DnB3eJ6sGuY5wAqTpVx4k" : "0x2b9F41c8D0e7A3b15c6E9d2F4a8B7c3E1d0f9e04" }
    }

    private func scan() {
        let s = vm.whitelist.first { $0.chain == chain && !$0.hold } ?? vm.whitelist[1]
        if wallet?.chains.contains(s.chain) == true { chain = s.chain }
        address = s.address
        model.toast("QR code scanned")
    }

    private func pick(_ w: SavedAddress) {
        if w.hold { model.toast("This address unlocks 24 hours after it was added"); return }
        if wallet?.chains.contains(w.chain) == false, let other = vm.wallets.first(where: { $0.chains.contains(w.chain) }) { fromID = other.id }
        address = w.address; chain = w.chain
    }

    private func review() {
        guard let w = wallet else { return }
        busy = true; error = nil
        let label = saved?.label
        Task {
            do {
                let q = try await vm.provider.prepareSend(from: w, chain: chain, to: address.trimmingCharacters(in: .whitespaces), amount: amount, token: token)
                busy = false
                ask(vm.approval(for: q, label: label)) { Task { await vm.execute(q) } }
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Add address

    private var addAddress: some View {
        let ok = !newLabel.trimmingCharacters(in: .whitespaces).isEmpty && newChain.accepts(newAddress)
        return SheetChrome(title: "Add to whitelist", onBack: { withAnimation(.smooth) { adding = false } }) {
            FormField(label: "Label") { BoxedTextField(placeholder: "e.g. Binance deposit", text: $newLabel) }
            FormField(label: "Network") { MenuField(selection: $newChain, options: WalletChain.all, title: \.name, logo: { $0.logo }) }
            FormField(label: "Address") { BoxedTextField(placeholder: newChain.placeholder, text: $newAddress, mono: true) }
            if !newAddress.isEmpty && !newChain.accepts(newAddress) {
                Label(WalletChain.kind(of: newAddress).map { $0 != newChain.kind } == true
                      ? "This looks like a \(newChain.kind == .evm ? "Solana" : "EVM") address, not a \(newChain.name) one"
                      : "Not a valid \(newChain.name) address", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            NoteBox(symbol: "checkmark.shield", text: "For safety, new addresses unlock 24 hours after you add them. You confirm with Face ID or Touch ID.")
        } foot: {
            Button("Back") { withAnimation(.smooth) { adding = false } }.buttonStyle(WideButton(kind: .plain))
            Button("Save address") {
                vm.addAddress(label: newLabel.trimmingCharacters(in: .whitespaces), address: newAddress.trimmingCharacters(in: .whitespaces), chain: newChain)
                model.toast("\(newLabel) added. Usable in 24 hours.")
                newLabel = ""; newAddress = ""
                withAnimation(.smooth) { adding = false }
            }
            .buttonStyle(WideButton()).disabled(!ok)
        }
    }
}

/// Move money between your own wallets. Uses the same prepare/execute path as Send.
struct TransferSheet: View {
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    @State private var fromID: String
    @State private var toID: String
    @State private var chain: WalletChain = .base
    @State private var token = "USDC"
    @State private var amount: Double = 500
    @State private var error: String?

    init(vm: WalletsViewModel, fromID: String) {
        self.vm = vm
        _fromID = State(initialValue: fromID)
        _toID = State(initialValue: vm.wallets.first { $0.id != fromID }?.id ?? "trading")
    }

    private var common: [WalletChain] {
        guard let a = vm.wallet(fromID), let b = vm.wallet(toID) else { return WalletChain.all }
        return a.chains.filter { b.chains.contains($0) }
    }
    private var available: Double { vm.balance(of: token, wallet: fromID, chain: chain) }

    var body: some View {
        SheetChrome(title: "Transfer", subtitle: "Between your wallets") {
            HStack(spacing: 10) {
                FormField(label: "From") {
                    MenuField(selection: $fromID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                }
                FormField(label: "To") {
                    MenuField(selection: $toID, options: vm.wallets.map(\.id).filter { $0 != fromID }, title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                }
            }
            FormField(label: "Network") { MenuField(selection: $chain, options: common, title: \.name, logo: { $0.logo }) }
            HStack(spacing: 10) {
                FormField(label: "Amount") { AmountField(value: $amount) }
                FormField(label: "Asset", trailing: "\(MoneyFmt.amount(available)) left") {
                    MenuField(selection: $token, options: vm.tokens(wallet: fromID, chain: chain), title: { $0 }, logo: { $0 })
                }
            }
            WrapRow {
                ForEach([("100", 100.0), ("500", 500), ("1,000", 1000), ("Max", available)], id: \.0) { q in
                    SelectChip(title: q.0, on: amount == q.1) { amount = q.1 }
                }
            }
            if amount > available {
                Text("Only \(MoneyFmt.amount(available)) \(token) on \(chain.name).").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            } else if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            if let to = vm.wallet(toID), let a = to.address(on: chain) {
                NoteBox(symbol: "person.crop.circle.badge.checkmark", text: "Arrives at \(to.name), \(shortAddr(a)) on \(chain.name).")
            }
        } foot: {
            Button("Review") { review() }.buttonStyle(WideButton()).disabled(amount <= 0 || amount > available || common.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .onChange(of: fromID) { _, f in
            if toID == f { toID = vm.wallets.first { $0.id != f }?.id ?? toID }
            if !common.contains(chain) { chain = common.first ?? .base }
        }
        .onChange(of: toID) { _, _ in if !common.contains(chain) { chain = common.first ?? .base } }
        .onChange(of: chain) { _, c in if !vm.tokens(wallet: fromID, chain: c).contains(token) { token = "USDC" } }
    }

    private func review() {
        guard let from = vm.wallet(fromID), let to = vm.wallet(toID)?.address(on: chain) else { return }
        Task {
            do {
                let q = try await vm.provider.prepareSend(from: from, chain: chain, to: to, amount: amount, token: token)
                ask(vm.approval(for: q, label: nil)) { Task { await vm.execute(q) } }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Receive / Deposit: pick a wallet and a network, then a real QR code and the address to copy.
struct WalletReceiveSheet: View {
    @Environment(AppModel.self) private var model
    let vm: WalletsViewModel
    @State private var walletID: String
    @State private var chain: WalletChain = .base
    var title = "Deposit"

    init(vm: WalletsViewModel, walletID: String, title: String) {
        self.vm = vm; self.title = title
        _walletID = State(initialValue: walletID)
    }

    var body: some View {
        let w = vm.wallet(walletID)
        let chains = w?.chains ?? WalletChain.all
        let addr = w?.address(on: chain) ?? ""
        SheetChrome(title: title) {
            FormField(label: "Wallet") {
                MenuField(selection: $walletID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
            }
            FormField(label: "Network") {
                WrapRow {
                    ForEach(chains) { c in SelectChip(title: c.name, logo: c.logo, on: c == chain) { chain = c } }
                }
            }
            VStack(spacing: 14) {
                AddressQR(text: addr)
                    .frame(width: 176, height: 176)
                    .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
                    .overlay { LogoMark(chain.logo, size: 34).padding(3).background(.white, in: Circle()) }
                    .id(addr)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                Button { Clip.copy(addr); model.toast("Address copied") } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Text(addr).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Image(systemName: "doc.on.doc").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Copy address")
            }
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.25), value: addr)
            NoteBox(symbol: "info.circle", text: chain.kind == .evm
                    ? "Only send assets on \(chain.name) to this address. The same address works on every EVM network: \(WalletChain.evm.map(\.name).joined(separator: ", "))."
                    : "Only send Solana assets (SOL and SPL tokens) to this address.")
        }
        .onChange(of: walletID) { _, _ in if let w = vm.wallet(walletID), !w.chains.contains(chain) { chain = w.chains.first ?? .base } }
    }
}

/// Bridge between networks: chains, token, amount and a route.
struct BridgeSheet: View {
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    @State private var walletID: String
    @State private var from: WalletChain = .base
    @State private var to: WalletChain = .arbitrum
    @State private var token: String
    @State private var amount: Double = 500
    @State private var route = "Across"
    static let routes: [(String, String, Double)] = [("Across", "About 20 seconds", 0.42), ("deBridge", "About 1 minute", 0.65)]

    init(vm: WalletsViewModel, walletID: String, token: String) {
        self.vm = vm
        _walletID = State(initialValue: walletID)
        _token = State(initialValue: ["USDC", "ETH"].contains(token) ? token : "USDC")
        if token == "SOL" { _from = State(initialValue: .solana); _to = State(initialValue: .base) }
    }

    private var available: Double { vm.balance(of: token, wallet: walletID, chain: from) }
    private var chains: [WalletChain] { vm.wallet(walletID)?.chains ?? WalletChain.all }

    var body: some View {
        SheetChrome(title: "Bridge") {
            FormField(label: "Wallet") {
                MenuField(selection: $walletID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
            }
            HStack(alignment: .bottom, spacing: 8) {
                FormField(label: "From") { MenuField(selection: $from, options: chains.filter { $0 != to }, title: \.name, logo: { $0.logo }) }
                Button { withAnimation(.snappy) { let t = from; from = to; to = t } } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        .frame(width: 32, height: 40)
                }
                .buttonStyle(PressStyle()).help("Swap networks")
                FormField(label: "To") { MenuField(selection: $to, options: chains.filter { $0 != from }, title: \.name, logo: { $0.logo }) }
            }
            HStack(spacing: 10) {
                FormField(label: "Amount") { AmountField(value: $amount) }
                FormField(label: "Token", trailing: "\(MoneyFmt.amount(available)) left") {
                    MenuField(selection: $token, options: ["USDC", "ETH", "SOL", "BNB"], title: { $0 }, logo: { $0 })
                }
            }
            if amount > available {
                Text("Only \(MoneyFmt.amount(available)) \(token) on \(from.name).").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            FormField(label: "Route") {
                VStack(spacing: 6) {
                    ForEach(Self.routes, id: \.0) { r in
                        SelectRow(title: r.0, subtitle: r.1, on: route == r.0, action: { route = r.0 }) {
                            LogoMark(r.0, size: 26)
                        } trailing: {
                            HStack(spacing: 8) {
                                if r.0 == "Across" { Text("Best").font(.system(size: 12)).foregroundStyle(Theme.green) }
                                Text("$\(r.2.formatted(.number.precision(.fractionLength(2))))").font(.system(size: 13)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        } foot: {
            Button("Review") { review() }.buttonStyle(WideButton()).disabled(amount <= 0 || amount > available).keyboardShortcut(.defaultAction)
        }
        .onChange(of: walletID) { _, _ in
            if !chains.contains(from) { from = chains.first ?? .base }
            if !chains.contains(to) || to == from { to = chains.first { $0 != from } ?? .base }
        }
    }

    private func review() {
        let r = Self.routes.first { $0.0 == route }!
        let (w, t, a, f, d) = (walletID, token, amount, from, to)
        let wname = vm.wallet(w)?.name ?? "Wallet"
        ask(Approval(kind: "Bridge", title: "Bridge \(MoneyFmt.amount(a)) \(t)",
                     lines: [["Wallet", wname], ["From", f.name], ["To", d.name], ["Amount", "\(MoneyFmt.amount(a)) \(t)"], ["Route", route], ["Time", r.1], ["Fee", "$\(r.2)"]],
                     checks: WalletSeed.checks(["Bridge contract audited", "Destination is your own wallet"]),
                     success: "\(MoneyFmt.amount(a)) \(t) arrived on \(d.name)",
                     receipt: .receipt(title: "Bridged \(MoneyFmt.amount(a)) \(t)", rows: [["From", f.name], ["To", d.name], ["Route", route]]))) {
            vm.bridge(wallet: w, token: t, amount: a, from: f, to: d, route: route)
        }
    }
}
