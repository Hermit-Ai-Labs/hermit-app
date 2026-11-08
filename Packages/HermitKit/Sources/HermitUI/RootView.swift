import SwiftUI
import HermitCore

/// The whole app. Mac (and iPad): sidebar on the left, the page on the right. iPhone: a tab bar with
/// Chat, Trade, Earn, Payments and Wallets, and the sidebar as a drawer. First launch asks what Hermit should call you.
public struct RootView: View {
    @State private var model: AppModel
    private let forcePhone: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// `phone: true` renders the iPhone layout anywhere (snapshot tests).
    public init(model: AppModel? = nil, phone: Bool = false) {
        _model = State(initialValue: model ?? AppModel())
        forcePhone = phone
    }

    private var compact: Bool {
        #if os(iOS)
        return forcePhone || sizeClass == .compact
        #else
        return forcePhone
        #endif
    }

    public var body: some View {
        ZStack {
            if model.user.isEmpty && !SnapshotMode.active {
                LoginView { name in withAnimation(.smooth(duration: 0.5)) { model.user = name } }
                    .transition(.opacity)
            } else if compact {
                CompactShell()
            } else if SnapshotMode.active {
                HStack(spacing: 0) { Sidebar().frame(width: 248); Divider(); RouteDetail() }
            } else {
                split
            }
        }
        // Inside .environment(model): the approval host reads AppModel from the environment.
        .sheet(item: $model.fundGoal) { g in
            FundSheet(goal: g).environment(model).tint(Theme.text)
        }
        .approvalHost(sheetOpen: model.fundGoal != nil) { model.fundGoal = nil }
        .environment(model)
        .environment(\.compact, compact)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light)
        .tint(Theme.accent)
        .focusedSceneValue(\.hermitModel, model)
        .overlay(alignment: .bottom) {
            if let t = model.toastText {
                ToastView(text: t).padding(.bottom, compact ? 96 : 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $model.approval) { a in
            ApprovalSheet(approval: a) { model.approved(a) }
                .environment(model)
                .foregroundStyle(Theme.text)
                .fitSheet()
        }
        .onAppear {
            // prepare_swap from the assistant: open Wallets on the prefilled Swap review. The user approves (or not).
            WalletsViewModel.shared.tools.presentSwap = { [model] intent in
                WalletsViewModel.shared.pendingSwap = intent
                model.open(.wallets, tab: "agent-swap")
            }
        }
        // A NEAR Intents swap's live status, opened right after its deposit is approved (or from Wallets).
        .sheet(item: Bindable(IntentsActivity.shared).focus) { f in
            IntentsStatusSheet(depositAddress: f.id).environment(model).tint(Theme.text)
        }
    }

    private var split: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            RouteDetail()
        }
    }
}

/// The page for the current route.
struct RouteDetail: View {
    @Environment(AppModel.self) private var model
    var body: some View {
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

// MARK: Menu bar commands (Mac): New Chat ⌘N, Focus chat box ⌘K.

public struct HermitCommands: Commands {
    @FocusedValue(\.hermitModel) private var model
    public init() {}
    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { model?.newChat() }.keyboardShortcut("n").disabled(model == nil)
        }
        CommandMenu("Chat") {
            Button("Focus Chat Box") { model?.focusTick += 1; if model?.route != .home && model?.route != .automations && model?.route != .projects { model?.route = .home } }
                .keyboardShortcut("k").disabled(model == nil)
            Button("Stop Reply") { model?.stop() }.keyboardShortcut(".").disabled(model?.busy != true)
            Divider()
            Button("Projects") { model?.open(.projects) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Automations") { model?.open(.automations) }.keyboardShortcut("2", modifiers: [.command, .option])
        }
    }
}

extension FocusedValues {
    @Entry var hermitModel: AppModel?
}
