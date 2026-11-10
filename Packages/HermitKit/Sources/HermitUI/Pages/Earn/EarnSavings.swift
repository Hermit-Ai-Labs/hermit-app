import SwiftUI
import HermitWallet
import HermitCore

// MARK: Savings

/// The first thing Earn shows: dollars you can put to work right now, one row per Aave v3 pool Hermit can deposit into
/// (USDC and USDT on Ethereum, Base and Arbitrum), with Deposit on the row. Pools for tokens you already hold come first.
struct EarnSavings: View {
    @Environment(AppModel.self) private var model
    private var feed: YieldsFeed { .shared }
    private var vm: WalletsViewModel { .shared }

    /// What you hold of a pool's token on its network, across wallets.
    private func held(_ p: EarnData.Pool) -> Double {
        guard let r = EarnRoute.aave(p) else { return 0 }
        return vm.holdings(wallet: nil, chain: r.chain).filter { $0.symbol.caseInsensitiveCompare(r.token.symbol) == .orderedSame }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        let list = feed.pools.filter { EarnRoute.aave($0) != nil }
            .sorted { a, b in
                let (ha, hb) = (held(a) > 0, held(b) > 0)
                return ha != hb ? ha : a.apy > b.apy
            }
        VStack(alignment: .leading, spacing: 0) {
            Text("Lend your dollars on Aave and earn interest every second. Withdraw any time.")
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
        return HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo(p.symbol), name: p.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(p.symbol) on \(p.chainName)").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(h > 0 ? "Aave, you have \(h.tradeGrouped(2))" : "Aave")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(EarnPoolRow.pct(p.apy)).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.green)
                Text("a year").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .monospacedDigit()
            Button("Deposit") { EarnFlow.shared.deposit = p }.buttonStyle(TradeSmallButton(kind: .primary))
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
