import SwiftUI
import Observation

/// Sites you added yourself (from Explore's address field or the browser menu), shown first in Explore. Kept on this
/// device only, newest first.
@MainActor @Observable
final class SavedSites {
    static let shared = SavedSites()
    struct Site: Codable, Identifiable, Hashable {
        var id: String { url }
        let url: String
        var title: String
        var host: String { URL(string: url)?.host() ?? url }
        /// Shown name: the page title when it's short, else the host without "www.".
        var name: String {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return t.isEmpty || t.count > 28 ? h : t
        }
    }

    private static let key = "hermitSavedSites"
    private(set) var sites: [Site] = []

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode([Site].self, from: d) { sites = s }
    }

    func contains(_ url: URL?) -> Bool { url.map { u in sites.contains { $0.host == u.host() } } ?? false }

    func add(_ url: URL, title: String = "") {
        guard let h = url.host() else { return }
        let root = "\(url.scheme ?? "https")://\(h)"
        sites.removeAll { $0.host == h }
        sites.insert(Site(url: root, title: title), at: 0)
        save()
    }

    func remove(_ url: URL?) {
        guard let h = url?.host() else { return }
        sites.removeAll { $0.host == h }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(sites) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// Explore's "Your sites": every site you added, as small tiles, plus Add. Tap to open; right-click or long-press to remove.
struct SavedSitesRow: View {
    @Environment(AppModel.self) private var model
    let onAdd: () -> Void
    private var store: SavedSites { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your sites").font(.system(size: 13)).foregroundStyle(Theme.muted)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(store.sites) { s in
                        Button {
                            if let u = URL(string: s.url) { DappBrowser.shared.open(u, model: model) }
                        } label: {
                            tile { MarketLogo(key: nil, name: s.name, size: 34, remote: URL(string: "https://\(s.host)/favicon.ico")) } label: { s.name }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { withAnimation(.snappy) { store.remove(URL(string: s.url)) } }
                        }
                        .accessibilityLabel("Open \(s.name)")
                    }
                    Button(action: onAdd) {
                        tile {
                            Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
                                .frame(width: 34, height: 34).background(Theme.hover, in: Circle())
                        } label: { "Add site" }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, 22)
    }

    private func tile<Icon: View>(@ViewBuilder _ icon: () -> Icon, label: () -> String) -> some View {
        VStack(spacing: 6) {
            icon()
            Text(label()).font(.system(size: 11.5)).foregroundStyle(Theme.text).lineLimit(1).frame(width: 72)
        }
        .frame(width: 76).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
