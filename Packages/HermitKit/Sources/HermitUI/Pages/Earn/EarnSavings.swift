import SwiftUI
import HermitWallet
import HermitCore

// MARK: Savings

/// The first thing Earn shows: dollars you can put to work right now. Aave v3 pools Hermit deposits into itself (USDC
/// and USDT on Base, Arbitrum and Ethereum) get Deposit on the row; the main Solana lenders (Kamino, Jupiter Lend) get
/// Open, which takes you to the app inside Hermit with your wallet connected. Tokens you already hold come first, then
/// the cheap networks, then the rest by rate.
struct EarnSavings: View {
    @Environment(AppModel.self) private var model
    private var feed: YieldsFeed { .shared }
    private var vm: WalletsViewModel { .shared }

    /// What you hold of a pool's token on its network, across wallets.
    private func held(_ p: EarnData.Pool) -> Double {
        guard let r = EarnRoute.aave(p) else { return 0 }
        return vm.holdings(wallet: nil, chain: r.chain).filter { $0.symbol.caseInsensitiveCompare(r.token.symbol) == .orderedSame }.reduce(0) { $0 + $1.amount }
    }

    /// Solana lending pools shown here (opened in the app, not deposited by Hermit).
    static let solanaLenders: [String: String] = ["kamino-lend": "Kamino", "jupiter-lend": "Jupiter Lend"]
    private func opensApp(_ p: EarnData.Pool) -> ExploreDapp? {
        guard p.chain == "Solana", let name = Self.solanaLenders[p.project], ["USDC", "USDT", "SOL"].contains(p.symbol.uppercased()) else { return nil }
        return ExploreData.dapps.first { $0.name == name }
    }
    /// 0 for the cheap networks (Base, Arbitrum, Solana), 1 for Ethereum (gas costs dollars).
    private func gasRank(_ p: EarnData.Pool) -> Int { p.chain == "Ethereum" ? 1 : 0 }

    /// Aave v3's main market on a network Hermit knows, even for a token it can't deposit itself (ETH, wBTC…): those
    /// open in Aave's app. Umbrella (slashable staking) and the Horizon RWA market aren't savings, so they stay in Explore.
    private func isAave(_ p: EarnData.Pool) -> Bool {
        p.isAaveMain && Chain.mainnets.contains { $0.id == p.chain.lowercased() && $0.kind == .evm }
    }

    /// The rate a row shows: for a pool Hermit deposits into, only what the deposit earns (rewards aren't collected);
    /// pools that open in their own app show their full rate, rewards included, since the app collects them.
    private func rate(_ p: EarnData.Pool) -> Double { EarnRoute.aave(p) != nil ? p.depositAPY : p.apy }

    var body: some View {
        let list = feed.pools.filter { EarnRoute.aave($0) != nil || isAave($0) || opensApp($0) != nil }
            .sorted { a, b in
                let (ha, hb) = (held(a) > 0, held(b) > 0)
                if ha != hb { return ha }
                if gasRank(a) != gasRank(b) { return gasRank(a) < gasRank(b) }
                return rate(a) > rate(b)
            }
        VStack(alignment: .leading, spacing: 0) {
            Text("Lend your dollars and earn interest every second. You can withdraw whenever the pool has spare cash, shown on each row as available. Base, Arbitrum and Solana cost cents; Ethereum costs dollars in gas.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            if feed.pools.isEmpty {
                switch feed.state {
                case .failed: MarketStatus(kind: .failed("Couldn't load rates")) { Task { await feed.refresh(force: true) } }
                default: MarketStatus(kind: .loading("Loading rates"))
                }
            } else if list.isEmpty {
                MarketStatus(kind: .empty("No savings pools right now"))
            }
            TradeRows(data: list) { p in row(p) }
            if !list.isEmpty {
                MarketSource(text: "Live rates from DefiLlama. Rates change; past rates aren't a promise.").padding(.top, 10)
            }
        }
        .marketPoll(every: 600) { await feed.refresh() }
    }

    private func row(_ p: EarnData.Pool) -> some View {
        let h = held(p)
        // DefiLlama's 30-day mean includes rewards, so it's left off a row whose rate leaves them out.
        let mean = EarnRoute.aave(p) != nil && (p.apyReward ?? 0) > 0 ? nil : p.apyMean30d
        return HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo(p.symbol), name: p.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.symbol) on \(p.chainName)").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                // For a lender DefiLlama's TVL is what's supplied minus what's borrowed: the cash there to withdraw.
                Text([h > 0 ? "\(p.name), you have \(h.tradeGrouped(2))" : p.name, "\(p.tvlUsd.tradeCompactUSD) available",
                      mean.map { "\(EarnPoolRow.pct($0)) 30-day avg" }].compactMap { $0 }.joined(separator: ", "))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(EarnPoolRow.pct(rate(p))).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.green)
                Text("a year").font(.system(size: 12)).foregroundStyle(Theme.hint)
            }
            .monospacedDigit()
            if EarnRoute.aave(p) != nil {
                Button("Deposit") { EarnFlow.shared.deposit = p }.buttonStyle(TradeSmallButton(kind: .primary))
            } else if let d = opensApp(p), let u = d.url {
                Button("Open") { DappBrowser.shared.open(u, dapp: d, model: model) }.buttonStyle(TradeSmallButton())
            } else if isAave(p), let u = EarnData.site(for: p.project) {
                Button("Open") { DappBrowser.shared.open(u, dapp: ExploreData.dapps.first { $0.name == "Aave" }, model: model) }.buttonStyle(TradeSmallButton())
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: Explore

/// Everything beyond savings, for people who want it: every big yield (to read about and ask Hermit), funding carry and
/// the vault explainer.
struct EarnExplore: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EarnDeFi()
            TradeSection(title: "Funding carry") { EarnArbitrage() }
            TradeSection(title: "Explain a vault") { EarnReverse() }
            TradeExploreMore(label: "opportunities", items: EarnData.catalog)
        }
    }
}
