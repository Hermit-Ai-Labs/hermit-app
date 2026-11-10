import SwiftUI
import HermitCore

/// Earn, simple first: Savings (Aave pools you can deposit into, Deposit on the row), Your deposits (what's earning, with
/// Withdraw), and Explore (every big yield, funding carry and the vault explainer) for people who want more.
struct EarnPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "save"
    @Bindable private var flow = EarnFlow.shared
    static let tabs = [("save", "Savings"), ("positions", "Your deposits"), ("explore", "Explore")]
    /// Tab ids from before Explore held them all, still asked for by links and the Mac tour.
    static let aliases = ["defi": "explore", "arb": "explore", "reverse": "explore"]

    var body: some View {
        Page(title: "Earn", tabs: Self.tabs, tab: $tab) { t in
            VStack(alignment: .leading, spacing: 0) {
                switch t {
                case "positions": EarnPositions()
                case "explore": EarnExplore()
                default: EarnSavings()
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
            if let r = model.tabRequest.map({ Self.aliases[$0] ?? $0 }), Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
    }
}
