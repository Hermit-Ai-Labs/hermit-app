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
        .chatDropTarget()
        .environment(model)
        .environment(\.compact, compact)
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .light)
        // Text that follows Dynamic Type (`uiFont`, `Font.serif`) grows up to the first accessibility size, where
        // cards and rows still hold their layout.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .tint(Theme.accent)
        .focusedSceneValue(\.hermitModel, model)
        .overlay(alignment: .bottom) { ToastHost(place: .page, bottom: compact ? 96 : 28) }
        .sheet(item: $model.approval) { a in
            ApprovalSheet(approval: a) { h in model.approved(a, hash: h) }
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
            #if DEBUG
            Task { @MainActor in try? await Task.sleep(for: .seconds(1.2)); DebugLaunch.applyRoot(model) }
            #endif
        }
        // A NEAR Intents swap's live status, opened right after its deposit is approved (or from Wallets).
        .sheet(item: Bindable(IntentsActivity.shared).focus) { f in
            IntentsStatusSheet(depositAddress: f.id).environment(model).tint(Theme.text)
        }
        #if os(iOS)
        // First launch on mobile data: one question before 2.3 GB goes over it. Shown once the name is in.
        .alert("Download Hermit's AI now?", isPresented: Binding(
            get: { model.models.cellularAsk != nil && !model.user.isEmpty },
            set: { if !$0, model.models.cellularAsk != nil { model.models.answerCellular(downloadNow: false) } })) {
            Button("Download now") { model.models.answerCellular(downloadNow: true) }
            Button("Wait for Wi-Fi", role: .cancel) { model.models.answerCellular(downloadNow: false) }
        } message: {
            Text("\(model.models.cellularSize) over mobile data. Or wait, and it starts by itself on Wi-Fi.")
        }
        #endif
        // A batch send's review (from chat): every recipient, one Face ID, then each transfer's status.
        .sheet(item: Bindable(BatchStore.shared).reviewing) { r in
            BatchSendSheet(id: r.id).environment(model).tint(Theme.text)
        }
    }

    private var split: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            RouteDetail()
                #if os(macOS)
                // No empty title band with a hard line across every page: the toolbar is see-through and the page
                // fades softly under it as it scrolls.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectStyle(.soft, for: .top)
                #endif
        }
        #if os(macOS)
        // Narrower than this, the Trade ticket and the Wallets columns stop fitting beside each other.
        .frame(minWidth: 820, minHeight: 560)
        #endif
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
        #if os(macOS)
        // AppKit hands focus to the first text field it finds when the old one goes away, so Trade opened scrolled
        // down with the cursor in Take profit. Pages without a chat box start with nothing focused.
        .onChange(of: model.route) { _, r in
            guard r != .home && r != .automations && r != .projects else { return }
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        #endif
    }
}

// MARK: Menu bar commands (Mac): New Chat ⌘N, Focus chat box ⌘K, Settings ⌘, and a Go menu (⌘1 to ⌘9).

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
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model?.open(.settings) }.keyboardShortcut(",").disabled(model == nil)
        }
        SidebarCommands()
        CommandMenu("Go") {
            ForEach(Array(Self.goRoutes.enumerated()), id: \.offset) { i, r in
                Button(r == .home ? "Home" : r.title) {
                    if r == .home { model?.newChat() } else { model?.open(r) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .disabled(model == nil)
            }
            Divider()
            Button("Connectors") { model?.open(.connectors) }.disabled(model == nil)
            Button("Files") { model?.open(.files) }.disabled(model == nil)
        }
    }

    /// ⌘1 to ⌘9, in sidebar order, then Wallets.
    static let goRoutes: [Route] = Route.sidebar + [.wallets]
}

extension FocusedValues {
    @Entry var hermitModel: AppModel?
}
