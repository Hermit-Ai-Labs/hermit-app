import SwiftUI
import HermitCore

/// iPhone: the native tab bar with Chat, Trade, Earn, Payments and Wallets. The menu button opens the
/// sidebar as a drawer, the pencil starts a new chat. Pages that aren't tabs open inside the Chat tab.
struct CompactShell: View {
    @Environment(AppModel.self) private var model

    enum TabID: Hashable { case chat, trade, earn, payments, wallets }

    static let tabs: [(TabID, String, String)] = [
        (.chat, "Chat", "bubble.left"), (.trade, "Trade", "chart.bar.xaxis"), (.earn, "Earn", "leaf"),
        (.payments, "Payments", "dollarsign.square"), (.wallets, "Wallets", "wallet.bifold"),
    ]

    private var selection: Binding<TabID> {
        Binding {
            switch model.route {
            case .trade: .trade
            case .earn: .earn
            case .payments: .payments
            case .wallets: .wallets
            default: .chat
            }
        } set: { tab in
            switch tab {
            case .chat: if [.trade, .earn, .payments, .wallets].contains(model.route) { model.route = .home }
            case .trade: model.open(.trade)
            case .earn: model.open(.earn)
            case .payments: model.open(.payments)
            case .wallets: model.open(.wallets)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if SnapshotMode.active { snapshotShell } else { tabView }
            drawer
        }
        .animation(.smooth(duration: 0.3), value: model.drawerOpen)
    }

    @ViewBuilder private var tabView: some View {
        #if os(iOS)
        TabView(selection: selection) {
            ForEach(Self.tabs, id: \.0) { t in
                Tab(t.1, systemImage: t.2, value: t.0) {
                    NavigationStack {
                        page(t.0)
                            .toolbar { bar }
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        #else
        snapshotShell
        #endif
    }

    @ViewBuilder private func page(_ tab: TabID) -> some View {
        switch tab {
        case .chat: RouteDetail()
        case .trade: TradePage().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        case .earn: EarnPage().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        case .payments: PaymentsPage().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        case .wallets: WalletsPage().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder private var bar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { model.drawerOpen = true } label: { Image(systemName: "line.3.horizontal") }
                .accessibilityLabel("Menu")
        }
        ToolbarItem(placement: .principal) { HermitMark(height: 15) }
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New chat")
        }
    }
    #endif

    /// The sidebar sliding in from the left over a dimmed app.
    @ViewBuilder private var drawer: some View {
        if model.drawerOpen {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { model.drawerOpen = false }
                .transition(.opacity)
            Sidebar()
                .frame(width: 304)
                .frame(maxHeight: .infinity)
                .background(Theme.subtle.ignoresSafeArea())
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 22, topTrailingRadius: 22))
                .shadow(color: .black.opacity(0.12), radius: 24, x: 6)
                .transition(.move(edge: .leading))
                .zIndex(2)
        }
    }

    // MARK: Offscreen stand-in (the Mac can't render UIKit's tab bar into a snapshot)

    private var snapshotShell: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.drawerOpen = true } label: { Image(systemName: "line.3.horizontal").font(.system(size: 17)) }
                Spacer()
                HermitMark(height: 15)
                Spacer()
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil").font(.system(size: 17)) }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.text)
            .padding(.horizontal, 20).frame(height: 52)
            page(selection.wrappedValue).frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
            HStack {
                ForEach(Self.tabs, id: \.0) { t in
                    let on = selection.wrappedValue == t.0
                    VStack(spacing: 3) {
                        Image(systemName: t.2).font(.system(size: 18, weight: on ? .semibold : .regular))
                        Text(t.1).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(on ? Theme.accent : Theme.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(on ? Theme.hover : .clear, in: Capsule())
                }
            }
            .padding(5)
            .background(Theme.bg.opacity(0.96), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
            .padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 6)
        }
        .background(Theme.bg)
    }
}
