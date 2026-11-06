import SwiftUI
import HermitCore
#if os(iOS)
import UIKit
#endif

/// Connectors: the apps, paid APIs and skills Hermit will be able to use. Sign-in to other apps isn't built yet,
/// so their Connect buttons are greyed out. The device calendar is real and connects with a permission prompt.
struct ConnectorsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var tab = "apps"
    private var calendar: CalendarStore { .shared }

    var body: some View {
        Page(title: "Connectors", subtitle: "Apps, paid APIs and skills Hermit can use",
             tabs: [("apps", "Apps"), ("apis", "Buy APIs"), ("skills", "Skills")], tab: $tab) {
            Button {} label: { Label("MCP", systemImage: "plus") }.buttonStyle(OutlineButton())
                .comingSoon("Custom MCP servers are coming soon")
        } content: { t in
            switch t {
            case "apis": apis
            case "skills": skills
            default: apps
            }
        }
        .onAppear {
            calendar.refreshAccess()
            if let r = model.tabRequest, ["apps", "apis", "skills"].contains(r) { tab = r; model.tabRequest = nil }
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WalletSymbolTile(symbol: "calendar", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendar").font(.system(size: 14, weight: .medium))
                    Text("Your events, read on this phone").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                switch calendar.access {
                case .full: PillTag(text: "On", color: Theme.green, dot: true)
                case .unknown: Button("Allow") { Task { await calendar.requestAccess() } }.buttonStyle(OutlineButton())
                case .writeOnly, .denied: Button("Open Settings") { openSettings() }.buttonStyle(OutlineButton())
                }
            }
            .padding(.vertical, 11)
            Hairline()
            RowList(items: ConnectorSeed.apps) { c in
                HStack(spacing: 12) {
                    LogoMark(c.name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 14, weight: .medium))
                        Text(c.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    soon("Connect")
                }
                .padding(.vertical, 11)
            }
        }
    }

    private var apis: some View {
        RowList(items: ConnectorSeed.apis) { a in
            HStack(spacing: 12) {
                LogoMark(a.by, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 14, weight: .medium))
                    Text("\(a.by), \(a.price)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                soon("Buy")
            }
            .padding(.vertical, 11)
        }
    }

    private var skills: some View {
        RowList(items: ConnectorSeed.skills) { s in
            HStack(spacing: 12) {
                WalletSymbolTile(symbol: s.symbol, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.system(size: 14, weight: .medium))
                    Text(s.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                soon("Enable")
            }
            .padding(.vertical, 11)
        }
    }

    /// A greyed button with "Coming soon" under it.
    private func soon(_ title: String) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(title) {}.buttonStyle(OutlineButton()).comingSoon()
            Text("Coming soon").font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
    }

    private func openSettings() {
        #if os(macOS)
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        #else
        let s = UIApplication.openSettingsURLString
        #endif
        if let u = URL(string: s) { openURL(u) }
    }
}

struct Connector: Identifiable, Hashable {
    var id: String { name }
    let name: String, desc: String
}

struct SkillItem: Identifiable, Hashable {
    var id: String { name }
    let name: String, desc: String, symbol: String
}

struct APIOffer: Identifiable, Hashable {
    var id: String { name }
    let name: String, by: String, price: String
}

/// The catalogue. Nothing here is connected yet.
enum ConnectorSeed {
    static let apps: [Connector] = [
        Connector(name: "Gmail", desc: "Read email and draft replies"),
        Connector(name: "Google Calendar", desc: "See and add events"),
        Connector(name: "Notion", desc: "Notes and docs"),
        Connector(name: "X", desc: "Read and post, when you ask"),
        Connector(name: "Telegram", desc: "Alerts and approvals in a chat"),
        Connector(name: "Discord", desc: "Servers and roles"),
        Connector(name: "GitHub", desc: "Repos and pull requests"),
        Connector(name: "Figma", desc: "Files and comments"),
        Connector(name: "Vercel", desc: "Deployments"),
    ]
    static let skills: [SkillItem] = [
        SkillItem(name: "Browser", desc: "Uses websites for you", symbol: "safari"),
        SkillItem(name: "Token screener", desc: "Screens new pairs for risks", symbol: "scope"),
        SkillItem(name: "Quest runner", desc: "Completes airdrop quests", symbol: "parachute"),
        SkillItem(name: "Research analyst", desc: "Writes token reports", symbol: "doc.text.magnifyingglass"),
    ]
    static let apis: [APIOffer] = [
        APIOffer(name: "GPT-5", by: "OpenAI", price: "$20 credits"),
        APIOffer(name: "Sonar", by: "Perplexity", price: "$0.005 a call"),
        APIOffer(name: "Birdeye Pro", by: "Birdeye", price: "$49 a month"),
        APIOffer(name: "Flux", by: "Black Forest Labs", price: "$0.03 an image"),
        APIOffer(name: "Firecrawl", by: "Firecrawl", price: "$0.002 a page"),
        APIOffer(name: "Query API", by: "Dune", price: "$0.01 a query"),
        APIOffer(name: "Smart money", by: "Nansen", price: "$0.02 a call"),
    ]
}
