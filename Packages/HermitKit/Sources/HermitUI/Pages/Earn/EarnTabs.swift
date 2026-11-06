import SwiftUI
import HermitCore

// MARK: Positions

/// Everything already earning. Deposits, carry bots and airdrop farms aren't wired up yet, so each section is empty.
struct EarnPositions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeSection(title: "DeFi", top: 0) {
                TradeEmpty(icon: "leaf", title: "Nothing deposited yet",
                           note: "Deposits open soon. Browse real yields in DeFi meanwhile.")
            }
            TradeSection(title: "Arbitrage") { MarketStatus(kind: .empty("No strategies running")) }
            TradeSection(title: "Airdrops") { MarketStatus(kind: .empty("No airdrop farms")) }
        }
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
                    if !compact { Button("Start") {}.buttonStyle(TradeSmallButton(kind: .primary)).disabled(true) }
                }
                .padding(.vertical, 12)
            }
            if !feed.perps.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        MarketSource(text: "Live funding from Hyperliquid, perps over $20M daily volume")
                        Spacer()
                        TradeSoon(text: "Strategies open soon").fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        MarketSource(text: "Live funding from Hyperliquid, perps over $20M daily volume")
                        TradeSoon(text: "Strategies open soon").fixedSize()
                    }
                }
                .padding(.top, 8)
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
