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

    static let drawerWidth: CGFloat = 312
    /// How far the drawer is pulled while a finger is on it: negative while closing, positive while opening from the edge.
    @State private var drag: CGFloat = 0
    @State private var dragging = false

    var body: some View {
        ZStack(alignment: .leading) {
            if SnapshotMode.active { snapshotShell } else { tabView }
            #if os(iOS)
            if !model.drawerOpen && !SnapshotMode.active { edgeSwipe }
            #endif
            drawer
        }
        .animation(dragging ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: model.drawerOpen)
    }

    /// 0 = closed, 1 = open, following the finger in between.
    private var openness: CGFloat {
        let base: CGFloat = model.drawerOpen ? 1 : 0
        return min(1, max(0, base + drag / Self.drawerWidth))
    }

    /// A thin strip on the left edge: swipe right from it to pull the drawer out.
    private var edgeSwipe: some View {
        Color.clear.frame(width: 18).frame(maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { v in dragging = true; drag = max(0, v.translation.width) }
                .onEnded { v in settle(predicted: v.predictedEndTranslation.width) })
            .ignoresSafeArea()
    }

    /// Lets go of the drawer: it opens or closes depending on where the throw would land.
    private func settle(predicted: CGFloat) {
        let landing = (model.drawerOpen ? Self.drawerWidth : 0) + predicted
        dragging = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            model.drawerOpen = landing > Self.drawerWidth / 2
            drag = 0
        }
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
            Button { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { model.drawerOpen = true } } label: { Image(systemName: "line.3.horizontal") }
                .accessibilityLabel("Menu")
        }
        ToolbarItem(placement: .principal) {
            // The mark is the way home: back to a fresh Chat from anywhere.
            Button { model.route = .home } label: { HermitMark(height: 15) }
                .buttonStyle(.plain).accessibilityLabel("Home")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New chat")
        }
    }
    #endif

    /// The sidebar over a dimmed app, edge to edge from the status bar to the home indicator. It follows the finger:
    /// drag it left to close, swipe in from the left edge to open, tap the dimmed app to close.
    @ViewBuilder private var drawer: some View {
        if model.drawerOpen || drag > 0 {
            Color.black.opacity(0.3 * openness).ignoresSafeArea()
                .onTapGesture { withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { model.drawerOpen = false } }
                .transition(.opacity)
            Sidebar()
                .frame(width: Self.drawerWidth)
                .frame(maxHeight: .infinity)
                .background {
                    UnevenRoundedRectangle(bottomTrailingRadius: 30, topTrailingRadius: 30, style: .continuous)
                        .fill(Theme.subtle)
                        .shadow(color: .black.opacity(0.14 * openness), radius: 28, x: 8)
                        .ignoresSafeArea()
                }
                .offset(x: -Self.drawerWidth * (1 - openness))
                .simultaneousGesture(DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        dragging = true; drag = min(0, v.translation.width)
                    }
                    .onEnded { v in if dragging { settle(predicted: v.predictedEndTranslation.width) } })
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
