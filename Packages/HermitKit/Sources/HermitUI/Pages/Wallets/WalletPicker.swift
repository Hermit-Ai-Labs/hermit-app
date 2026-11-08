import SwiftUI
import HermitWallet

/// Wallet switcher: All wallets, then the wallets on this device with an add action.
struct WalletPicker: View {
    let vm: WalletsViewModel
    @Binding var selected: String
    var onRemove: (WalletAccount) -> Void = { _ in }
    let onAdd: (WalletAccount.Custody) -> Void
    @State private var open = false
    @State private var hover = false

    private var current: WalletAccount? { vm.wallet(selected) }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                WalletSymbolTile(symbol: current?.symbol ?? "wallet.bifold", size: 26)
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
        #if os(iOS)
        // iPhone: a bottom sheet. A popover here opened upwards over the navigation bar.
        .sheet(isPresented: $open) {
            WalletMenuSheet(vm: vm, selected: $selected, close: { open = false }, onRemove: remove, onAdd: onAdd)
        }
        #if DEBUG
        .task { try? await Task.sleep(for: .seconds(1.5)); if DebugLaunch.take("picker") { open = true } }
        #endif
        #else
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WalletMenu(vm: vm, selected: $selected, close: { open = false }, onRemove: remove, onAdd: onAdd)
        }
        #endif
    }

    /// Close the list first, then ask (a dialog can't sit on a closing sheet).
    private func remove(_ w: WalletAccount) {
        open = false
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); onRemove(w) }
    }
}

#if os(iOS)
/// iPhone: the wallet list as a sheet exactly its own height, solid paper all the way down.
private struct WalletMenuSheet: View {
    let vm: WalletsViewModel
    @Binding var selected: String
    let close: () -> Void
    let onRemove: (WalletAccount) -> Void
    let onAdd: (WalletAccount.Custody) -> Void
    @State private var height: CGFloat = 300

    var body: some View {
        ScrollView {
            WalletMenu(vm: vm, selected: $selected, close: close, onRemove: onRemove, onAdd: onAdd, width: nil)
                .padding(.top, 18).padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(min(height + 30, 640))])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .glassSheetBackground()
    }
}
#endif

/// The picker's dropdown: All wallets, then the wallets on this device.
struct WalletMenu: View {
    let vm: WalletsViewModel
    @Binding var selected: String
    let close: () -> Void
    var onRemove: (WalletAccount) -> Void = { _ in }
    let onAdd: (WalletAccount.Custody) -> Void
    /// Fixed width in the Mac popover; nil fills the iPhone sheet.
    var width: CGFloat? = 350

    var body: some View { menu }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(id: "all", symbol: "wallet.bifold", title: "All wallets", sub: "\(vm.wallets.count) wallet\(vm.wallets.count == 1 ? "" : "s")", mono: false, usd: vm.totalUSD)
            Hairline().padding(.vertical, 6)
            header("On \(Device.here)", "Keys never leave it")
            ForEach(vm.wallets) { w in
                row(id: w.id, symbol: w.symbol, title: w.name, sub: w.shortAddress, mono: true, usd: vm.totalUSD == nil ? nil : vm.total(w.id),
                    chains: Chain.mainnets)
                    .contextMenu {
                        Button { withAnimation(.smooth(duration: 0.25)) { selected = w.id }; close() } label: { Label("Open", systemImage: "wallet.bifold") }
                        Button(role: .destructive) { onRemove(w) } label: { Label("Remove from \(Device.here)", systemImage: "trash") }
                    }
            }
            addRow("Create or import a wallet") { close(); onAdd(.local) }
        }
        .padding(8)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(width == nil ? Color.clear : Theme.bg)   // clear on the iPhone sheet's glass, paper in the Mac popover
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
    }

    private func addRow(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8.5).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
        }
        .buttonStyle(WalletMenuRowStyle())
    }

    private func row(id: String, symbol: String, title: String, sub: String, mono: Bool, usd: Double?, chains: [Chain] = []) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { selected = id }
            close()
        } label: {
            HStack(spacing: 10) {
                WalletSymbolTile(symbol: symbol, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                    HStack(spacing: 6) {
                        Text(sub).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11.5)).foregroundStyle(Theme.muted)
                        if chains.count > 1 { ChainStack(chains: chains, size: 12) }
                    }
                }
                Spacer(minLength: 8)
                Text(usd.map { MoneyFmt.usd($0, digits: $0 < 100 ? 2 : 0) } ?? "$—").font(.system(size: 13.5)).monospacedDigit()
                    .foregroundStyle(usd == nil ? Theme.faint : Theme.text)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                    .opacity(selected == id ? 1 : 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(selected == id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(WalletMenuRowStyle())
    }
}

/// Snapshot helper: the dropdown on its own.
struct WalletPickerMenuPreview: View {
    let vm: WalletsViewModel
    var body: some View { WalletMenu(vm: vm, selected: .constant("all"), close: {}, onAdd: { _ in }) }
}

/// Menu-like row: hover highlight, quick press.
struct WalletMenuRowStyle: ButtonStyle {
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
