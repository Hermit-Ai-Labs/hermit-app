import SwiftUI

/// Binance-style wallet switcher: All wallets, then Local wallets and Privy wallets, each group with its own add action.
struct WalletPicker: View {
    let vm: WalletsViewModel
    @Binding var selected: String
    let onAdd: (WalletAccount.Custody) -> Void
    @State private var open = false
    @State private var hover = false

    private var current: WalletAccount? { vm.wallet(selected) }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                SymbolTile(symbol: current?.symbol ?? "wallet.bifold", size: 26)
                Text(current?.name ?? "All wallets").font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.leading, 5).padding(.trailing, 13).padding(.vertical, 5)
            .background(hover || open ? Theme.hover : Theme.subtle, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .animation(.snappy(duration: 0.25), value: open)
        .accessibilityLabel("Wallet: \(current?.name ?? "All wallets")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WalletMenu(vm: vm, selected: $selected, close: { open = false }, onAdd: onAdd)
                .presentationCompactAdaptation(.popover)
        }
    }

}

/// The picker's dropdown: All wallets, Local wallets, Privy wallets.
struct WalletMenu: View {
    let vm: WalletsViewModel
    @Binding var selected: String
    let close: () -> Void
    let onAdd: (WalletAccount.Custody) -> Void

    var body: some View { menu }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(id: "all", symbol: "wallet.bifold", title: "All wallets", sub: "\(vm.wallets.count) wallets", mono: false, usd: vm.total())
            ForEach([WalletAccount.Custody.local, .privy], id: \.self) { g in
                Hairline().padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g == .local ? "Local wallets" : "Privy wallets").font(.system(size: 12.5, weight: .semibold))
                    Text(g == .local ? "Keys stay on this device" : "Keyless, sign in with email or passkey")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
                ForEach(vm.wallets.filter { $0.custody == g }) { w in
                    row(id: w.id, symbol: w.symbol, title: w.name, sub: w.shortAddress, mono: true, usd: vm.total(w.id), chains: w.chains)
                }
                Button { close(); onAdd(g) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 8.5).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        Text(g == .local ? "Create or import local wallet" : "Create Privy wallet").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .padding(8)
        .frame(width: 350)
        .background(Theme.bg)
    }

    private func row(id: String, symbol: String, title: String, sub: String, mono: Bool, usd: Double, chains: [WalletChain] = []) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { selected = id }
            close()
        } label: {
            HStack(spacing: 10) {
                SymbolTile(symbol: symbol, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text(sub).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11.5)).foregroundStyle(Theme.muted)
                        if chains.count > 1 { ChainStack(chains: chains, size: 12) }
                    }
                }
                Spacer(minLength: 8)
                Text(MoneyFmt.usd(usd)).font(.system(size: 13.5)).monospacedDigit().foregroundStyle(Theme.text)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                    .opacity(selected == id ? 1 : 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(selected == id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// Snapshot helper: the dropdown on its own.
struct WalletPickerMenuPreview: View {
    let vm: WalletsViewModel
    var body: some View { WalletMenu(vm: vm, selected: .constant("all"), close: {}, onAdd: { _ in }) }
}

/// Menu-like row: hover highlight, quick press.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { MenuRowBody(configuration: configuration) }
    struct MenuRowBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? Theme.hover : hover ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}
