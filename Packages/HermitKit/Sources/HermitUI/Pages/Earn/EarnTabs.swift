import SwiftUI
import HermitWallet
import HermitCore

// MARK: Positions

/// Everything already earning, read from chain for the first wallet: Aave v3 deposits (aToken balances, which grow with
/// interest) with Withdraw, and the Hyperliquid account. Nothing here is sample data.
struct EarnPositions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @State private var rows: [AaveRow] = []
    @State private var loaded = false
    @State private var error: String?
    private var vm: WalletsViewModel { .shared }
    private var hl: HyperliquidStore { .shared }

    struct AaveRow: Identifiable, Hashable {
        var id: String { chain.id + token.symbol }
        let chain: Chain, token: Token, amount: UInt128
        var text: String { Units.format(amount, decimals: token.decimals, maxFraction: 4) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeSection(title: "DeFi", top: 0) {
                if !vm.hasWallet {
                    TradeEmpty(icon: "leaf", title: "No wallet yet", note: "Create a wallet, then deposit into a pool from DeFi.")
                } else if !loaded {
                    MarketStatus(kind: .loading("Reading your deposits"))
                } else if rows.isEmpty {
                    TradeEmpty(icon: "leaf", title: "Nothing deposited yet", note: "Open a pool in DeFi and tap Deposit. It shows here, earning.")
                }
                ForEach(rows) { r in
                    HStack(spacing: 12) {
                        MarketLogo(key: TradeData.logo(r.token.symbol), name: r.token.symbol, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aave \(r.token.symbol)").font(.system(size: 14, weight: .medium))
                            Text(r.chain.name).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Text("\(r.text) \(r.token.symbol)").font(.system(size: 14, weight: .medium)).monospacedDigit()
                        Button("Withdraw") { withdraw(r) }.buttonStyle(TradeSmallButton())
                    }
                    .padding(.vertical, 11)
                }
            }
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
        .task(id: vm.firstWalletID) { await load(); await hl.refresh() }
    }

    private func load() async {
        guard let w = vm.wallets.first, let owner = EVMAddress(w.record.evmAddress) else { loaded = true; return }
        var out: [AaveRow] = []
        let jobs = Chain.mainnets.filter { AaveV3.pool(on: $0) != nil }.flatMap { c in
            c.tokens.filter { TokenTable.stableSymbols.contains($0.symbol) }.map { (c, $0, vm.service.evm(c)) }
        }
        await withTaskGroup(of: AaveRow?.self) { g in
            for (chain, token, client) in jobs {
                g.addTask {
                    guard let aToken = try? await AaveV3.aToken(chain: chain, token: token, client: client),
                          let bal = try? await client.tokenBalance(token: aToken, owner: owner), bal > 0 else { return nil }
                    return AaveRow(chain: chain, token: token, amount: bal)
                }
            }
            for await r in g { if let r { out.append(r) } }
        }
        rows = out.sorted { $0.chain.name < $1.chain.name }
        loaded = true
    }

    private func withdraw(_ r: AaveRow) {
        guard let w = vm.wallets.first, let owner = EVMAddress(w.record.evmAddress), let pool = AaveV3.pool(on: r.chain) else { return }
        let call = AaveV3.withdrawCall(token: r.token, amount: nil, owner: owner, pool: pool)
        let svc = vm.service, wid = w.record.id, chain = r.chain
        ask(Approval(kind: "Withdraw on \(r.chain.name)", title: "Withdraw \(r.text) \(r.token.symbol)",
                     lines: [["From", "Aave v3, \(r.chain.name)"], ["Amount", "All, about \(r.text) \(r.token.symbol)"], ["To", w.name]],
                     checks: ["Simulated before it's signed", "Signed on \(Device.here) with your wallet's key"],
                     success: "Withdrew \(r.token.symbol)") {
            try await svc.executeCalls(walletID: wid, chain: chain, [call]).last ?? ""
        }) { Task { await load(); await vm.refresh() } }
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
        let list = feed.pools.filter { f($0) && (chain == "All" || $0.chain == chain) }.prefix(40)
        VStack(alignment: .leading, spacing: 0) {
            TradeFlow(spacing: 10) {
                Segmented(options: EarnData.filters.map { ($0.0, $0.0) }, selection: $filter)
                Segmented(options: [("All", "All chains")] + EarnData.chains.map { ($0.llama, $0.name) }, selection: $chain)
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
                MarketSource(text: "Largest pools first, at least $10M deep. APY from DefiLlama, refreshed hourly.").padding(.top, 10)
            }
        }
        .marketPoll(every: 600) { await feed.refresh() }
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
                        Text("APR now").font(.system(size: 12)).foregroundStyle(Theme.faint)
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
