import SwiftUI

/// Connect control. Connecting apps isn't wired up yet, so it's a greyed Connect with a tooltip, never a fake "Connected".
struct ExploreConnectButton: View {
    let dapp: ExploreDapp
    var block = false

    var body: some View {
        Button {} label: {
            Text("Connect")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.faint)
                .frame(maxWidth: block ? .infinity : nil).frame(minWidth: 104).frame(height: PayMetrics.chip + 2)
                .background(Color(hex: 0xF2F2F0), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("Connecting apps opens soon")
        .accessibilityLabel("Connect \(dapp.name), opens soon")
    }
}

/// "TVL $5.1B" plus the 7-day change, or nothing when DefiLlama doesn't track the app.
struct ExploreTVLText: View {
    let dapp: ExploreDapp
    private var store: ExploreStore { .shared }
    var body: some View {
        if let v = store.value(dapp) {
            HStack(spacing: 4) {
                Text("TVL \(v.tvl.tradeCompactUSD)")
                if let c = v.change7d { Text(c.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())) + "% 7d").foregroundStyle(c >= 0 ? Theme.green : Theme.red) }
            }
            .monospacedDigit()
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
                ExploreTVLText(dapp: dapp)
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
                ExploreTVLText(dapp: dapp).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    .frame(width: 170, alignment: .trailing)
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
