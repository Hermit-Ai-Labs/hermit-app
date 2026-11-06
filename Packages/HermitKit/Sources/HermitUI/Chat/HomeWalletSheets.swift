import SwiftUI
import CoreImage.CIFilterBuiltins
import HermitCore
import HermitWallet

/// Wallet actions under the home greeting, backed by the same wallets and engine as the Wallets page.
/// Send and Receive are real; Swap and Buy aren't connected yet and say so.
enum HomeWalletSheet: String, Identifiable { case send, swap, receive, buy; var id: String { rawValue } }

struct WalletActionSheet: View {
    let kind: HomeWalletSheet
    var body: some View {
        switch kind {
        case .send: SendSheet()
        case .swap: NotAvailableSheet(title: "Swap", symbol: "arrow.left.arrow.right",
                                      text: "Swapping from the wallet isn't available yet. It arrives after the wallet's security review.")
        case .receive: ReceiveSheet()
        case .buy: NotAvailableSheet(title: "Buy", symbol: "creditcard",
                                     text: "Buying crypto with a card or Apple Pay isn't available yet. To fund a wallet, send to its address from an exchange.")
        }
    }
}

/// Hands an approval to the model after the sheet has gone, so the two sheets never overlap.
@MainActor private func approveAfterDismiss(_ model: AppModel, _ a: Approval, _ dismiss: DismissAction) {
    dismiss()
    Task { try? await Task.sleep(for: .milliseconds(350)); model.approval = a }
}

/// Shown instead of a flow when there's no wallet yet: one tap to the Wallets page to create one.
private struct NeedsWallet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    var body: some View {
        SheetChrome(title: title) {
            Text("Create or import a wallet first. It takes a few seconds, and the keys stay on this device.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        } foot: {
            Button("Import phrase") { dismiss(); model.open(.wallets, tab: "import") }.buttonStyle(WideButton(kind: .plain))
            Button("Create a wallet") { dismiss(); model.open(.wallets, tab: "create") }.buttonStyle(WideButton())
        }
    }
}

/// A flow that isn't connected yet: an honest note and a greyed button.
struct NotAvailableSheet: View {
    let title: String
    let symbol: String
    let text: String
    var body: some View {
        SheetChrome(title: title) {
            HStack(alignment: .top, spacing: 12) {
                WalletSymbolTile(symbol: symbol, size: 40)
                Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        } foot: {
            Button("Review") {}.buttonStyle(WideButton()).notYet("\(title) isn't available yet")
        }
    }
}

/// Quick send from Home: wallet, network, address, amount. Review simulates and scans; Approve signs and sends.
struct SendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var vm = WalletsViewModel.shared
    @State private var walletID = WalletsViewModel.shared.firstWalletID ?? ""
    @State private var chain: Chain = Chain.defaultSend
    @State private var token = Chain.defaultSend.nativeSymbol
    @State private var to = ""
    @State private var amount = ""
    @State private var busy = false
    @State private var error: String?

    private var held: Holding? { vm.holding(token, wallet: walletID, chain: chain) }
    private var value: Double { AmountText.value(amount) ?? 0 }
    private var valid: Bool { chain.accepts(to) }

    var body: some View {
        if !vm.hasWallet { NeedsWallet(title: "Send") } else { form }
    }

    private var form: some View {
        SheetChrome(title: "Send") {
            HStack(spacing: 10) {
                if vm.wallets.count > 1 {
                    FormField(label: "From") {
                        MenuField(selection: $walletID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                    }
                }
                FormField(label: "Network") { MenuField(selection: $chain, options: sendPickerChains, title: sendChainTitle, logo: { $0.logo }) }
            }
            FormField(label: "To") { BoxedTextField(placeholder: chain.placeholder, text: $to, mono: true) }
            if !to.isEmpty && !valid {
                Label("Not a valid \(chain.name) address", systemImage: "exclamationmark.circle").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            HStack(spacing: 10) {
                FormField(label: "Amount") { AmountTextField(text: $amount) }
                FormField(label: "Asset", trailing: "\(held?.exact ?? "0") available") {
                    MenuField(selection: $token, options: vm.tokens(chain: chain), title: { $0 }, logo: { $0 })
                }
            }
            if !chain.sendsEnabled { MainnetLockedNote() }
            else if value > (held?.amount ?? 0) {
                Text(vm.loaded ? "Only \(held?.exact ?? "0") \(token) on \(chain.name)." : "Balances are still loading.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.red)
            } else if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { review() } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Simulating" : "Review") }
            }
            .buttonStyle(WideButton())
            .disabled(!chain.sendsEnabled || !valid || value <= 0 || value > (held?.amount ?? 0) || busy)
            .keyboardShortcut(.defaultAction)
        }
        .onChange(of: chain) { _, c in if !vm.tokens(chain: c).contains(token) { token = c.nativeSymbol }; error = nil }
        .task { if !vm.loaded && !WalletsViewModel.runningTests { await vm.refresh() } }
    }

    private func review() {
        busy = true; error = nil
        let (w, c, t, a, tk) = (walletID, chain, to, AmountText.clean(amount), token)
        Task {
            do {
                let p = try await vm.prepareSend(from: w, chain: c, to: t, amount: a, token: tk)
                let approval = try vm.approval(for: p)
                busy = false
                approveAfterDismiss(model, approval, dismiss)
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
}

/// Quick receive from Home: the wallet's real EVM or Solana address with a QR code.
struct ReceiveSheet: View {
    @Environment(AppModel.self) private var model
    @State private var vm = WalletsViewModel.shared
    @State private var walletID = WalletsViewModel.shared.firstWalletID ?? ""
    @State private var kind: ChainKind = .evm

    var body: some View {
        if !vm.hasWallet { NeedsWallet(title: "Receive") } else { content }
    }

    private var content: some View {
        let w = vm.wallet(walletID) ?? vm.wallets.first
        let address = (kind == .evm ? w?.evmAddress : w?.solanaAddress) ?? ""
        return SheetChrome(title: "Receive", subtitle: w?.name) {
            if vm.wallets.count > 1 {
                FormField(label: "Wallet") {
                    MenuField(selection: $walletID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 }, symbol: { vm.wallet($0)?.symbol })
                }
            }
            Segmented(options: [(ChainKind.evm, "EVM networks"), (.solana, "Solana")], selection: $kind)
            VStack(spacing: 14) {
                QRCode(text: address).frame(width: 180, height: 180)
                    .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
                    .id(address)
                Text(address).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button { Clip.copy(address); model.toast("Address copied") } label: { Label("Copy address", systemImage: "doc.on.doc") }
                    .buttonStyle(WideButton(kind: .plain))
                Text(kind == .evm ? "Works on \(Chain.evmMainnets.map(\.name).joined(separator: ", ")) and their testnets."
                                  : "Solana and Solana Devnet: SOL and SPL tokens only.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct QRCode: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            img.interpolation(.none).resizable().scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit()
        }
    }
    static func make(_ s: String) -> Image? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}
