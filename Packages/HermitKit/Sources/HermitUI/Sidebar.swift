import SwiftUI
import HermitCore

/// Claude-style sidebar from the demo: funds card, New chat, pages, projects (expand to see their chats),
/// recents (saved chats you can reopen), account.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SignIn.key) private var signedIn = false
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if SnapshotMode.active { list.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
                ScrollView { list }.scrollIndicators(.never)
            }
            Divider().overlay(Theme.border)
            account
        }
        .background(Theme.subtle)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HermitMark(height: 15).padding(.leading, 8).padding(.bottom, 12).padding(.top, 2)
            funds.padding(.bottom, 10)
            ForEach(Route.sidebar) { r in row(r) }
            section("Projects")
            ForEach(model.projectList) { p in projectRow(p) }
            section("Recents")
            ForEach(model.recentConversations.prefix(14)) { c in
                chatRow(c, indent: 0)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 12)
        .animation(.snappy(duration: 0.25), value: expanded)
        .animation(.snappy(duration: 0.25), value: model.conversations.map(\.id))
    }

    private var funds: some View {
        Button { model.open(.wallets) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Under management").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                HStack {
                    Text("$48,320").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    Spacer()
                    Text("+2.6%").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.green)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
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
                if r == .payments { Text("2").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                if r == .home { Text("⌘N").font(.system(size: 11)).foregroundStyle(Theme.faint).opacity(SnapshotMode.active ? 0 : 1) }
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
                Section(model.email) {
                    Button { model.open(.wallets) } label: { Label("Wallets", systemImage: "wallet.bifold"); Text("$48,320") }
                    Button("Files", systemImage: "doc") { model.open(.files) }
                    Button("Connectors", systemImage: "puzzlepiece.extension") { model.open(.connectors) }
                    Button("Settings", systemImage: "gearshape") { model.open(.settings) }.keyboardShortcut(",", modifiers: .command)
                }
                Divider()
                Button("Get help", systemImage: "questionmark.circle") {
                    model.newChat()
                    model.react("How do I get started?", "Ask anything in chat. Try \"best safe yield for 10k USDC\" or \"what news is moving the market\". Anything that moves money shows an approval first.")
                }
                Divider()
                Button("Log out", systemImage: "rectangle.portrait.and.arrow.right") {
                    model.newChat()
                    withAnimation(.smooth) { signedIn = false }
                }
            } label: {
                HStack(spacing: 9) {
                    Text(String(model.user.prefix(1))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Theme.text, in: Circle())
                    Text(model.user).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
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
