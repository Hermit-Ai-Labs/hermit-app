import SwiftUI
import HermitCore

/// The whole app: sidebar on the left, the page on the right. On iPhone the split view collapses to a stack.
public struct RootView: View {
    @State private var model: AppModel
    public init(model: AppModel? = nil) { _model = State(initialValue: model ?? AppModel()) }

    public var body: some View {
        if SnapshotMode.active {
            HStack(spacing: 0) { Sidebar().frame(width: 248); Divider(); detail }
                .environment(model)
        } else {
            split
        }
    }

    private var detail: some View {
        Group {
            switch model.route {
            case .home: if model.inChat { ChatView() } else { HomeView() }
            case .projects: ProjectsPage()
            case .automations: AutomationsPage()
            case .trade: TradePage()
            case .earn: EarnPage()
            case .payments: PaymentsPage()
            case .explore: ExplorePage()
            case .calendar: CalendarPage()
            case .wallets: WalletsPage()
            case .connectors: ConnectorsPage()
            case .files: FilesPage()
            case .settings: SettingsPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var split: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if let t = model.toastText { ToastView(text: t).padding(.bottom, 28).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .environment(model)
        .tint(Theme.accent)
        .sheet(item: $model.approval) { a in
            ApprovalSheet(approval: a) { model.approved(a) }
        }
    }
}

struct PlaceholderPage: View {
    let route: Route
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: route.symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.faint)
            Text(route.title).font(.serif(30))
            Text("Coming to the native app next.").foregroundStyle(Theme.muted)
        }
    }
}
