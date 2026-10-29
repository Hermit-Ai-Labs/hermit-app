import SwiftUI
import CoreImage.CIFilterBuiltins
import HermitCore

/// Phantom-style wallet actions under the home greeting: money moves sit right next to the AI.
enum WalletSheet: String, Identifiable { case send, swap, receive, buy; var id: String { rawValue } }

struct WalletActionSheet: View {
    let kind: WalletSheet
    var body: some View {
        switch kind {
        case .send: SendSheet()
        case .swap: SwapSheet()
        case .receive: ReceiveSheet()
        case .buy: BuySheet()
        }
    }
}

private let prices: [String: Double] = ["USDC": 1, "ETH": 3498, "SOL": 186.6, "HYPE": 24.06]
private let tokens = ["USDC", "ETH", "SOL", "HYPE"]

/// Hands an approval to the model after the sheet has gone, so the two sheets never overlap.
@MainActor private func approveAfterDismiss(_ model: AppModel, _ a: Approval, _ dismiss: DismissAction) {
    dismiss()
    Task { try? await Task.sleep(for: .milliseconds(350)); model.approval = a }
}

private struct TokenPicker: View {
    @Binding var token: String
    var body: some View {
        Menu {
            ForEach(tokens, id: \.self) { t in Button(t) { token = t } }
        } label: {
            HStack(spacing: 6) {
                LogoMark(token, size: 22)
                Text(token).font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.bg, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct AmountBox<Trailing: View>: View {
    let label: String
    @ViewBuilder var amount: () -> AnyView
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) { amount(); Spacer(minLength: 8); trailing() }
        }
        .padding(14)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

struct SwapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var from = "USDC"
    @State private var to = "ETH"
    @State private var amount: Double = 500

    private var out: Double { amount * (prices[from] ?? 1) / (prices[to] ?? 1) }
    private var outText: String { out < 1 ? String(format: "%.4f", out) : out.formatted(.number.precision(.fractionLength(0...2))) }

    var body: some View {
        SheetScaffold(title: "Swap") {
            AmountBox(label: "You pay") {
                AnyView(TextField("0", value: $amount, format: .number).textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).monospacedDigit())
            } trailing: { TokenPicker(token: $from) }
            Button { withAnimation(.snappy) { let f = from; from = to; to = f } } label: {
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32).background(Theme.bg, in: Circle()).overlay(Circle().strokeBorder(Theme.border))
            }
            .buttonStyle(PressStyle()).frame(maxWidth: .infinity).padding(.vertical, -10).zIndex(1)
            AmountBox(label: "You receive") {
                AnyView(Text(outText).font(.system(size: 24, weight: .semibold)).monospacedDigit().contentTransition(.numericText()))
            } trailing: { TokenPicker(token: $to) }
            HStack {
                Text("1 \(from) = \(String(format: "%.4g", (prices[from] ?? 1) / (prices[to] ?? 1))) \(to)")
                Spacer()
                Text("Fee $0.04")
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        } foot: {
            Button("Review") {
                approveAfterDismiss(model, Approval(kind: "Swap", title: "Swap \(amount.formatted()) \(from) to \(to)",
                    lines: [["Pay", "\(amount.formatted()) \(from)"], ["Receive", "≈ \(outText) \(to)"], ["Route", "Best of 6 DEXs"], ["Fee", "$0.04"]],
                    checks: Approval.checks(["Price impact under 0.1%"]), success: "Got \(outText) \(to)"), dismiss)
            }
            .buttonStyle(SheetButton(primary: true)).disabled(amount <= 0 || from == to)
        }
    }
}

struct BuySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var usd: Double = 100
    @State private var token = "USDC"
    @State private var applePay = true

    var body: some View {
        let get = usd / (prices[token] ?? 1)
        SheetScaffold(title: "Buy") {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("$").font(.system(size: 36, weight: .semibold)).foregroundStyle(Theme.muted)
                TextField("0", value: $usd, format: .number).textFieldStyle(.plain).font(.system(size: 44, weight: .semibold)).monospacedDigit()
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                ForEach([50.0, 100, 250, 500], id: \.self) { v in
                    Button("$\(Int(v))") { withAnimation(.snappy) { usd = v } }.buttonStyle(SmallChip(on: usd == v))
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                ForEach(tokens, id: \.self) { t in
                    Button { withAnimation(.snappy) { token = t } } label: {
                        VStack(spacing: 5) { LogoMark(t, size: 24); Text(t).font(.system(size: 12, weight: .medium)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(token == t ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(token == t ? Theme.text : Theme.border, lineWidth: token == t ? 1.5 : 1))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            VStack(spacing: 8) {
                payRow(true, "Apple Pay", "Instant")
                payRow(false, "Visa ending 4242", "Instant, 1% fee")
            }
            Text("Lands in Main. USDC has no fee.").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
        } foot: {
            Button("Review") {
                approveAfterDismiss(model, Approval(kind: "Buy crypto", title: "Buy $\(Int(usd)) of \(token)",
                    lines: [["Pay", "$\(String(format: "%.2f", usd)) with \(applePay ? "Apple Pay" : "Visa ending 4242")"],
                            ["Get", "≈ \(get < 1 ? String(format: "%.4f", get) : String(format: "%.2f", get)) \(token)"], ["To", "Main wallet"],
                            ["Fee", token == "USDC" ? "$0" : String(format: "$%.2f", usd * 0.01)]],
                    checks: Approval.checks(["Delivered to your own wallet"]), success: "\(token) is in Main"), dismiss)
            }
            .buttonStyle(SheetButton(primary: true)).disabled(usd <= 0)
        }
    }

    private func payRow(_ apple: Bool, _ title: String, _ detail: String) -> some View {
        Button { withAnimation(.snappy) { applePay = apple } } label: {
            HStack(spacing: 12) {
                Image(systemName: apple ? "apple.logo" : "creditcard").font(.system(size: 14)).frame(width: 30, height: 30)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: applePay == apple ? "checkmark.circle.fill" : "circle").foregroundStyle(applePay == apple ? Theme.text : Theme.faint)
            }
            .padding(10).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(applePay == apple ? Theme.text : Theme.border))
        }
        .buttonStyle(.plain)
    }
}

struct SendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var to = ""
    @State private var amount: Double = 100
    @State private var token = "USDC"

    private var valid: Bool { to.hasSuffix(".eth") || (to.hasPrefix("0x") && to.count >= 10) }

    var body: some View {
        SheetScaffold(title: "Send") {
            VStack(alignment: .leading, spacing: 6) {
                Text("To").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                TextField(text: $to, prompt: Text("Address or ENS, e.g. alice.eth").foregroundStyle(Theme.faint)) { Text("To") }.textFieldStyle(.plain).font(.system(size: 14))
                    .autocorrectionDisabled()
                    .padding(12).background(Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
                HStack(spacing: 6) {
                    ForEach(["alice.eth", "bob.base.eth", "Vault"], id: \.self) { s in
                        Button(s) { to = s == "Vault" ? "0xF09e…13B4" : s }.buttonStyle(SmallChip())
                    }
                }
            }
            AmountBox(label: "Amount") {
                AnyView(TextField("0", value: $amount, format: .number).textFieldStyle(.plain).font(.system(size: 24, weight: .semibold)).monospacedDigit())
            } trailing: { TokenPicker(token: $token) }
            Text("From Main, 21,400 available. Network fee about $0.01.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        } foot: {
            Button("Review") {
                approveAfterDismiss(model, Approval(kind: "Transfer", title: "Send \(amount.formatted()) \(token) to \(to)",
                    lines: [["To", to], ["Amount", "\(amount.formatted()) \(token)"], ["From", "Main wallet"], ["Fee", "$0.01"]],
                    checks: Approval.checks(["Address is not a known drainer"]), success: "Sent to \(to)"), dismiss)
            }
            .buttonStyle(SheetButton(primary: true)).disabled(!valid || amount <= 0)
        }
    }
}

struct ReceiveSheet: View {
    @Environment(AppModel.self) private var model
    let address = "0x7a3F9c21B04e88d5A1f6c3E2d90Bb4e7c51A9c2E"
    var body: some View {
        SheetScaffold(title: "Receive") {
            VStack(spacing: 14) {
                QRCode(text: address).frame(width: 180, height: 180)
                    .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
                Text("Main wallet").font(.system(size: 14, weight: .medium))
                Text(address).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button { Clipboard.copy(address); model.toast("Address copied") } label: { Label("Copy address", systemImage: "doc.on.doc") }
                    .buttonStyle(PlainCardButton())
                Text("Send only on Base, Ethereum, Arbitrum or Polygon.").font(.system(size: 12)).foregroundStyle(Theme.faint)
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
