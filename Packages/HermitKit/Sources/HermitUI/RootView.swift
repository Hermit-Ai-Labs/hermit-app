import SwiftUI
import HermitCore

/// The whole app: sidebar on the left, the page on the right. On iPhone the split view collapses to a stack.
public struct RootView: View {
    @State private var model: AppModel
    public init(model: AppModel? = nil) { _model = State(initialValue: model ?? AppModel()) }

    public var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            Group {
                switch model.route {
                case .home: if model.inChat { ChatView() } else { HomeView() }
                default: PlaceholderPage(route: model.route)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
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
