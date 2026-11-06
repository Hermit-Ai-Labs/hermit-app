import SwiftUI

/// Payments: scheduled and recurring payments, saved payees, a transfer form and the API catalogue.
/// Everything you enter is kept on this device. Sending from here is not live yet, so the pay buttons are greyed out.
struct PaymentsPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab: PayTab = .schedule
    @State private var width: CGFloat = 1000
    @State private var newPayment = false
    private var store: PaymentsStore { .shared }

    enum PayTab: String, Hashable, CaseIterable { case schedule, payees, transfer, apis }

    private var tabs: [(PayTab, String)] {
        [(.schedule, "Schedule"), (.payees, store.payees.isEmpty ? "Payees" : "Payees \(store.payees.count)"), (.transfer, "Transfer"), (.apis, "APIs")]
    }

    var body: some View {
        let compact = width < 640
        Page(title: "Payments", tabs: tabs, tab: $tab) {
            Button { newPayment = true } label: { Label("Schedule", systemImage: "plus") }
                .buttonStyle(BlackButton())
                .keyboardShortcut("n", modifiers: [.command, .shift])
        } content: { t in
            VStack(alignment: .leading, spacing: 0) {
                switch t {
                case .schedule: PaySchedule(compact: compact)
                case .payees: PayPayees()
                case .transfer: PayTransfer(compact: compact).frame(maxWidth: 560, alignment: .leading)
                case .apis:
                    PayApis()
                    PayExploreMore(label: "services", items: PaymentsData.moreServices).padding(.top, 36)
                }
            }
        }
        .payWidth($width)
        .sheet(isPresented: $newPayment) { PayScheduleSheet(item: nil) }
        .onAppear {
            if let r = model.tabRequest, let v = PayTab(rawValue: r) { tab = v; model.tabRequest = nil }
        }
    }
}
