import SwiftUI

/// Claude-style sidebar from the demo: funds card, New chat, pages, projects, recents, account.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HermitMark(height: 15).padding(.leading, 8).padding(.bottom, 12)
                    funds.padding(.bottom, 10)
                    ForEach(Route.allCases) { r in row(r) }
                    section("Projects")
                    ForEach(model.projects, id: \.0) { p in
                        HStack(spacing: 8) {
                            Circle().fill(p.1).frame(width: 6, height: 6)
                            Text(p.0).lineLimit(1)
                        }
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .padding(.vertical, 5).padding(.horizontal, 10)
                    }
                    section("Recents")
                    ForEach(model.recents, id: \.self) { r in
                        Text(r).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                            .padding(.vertical, 5).padding(.horizontal, 10)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            Divider().overlay(Theme.border)
            account
        }
        .background(Theme.subtle)
    }

    private var funds: some View {
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
    }

    private func row(_ r: Route) -> some View {
        let active = model.route == r && (r != .home || !model.inChat)
        return Button {
            if r == .home { model.newChat() } else { model.route = r }
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
            }
            .foregroundStyle(r == .home ? Theme.text : (active ? Theme.text : Theme.muted))
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(active ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
    }

    private var account: some View {
        HStack(spacing: 9) {
            Text("R").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Theme.text, in: Circle())
            Text(model.user).font(.system(size: 13.5, weight: .medium))
            Text("Local").font(.system(size: 13)).foregroundStyle(Theme.faint)
            Spacer()
            Image(systemName: "wallet.bifold").font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
