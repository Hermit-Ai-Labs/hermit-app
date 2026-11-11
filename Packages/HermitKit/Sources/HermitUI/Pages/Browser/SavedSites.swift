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

/// Explore's "Your sites": the heading with Add on its right, then every site you added as a pill (icon and name),
/// left-aligned under the heading and wrapping like the category chips. Tap to open; right-click or long-press to remove.
struct SavedSitesRow: View {
    @Environment(AppModel.self) private var model
    let onAdd: () -> Void
    private var store: SavedSites { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Your sites").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(action: onAdd) {
                    Label("Add site", systemImage: "plus").font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(PayPillButton(kind: .outline))
            }
            if store.sites.isEmpty {
                Text("Add any site to open it here in one tap.").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            } else {
                PayFlow(spacing: 6) {
                    ForEach(store.sites) { s in
                        PayChip(on: false, action: { if let u = URL(string: s.url) { DappBrowser.shared.open(u, model: model) } }) {
                            // A directory app gets its bundled logo: many sites answer /favicon.ico with a page or nothing.
                            if let app = DappBrowser.directoryName(for: s.host) { MarketLogo(key: app, name: s.name, size: 16) }
                            else { MarketLogo(key: nil, name: s.name, size: 16, remote: URL(string: "https://\(s.host)/favicon.ico")) }
                            Text(s.name)
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) { withAnimation(.snappy) { store.remove(URL(string: s.url)) } }
                        }
                        .accessibilityLabel("Open \(s.name)")
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }
}

/// Hermit's own Add a site dialog (centered on the Mac, a bottom sheet on iPhone): type an address, see the site it
/// resolves to, then Add or Add and open.
struct AddSiteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var url: URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.contains(".") && !t.hasSuffix(".") ? DappBrowserSession.normalize(t) : nil
    }
    private var already: Bool { SavedSites.shared.contains(url) }

    var body: some View {
        SheetChrome(title: "Add a site", width: 420) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type a site's address. It shows in Your sites and opens in Hermit's browser.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                BoxedTextField(placeholder: "app.uniswap.org", text: $text)
                    #if os(iOS)
                    .keyboardType(.URL).submitLabel(.done)
                    #endif
                    .onSubmit { add(open: false) }
                HStack(spacing: 8) {
                    Image(systemName: url == nil ? "globe" : "checkmark.circle.fill")
                        .foregroundStyle(url == nil ? Theme.faint : Theme.green)
                    Text(url?.host() ?? (text.isEmpty ? "Enter an address like example.com" : "That isn't a web address yet"))
                        .foregroundStyle(url == nil ? Theme.faint : Theme.text).lineLimit(1)
                    if already { Text("Already in Your sites").foregroundStyle(Theme.muted) }
                }
                .font(.system(size: 12.5))
                .animation(.snappy(duration: 0.15), value: url)
            }
        } foot: {
            HStack(spacing: 8) {
                Button("Add") { add(open: false) }.buttonStyle(WideButton(kind: .plain))
                Button("Add and open") { add(open: true) }.buttonStyle(WideButton(kind: .black))
            }
            .disabled(url == nil)
        }
    }

    private func add(open: Bool) {
        guard let u = url else { return }
        withAnimation(.snappy) { SavedSites.shared.add(u) }
        dismiss()
        if open { DappBrowser.shared.open(u, model: model) } else { model.toast("Added \(u.host() ?? "")") }
    }
}
