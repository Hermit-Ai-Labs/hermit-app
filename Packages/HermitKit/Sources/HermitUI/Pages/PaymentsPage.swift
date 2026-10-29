import SwiftUI

/// Payments: stablecoin-first (USDC on Base). Direct transfers, x402 for APIs, Bridge payouts for bills.
/// Tabs from the demo: Schedule, Approvals (with a count), Transfer, Bills, APIs.
struct PaymentsPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab: PayTab = .schedule
    @State private var width: CGFloat = 1000
    private var store: PaymentsStore { .shared }

    enum PayTab: String, Hashable, CaseIterable { case schedule, approvals, transfer, bills, apis }

    private var tabs: [(PayTab, String)] {
        let n = store.pending.count
        return [(.schedule, "Schedule"), (.approvals, n > 0 ? "Approvals \(n)" : "Approvals"), (.transfer, "Transfer"),
                (.bills, "Bills"), (.apis, "APIs")]
    }

    var body: some View {
        let compact = width < 640
        Page(title: "Payments", tabs: tabs, tab: $tab) {
            Text("\(PayFormat.usd(store.balance)) USDC")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).monospacedDigit()
                .contentTransition(.numericText())
        } content: { t in
            VStack(alignment: .leading, spacing: 0) {
                switch t {
                case .schedule: PaySchedule(compact: compact)
                case .approvals: PayApprovals()
                case .transfer: PayTransfer(compact: compact).frame(maxWidth: 560, alignment: .leading)
                case .bills: PayBills()
                case .apis: PayApis()
                }
                if t == .schedule || t == .apis {
                    PayExploreMore(label: "services", items: PaymentsData.moreServices).padding(.top, 36)
                }
            }
        }
        .payWidth($width)
        .payApprovalWatch(model)
        .onAppear {
            if let r = model.tabRequest, let v = PayTab(rawValue: r) { tab = v; model.tabRequest = nil }
        }
    }
}
