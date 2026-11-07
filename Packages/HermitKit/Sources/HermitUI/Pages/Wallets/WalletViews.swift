import SwiftUI
import HermitCore
import HermitWallet

enum AllWalletsTab: String, CaseIterable, Hashable {
    case tokens, dapps, gas, activity, accounts
    /// The tabs that work today. DApps (WalletConnect) and Accounts come back when they're built.
    static let shipped: [AllWalletsTab] = [.tokens, .gas, .activity]
    var title: String {
        switch self { case .tokens: "Tokens"; case .dapps: "DApps"; case .gas: "Gas"; case .activity: "Activity"; case .accounts: "Accounts" }
    }
}

/// Greys out a control that isn't connected yet and says why on hover.
struct NotYet: ViewModifier {
    let reason: String
    func body(content: Content) -> some View {
        // Button styles draw their own readable disabled look; this only softens non-button rows a little.
        content.disabled(true).opacity(0.7).help(reason)
    }
}
extension View {
    func notYet(_ reason: String) -> some View { modifier(NotYet(reason: reason)) }
}

// MARK: Header

/// Balance and the exchange-style actions. Scoped to one wallet or all of them.
struct BalanceCard<Sub: View>: View {
    let vm: WalletsViewModel
    let label: String
    let oneWallet: Bool
    let open: (WalletSheet) -> Void
    var walletID: String? = nil
    @ViewBuilder var sub: () -> Sub

    private var usd: Double? {
        guard let t = vm.totalUSD else { return nil }
        return walletID == nil ? t : vm.total(walletID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Button { Task { await vm.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                        .rotationEffect(.degrees(vm.refreshing ? 360 : 0))
                        .animation(vm.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: vm.refreshing)
                }
                .buttonStyle(PressStyle()).disabled(vm.refreshing)
                .help("Refresh balances").accessibilityLabel("Refresh balances")
                Button { open(.history(wallet: walletID)) } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Transaction history")
                .accessibilityLabel("Transaction history")
            }
            Group {
                if let usd {
                    Text(MoneyFmt.usd(usd, digits: usd < 100 ? 2 : 0)).contentTransition(.numericText()).animation(.smooth, value: usd)
                } else {
                    Text("$—").foregroundStyle(Theme.faint)
                }
            }
            .font(.system(size: 36, weight: .semibold)).tracking(-0.8).monospacedDigit()
            .padding(.top, 2)
            Text(status).font(.system(size: 12.5)).foregroundStyle(vm.unreachable.contains { !$0.isTestnet } ? Theme.red : Theme.muted)
                .lineLimit(2).padding(.top, 3)
            sub().padding(.top, 3)
            HStack(spacing: 18) {
                RoundAction(title: oneWallet ? "Add funds" : "Deposit", symbol: "arrow.down.to.line") { open(.receive(wallet: walletID)) }
                RoundAction(title: "Send", symbol: "arrow.up.right") { open(.send(from: walletID, chain: nil, token: nil)) }
                RoundAction(title: "Swap", symbol: "arrow.triangle.2.circlepath") { open(.swap(from: walletID, bridge: false, token: nil, chain: nil)) }
                RoundAction(title: "Bridge", symbol: "point.3.connected.trianglepath.dotted") { open(.swap(from: walletID, bridge: true, token: nil, chain: nil)) }
            }
            .padding(.top, 22)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private var status: String {
        if vm.refreshing && !vm.loaded { return "Loading balances…" }
        let down = vm.unreachable.filter { !$0.isTestnet }
        if !down.isEmpty { return "Couldn't reach \(down.map(\.name).joined(separator: ", ")). Total unknown." }
        if vm.loaded && vm.totalUSD == nil && vm.prices.isEmpty { return "Prices unavailable right now." }
        if let d = vm.lastUpdated { return "Mainnet value, updated \(d.formatted(date: .omitted, time: .shortened)). Testnet coins count as $0." }
        return "Mainnet value."
    }
}

/// Where the money is, by token, from real mainnet balances and prices.
struct AllocationCard: View {
    let vm: WalletsViewModel
    var walletID: String? = nil
    static let palette: [Color] = [Color(hex: 0x121212), Color(hex: 0x4E1F96), Color(hex: 0x8E73CF), Color(hex: 0xB7A6E8),
                                   Color(hex: 0xC9BFE6), Color(hex: 0xE4E4E2)]

    var body: some View {
        let byToken = Dictionary(grouping: vm.holdings(wallet: walletID, chain: nil).filter { $0.priced && $0.usd >= 0.01 }, by: \.symbol)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.usd }) }.sorted { $0.1 > $1.1 }
        let total = byToken.reduce(0) { $0 + $1.1 }
        let rows = Array(byToken.prefix(5)) + (byToken.count > 5 ? [("Other", byToken.dropFirst(5).reduce(0) { $0 + $1.1 })] : [])
        VStack(alignment: .leading, spacing: 14) {
            Text("Allocation").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            if total <= 0 {
                Text("Nothing with a price yet. Mainnet tokens show up here once they arrive.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    Ring(parts: rows.enumerated().map { ($1.1 / total, Self.palette[min($0, Self.palette.count - 1)]) }).frame(width: 96, height: 96)
                    VStack(spacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, d in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Self.palette[min(i, Self.palette.count - 1)]).frame(width: 8, height: 8)
                                Text(d.0).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(MoneyFmt.usdSmart(d.1)).monospacedDigit()
                                Text("\(Int((d.1 / total * 100).rounded()))%").foregroundStyle(Theme.faint).monospacedDigit().frame(width: 34, alignment: .trailing)
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
            }
            Text("Agent-managed funds: not set up yet").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    struct Ring: View {
        let parts: [(Double, Color)]
        var body: some View {
            ZStack {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    let start = parts.prefix(i).reduce(0) { $0 + $1.0 }
                    Circle().trim(from: start + (parts.count > 1 ? 0.006 : 0), to: start + part.0 - (parts.count > 1 ? 0.006 : 0))
                        .stroke(part.1, style: StrokeStyle(lineWidth: 14))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(7)
        }
    }
}

// MARK: No wallet yet

struct NoWalletView: View {
    let open: (WalletSheet) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No wallet on this device yet").font(.system(size: 22, weight: .semibold))
                Text("One recovery phrase gives you an address on every network Hermit supports. Your keys are made on this phone and locked by Face ID.")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Works on").font(.system(size: 12)).foregroundStyle(Theme.faint)
                ChainStack(chains: Chain.mainnets, size: 18)
            }
            VStack(spacing: 10) {
                HoloPromptCard(image: "crab-faceid", title: "Create your wallet", subtitle: "Keys made on this phone", symbol: "plus") {
                    open(.addWallet(.local, start: .create))
                }
                Button("Import recovery phrase") { open(.addWallet(.local, start: .importPhrase)) }.buttonStyle(WideButton(kind: .plain))
            }
            .frame(maxWidth: 460)
            OfflineKeysBadge().frame(maxWidth: 460)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: All wallets

struct AllWalletsView: View {
    let vm: WalletsViewModel
    @Binding var tab: AllWalletsTab
    let wide: Bool
    let open: (WalletSheet) -> Void
    var pick: (String) -> Void = { _ in }
    var remove: (WalletAccount) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 14) { balance; AllocationCard(vm: vm) }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 14) { balance; AllocationCard(vm: vm) }
                }
            }
            walletList.padding(.top, 22)
            PageTabs(tabs: AllWalletsTab.shipped.map { ($0, $0.title) }, selection: $tab).padding(.top, 22)
            Group {
                switch tab {
                case .tokens: TokensList(vm: vm, walletID: nil, open: open)
                case .dapps: DAppsList()
                case .gas: GasList(vm: vm, walletID: nil)
                case .activity: ActivityList(vm: vm, walletID: nil, open: open)
                case .accounts: AccountsList()
                }
            }
            .padding(.top, 14)
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
    }

    /// Every wallet on this phone, each with its own actions (Open, Back up, Remove) one tap away.
    private var walletList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your wallets").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.bottom, 4)
            ForEach(vm.wallets) { w in
                HStack(spacing: 10) {
                    Button { pick(w.id) } label: {
                        HStack(spacing: 10) {
                            WalletSymbolTile(symbol: w.symbol, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                                Text(w.shortAddress).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            Text(MoneyFmt.usd(vm.total(w.id), digits: 2)).font(.system(size: 13.5)).monospacedDigit().foregroundStyle(Theme.text)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button { pick(w.id) } label: { Label("Open", systemImage: "wallet.bifold") }
                        Button { open(.phrase(w.id)) } label: { Label(w.backedUp ? "Recovery phrase" : "Back up words", systemImage: "key") }
                        Divider()
                        Button(role: .destructive) { remove(w) } label: { Label("Remove from this phone", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 34, height: 34).background(Theme.hover, in: Circle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(w.name) options")
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var balance: some View {
        BalanceCard(vm: vm, label: "Total balance, \(vm.wallets.count) wallet\(vm.wallets.count == 1 ? "" : "s")", oneWallet: false, open: open) { EmptyView() }
    }
}

/// Network filter for Tokens and Activity: a native menu, not a second tab row.
struct ChainFilter: View {
    @Binding var chain: Chain?
    var chains: [Chain] = Chain.all
    var body: some View {
        Menu {
            Picker("Network", selection: $chain) {
                Text("All networks").tag(Chain?.none)
                Divider()
                ForEach(chains) { c in Text(c.name).tag(Optional(c)) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let chain { LogoMark(chain.logo, size: 16) } else { ChainStack(chains: Array(Chain.mainnets.prefix(4)), size: 14) }
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
    @State private var chain: Chain?

    var body: some View {
        let groups = vm.tokenGroups(wallet: walletID, chain: chain)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(groups.count) token\(groups.count == 1 ? "" : "s") on \(chain?.name ?? "\(Set(groups.flatMap(\.chains)).count) networks")")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                ChainFilter(chain: $chain)
            }
            if groups.isEmpty {
                EmptyNote(text: !vm.loaded ? "Loading balances…"
                          : "No tokens on \(chain?.name ?? "any network") yet. Deposit to your address to get started; on testnets, use a faucet.")
            }
            RowList(items: groups) { g in
                Button { open(.token(g)) } label: {
                    HStack(spacing: 12) {
                        TokenLogo(symbol: g.symbol, chain: g.chains.count == 1 ? g.chains[0] : nil, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(g.symbol).font(.system(size: 14, weight: .medium))
                                if g.testnet { PillTag(text: "Testnet", color: Theme.muted) }
                            }
                            HStack(spacing: 6) {
                                Text(MoneyFmt.amount(g.amount)).monospacedDigit()
                                if g.chains.count > 1 { ChainStack(chains: g.chains, size: 13) }
                                else if let c = g.chains.first { Text(c.name) }
                            }
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            if g.priced {
                                Text(MoneyFmt.usd(g.usd, digits: g.usd < 10 ? 2 : 0)).font(.system(size: 14)).monospacedDigit()
                                if let ch = g.change {
                                    Text(MoneyFmt.pct(ch)).font(.system(size: 12.5)).monospacedDigit()
                                        .foregroundStyle(ch > 0 ? Theme.green : ch < 0 ? Theme.red : Theme.muted)
                                }
                            } else {
                                Text(g.testnet ? "No value" : "No price").font(.system(size: 13)).foregroundStyle(Theme.faint)
                            }
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

/// DeFi positions aren't tracked yet: say so instead of showing made-up ones.
struct DAppsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmptyNote(text: "DeFi positions (lending, perps, vaults) aren't tracked yet.")
            Button("Connect a DApp") {}.buttonStyle(OutlineButton()).notYet("Connecting apps is coming soon")
        }
    }
}

/// Gas is the native coin on each network, read from the chain.
struct GasList: View {
    let vm: WalletsViewModel
    let walletID: String?
    @State private var testnets = false

    var body: some View {
        let tanks = vm.gas(wallet: walletID).filter { $0.chain.isTestnet == testnets }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gas by network", systemImage: "fuelpump").font(.system(size: 13.5, weight: .medium))
                Spacer()
                Segmented(options: [(false, "Mainnets"), (true, "Testnets")], selection: $testnets)
            }
            RowList(items: tanks) { g in gasRow(g) }
            Text("To refill, send the network's coin to your address from Add funds.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(.top, 6)
        }
    }

    private func gasRow(_ g: GasTank) -> some View {
        HStack(spacing: 12) {
            LogoMark(g.chain.logo, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.chain.name).font(.system(size: 14, weight: .medium))
                Text(g.low ? "Empty: sends on \(g.chain.name) need \(g.chain.nativeSymbol) for fees" : "\(MoneyFmt.amount(g.amount)) \(g.chain.nativeSymbol)")
                    .font(.system(size: 12.5)).foregroundStyle(g.low ? Theme.amber : Theme.muted).monospacedDigit().lineLimit(1)
            }
            Spacer()
            Text(g.usd.map { MoneyFmt.usd($0, digits: 2) } ?? (g.chain.isTestnet ? "Testnet" : "—"))
                .font(.system(size: 13)).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .padding(.vertical, 11)
    }

    private func gasButton(_ symbol: String, label: String) -> some View {
        Button {} label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 34, height: 34).background(Theme.hover, in: Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

struct ActivityList: View {
    let vm: WalletsViewModel
    let walletID: String?
    let open: (WalletSheet) -> Void
    @State private var chain: Chain?

    var body: some View {
        let items = vm.activity(wallet: walletID, chain: chain)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(items.count) send\(items.count == 1 ? "" : "s") from this device").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                ChainFilter(chain: $chain)
            }
            if items.isEmpty { EmptyNote(text: "Nothing sent from Hermit\(chain.map { " on \($0.name)" } ?? "") yet.") }
            RowList(items: items) { a in ActivityRow(item: a, wallet: walletID == nil ? vm.wallet(a.walletID)?.name : nil) { open(.activity(a)) } }
            ExplorerLinks(vm: vm, walletID: walletID, chain: chain)
        }
        .animation(.smooth(duration: 0.25), value: chain)
    }
}

/// Incoming transfers and older history live on the block explorers; one tap opens your address there.
struct ExplorerLinks: View {
    @Environment(\.openURL) private var openURL
    let vm: WalletsViewModel
    let walletID: String?
    var chain: Chain?
    var body: some View {
        if let w = vm.wallet(walletID) ?? vm.wallets.first {
            let chains = chain.map { [$0] } ?? [Chain.ethereum, .base, .solana]
            VStack(alignment: .leading, spacing: 6) {
                Text("Received transfers and older history are on the explorer\(walletID == nil && vm.wallets.count > 1 ? " (\(w.name))" : ""):")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                WrapRow {
                    ForEach(chains) { c in
                        if let a = w.address(on: c), let url = c.explorerURL(address: a) {
                            SelectChip(title: c.name, logo: c.logo, on: false) { openURL(url) }
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    var wallet: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 32, height: 32).background(Theme.hover, in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        LogoMark(item.chain.logo, size: 14).padding(1).background(Theme.bg, in: Circle()).offset(x: 3, y: 3)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.what).font(.system(size: 14)).lineLimit(1)
                    Text([item.when, item.chain.name, wallet].compactMap { $0 }.joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(item.amountText).font(.system(size: 14)).monospacedDigit().lineLimit(1)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Linked social accounts aren't connected to anything yet.
struct AccountsList: View {
    static let apps = [("X", "Quests and posts"), ("Discord", "Airdrop roles"), ("Telegram", "Alerts and alpha groups")]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.apps, id: \.0) { a in
                HStack(spacing: 12) {
                    LogoMark(a.0, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.0).font(.system(size: 14, weight: .medium))
                        Text(a.1).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Connect") {}.buttonStyle(BlackButton()).notYet("Linking accounts isn't available yet")
                }
                .padding(.vertical, 11)
                Hairline()
            }
            Text("Linking social accounts to wallets is coming later.").font(.system(size: 12.5)).foregroundStyle(Theme.faint).padding(.top, 6)
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
    let remove: () -> Void
    @State private var tab = "tokens"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !wallet.backedUp {
                Button { open(.phrase(wallet.id)) } label: {
                    Label("This wallet's recovery phrase isn't backed up. Back it up now.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Theme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).padding(.bottom, 14)
            }
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 14) { header; NetworksCard(vm: vm, wallet: wallet) }
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 14) { header; NetworksCard(vm: vm, wallet: wallet) }
                }
            }
            manage.padding(.top, 14)
            PageTabs(tabs: [("tokens", "Tokens"), ("gas", "Gas"), ("activity", "Activity"), ("security", "Security")], selection: $tab)
                .padding(.top, 20)
            Group {
                switch tab {
                case "tokens": TokensList(vm: vm, walletID: wallet.id, open: open)
                case "gas": GasList(vm: vm, walletID: wallet.id)
                case "security": security
                default: ActivityList(vm: vm, walletID: wallet.id, open: open)
                }
            }
            .padding(.top, 14)
            .id(tab)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.22), value: tab)
    }

    /// The wallet's own actions, in plain sight: back up its words, or remove it from this phone.
    private var manage: some View {
        HStack(spacing: 8) {
            Button { open(.phrase(wallet.id)) } label: {
                Label(wallet.backedUp ? "Recovery phrase" : "Back up words", systemImage: "key")
            }
            .buttonStyle(OutlineButton())
            Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
                .buttonStyle(DangerOutlineButton())
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        BalanceCard(vm: vm, label: "\(wallet.name), \(wallet.source.lowercased())", oneWallet: true, open: open, walletID: wallet.id) {
            VStack(alignment: .leading, spacing: 4) {
                if let a = wallet.evmAddress { addressLine(a, chains: Chain.evmMainnets, name: "EVM") }
                if let a = wallet.solanaAddress { addressLine(a, chains: [.solana], name: "Solana") }
            }
            .padding(.top, 4)
        }
    }

    private func addressLine(_ a: String, chains: [Chain], name: String) -> some View {
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

    private var security: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailLines(lines: [("Keys", "Made and kept on this device"), ("Recovery phrase", "\(wallet.record.wordCount) words, \(wallet.backedUp ? "backed up" : "not backed up")"),
                                ("Created", wallet.record.created.formatted(date: .abbreviated, time: .omitted)),
                                ("EVM path", KeyVault.evmPath), ("Solana path", KeyVault.solanaPath)],
                        monoKeys: ["EVM path", "Solana path"])
            ButtonPair {
                Button("Show recovery phrase") { open(.phrase(wallet.id)) }.buttonStyle(WideButton())
            } second: {
                Button("Remove from this phone", role: .destructive, action: remove).buttonStyle(DangerWideButton())
            }
            NoteBox(symbol: "lock.shield", text: "Every send and every look at your words asks for Face ID, Touch ID or your passcode.")
        }
    }
}

/// Red outline button for removing things.
struct DangerOutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.red.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.red.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct DangerWideButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.red)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(Theme.red.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.red.opacity(0.35)))
            .contentShape(Rectangle())
    }
}

/// One confirmation for removing a wallet, wherever it's asked from. Says what's on it and whether its words are backed up.
struct RemoveWalletDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    let vm: WalletsViewModel
    @Binding var wallet: WalletAccount?
    func body(content: Content) -> some View {
        content.confirmationDialog("Remove \(wallet?.name ?? "wallet") from this phone?",
                                   isPresented: Binding(get: { wallet != nil }, set: { if !$0 { wallet = nil } }),
                                   titleVisibility: .visible, presenting: wallet) { w in
            Button("Remove \(w.name)", role: .destructive) {
                do { try vm.deleteWallet(w.id); model.toast("\(w.name) removed") } catch { model.toast(error.localizedDescription) }
            }
            if !w.backedUp { Button("Back up words first") { wallet = nil; model.open(.wallets, tab: w.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { w in
            let usd = vm.total(w.id)
            let money = usd > 0.01 ? "It holds \(MoneyFmt.usd(usd, digits: 2)). " : ""
            Text(money + (w.backedUp
                ? "Its keys are deleted from this phone. You can restore it any time with its recovery phrase."
                : "Its words aren't backed up: once removed, this wallet and anything on it can't be recovered."))
        }
    }
}

/// Where one wallet's money sits, by network (mainnet dollars).
struct NetworksCard: View {
    let vm: WalletsViewModel
    let wallet: WalletAccount
    var body: some View {
        let rows = Chain.mainnets.map { c in (c, vm.holdings(wallet: wallet.id, chain: c).reduce(0) { $0 + $1.usd }) }.sorted { $0.1 > $1.1 }
        let total = max(rows.reduce(0) { $0 + $1.1 }, 0.01)
        VStack(alignment: .leading, spacing: 12) {
            Text("Networks").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            ForEach(rows, id: \.0) { r in
                HStack(spacing: 10) {
                    LogoMark(r.0.logo, size: 20)
                    Text(r.0.name).font(.system(size: 13)).lineLimit(1).fixedSize().frame(minWidth: 96, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hover)
                            Capsule().fill(Theme.text).frame(width: max(r.1 > 0 ? 3 : 0, g.size.width * r.1 / total))
                        }
                    }
                    .frame(height: 4)
                    Text(vm.unreachable.contains(r.0) ? "—" : MoneyFmt.usd(r.1, digits: r.1 > 0 && r.1 < 10 ? 2 : 0))
                        .font(.system(size: 12.5)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}
