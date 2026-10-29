import SwiftUI
import HermitCore

/// Earn: what is already earning, then DeFi, arbitrage and airdrop opportunities, and Reverse (explain any vault).
struct EarnPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "positions"
    private var store: TradeEarnStore { .shared }
    static let tabs = [("positions", "Positions"), ("defi", "DeFi"), ("arb", "Arbitrage"), ("airdrops", "Airdrops"), ("reverse", "Reverse")]

    var body: some View {
        Page(title: "Earn", tabs: Self.tabs, tab: $tab) { t in
            VStack(alignment: .leading, spacing: 0) {
                switch t {
                case "defi": EarnDeFi()
                case "arb": EarnArbitrage()
                case "airdrops": EarnAirdrops()
                case "reverse": EarnReverse()
                default: EarnPositions()
                }
                if ["defi", "arb", "airdrops"].contains(t) {
                    TradeExploreMore(label: "opportunities", items: EarnData.catalog)
                }
            }
        }
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
        .onChange(of: model.approval == nil) { _, closed in if closed { store.approvalClosed(model) } }
    }
}
