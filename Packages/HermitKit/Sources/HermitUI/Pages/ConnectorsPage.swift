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
    @State private var sheet: ConnectorSheet?
    private var store: ConnectorStore { .shared }

    enum ConnectorSheet: Identifiable {
        case binanceConnect, binance, addMCP, server(ConnectorStore.MCPServer)
        var id: String {
            switch self { case .binanceConnect: "bc"; case .binance: "b"; case .addMCP: "m"; case .server(let s): s.id.uuidString }
        }
    }
    private var calendar: CalendarStore { .shared }

    var body: some View {
        // Only what works today. Other apps, paid APIs, skills and MCP servers come back as each one is built.
        Page(title: "Connectors", subtitle: "Apps and tools Hermit can use", tabs: [("apps", "Apps")], tab: $tab) {
            Button { sheet = .addMCP } label: { Label("MCP", systemImage: "plus") }.buttonStyle(OutlineButton())
        } content: { t in
            switch t {
            case "apis": apis
            case "skills": skills
            default: apps
            }
        }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .binanceConnect: BinanceConnectSheet { model.toast("Binance connected") }
                case .binance: BinanceSheet()
                case .addMCP: MCPAddSheet()
                case .server(let srv): MCPServerSheet(server: srv)
                }
            }
            .environment(model).tint(Theme.text)
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
            if Self.showBinance {
            Hairline()
            HStack(spacing: 12) {
                LogoMark("binance", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Binance").font(.system(size: 14, weight: .medium))
                    Text(store.binanceConnected ? "Balances and spot orders" : "Your exchange account, with your own API key")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if store.binanceConnected {
                    Button("Open") { sheet = .binance }.buttonStyle(OutlineButton())
                } else {
                    Button("Connect") { sheet = .binanceConnect }.buttonStyle(BlackButton())
                }
            }
            .padding(.vertical, 11)
            }
            Text("MCP servers").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 22).padding(.bottom, 4)
            if store.servers.isEmpty {
                Button { sheet = .addMCP } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted).frame(width: 34, height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add an MCP server").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                            Text("Any remote server, by its https address").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(store.servers) { s in
                Button { sheet = .server(s) } label: {
                    HStack(spacing: 12) {
                        WalletSymbolTile(symbol: "point.3.connected.trianglepath.dotted", size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                            Text(store.tools[s.id].map { "\($0.count) tools" } ?? (URL(string: s.url)?.host() ?? s.url))
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if Self.showUnbuilt { Hairline() }
            if Self.showUnbuilt { RowList(items: ConnectorSeed.apps) { c in
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
            } }
        }
    }

    /// Off in shipped builds: rows whose Connect doesn't work yet.
    static let showUnbuilt = false
    /// Binance is built (ConnectorSheets.swift) but off for the first TestFlight; flip to bring it back.
    static let showBinance = false

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
