import SwiftUI
import Observation
import HermitCore

/// Connectors (demo: Connectors.jsx): Apps, Buy APIs, Skills, plus + MCP.
/// Turning on an OAuth or MCP app runs the demo sign-in; buying an API goes through the approval sheet.
struct ConnectorsPage: View {
    @Environment(AppModel.self) private var model
    @State private var store = ConnectorsStore.shared
    @State private var tab = "apps"
    @State private var sheet: ConnectorSheet?

    enum ConnectorSheet: Identifiable {
        case connect(String), mcp
        var id: String { if case .connect(let a) = self { return a }; return "mcp" }
    }

    var body: some View {
        Page(title: "Connectors", subtitle: "Apps, paid APIs and skills Hermit can use",
             tabs: [("apps", "Apps"), ("apis", "Buy APIs"), ("skills", "Skills")], tab: $tab) {
            Button { sheet = .mcp } label: { Label("MCP", systemImage: "plus") }.buttonStyle(OutlineButton())
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
                case .connect(let app): ConnectAppSheet(app: app) { store.set(app, on: true) }
                case .mcp: AddMcpSheet { name in
                    store.addMcp(name); tab = "apps"; model.toast("\(name) connected")
                }
                }
            }
            .environment(model).tint(Theme.text)
        }
        .approvalHost(sheetOpen: sheet != nil) { sheet = nil }
        .onAppear {
            if let r = model.tabRequest, ["apps", "apis", "skills"].contains(r) { tab = r; model.tabRequest = nil }
        }
    }

    private var apps: some View {
        RowList(items: store.apps) { c in
            HStack(spacing: 12) {
                LogoMark(c.name, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.name).font(.system(size: 14, weight: .medium))
                        if c.kind == "MCP" || c.kind == "OAuth" { Text(c.kind).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    }
                    Text(c.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Toggle(isOn: Binding(get: { store.on.contains(c.name) }, set: { toggle(c, $0) })) { Text(c.name) }
                    .labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
            .padding(.vertical, 11)
        }
    }

    private func toggle(_ c: Connector, _ on: Bool) {
        if !on { store.set(c.name, on: false); model.toast("\(c.name) disconnected"); return }
        if c.kind == "OAuth" || (c.kind == "MCP" && !c.custom) { sheet = .connect(c.name) }
        else { store.set(c.name, on: true); model.toast("\(c.name) on") }
    }

    private var apis: some View { APIList(store: store) }

    private var skills: some View {
        RowList(items: ConnectorSeed.skills) { s in
            HStack(spacing: 12) {
                WalletSymbolTile(symbol: s.symbol, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.system(size: 14, weight: .medium))
                    Text(s.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if s.locked {
                    Text("Always on").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                } else if store.skills.contains(s.name) {
                    Button { withAnimation(.snappy) { _ = store.skills.remove(s.name) }; model.toast("\(s.name) off") } label: {
                        PillTag(text: "On", color: Theme.green, dot: true)
                    }
                    .buttonStyle(PressStyle()).help("Turn off")
                } else {
                    Button("Enable") { withAnimation(.snappy) { _ = store.skills.insert(s.name) }; model.toast("\(s.name) enabled") }
                        .buttonStyle(OutlineButton())
                }
            }
            .padding(.vertical, 11)
        }
    }
}

/// Buy APIs: each Buy is a money move, so it opens the approval sheet.
private struct APIList: View {
    @Environment(\.askApproval) private var ask
    @Environment(AppModel.self) private var model
    let store: ConnectorsStore
    var body: some View {
        RowList(items: ConnectorSeed.apis) { a in
            HStack(spacing: 12) {
                LogoMark(a.by, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 14, weight: .medium))
                    Text("\(a.by), \(a.price)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if store.bought.contains(a.name) {
                    PillTag(text: "Active", color: Theme.green, dot: true)
                } else {
                    Button("Buy") {
                        ask(Approval(kind: "API purchase", title: a.name,
                                     lines: [["Seller", a.by], ["Price", a.price], ["Pay with", "USDC on Base"], ["Monthly cap", "$100"]],
                                     checks: WalletSeed.checks(["Seller matches registry"]), success: "\(a.name) connected",
                                     receipt: .receipt(title: "\(a.name) bought", rows: [["Seller", a.by], ["Price", a.price]]))) {
                            withAnimation(.snappy) { _ = store.bought.insert(a.name) }
                        }
                    }
                    .buttonStyle(BlackButton())
                }
            }
            .padding(.vertical, 11)
        }
    }
}

struct Connector: Identifiable, Hashable {
    var id: String { name }
    let name: String, kind: String, desc: String
    var custom = false
}

struct SkillItem: Identifiable, Hashable {
    var id: String { name }
    let name: String, desc: String, symbol: String, locked: Bool
}

struct APIOffer: Identifiable, Hashable {
    var id: String { name }
    let name: String, by: String, price: String
}

enum ConnectorSeed {
    static let apps: [(Connector, Bool)] = [
        (Connector(name: "Gmail", kind: "MCP", desc: "Email"), true),
        (Connector(name: "Google Calendar", kind: "MCP", desc: "Calendar"), true),
        (Connector(name: "Notion", kind: "MCP", desc: "Notes and docs"), true),
        (Connector(name: "X", kind: "OAuth", desc: "Posts and quests"), true),
        (Connector(name: "Telegram", kind: "MCP", desc: "Alpha groups, alerts"), false),
        (Connector(name: "Discord", kind: "OAuth", desc: "Airdrop roles"), false),
        (Connector(name: "OpenAI", kind: "Paid API", desc: "Billed per call in USDC"), true),
        (Connector(name: "Perplexity", kind: "Paid API", desc: "Web research"), true),
        (Connector(name: "GitHub", kind: "MCP", desc: "Repos and scripts"), false),
        (Connector(name: "Dune", kind: "API", desc: "On-chain queries"), true),
        (Connector(name: "Nansen", kind: "API", desc: "Smart money flows"), true),
    ]
    static let skills: [SkillItem] = [
        SkillItem(name: "Hazard scan", desc: "Checks every transaction", symbol: "checkmark.shield", locked: true),
        SkillItem(name: "Injection shield", desc: "Ignores instructions in web pages and email", symbol: "lock.shield", locked: true),
        SkillItem(name: "Browser takeover", desc: "Uses websites for you", symbol: "safari", locked: false),
        SkillItem(name: "Meme sniper", desc: "Screens new pairs", symbol: "scope", locked: false),
        SkillItem(name: "Airdrop farmer", desc: "Completes quests", symbol: "parachute", locked: false),
        SkillItem(name: "Research analyst", desc: "Token reports", symbol: "doc.text.magnifyingglass", locked: false),
    ]
    static let apis: [APIOffer] = [
        APIOffer(name: "GPT-5", by: "OpenAI", price: "$20 credits"),
        APIOffer(name: "Sonar", by: "Perplexity", price: "$0.005 a call"),
        APIOffer(name: "Birdeye Pro", by: "Birdeye", price: "$49 a month"),
        APIOffer(name: "Flux", by: "Black Forest Labs", price: "$0.03 an image"),
        APIOffer(name: "Firecrawl", by: "Firecrawl", price: "$0.002 a page"),
    ]
}

/// Connector state, kept while the app runs.
@MainActor @Observable
final class ConnectorsStore {
    static let shared = ConnectorsStore()
    var apps: [Connector] = ConnectorSeed.apps.map { $0.0 }
    var on: Set<String> = Set(ConnectorSeed.apps.filter { $0.1 }.map { $0.0.name })
    var skills: Set<String> = []
    var bought: Set<String> = []

    func set(_ name: String, on value: Bool) {
        withAnimation(.snappy) { if value { on.insert(name) } else { on.remove(name) } }
    }
    func addMcp(_ name: String) {
        withAnimation(.smooth) {
            apps.removeAll { $0.name == name }
            apps.insert(Connector(name: name, kind: "MCP", desc: "Custom server", custom: true), at: 0)
            on.insert(name)
        }
    }
}
