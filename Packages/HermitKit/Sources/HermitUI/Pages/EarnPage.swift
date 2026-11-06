import SwiftUI
import HermitCore

/// Earn: what you have earning (nothing until deposits are wired), real DeFi yields, live funding-rate carry,
/// airdrops, and Reverse (Hermit explains any vault in chat).
struct EarnPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "defi"
    static let tabs = [("positions", "Positions"), ("defi", "DeFi"), ("arb", "Arbitrage"), ("airdrops", "Airdrops"), ("reverse", "Reverse")]

    var body: some View {
        Page(title: "Earn", tabs: Self.tabs, tab: $tab) { t in
            VStack(alignment: .leading, spacing: 0) {
                switch t {
                case "positions": EarnPositions()
                case "arb": EarnArbitrage()
                case "airdrops": EarnAirdrops()
                case "reverse": EarnReverse()
                default: EarnDeFi()
                }
                if ["defi", "arb", "airdrops"].contains(t) {
                    TradeExploreMore(label: "opportunities", items: EarnData.catalog)
                }
            }
        }
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
    }
}
