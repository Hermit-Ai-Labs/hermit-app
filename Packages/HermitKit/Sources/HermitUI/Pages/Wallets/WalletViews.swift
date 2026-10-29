import SwiftUI
import HermitCore

enum AllWalletsTab: String, CaseIterable, Hashable {
    case tokens, dapps, gas, activity, accounts
    var title: String {
        switch self { case .tokens: "Tokens"; case .dapps: "DApps"; case .gas: "Gas"; case .activity: "Activity"; case .accounts: "Accounts" }
    }
}

// MARK: Header

/// Balance, change, and the four exchange-style actions. Scoped to one wallet or all of them.
struct BalanceCard<Sub: View>: View {
    let label: String
    let usd: Double
    let oneWallet: Bool
    let open: (WalletSheet) -> Void
    var walletID: String? = nil
    @ViewBuilder var sub: () -> Sub

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Button { open(.history(wallet: walletID)) } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Transaction history")
                .accessibilityLabel("Transaction history")
            }
            Text(MoneyFmt.usd(usd)).font(.system(size: 36, weight: .semibold)).tracking(-0.8).monospacedDigit()
                .contentTransition(.numericText()).animation(.smooth, value: usd)
                .padding(.top, 2)
            sub().padding(.top, 3)
            HStack(spacing: 18) {
                RoundAction(title: oneWallet ? "Add funds" : "Deposit", symbol: "arrow.down.to.line") { open(.receive(wallet: walletID)) }
                RoundAction(title: "Send", symbol: "arrow.up.right") { open(.send(from: walletID, chain: nil, token: nil)) }
                RoundAction(title: "Transfer", symbol: "arrow.left.arrow.right") { open(.transfer(from: walletID)) }
                RoundAction(title: "Bridge", symbol: "point.3.connected.trianglepath.dotted") { open(.bridge(token: nil)) }
            }
            .padding(.top, 22)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// Assets the agent manages, as a pie: by token or by project. Project rows open Projects.
struct AumCard: View {
    @Environment(AppModel.self) private var model
    @State private var byProject = false

    var body: some View {
        let data = byProject ? WalletSeed.aumByProject : WalletSeed.aumByAsset
        let total = data.reduce(0) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Managed by agent").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Segmented(options: [(false, "Assets"), (true, "Projects")], selection: $byProject)
            }
            HStack(alignment: .center, spacing: 18) {
                Donut(parts: data.map { ($0.1 / total, $0.2) }).frame(width: 96, height: 96)
                    .animation(.smooth, value: byProject)
                VStack(spacing: 5) {
                    ForEach(data, id: \.0) { d in
                        Button {
                            if byProject && d.0 != "Not in a project" { model.open(.projects, tab: d.0) }
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(d.2).frame(width: 8, height: 8)
                                Text(d.0).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 6)
                                Text(MoneyFmt.usd(d.1)).monospacedDigit()
                                Text("\(Int((d.1 / total * 100).rounded()))%").foregroundStyle(Theme.faint).monospacedDigit().frame(width: 34, alignment: .trailing)
                            }
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!byProject || d.0 == "Not in a project")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// Short balance curve with 1W / 1M / 3M / 1Y.
struct BalanceChart: View {
    let total: Double
    @Binding var range: String
    static let ranges: [(String, Int)] = [("1W", 7), ("1M", 30), ("3M", 90), ("1Y", 365)]

    static func series(_ total: Double, _ range: String) -> [Double] {
        let n = ranges.first { $0.0 == range }?.1 ?? 30
        // A wiggly walk, then bent so it ends at today's total after a believable gain for the range.
        let raw = Candle.series(seed: 5 + n, count: min(n, 80), start: 100, vol: 0.012, drift: 0).map(\.c)
        let growth = ["1W": 0.018, "1M": 0.086, "3M": 0.17, "1Y": 0.42][range] ?? 0.08
        let first = raw.first ?? 100, last = raw.last ?? 100, count = Double(max(raw.count - 1, 1))
        let start = total / (1 + growth)
        return raw.enumerated().map { i, v in
            let t = Double(i) / count
            let trend = start + (total - start) * t
            return trend * (v / (first + (last - first) * t))
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            LineChart(values: Self.series(total, range)).frame(height: 90)
                .animation(.smooth(duration: 0.35), value: range)
            Segmented(options: Self.ranges.map { ($0.0, $0.0) }, selection: $range)
        }
    }
}

// MARK: All wallets

struct AllWalletsView: View {
    let vm: WalletsViewModel
    @Binding var tab: AllWalletsTab
    let wide: Bool
    let open: (WalletSheet) -> Void
    @State private var range = "1M"

    var body: some View {
        let total = vm.total()
        let series = BalanceChart.series(total, range)
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 14) { balance(total, series); AumCard() }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 14) { balance(total, series); AumCard() }
                }
            }
            BalanceChart(total: total, range: $range).padding(.top, 18)
            PageTabs(tabs: AllWalletsTab.allCases.map { ($0, $0.title) }, selection: $tab).padding(.top, 22)
            Group {
                switch tab {
                case .tokens: TokensList(vm: vm, walletID: nil, open: open)
                case .dapps: DAppsList()
                case .gas: GasList(vm: vm, open: open)
                case .activity: ActivityList(vm: vm, walletID: nil, open: open)
                case .accounts: AccountsList(vm: vm, open: open)
                }
            }
            .padding(.top, 14)
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
    }

    private func balance(_ total: Double, _ series: [Double]) -> some View {
        let gain = total - (series.first ?? total)
        return BalanceCard(label: "Total balance", usd: total, oneWallet: false, open: open) {
            Text("\(MoneyFmt.signed(gain)) in \(range)").font(.system(size: 13)).foregroundStyle(gain >= 0 ? Theme.green : Theme.red)
                .contentTransition(.numericText()).animation(.smooth, value: range)
        }
    }
}

/// Network filter for Tokens and Activity: a native menu, not a second tab row.
struct ChainFilter: View {
    @Binding var chain: WalletChain?
    var chains: [WalletChain] = WalletChain.all
    var body: some View {
        Menu {
            Picker("Network", selection: $chain) {
                Text("All networks").tag(WalletChain?.none)
                Divider()
                ForEach(chains) { c in Text(c.name).tag(Optional(c)) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let chain { LogoMark(chain.logo, size: 16) } else { ChainStack(chains: Array(chains.prefix(4)), size: 14) }
                Text(chain?.name ?? "All networks").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.subtle, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Network")
    }
}

struct TokensList: View {
    let vm: WalletsViewModel
    let walletID: String?
    let open: (WalletSheet) -> Void
    @State private var chain: WalletChain?

    var body: some View {
        let groups = vm.tokenGroups(wallet: walletID, chain: chain)
        let chains = walletID.flatMap { vm.wallet($0)?.chains } ?? WalletChain.all
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(MoneyFmt.usd(groups.reduce(0) { $0 + $1.usd })) on \(chain?.name ?? "\(Set(groups.flatMap(\.chains)).count) networks")")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).contentTransition(.numericText())
                Spacer()
                ChainFilter(chain: $chain, chains: chains)
            }
            if groups.isEmpty { EmptyNote(text: "No tokens on \(chain?.name ?? "any network") yet.") }
            RowList(items: groups) { g in
                Button { open(.token(g)) } label: {
                    HStack(spacing: 12) {
                        TokenLogo(symbol: g.symbol, chain: g.chains.count == 1 ? g.chains[0] : nil, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.symbol).font(.system(size: 14, weight: .medium))
                            HStack(spacing: 6) {
                                Text(MoneyFmt.amount(g.amount)).monospacedDigit()
                                if g.chains.count > 1 { ChainStack(chains: g.chains, size: 13) }
                                else if let c = g.chains.first { Text(c.name) }
                            }
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(MoneyFmt.usd(g.usd)).font(.system(size: 14)).monospacedDigit()
                            Text(MoneyFmt.pct(g.change)).font(.system(size: 12.5)).monospacedDigit()
                                .foregroundStyle(g.change > 0 ? Theme.green : g.change < 0 ? Theme.red : Theme.muted)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .animation(.smooth(duration: 0.25), value: chain)
    }
}

struct DAppsList: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RowList(items: WalletSeed.dapps) { d in
            Button { model.open(d.type.contains("Perps") || d.type.contains("Spot") ? .trade : .earn) } label: {
                HStack(spacing: 12) {
                    TokenLogo(symbol: d.name, chain: d.chain, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 14, weight: .medium))
                        Text("\(d.type), \(d.chain.name)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFmt.usd(d.usd)).font(.system(size: 14)).monospacedDigit()
                        Text(MoneyFmt.signed(d.pnl)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(d.pnl >= 0 ? Theme.green : Theme.red)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(RowButtonStyle())
        }
    }
}

struct GasList: View {
    @Bindable var vm: WalletsViewModel
    let open: (WalletSheet) -> Void

    var body: some View {
        let total = vm.gas.reduce(0) { $0 + $1.usd }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label { Text("Gas ") + Text(MoneyFmt.usd(total)).foregroundStyle(Theme.faint) } icon: { Image(systemName: "fuelpump") }
                    .font(.system(size: 13.5, weight: .medium))
                Spacer()
                Text("Auto top-up").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Toggle("Auto top-up", isOn: $vm.autoTopUp).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.text)
            }
            RowList(items: vm.gas) { g in gasRow(g) }
            HStack(spacing: 4) {
                Text(vm.autoTopUp ? "Refills any chain below 20 transactions." : "Auto top-up is off.")
                Button("Bridge funds") { open(.bridge(token: nil)) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(.top, 6)
        }
    }

    private func gasRow(_ g: GasTank) -> some View {
        HStack(spacing: 12) {
            LogoMark(g.chain.logo, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(g.chain.name).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("\(MoneyFmt.amount(g.amount)) \(g.chain.gasToken)").font(.system(size: 12.5)).monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hover)
                        Capsule().fill(g.low ? Theme.red : Theme.text).frame(width: geo.size.width * g.level)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text("\(g.low ? "Low, " : "")\(g.txs.formatted(.number.locale(Locale(identifier: "en_US")))) txs left")
                        .foregroundStyle(g.low ? Theme.red : Theme.muted).lineLimit(1)
                    Spacer()
                    Text(g.usd >= 10 ? MoneyFmt.usd(g.usd) : MoneyFmt.usd(g.usd, digits: 2)).foregroundStyle(Theme.muted).monospacedDigit()
                }
                .font(.system(size: 12))
            }
            HStack(spacing: 6) {
                gasButton("arrow.down.to.line", brand: g.low, label: "Top up \(g.chain.name) gas") { open(.gasTopUp(g.chain)) }
                gasButton("arrow.up.right", brand: false, label: "Withdraw \(g.chain.name) gas") { open(.gasWithdraw(g.chain)) }
                    .disabled(g.usd < 1).opacity(g.usd < 1 ? 0.4 : 1)
            }
            .padding(.leading, 6)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { open(.gasTopUp(g.chain)) }
    }

    private func gasButton(_ symbol: String, brand: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(brand ? .white : Theme.text)
                .frame(width: 34, height: 34)
                .background(brand ? Theme.accent : Theme.hover, in: Circle())
        }
        .buttonStyle(PressStyle())
        .help(label).accessibilityLabel(label)
    }
}

struct ActivityList: View {
    let vm: WalletsViewModel
    let walletID: String?
    let open: (WalletSheet) -> Void
    @State private var chain: WalletChain?

    var body: some View {
        let items = vm.activity(wallet: walletID, chain: chain)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(items.count) transactions").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                ChainFilter(chain: $chain)
            }
            if items.isEmpty { EmptyNote(text: "Nothing on \(chain?.name ?? "any network") yet.") }
            RowList(items: items) { a in ActivityRow(item: a, wallet: walletID == nil ? vm.wallet(a.walletID)?.name : nil) { open(.activity(a)) } }
        }
        .animation(.smooth(duration: 0.25), value: chain)
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    var wallet: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.usd > 0 ? "arrow.down.left" : "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.usd > 0 ? Theme.green : Theme.muted)
                    .frame(width: 32, height: 32).background(item.usd > 0 ? Theme.green.opacity(0.1) : Theme.hover, in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        LogoMark(item.chain.logo, size: 14).padding(1).background(Theme.bg, in: Circle()).offset(x: 3, y: 3)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.what).font(.system(size: 14)).lineLimit(1)
                    Text([item.when, item.via, wallet].compactMap { $0 }.joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(item.usd == 0 ? "$0" : MoneyFmt.signed(item.usd)).font(.system(size: 14)).monospacedDigit()
                    .foregroundStyle(item.usd > 0 ? Theme.green : Theme.text)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct AccountsList: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: WalletsViewModel
    let open: (WalletSheet) -> Void
    var body: some View {
        RowList(items: WalletSeed.accounts) { a in
            let on = vm.linked.contains(a.app)
            HStack(spacing: 12) {
                LogoMark(a.app, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(on ? a.handle : a.app).font(.system(size: 14, weight: .medium))
                    Text(on ? a.on : a.off).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if on {
                    Button("Disconnect") { withAnimation(.snappy) { _ = vm.linked.remove(a.app) }; model.toast("\(a.app) disconnected") }
                        .buttonStyle(OutlineButton())
                } else {
                    Button("Connect") { open(.connect(a.app)) }.buttonStyle(BlackButton())
                }
            }
            .padding(.vertical, 11)
        }
    }
}

// MARK: One wallet

struct OneWalletView: View {
    @Environment(AppModel.self) private var model
    let vm: WalletsViewModel
    let wallet: WalletAccount
    let wide: Bool
    let open: (WalletSheet) -> Void
    @State private var tab = "tokens"

    var body: some View {
        let l = WalletSeed.links[wallet.id] ?? WalletLinks()
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 14) { header; NetworksCard(vm: vm, wallet: wallet) }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 14) { header; NetworksCard(vm: vm, wallet: wallet) }
                }
            }
            PageTabs(tabs: [("tokens", "Tokens"), ("projects", count("Projects", l.projects.count)), ("trading", count("Trading", l.trades.count)),
                            ("payments", count("Payments", l.payments.count)), ("defi", count("DeFi", l.defi.count)), ("activity", "Activity")],
                     selection: $tab)
                .padding(.top, 24)
            Group {
                switch tab {
                case "tokens": TokensList(vm: vm, walletID: wallet.id, open: open)
                case "projects": projects(l)
                case "trading": trading(l)
                case "payments": payments(l)
                case "defi": defi(l)
                default: ActivityList(vm: vm, walletID: wallet.id, open: open)
                }
            }
            .padding(.top, 14)
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
    }

    private func count(_ s: String, _ n: Int) -> String { n > 0 ? "\(s) \(n)" : s }

    private var header: some View {
        BalanceCard(label: "\(wallet.kind), \(wallet.source.lowercased().hasPrefix("privy") ? "keyless" : wallet.source)", usd: vm.total(wallet.id), oneWallet: true, open: open, walletID: wallet.id) {
            VStack(alignment: .leading, spacing: 4) {
                if let a = wallet.evmAddress { addressLine(a, chains: WalletChain.evm, name: "EVM") }
                if let a = wallet.solanaAddress { addressLine(a, chains: [.solana], name: "Solana") }
            }
            .padding(.top, 4)
        }
    }

    private func addressLine(_ a: String, chains: [WalletChain], name: String) -> some View {
        Button { Clip.copy(a); model.toast("\(name) address copied") } label: {
            HStack(spacing: 7) {
                ChainStack(chains: chains, size: 15)
                Text(shortAddr(a)).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.muted)
                Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(name) address: \(a)")
    }

    private func linkRow<T: View>(_ action: @escaping () -> Void, @ViewBuilder _ content: () -> T) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 11)
        }
        .buttonStyle(RowButtonStyle())
    }

    @ViewBuilder private func projects(_ l: WalletLinks) -> some View {
        if l.projects.isEmpty { EmptyNote(text: "No projects use this wallet.") }
        VStack(spacing: 0) {
            ForEach(Array(l.projects.enumerated()), id: \.offset) { i, p in
                linkRow({ model.open(.projects, tab: p.0) }) {
                    Circle().fill(WalletSeed.projectColors[p.0] ?? Theme.faint).frame(width: 10, height: 10)
                    Text(p.0).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(MoneyFmt.usd(p.1)).font(.system(size: 14)).monospacedDigit()
                }
                if i < l.projects.count - 1 { Hairline() }
            }
        }
    }

    @ViewBuilder private func trading(_ l: WalletLinks) -> some View {
        if l.trades.isEmpty { EmptyNote(text: "No open trades.") }
        VStack(spacing: 0) {
            ForEach(Array(l.trades.enumerated()), id: \.offset) { i, t in
                linkRow({ model.open(.trade) }) {
                    LogoMark(t.0, size: 30)
                    Text(t.1).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(MoneyFmt.signed(t.2)).font(.system(size: 14)).monospacedDigit().foregroundStyle(t.2 >= 0 ? Theme.green : Theme.red)
                }
                if i < l.trades.count - 1 { Hairline() }
            }
        }
    }

    @ViewBuilder private func payments(_ l: WalletLinks) -> some View {
        if l.payments.isEmpty { EmptyNote(text: "No payments from this wallet.") }
        VStack(spacing: 0) {
            ForEach(Array(l.payments.enumerated()), id: \.offset) { i, p in
                linkRow({ model.open(.payments) }) {
                    LogoMark(p.0, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.0).font(.system(size: 14, weight: .medium))
                        Text(p.1).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    .lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFmt.usd(p.2)).font(.system(size: 14)).monospacedDigit()
                        Text(p.3).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                }
                if i < l.payments.count - 1 { Hairline() }
            }
        }
    }

    @ViewBuilder private func defi(_ l: WalletLinks) -> some View {
        if l.defi.isEmpty { EmptyNote(text: "No DeFi positions.") }
        VStack(spacing: 0) {
            ForEach(Array(l.defi.enumerated()), id: \.offset) { i, d in
                linkRow({ model.open(.earn) }) {
                    LogoMark(d.0, size: 30)
                    Text("\(d.0) \(d.1)").font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFmt.usd(d.2)).font(.system(size: 14)).monospacedDigit()
                        Text("\(d.3.formatted(.number.precision(.fractionLength(1))))%").font(.system(size: 12)).foregroundStyle(Theme.green)
                    }
                }
                if i < l.defi.count - 1 { Hairline() }
            }
        }
    }
}

/// Where one wallet's money sits, by network.
struct NetworksCard: View {
    let vm: WalletsViewModel
    let wallet: WalletAccount
    var body: some View {
        let total = max(vm.total(wallet.id), 0.01)
        let rows = wallet.chains.map { c in (c, vm.holdings(wallet: wallet.id, chain: c).reduce(0) { $0 + $1.usd }) }.sorted { $0.1 > $1.1 }
        VStack(alignment: .leading, spacing: 12) {
            Text("Networks").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            ForEach(rows, id: \.0) { r in
                HStack(spacing: 10) {
                    LogoMark(r.0.logo, size: 20)
                    Text(r.0.name).font(.system(size: 13)).frame(width: 82, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hover)
                            Capsule().fill(Theme.text).frame(width: max(r.1 > 0 ? 3 : 0, g.size.width * r.1 / total))
                        }
                    }
                    .frame(height: 4)
                    Text(MoneyFmt.usd(r.1)).font(.system(size: 12.5)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}
