import SwiftUI
import HermitWallet

/// Settings > Sites: every site connected to a wallet from Hermit's browser, with Disconnect. Kept on this device only.
struct ConnectedSitesSettings: View {
    @Environment(AppModel.self) private var model
    private var store: DappPermissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sites you connected in Hermit's browser can see that wallet's address and ask for signatures. Each signature still needs your approval.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            if store.sites.isEmpty {
                EmptyState(symbol: "globe", title: "No connected sites",
                           text: "Open an app from Explore and connect it to see it here.") {
                    Button("Open Explore") { model.open(.explore) }.buttonStyle(OutlineButton())
                }
            } else {
                ForEach(Array(store.sites.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Hairline() }
                    SettingRow(title: URL(string: s.origin)?.host() ?? s.origin, sub: sub(s)) {
                        Button("Disconnect") {
                            withAnimation(.snappy) { store.disconnect(s.origin) }
                            model.toast("Disconnected \(URL(string: s.origin)?.host() ?? s.origin)")
                        }
                        .buttonStyle(PayPillButton(kind: .outline))
                    }
                }
                Hairline()
                HStack {
                    Spacer()
                    Button("Disconnect all") { withAnimation(.snappy) { store.disconnectAll() }; model.toast("Disconnected every site") }
                        .buttonStyle(PayPillButton(kind: .outline))
                }
                .padding(.top, 14)
            }
        }
    }

    private func sub(_ s: DappPermissions.Site) -> String {
        let wallet = WalletsViewModel.shared.service.wallets.first { $0.id == s.walletID }?.name ?? "Deleted wallet"
        let chain = Chain.with(chainId: s.chainID)?.name ?? "Chain \(s.chainID)"
        return "\(wallet), \(DappDecoder.short(s.address)) on \(chain). Last used \(s.lastUsed.formatted(.relative(presentation: .named)))"
    }
}
