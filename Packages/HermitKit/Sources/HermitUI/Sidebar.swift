import SwiftUI
import HermitCore

/// Claude-style sidebar from the demo: wallets card, New chat, pages, projects (expand to see their chats),
/// recents (saved chats you can reopen), you.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if SnapshotMode.active { list.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
                ScrollView { list }.scrollIndicators(.never)
            }
            Divider().overlay(Theme.border)
            account
        }
        #if os(macOS)
        .background(Theme.subtle)
        #endif
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HermitMark(height: 15).padding(.leading, 10).padding(.bottom, 14).padding(.top, compactTop)
            funds.padding(.bottom, 10)
            ForEach(Route.sidebar) { r in row(r) }
            if !model.projectList.isEmpty {
                section("Projects")
                ForEach(model.projectList) { p in projectRow(p) }
            }
            section("Recents")
            ForEach(model.recentConversations.prefix(14)) { c in
                chatRow(c, indent: 0)
            }
            if model.recentConversations.isEmpty {
                Text("Your chats show up here").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 12)
        .animation(.snappy(duration: 0.25), value: expanded)
        .animation(.snappy(duration: 0.25), value: model.conversations.map(\.id))
    }

    /// iPhone drawer: a little air under the status bar.
    private var compactTop: CGFloat {
        #if os(iOS)
        10
        #else
        2
        #endif
    }

    private var wallets: WalletsViewModel { .shared }

    /// The wallets' total, or a way to create the first one.
    private var funds: some View {
        Button { model.open(.wallets) } label: {
            VStack(alignment: .leading, spacing: 2) {
                if wallets.loaded && wallets.wallets.isEmpty {
                    Text("No wallet yet").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    HStack {
                        Text("Create a wallet").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("Wallets").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    Text(MoneyFmt.usdSmart(wallets.total())).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .redacted(reason: wallets.loaded ? [] : .placeholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .task { if !wallets.loaded { await wallets.refresh() } }
    }

    private func isActive(_ r: Route) -> Bool {
        if r == .home { return model.route == .home && model.currentID == nil && model.chatProject == nil }
        return model.route == r
    }

    private func row(_ r: Route) -> some View {
        let active = isActive(r)
        return Button {
            if r == .home { model.newChat() } else { model.open(r) }
        } label: {
            HStack(spacing: 10) {
                if r == .home {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Theme.accent, in: Circle())
                } else {
                    Image(systemName: r.symbol).font(.system(size: 13)).frame(width: 18)
                }
                Text(r.title).font(.system(size: 13.5, weight: r == .home ? .medium : .regular))
                Spacer()
                #if os(macOS)
                if r == .home { Text("⌘N").font(.system(size: 11)).foregroundStyle(Theme.faint).opacity(SnapshotMode.active ? 0 : 1) }
                #endif
            }
            .foregroundStyle(r == .home ? Theme.text : (active ? Theme.text : Theme.muted))
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SideRowStyle(active: active))
    }

    private func projectRow(_ p: Project) -> some View {
        let open = expanded.contains(p.name)
        let active = model.route == .projects && model.projectOpen == p.name
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { if open { expanded.remove(p.name) } else { expanded.insert(p.name) } }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 18, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(open ? "Hide chats" : "Show chats")
                Button { model.openProject(p.name) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(p.color).frame(width: 6, height: 6)
                        Text(p.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13)).foregroundStyle(active ? Theme.text : Theme.muted)
                    .padding(.vertical, 5).padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SideRowStyle(active: active))
            }
            if open {
                let chats = model.chats(in: p.name)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chats) { c in chatRow(c, indent: 26) }
                    if chats.isEmpty {
                        Text("No chats yet").font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(.leading, 32).padding(.vertical, 4)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func chatRow(_ c: Conversation, indent: CGFloat) -> some View {
        let active = model.route == .home && model.currentID == c.id
        return Button { model.openConversation(c.id) } label: {
            Text(c.title).font(.system(size: 13)).foregroundStyle(active ? Theme.text : Theme.muted).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(SideRowStyle(active: active))
        .padding(.leading, indent)
        .contextMenu {
            Button("Open", systemImage: "bubble.left") { model.openConversation(c.id) }
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteConversation(c.id) }
        }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
    }

    private var account: some View {
        HStack(spacing: 9) {
            Menu {
                Section(model.user) {
                    Button { model.open(.wallets) } label: {
                        Label("Wallets", systemImage: "wallet.bifold")
                        if !wallets.wallets.isEmpty { Text(MoneyFmt.usdSmart(wallets.total())) }
                    }
                    Button("Files", systemImage: "doc") { model.open(.files) }
                    Button("Connectors", systemImage: "puzzlepiece.extension") { model.open(.connectors) }
                    Button("Settings", systemImage: "gearshape") { model.open(.settings) }.keyboardShortcut(",", modifiers: .command)
                    Button("Change name", systemImage: "person") { model.open(.settings, tab: "profile") }
                }
                Divider()
                Button("Get help", systemImage: "questionmark.circle") {
                    model.showHelp()
                }
            } label: {
                HStack(spacing: 9) {
                    Group {
                        if let initial = model.user.first {
                            Text(String(initial).uppercased()).font(.system(size: 12, weight: .semibold))
                        } else {
                            Image(systemName: "person.fill").font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(.white).frame(width: 26, height: 26).background(Theme.text, in: Circle())
                    Text(model.user.isEmpty ? "You" : model.user).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("Local").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.faint)
                }
                .padding(.vertical, 5).padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(SideRowStyle(active: false)).menuIndicator(.hidden)
            Button { model.open(.wallets) } label: {
                Image(systemName: "wallet.bifold").font(.system(size: 13)).foregroundStyle(model.route == .wallets ? Theme.text : Theme.muted)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(ToolStyle()).help("Wallets")
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }
}

/// Sidebar rows: soft grey when active or hovered.
struct SideRowStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        SideRowBody(active: active, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct SideRowBody<Content: View>: View {
    let active: Bool
    let pressed: Bool
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .background(active ? Theme.hover : (hover || pressed) ? Theme.hover.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { h in withAnimation(.snappy(duration: 0.12)) { hover = h } }
    }
}
