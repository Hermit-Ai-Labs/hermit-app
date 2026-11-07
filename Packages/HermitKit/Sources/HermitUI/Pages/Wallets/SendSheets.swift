import SwiftUI
import HermitCore
import HermitWallet

/// Network order for pickers: the testnets that can send first, then mainnets (view and receive only for now).
let sendPickerChains: [Chain] = Chain.testnets + Chain.mainnets

/// "Base Sepolia" for testnets, "Base (sends locked)" for mainnets while mainnet sends are off.
func sendChainTitle(_ c: Chain) -> String { c.sendsEnabled ? c.name : "\(c.name) (sends locked)" }

/// Shown under the form when a mainnet is picked: the Review button is greyed.
struct MainnetLockedNote: View {
    var body: some View {
        NoteBox(symbol: "lock.fill", text: "Sends on this network are switched off in this build. Pick another network.",
                tint: Theme.amber)
    }
}

/// Amount typed as text so the exact value reaches the engine (no floating-point rounding).
struct AmountTextField: View {
    @Binding var text: String
    var body: some View {
        TextField("0", text: $text)
            .textFieldStyle(.plain).font(.system(size: 14)).monospacedDigit()
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .modifier(FieldBox())
    }
}

/// A fraction of an exact balance, rounded down to at most 8 decimals ("25%", "50%").
func fractionText(_ h: Holding?, _ f: Double) -> String {
    guard let h, h.amount > 0 else { return "0" }
    let digits = 8.0
    let v = (h.amount * f * pow(10, digits)).rounded(.down) / pow(10, digits)
    var s = String(format: "%.8f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// Send: from wallet, network, address (paste), saved addresses (whitelist, 24-hour hold on new ones), amount.
/// Review simulates the transfer and runs the hazard scan; Approve signs with Touch ID / Face ID and broadcasts.
/// Testnets only for now; mainnet networks show the send greyed out.
struct WalletSendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @Bindable var vm: WalletsViewModel
    @State private var fromID: String
    @State private var chain: Chain
    @State private var token: String
    @State private var address = ""
    @State private var amount = ""
    @State private var adding = false
    @State private var scanning = false
    @State private var error: String?
    @State private var busy = false
    // Add address form
    @State private var newLabel = ""
    @State private var newKind: ChainKind = .evm
    @State private var newAddress = ""

    init(vm: WalletsViewModel, fromID: String, chain: Chain?, token: String?) {
        self.vm = vm
        let w = vm.wallet(fromID) ?? vm.wallets.first
        let pre = vm.sendPrefill
        vm.sendPrefill = nil
        let c = pre?.chain ?? chain ?? Chain.defaultSend
        _fromID = State(initialValue: w?.id ?? "")
        _chain = State(initialValue: c)
        let want = pre?.token ?? token
        _token = State(initialValue: want.flatMap { t in vm.tokens(chain: c).contains(t) ? t : nil } ?? c.nativeSymbol)
        _address = State(initialValue: pre?.address ?? "")
        _amount = State(initialValue: pre?.amount ?? "")
    }

    private var wallet: WalletAccount? { vm.wallet(fromID) }
    private var saved: SavedAddress? { vm.saved(address) }
    private var valid: Bool { chain.accepts(address) }
    private var kindMismatch: Bool { !valid && Chain.kind(of: address).map { $0 != chain.kind } == true }
    private var wrongNet: Bool { (saved.map { $0.kind != chain.kind }) ?? false }
    private var blocked: Bool { vm.whitelistOnly && vm.ownWallet(for: address) == nil && (saved == nil || saved!.hold) }
    private var held: Holding? { vm.holding(token, wallet: fromID, chain: chain) }
    private var available: Double { held?.amount ?? 0 }
    private var value: Double { AmountText.value(amount) ?? 0 }
    private var canReview: Bool {
        chain.sendsEnabled && valid && value > 0 && value <= available && !blocked && !wrongNet && !busy && wallet != nil
    }

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
                    MenuField(selection: $chain, options: sendPickerChains, title: sendChainTitle, logo: { $0.logo })
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
                    #if os(iOS)
                    if QRScannerView.available {
                        Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder").font(.system(size: 15)).foregroundStyle(Theme.text) }
                            .buttonStyle(PressStyle()).accessibilityLabel("Scan QR code")
                    }
                    #endif
                }
                .modifier(FieldBox())
            }
            if !address.isEmpty { status.transition(.opacity.combined(with: .offset(y: -4))) }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Saved addresses") {
                    HStack(spacing: 8) {
                        Text("Whitelist only").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Toggle("Whitelist only", isOn: $vm.whitelistOnly).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.text)
                    }
                }
                let list = vm.whitelist.filter { $0.kind == chain.kind }
                if list.isEmpty {
                    Text("No saved \(chain.kind == .evm ? "EVM" : "Solana") addresses yet.").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                }
                ForEach(list) { w in
                    SelectRow(title: w.label, subtitle: "\(shortAddr(w.address)), \(w.networkName)", mono: true,
                              on: address == w.address, action: { pick(w) }) {
                        LogoMark(w.kind == .evm ? "ethereum" : "solana", size: 26)
                    } trailing: {
                        if w.hold { PillTag(text: "24h hold", color: Theme.amber) }
                        else { Image(systemName: "checkmark.shield.fill").font(.system(size: 14)).foregroundStyle(Theme.green) }
                    }
                    .opacity(w.hold ? 0.65 : 1)
                    .contextMenu { Button("Remove", role: .destructive) { vm.removeAddress(w) } }
                }
                SelectRow(title: "Add address", subtitle: "Save a label and address", action: {
                    newKind = chain.kind
                    withAnimation(.smooth) { adding = true }
                }) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                }
            }

            HStack(spacing: 10) {
                FormField(label: "Amount") { AmountTextField(text: $amount) }
                FormField(label: "Asset", trailing: "\(held?.exact ?? "0") available") {
                    MenuField(selection: $token, options: vm.tokens(chain: chain), title: { $0 }, logo: { $0 })
                }
            }
            WrapRow {
                ForEach([("25%", 0.25), ("50%", 0.5)], id: \.0) { q in
                    SelectChip(title: q.0, on: amount == fractionText(held, q.1) && available > 0) { amount = fractionText(held, q.1) }
                }
                SelectChip(title: "Max", on: amount == (held?.exact ?? "") && available > 0) { amount = held?.exact ?? "0" }
            }
            if !chain.sendsEnabled {
                MainnetLockedNote()
            } else if value > available {
                Text(vm.loaded ? "Only \(held?.exact ?? "0") \(token) in \(wallet?.name ?? "this wallet") on \(chain.name)." : "Balances are still loading.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.red)
            } else if let error {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
        } foot: {
            Button { review() } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Simulating" : "Review")
                }
            }
            .buttonStyle(WideButton())
            .disabled(!canReview)
            .help(chain.sendsEnabled ? "" : "Sends on this network are switched off in this build")
            .keyboardShortcut(.defaultAction)
        }
        .animation(.smooth(duration: 0.25), value: address)
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            QRScannerSheet { code in address = QRScannerView.address(from: code); scanning = false }
        }
        #endif
        .onChange(of: chain) { _, c in
            if !vm.tokens(chain: c).contains(token) { token = c.nativeSymbol }
            error = nil
        }
    }

    @ViewBuilder private var status: some View {
        let (icon, text, color): (String, String, Color) = {
            if let s = saved, wrongNet { return ("exclamationmark.triangle.fill", "\(s.label) is saved as a \(s.networkName) address, not \(chain.name)", Theme.red) }
            if let s = saved, !s.hold { return ("checkmark.shield.fill", "Saved: \(s.label)", Theme.green) }
            if saved?.hold == true { return ("clock", "Unlocks 24 hours after it was saved", Theme.amber) }
            if kindMismatch { return ("exclamationmark.triangle.fill", chain.kind == .solana ? "That is an EVM address. Pick an EVM network or paste a Solana address." : "That is a Solana address. Pick Solana or paste a 0x address.", Theme.red) }
            if !valid { return ("exclamationmark.circle", "Not a valid \(chain.name) address", Theme.red) }
            if let own = vm.ownWallet(for: address) { return ("person.crop.circle.badge.checkmark", "Your own wallet: \(own.name)", Theme.green) }
            if vm.whitelistOnly { return ("lock.fill", "Not saved. Add it first, or turn off Whitelist only.", Theme.red) }
            if ENS.looksLikeName(address) { return ("info.circle", "ENS name: resolved on Ethereum at Review.", Theme.muted) }
            return ("info.circle", "New address. Double-check before sending.", Theme.muted)
        }()
        Label(text, systemImage: icon).font(.system(size: 12.5)).foregroundStyle(color).padding(.top, -6)
    }

    private func paste() {
        if let s = Clip.paste()?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count < 100 { address = s }
        else { model.toast("Nothing to paste") }
    }

    private func pick(_ w: SavedAddress) {
        if w.hold { model.toast("This address unlocks 24 hours after it was saved"); return }
        address = w.address
        if w.kind != chain.kind { chain = w.kind == .solana ? .solanaDevnet : Chain.defaultSend }
    }

    private func review() {
        busy = true; error = nil
        let (f, c, to, a, t) = (fromID, chain, address, AmountText.clean(amount), token)
        Task {
            do {
                let p = try await vm.prepareSend(from: f, chain: c, to: to, amount: a, token: t)
                busy = false
                ask(try vm.approval(for: p))
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Add address

    private var addAddress: some View {
        let probe: Chain = newKind == .evm ? .ethereum : .solana
        let ok = !newLabel.trimmingCharacters(in: .whitespaces).isEmpty && EVMOrSolana.valid(newAddress, kind: newKind)
        return SheetChrome(title: "Save an address", onBack: { withAnimation(.smooth) { adding = false } }) {
            FormField(label: "Label") { BoxedTextField(placeholder: "e.g. Coinbase deposit", text: $newLabel) }
            FormField(label: "Type") { Segmented(options: [(ChainKind.evm, "EVM networks"), (.solana, "Solana")], selection: $newKind) }
            FormField(label: "Address") { BoxedTextField(placeholder: newKind == .evm ? "0x…" : "Solana address", text: $newAddress, mono: true) }
            if !newAddress.isEmpty && !EVMOrSolana.valid(newAddress, kind: newKind) {
                Label(Chain.kind(of: newAddress).map { $0 != newKind } == true
                      ? "This looks like a \(newKind == .evm ? "Solana" : "EVM") address"
                      : "Not a valid \(probe.kind == .evm ? "EVM" : "Solana") address", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            NoteBox(symbol: "checkmark.shield", text: "For safety, a new address can be used 24 hours after you save it. Saved addresses stay on this device.")
        } foot: {
            Button("Back") { withAnimation(.smooth) { adding = false } }.buttonStyle(WideButton(kind: .plain))
            Button("Save address") {
                let label = newLabel.trimmingCharacters(in: .whitespaces)
                vm.addAddress(label: label, address: newAddress.trimmingCharacters(in: .whitespaces), kind: newKind)
                model.toast("\(label) saved. Usable in 24 hours.")
                newLabel = ""; newAddress = ""
                withAnimation(.smooth) { adding = false }
            }
            .buttonStyle(WideButton()).disabled(!ok)
        }
    }
}

/// Plain address checks (no ENS) for saved addresses.
enum EVMOrSolana {
    static func valid(_ raw: String, kind: ChainKind) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .evm ? EVMAddress(s) != nil : SolanaPublicKey(s) != nil
    }
}

/// Move money between your own wallets. Same prepare / approve / send path as Send (testnets only for now).
struct TransferSheet: View {
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    @State private var fromID: String
    @State private var toID: String
    @State private var chain: Chain = Chain.defaultSend
    @State private var token = Chain.defaultSend.nativeSymbol
    @State private var amount = ""
    @State private var error: String?
    @State private var busy = false

    init(vm: WalletsViewModel, fromID: String) {
        self.vm = vm
        let f = vm.wallet(fromID)?.id ?? vm.wallets.first?.id ?? ""
        _fromID = State(initialValue: f)
        _toID = State(initialValue: vm.wallets.first { $0.id != f }?.id ?? "")
    }

    private var held: Holding? { vm.holding(token, wallet: fromID, chain: chain) }
    private var available: Double { held?.amount ?? 0 }
    private var value: Double { AmountText.value(amount) ?? 0 }

    var body: some View {
        SheetChrome(title: "Transfer", subtitle: "Between your wallets") {
            if vm.wallets.count < 2 {
                NoteBox(symbol: "info.circle", text: "You have one wallet. Add another to move money between them.")
            } else {
                HStack(spacing: 10) {
                    FormField(label: "From") {
                        MenuField(selection: $fromID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                    }
                    FormField(label: "To") {
                        MenuField(selection: $toID, options: vm.wallets.map(\.id).filter { $0 != fromID }, title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                    }
                }
                FormField(label: "Network") { MenuField(selection: $chain, options: sendPickerChains, title: sendChainTitle, logo: { $0.logo }) }
                HStack(spacing: 10) {
                    FormField(label: "Amount") { AmountTextField(text: $amount) }
                    FormField(label: "Asset", trailing: "\(held?.exact ?? "0") available") {
                        MenuField(selection: $token, options: vm.tokens(chain: chain), title: { $0 }, logo: { $0 })
                    }
                }
                WrapRow {
                    ForEach([("25%", 0.25), ("50%", 0.5)], id: \.0) { q in SelectChip(title: q.0, on: false) { amount = fractionText(held, q.1) } }
                    SelectChip(title: "Max", on: false) { amount = held?.exact ?? "0" }
                }
                if !chain.sendsEnabled { MainnetLockedNote() }
                else if value > available { Text("Only \(held?.exact ?? "0") \(token) on \(chain.name).").font(.system(size: 12.5)).foregroundStyle(Theme.red) }
                else if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
                if let to = vm.wallet(toID), let a = to.address(on: chain) {
                    NoteBox(symbol: "person.crop.circle.badge.checkmark", text: "Arrives at \(to.name), \(shortAddr(a)) on \(chain.name).")
                }
            }
        } foot: {
            Button { review() } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Simulating" : "Review") }
            }
            .buttonStyle(WideButton())
            .disabled(vm.wallets.count < 2 || !chain.sendsEnabled || value <= 0 || value > available || busy)
            .keyboardShortcut(.defaultAction)
        }
        .onChange(of: fromID) { _, f in if toID == f { toID = vm.wallets.first { $0.id != f }?.id ?? toID } }
        .onChange(of: chain) { _, c in if !vm.tokens(chain: c).contains(token) { token = c.nativeSymbol } }
    }

    private func review() {
        guard let to = vm.wallet(toID)?.address(on: chain) else { return }
        busy = true; error = nil
        let (f, c, a, t) = (fromID, chain, AmountText.clean(amount), token)
        Task {
            do {
                let p = try await vm.prepareSend(from: f, chain: c, to: to, amount: a, token: t)
                busy = false
                ask(try vm.approval(for: p))
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
}

/// Receive / Deposit: pick a wallet and a network, then a real QR code and the address to copy.
struct WalletReceiveSheet: View {
    @Environment(AppModel.self) private var model
    let vm: WalletsViewModel
    @State private var walletID: String
    @State private var chain: Chain = .base
    var title = "Deposit"

    init(vm: WalletsViewModel, walletID: String, title: String) {
        self.vm = vm; self.title = title
        _walletID = State(initialValue: vm.wallet(walletID)?.id ?? vm.wallets.first?.id ?? "")
    }

    var body: some View {
        let addr = vm.wallet(walletID)?.address(on: chain) ?? ""
        SheetChrome(title: title) {
            if vm.wallets.count > 1 {
                FormField(label: "Wallet") {
                    MenuField(selection: $walletID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                }
            }
            FormField(label: "Network") {
                VStack(alignment: .leading, spacing: 8) {
                    WrapRow { ForEach(Chain.mainnets) { c in SelectChip(title: c.name, logo: c.logo, on: c == chain) { chain = c } } }
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
                    ? "Only send assets on \(chain.name) to this address. The same address works on every EVM network: \(Chain.evmMainnets.map(\.name).joined(separator: ", "))."
                    : "Only send \(chain.isTestnet ? "Solana Devnet" : "Solana") assets (SOL and SPL tokens) to this address.")
        }
    }
}
