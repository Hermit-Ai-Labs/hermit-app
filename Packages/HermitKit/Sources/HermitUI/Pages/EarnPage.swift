import SwiftUI
import HermitCore

/// Earn: what you have earning (Aave v3 supplies with their live APY, and Hyperliquid), real DeFi yields, live funding-rate carry,
/// airdrops, and Reverse (Hermit explains any vault in chat).
struct EarnPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "defi"
    @Bindable private var flow = EarnFlow.shared
    static let tabs = [("positions", "Positions"), ("defi", "DeFi"), ("arb", "Funding"), ("reverse", "Reverse")]

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
        .sheet(item: $flow.deposit) { p in EarnDepositSheet(pool: p).environment(model).tint(Theme.text) }
        .approvalHost(sheetOpen: flow.deposit != nil) { flow.deposit = nil }
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            if DebugLaunch.take("earn-deposit") {
                flow.deposit = EarnData.Pool(pool: "debug-aave-base-usdc", chain: "Base", project: "aave-v3", symbol: "USDC", tvlUsd: 412_000_000, apy: 4.62,
                                             apyBase: 4.62, apyReward: nil, apyMean30d: 4.4, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: nil)
            }
        }
        #endif
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
    }
}
