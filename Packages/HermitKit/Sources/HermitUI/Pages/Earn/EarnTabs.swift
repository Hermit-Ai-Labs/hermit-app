import SwiftUI
import HermitWallet
import HermitCore

// MARK: Positions

/// Everything already earning, read from chain for every wallet: Aave v3 supplies on Ethereum, Base and Arbitrum
/// (aToken balances, which grow with interest) with the live supply APY and Withdraw, NEAR staked with validators
/// (EarnStakedNear), and the Hyperliquid account.
/// Nothing here is sample data.
struct EarnPositions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @State private var rows: [AavePosition] = []
    @State private var failed: [Chain] = []
    @State private var loaded = false
    /// When the rows on screen were saved, while they're last time's copy and the chain hasn't answered yet.
    @State private var savedAt: Date?
    @State private var error: String?
    private var vm: WalletsViewModel { .shared }
    private var hl: HyperliquidStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeSection(title: "Aave", top: 0) {
                if !vm.hasWallet {
                    TradeEmpty(icon: "leaf", title: "No wallet yet", note: "Create a wallet, then deposit from Savings.")
                } else if !loaded && rows.isEmpty {
                    MarketStatus(kind: .loading("Reading your deposits"))
                } else if rows.isEmpty && failed.isEmpty {
                    TradeEmpty(icon: "leaf", title: "Nothing deposited yet", note: "Tap Deposit on a pool in Savings, or ask Hermit to deposit. It shows here, earning.")
                }
                ForEach(rows) { r in
                    HStack(spacing: 12) {
                        MarketLogo(key: TradeData.logo(r.token.symbol), name: r.token.symbol, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aave \(r.token.symbol)").font(.system(size: 14, weight: .medium))
                            Text([r.chain.name, vm.wallets.count > 1 ? vm.wallet(r.walletID.uuidString)?.name : nil].compactMap { $0 }.joined(separator: ", "))
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(r.text) \(r.token.symbol)").font(.system(size: 14, weight: .medium)).monospacedDigit()
                            Text(r.supplyAPY.map { String(format: "%.2f%% APY", $0 * 100) } ?? "APY unknown")
                                .font(.system(size: 12.5)).foregroundStyle(r.supplyAPY == nil ? Theme.faint : Theme.green).monospacedDigit()
                        }
                        // Only once the chain has answered: never a withdrawal from a saved copy.
                        Button("Withdraw") { withdraw(r) }.buttonStyle(TradeSmallButton()).disabled(!loaded)
                    }
                    .padding(.vertical, 11)
                }
                if loaded && !failed.isEmpty {
                    MarketStatus(kind: .failed("Couldn't reach \(failed.map(\.name).joined(separator: ", ")), so deposits there aren't shown")) {
                        Task { await load() }
                    }
                }
                if loaded && !rows.isEmpty {
                    MarketSource(text: "Supplied amounts include interest so far. APY is Aave's live supply rate, read from the pool contract.").padding(.top, 6)
                } else if !loaded, let savedAt {
                    MarketSource(text: "Read \(Freshness.ago(savedAt)). Updating…").padding(.top, 6)
                }
            }
            EarnStakedNear()
            TradeSection(title: "Hyperliquid") {
                if let a = hl.account, a.accountValue > 0 {
                    HStack {
                        Text("Account value").foregroundStyle(Theme.muted)
                        Spacer()
                        Text("$" + a.accountValue.tradeGrouped(2)).monospacedDigit()
                        Button("Open") { model.open(.trade, tab: "positions") }.buttonStyle(TradeSmallButton())
                    }
                    .font(.system(size: 14)).padding(.vertical, 11)
                } else {
                    MarketStatus(kind: .empty("No funds on Hyperliquid"))
                }
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).padding(.top, 10) }
        }
        .task(id: vm.wallets.map(\.id)) {
            restoreSaved()
            // Aave and Hyperliquid at once; neither waits for the other.
            let store = hl
            async let h: () = store.refresh()
            await load()
            _ = await h
        }
        .onChange(of: model.approvalCount) { _, _ in Task { await load() } }
    }

    private func load() async {
        guard vm.hasWallet else { rows = []; loaded = true; return }
        let r = await vm.service.aavePositions(wallets: vm.wallets.map(\.record))
        withAnimation(.smooth) { rows = r.positions; failed = r.failed; loaded = true; savedAt = nil }
        // Saved only when every network answered, so a saved copy never misses a deposit.
        guard r.failed.isEmpty else { return }
        for w in vm.wallets {
            let mine = r.positions.filter { $0.walletID == w.record.id }.map { SavedAave($0) }
            SnapshotStore.live.save(mine, "aave", wallet: w.id)
        }
    }

    /// Last time's deposits, shown while the chain is read again (Withdraw waits for the live read).
    private func restoreSaved() {
        guard !loaded, rows.isEmpty else { return }
        var out: [AavePosition] = [], oldest: Date?
        for w in vm.wallets {
            guard let s = SnapshotStore.live.load("aave", wallet: w.id, as: [SavedAave].self, maxAge: 30 * 86_400) else { return }
            out += s.value.compactMap { $0.position(wallet: w.record.id) }
            oldest = min(oldest ?? s.saved, s.saved)
        }
        guard let oldest, !out.isEmpty else { return }
        rows = out; savedAt = oldest
    }

    private func withdraw(_ r: AavePosition) {
        do {
            ask(try HermitToolbox.withdrawApproval(r, amount: nil)) { Task { await load(); await vm.refresh() } }
        } catch {
            self.error = (error as? WalletError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// One Aave deposit as saved on this device: which token, where, and how much.
private struct SavedAave: Codable, Sendable {
    let chain, symbol, amount: String
    let apy: Double?

    init(_ p: AavePosition) { chain = p.chain.id; symbol = p.token.symbol; amount = String(p.amount); apy = p.supplyAPY }

    func position(wallet: UUID) -> AavePosition? {
        guard let c = Chain.with(id: chain), let t = AaveV3.tokens(on: c).first(where: { $0.symbol == symbol }),
              let a = UInt128(amount) else { return nil }
        return AavePosition(walletID: wallet, chain: c, token: t, amount: a, supplyAPY: apy)
    }
}

// MARK: DeFi

/// Real pools from DefiLlama: stablecoins and majors on Ethereum, Base, Arbitrum, BNB Chain and Solana.
struct EarnDeFi: View {
    @State private var filter = "All"
    @State private var chain = "All"
    private var feed: YieldsFeed { .shared }

    var body: some View {
        let f: (EarnData.Pool) -> Bool = EarnData.filters.first { $0.0 == filter }?.1 ?? { _ in true }
        let list = feed.pools.filter { f($0) && (chain == "All" || $0.chain == chain) }.prefix(30)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Segmented(options: EarnData.filters.map { ($0.0, $0.0) }, selection: $filter)
                Spacer(minLength: 0)
                NetworkMenu(selection: $chain)
            }
            .padding(.bottom, 12)
            if feed.pools.isEmpty {
                switch feed.state {
                case .failed: MarketStatus(kind: .failed("Couldn't reach DefiLlama")) { Task { await feed.refresh(force: true) } }
                default: MarketStatus(kind: .loading("Loading yields from DefiLlama"))
                }
            } else if list.isEmpty {
                MarketStatus(kind: .empty("No pools match"))
            }
            TradeRows(data: Array(list)) { EarnPoolRow(pool: $0) }
                .animation(.smooth(duration: 0.3), value: filter)
                .animation(.smooth(duration: 0.3), value: chain)
            if !feed.pools.isEmpty {
                MarketSource(text: "Largest pools first, at least $10M deep ($1M for Aave pools Hermit deposits into). APY from DefiLlama, refreshed hourly." + feed.ageNote).padding(.top, 10)
            }
        }
        .marketPoll(every: 600) { await feed.refresh() }
    }
}

/// One "All networks" button that opens a menu of networks, instead of a second row of pills.
struct NetworkMenu: View {
    @Binding var selection: String
    var body: some View {
        Menu {
            Picker("Network", selection: $selection) {
                Text("All networks").tag("All")
                ForEach(EarnData.chains, id: \.llama) { Text($0.name).tag($0.llama) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(selection == "All" ? "All networks" : EarnData.chainName(selection))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 9))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: Arbitrage

/// Cash and carry, live: long spot and short the perp to collect funding. Rates are Hyperliquid's current hourly funding,
/// annualized, so they move every hour. Starting a bot isn't wired up yet.
struct EarnArbitrage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    private var feed: MarketFeed { .shared }

    var body: some View {
        let list = feed.perps.values.filter { $0.vol >= 20_000_000 && !$0.coin.hasPrefix("xyz:") }
            .sorted { abs($0.fundAPR) > abs($1.fundAPR) }.prefix(8)
        VStack(alignment: .leading, spacing: 0) {
            Text("Hold the coin and short its perp: price moves cancel out and you collect funding while it stays positive. When it's negative, the trade flips.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            if feed.perps.isEmpty {
                MarketStatus(kind: feed.perpState == .failed ? .failed("Couldn't reach Hyperliquid") : .loading("Loading funding rates")) {
                    Task { await feed.refreshPerps() }
                }
            }
            TradeRows(data: Array(list)) { p in
                HStack(spacing: 12) {
                    MarketLogo(key: TradeData.logo(p.sym), name: p.sym)
                    VStack(alignment: .leading, spacing: 2) {
                        if compact {
                            // Phone: the coin, then the trade and its funding in a few words.
                            Text(p.sym).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(p.funding >= 0 ? "Cash and carry" : "Reverse carry"), \(p.fundPct.tradeTrim(4))%/h")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
                        } else {
                            Text("\(p.sym) \(p.funding >= 0 ? "cash and carry" : "reverse carry")").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("Funding \(p.fundPct.tradeTrim(4))% an hour, \(p.vol.tradeCompactUSD) volume").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(EarnPoolRow.pct(abs(p.fundAPR))).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        Text("APR now").font(.system(size: 12)).foregroundStyle(Theme.hint)
                    }
                    .monospacedDigit()
                    Button("Ask") { model.send("Walk me through a \(p.sym) funding carry trade. Hyperliquid funding is \(p.fundPct.tradeTrim(4))% an hour right now.") }
                        .buttonStyle(TradeSmallButton())
                }
                .padding(.vertical, 12)
            }
            if !feed.perps.isEmpty {
                MarketSource(text: "Live funding from Hyperliquid, perps over $20M daily volume").padding(.top, 8)
            }
        }
        .marketPoll(every: 30) { await feed.refreshPerps() }
    }
}

// MARK: Airdrops

/// No farms run yet. Hermit can still talk through what's worth farming.
struct EarnAirdrops: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TradeSection(title: "Your farms", top: 0) {
            Button { model.send("Which airdrops are worth farming right now, and what does each one take?") } label: {
                Label("Ask Hermit", systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(TradeSmallButton())
        } content: {
            TradeEmpty(icon: "parachute", title: "No airdrop farms yet",
                       note: "Airdrop farming opens soon. Hermit will run the tasks from your wallets and track points here.")
        }
    }
}

// MARK: Reverse

/// Paste any vault or wallet and Hermit explains, in chat, where the yield comes from.
struct EarnReverse: View {
    @Environment(AppModel.self) private var model
    @State private var v = ""
    private var addr: String { v.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Paste a vault or wallet. Hermit splits the yield by source, stress-tests it and suggests a safer way to get it.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                TradeField(placeholder: "Paste a vault or wallet address", text: $v, mono: !v.isEmpty)
                    .onSubmit(run)
                Button("Analyze", action: run).buttonStyle(TradeSmallButton(kind: .brand, height: 40)).disabled(addr.isEmpty)
            }
        }
    }

    private func run() {
        guard !addr.isEmpty else { return }
        model.send("Reverse engineer this vault: where does its yield come from, and what are the risks? \(addr)")
    }
}
