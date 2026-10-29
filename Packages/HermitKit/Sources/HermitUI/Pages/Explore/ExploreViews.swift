import SwiftUI

/// Claude-style connect control: Connect, or Connected (green check) that turns into Disconnect on hover.
/// A short spinner while it connects, so the change reads as real.
struct ExploreConnectButton: View {
    @Environment(AppModel.self) var model
    let dapp: ExploreDapp
    var block = false
    @State var hover = false
    private var store: ExploreStore { .shared }

    var body: some View {
        let on = store.connected.contains(dapp.name)
        let busy = store.connecting.contains(dapp.name)
        Button(action: toggle) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).transition(.opacity)
                } else if on && hover {
                    Text("Disconnect").foregroundStyle(Theme.red).transition(.opacity)
                } else if on {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.green)
                        Text("Connected")
                    }
                    .transition(.opacity)
                } else {
                    Text("Connect").transition(.opacity)
                }
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            .frame(maxWidth: block ? .infinity : nil).frame(minWidth: 104).frame(height: PayMetrics.chip + 2)
            .background(bg(on: on), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? (hover ? Theme.red.opacity(0.15) : Theme.border) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .disabled(busy)
        .animation(.snappy(duration: 0.18), value: hover)
        .animation(.snappy(duration: 0.25), value: on)
        .animation(.snappy(duration: 0.25), value: busy)
        .accessibilityLabel(on ? "Disconnect \(dapp.name)" : "Connect \(dapp.name)")
    }

    private func bg(on: Bool) -> Color {
        if on { return hover ? Theme.red.opacity(0.07) : Theme.bg }
        return hover ? Color(hex: 0xE8E8E6) : Color(hex: 0xF2F2F0)
    }

    private func toggle() {
        let name = dapp.name
        if store.connected.contains(name) {
            store.connected.remove(name)
            model.toast("\(name) disconnected")
        } else {
            store.connecting.insert(name)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                store.connecting.remove(name)
                store.connected.insert(name)
                model.toast("\(name) connected")
            }
        }
    }
}

/// Grid card for New and Trending.
struct ExploreCard: View {
    @Environment(AppModel.self) var model
    let dapp: ExploreDapp
    @State var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LogoMark(dapp.name, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dapp.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(dapp.cat).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Text(dapp.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .lineLimit(2, reservesSpace: true).lineSpacing(2)
            HStack(spacing: 6) {
                Text(dapp.tvl).monospacedDigit()
                Text(dapp.chain).foregroundStyle(Theme.faint).lineLimit(1)
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            ExploreConnectButton(dapp: dapp, block: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(hover ? Color(hex: 0xD8D8D6) : Theme.border))
        .shadow(color: .black.opacity(hover ? 0.05 : 0), radius: 10, y: 4)
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.18), value: hover)
        .contextMenu { ExploreMenu(dapp: dapp) }
    }
}

/// Row for the All tab.
struct ExploreRow: View {
    let dapp: ExploreDapp
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            LogoMark(dapp.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dapp.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if dapp.isNew {
                        Text("New").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(hex: 0xF1ECFA), in: Capsule())
                    }
                }
                Text(compact ? dapp.desc : "\(dapp.desc), \(dapp.chain)")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !compact {
                Text(dapp.tvl).font(.system(size: 12.5)).foregroundStyle(Theme.faint).monospacedDigit().lineLimit(1)
                    .frame(width: 110, alignment: .trailing)
            }
            ExploreConnectButton(dapp: dapp)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu { ExploreMenu(dapp: dapp) }
    }
}

struct ExploreMenu: View {
    @Environment(AppModel.self) var model
    let dapp: ExploreDapp
    var body: some View {
        Button("Ask Hermit about \(dapp.name)", systemImage: "sparkles") { model.send("Tell me about \(dapp.name)") }
        Button("Copy name", systemImage: "doc.on.doc") { PayClipboard.copy(dapp.name); model.toast("Copied") }
    }
}
