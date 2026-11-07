import SwiftUI

/// Expandable opportunity row: tap for the pool's real history and stats, then ask Hermit about it.
/// Aave v3 pools on Ethereum, Base and Arbitrum get Deposit; every pool gets Ask.
struct EarnPoolRow: View {
    let pool: EarnData.Pool
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var width: CGFloat = 800

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.32)) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    MarketLogo(key: pool.logo, name: pool.name, remote: MarketLogo.protocolIcon(pool.project))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pool.name) \(pool.symbol)").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(pool.chainName), \(pool.tvlUsd.tradeCompactUSD) TVL" + (pool.poolMeta.map { ", \($0)" } ?? ""))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(EarnPoolRow.pct(pool.apy)).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(TradeRowButton())
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                EarnPoolDetail(pool: pool)
                    .padding(.leading, width >= 600 ? 44 : 0)
                    .padding(.top, 2).padding(.bottom, 18)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .clipped()
        .tradeWidth($width)
    }

    /// "5.12%"; tiny rates keep two decimals, big ones one.
    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(v >= 10 ? 1 : 2))) + "%"
    }
}

/// The expanded part: 90 days of APY from DefiLlama, the pool's own numbers, Deposit (greyed) and Ask.
struct EarnPoolDetail: View {
    let pool: EarnData.Pool
    @Environment(AppModel.self) private var model
    @State private var failed = false
    private var feed: YieldsFeed { .shared }

    var body: some View {
        let h = feed.history[pool.pool]
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("APY, last 90 days").foregroundStyle(Theme.muted)
                Spacer()
                if let h, !h.isEmpty { Text("Avg \(EarnPoolRow.pct(h.map(\.apy).reduce(0, +) / Double(h.count)))").monospacedDigit() }
            }
            .font(.system(size: 12.5)).padding(.bottom, 6)
            Group {
                if let h, h.count > 1 {
                    LineChart(values: h.map(\.apy), color: Theme.text)
                } else if failed {
                    MarketStatus(kind: .failed("Couldn't load history")) { failed = false; Task { await load() } }
                } else {
                    MarketStatus(kind: SnapshotMode.active ? .empty("History loads from DefiLlama") : .loading("Loading history"))
                }
            }
            .frame(height: 80)
            TradeKV(pairs: [("Base APY", EarnPoolRow.pct(pool.apyBase)), ("Rewards APY", EarnPoolRow.pct(pool.apyReward)),
                            ("30-day mean", EarnPoolRow.pct(pool.apyMean30d)), ("TVL", pool.tvlUsd.tradeCompactUSD),
                            ("Chain", pool.chainName), ("Asset", pool.stablecoin ? "Stablecoin" : pool.symbol)])
                .padding(.top, 14)
            HStack(spacing: 8) {
                if EarnRoute.aave(pool) != nil {
                    Button("Deposit") { EarnFlow.shared.deposit = pool }.buttonStyle(TradeSmallButton(kind: .primary))
                }
                Button { model.send("Is \(pool.name) \(pool.symbol) on \(pool.chainName) at \(EarnPoolRow.pct(pool.apy)) APY a good place for my money? What are the risks?") } label: {
                    Label("Ask", systemImage: "sparkles")
                }
                .buttonStyle(TradeSmallButton(kind: .brand))
            }
            .padding(.top, 14)
            MarketSource(text: "Data from DefiLlama. Yields change; past APY isn't a promise.").padding(.top, 10)
        }
        .task { await load() }
    }

    private func load() async {
        if !(await feed.loadHistory(pool.pool)) && !SnapshotMode.active { failed = true }
    }
}
