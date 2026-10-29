import SwiftUI
import HermitCore

// MARK: Positions

/// Everything already earning: DeFi deposits, arbitrage bots and airdrop farms.
struct EarnPositions: View {
    @Environment(AppModel.self) private var model
    @State private var open: TradeData.Strategy?
    private var store: TradeEarnStore { .shared }

    var body: some View {
        let ps = store.earnPositions
        let total = ps.reduce(0) { $0 + $1.usd }
        let apy = total > 0 ? ps.reduce(0) { $0 + $1.usd * $1.apy } / total : 0
        VStack(alignment: .leading, spacing: 0) {
            TradeStats(items: [("Earning", "$" + total.tradeGrouped(), Theme.text), ("APY", String(format: "%.1f%%", apy), Theme.green),
                               ("Per month", "$" + (total * apy / 1200).tradeGrouped(), Theme.text),
                               ("Earned (24h)", "+$" + (total * apy / 36500).tradeGrouped(2), Theme.green)])

            TradeSection(title: "DeFi") {
                if ps.isEmpty { Text("Nothing deposited").font(.system(size: 13.5)).foregroundStyle(Theme.faint).padding(.vertical, 12) }
                TradeRows(data: ps) { p in
                    HStack(spacing: 12) {
                        LogoMark(p.proto, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text("\(p.by) on \(p.when)").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("$" + p.usd.tradeGrouped()).font(.system(size: 14))
                            Text(p.apy.tradeTrim(1) + "%").font(.system(size: 12.5)).foregroundStyle(Theme.green)
                        }
                        .monospacedDigit()
                        Button("Withdraw") { withdraw(p) }.buttonStyle(TradeSmallButton())
                    }
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .contextMenu {
                        Button("Withdraw") { withdraw(p) }
                        Button("Ask Hermit about \(p.name)") { model.send("Is \(p.proto) \(p.name) still a good place for my money?") }
                    }
                }
            }

            TradeSection(title: "Arbitrage") {
                TradeRows(data: EarnData.arbStrategies) { st in
                    TradeStrategyRow(st: st, paused: store.paused.contains(st.id)) { open = st }
                }
            }

            TradeSection(title: "Airdrops") {
                TradeRows(data: EarnData.airdrops) { a in
                    Button { model.send("How is the \(a.name) airdrop farm going?") } label: {
                        HStack(spacing: 12) {
                            LogoMark(a.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                                Text("\(a.wallets) wallets, $\(a.funds.tradeGrouped()) in use").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                                EarnProgress(value: Double(a.done) / Double(a.total)).frame(maxWidth: 220).padding(.top, 8)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(a.done)/\(a.total)").font(.system(size: 14)).foregroundStyle(Theme.text)
                                Text("−$" + a.loss.tradeGrouped()).font(.system(size: 12.5)).foregroundStyle(Theme.red)
                            }
                            .monospacedDigit()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(TradeRowButton())
                }
            }
        }
        .sheet(item: $open) { TradeStrategySheet(st: $0) }
    }

    private func withdraw(_ p: EarnData.Position) {
        let a = Approval(kind: "Withdraw", title: "Withdraw from \(p.name)",
                         lines: [["From", "\(p.proto) \(p.name)"], ["Amount", "$" + p.usd.tradeGrouped()], ["To", "Main wallet"], ["Arrives", p.note ?? "Now"]],
                         checks: tradeChecks(), success: "Withdrawn to Main")
        store.approve(model, a) { store.earnPositions.removeAll { $0.id == p.id } }
    }
}

/// Thin progress bar (quests done).
struct EarnProgress: View {
    let value: Double
    var color: Color = Theme.text
    var body: some View {
        Capsule().fill(Theme.hover).frame(height: 5)
            .overlay(alignment: .leading) { Capsule().fill(color).scaleEffect(x: value, anchor: .leading) }
    }
}

// MARK: DeFi

struct EarnDeFi: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "All"
    private var store: TradeEarnStore { .shared }

    var body: some View {
        let f = EarnData.filters.first { $0.0 == filter }!.1
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: EarnData.filters.map { ($0.0, $0.0) }, selection: $filter).padding(.bottom, 12)
            TradeRows(data: EarnData.opps.filter(f)) { o in
                EarnOppRow(logo: o.proto, title: "\(o.proto) \(o.name)", isNew: o.isNew, metric: o.apy.tradeTrim(1) + "%",
                           detail: EarnData.details[o.name], action: "Deposit") {
                    Text("\(o.risk.rawValue) risk").foregroundStyle(o.risk.color)
                } onAction: { deposit(o) }
            }
            .animation(.smooth(duration: 0.3), value: filter)
        }
    }

    private func deposit(_ o: EarnData.Opp) {
        let asset = o.asset == "Basket" ? "USDC" : o.asset
        let a = Approval(kind: "Deposit", title: "Deposit into \(o.name)",
                         lines: [["Amount", "1,000 \(asset)"], ["APY", o.apy.tradeTrim(1) + "%"], ["Withdraw", EarnData.details[o.name]?.exit ?? "Anytime"]],
                         checks: tradeChecks(o.risk == .high ? ["Impermanent loss: LP can lose value versus holding"] : []),
                         success: "Earning \(o.apy.tradeTrim(1))%",
                         receipt: .receipt(title: "Deposited into \(o.proto) \(o.name)", rows: [["Amount", "1,000 \(asset)"], ["APY", o.apy.tradeTrim(1) + "%"]]))
        store.approve(model, a, toast: "Deposited. See Positions") {
            store.earnPositions.insert(EarnData.Position(proto: o.proto, name: o.name, usd: 1000, apy: o.apy, by: "You", when: "just now"), at: 0)
        }
    }
}

// MARK: Arbitrage

struct EarnArbitrage: View {
    @Environment(AppModel.self) private var model
    private var store: TradeEarnStore { .shared }

    var body: some View {
        let bots = EarnData.arbStrategies
        let capital = bots.reduce(0) { $0 + $1.capital }, pnl = bots.reduce(0) { $0 + $1.pnl }
        VStack(alignment: .leading, spacing: 0) {
            TradeStats(items: [("Deployed", "$" + capital.tradeGrouped(), Theme.text), ("Profit 30d", "+$" + pnl.tradeGrouped(), Theme.green),
                               ("Annualized", String(format: "%.1f%%", pnl / capital * 1200), Theme.green), ("Live spreads", "\(EarnData.arbOpps.count)", Theme.text)])
            TradeRows(data: EarnData.arbOpps) { o in
                EarnOppRow(logo: o.sym, title: o.name, metric: o.apr.tradeTrim(1) + "%", detail: EarnData.details[o.name], action: "Start") {
                    Text(o.note).foregroundStyle(Theme.muted)
                } onAction: {
                    let a = Approval(kind: "Start strategy", title: o.name,
                                     lines: [["Capital", "2,000 USDC"], ["Est. APR", o.apr.tradeTrim(1) + "%"], ["Exit", "Automatic when the spread closes"]],
                                     checks: tradeChecks(["Delta-neutral: price moves net to zero"]), success: "Strategy running")
                    store.approve(model, a, toast: "\(o.name) running")
                }
            }
            .padding(.top, 36)
        }
    }
}

// MARK: Airdrops

struct EarnAirdrops: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 900

    var body: some View {
        let ads = EarnData.airdrops
        VStack(alignment: .leading, spacing: 0) {
            TradeStats(items: [("Wallets running", "\(ads.reduce(0) { $0 + $1.wallets })", Theme.text),
                               ("Funds in use", "$" + ads.reduce(0) { $0 + $1.funds }.tradeGrouped(), Theme.text),
                               ("Current loss", "−$" + ads.reduce(0) { $0 + $1.loss }.tradeGrouped(), Theme.red),
                               ("Est. value", "$1.1k–3.3k", Theme.green)])
            TradeRows(data: EarnData.airdropOpps) { o in
                EarnOppRow(logo: o.logo, title: o.name, metric: o.est, detail: o.d, action: "Farm") {
                    Text(o.note).foregroundStyle(Theme.muted)
                } onAction: { model.toast("Farming \(o.name). Find it in Automations") }
            }
            .padding(.top, 36)

            TradeSection(title: "Hermit points") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: width >= 600 ? 3 : 1), spacing: 12) {
                    ForEach(EarnData.pointTasks, id: \.1) { icon, t, pts in
                        Button { model.toast("\(t): \(pts) pts") } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.text).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                                    Text("\(pts) pts").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(EarnCardButton())
                    }
                }
            }
        }
        .tradeWidth($width)
    }
}

/// White card that lifts a touch on hover.
struct EarnCardButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TradeHover { h in
            configuration.label
                .background(configuration.isPressed ? Theme.hover : h ? Theme.subtle : Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: Reverse

/// Paste any vault or wallet and Hermit explains where the yield comes from, then rebuilds it safer.
struct EarnReverse: View {
    @Environment(AppModel.self) private var model
    @State private var v = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Paste a vault or wallet. Hermit splits the yield by source, stress-tests it and rebuilds it with less risk.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                TradeField(placeholder: "Paste a vault or wallet address", text: $v, mono: !v.isEmpty)
                    .onSubmit { run(nil) }
                Button("Analyze") { run(nil) }.buttonStyle(TradeSmallButton(kind: .brand, height: 40))
            }
            TradeSection(title: "High-yield vaults to try") {
                TradeRows(data: EarnData.sampleVaults) { x in
                    Button { run(x.addr) } label: {
                        HStack(spacing: 12) {
                            LogoMark(x.proto, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(x.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                                Text(x.addr).font(.system(size: 12.5).monospaced()).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 8)
                            Text(x.apy).font(.system(size: 14)).monospacedDigit().foregroundStyle(Theme.green)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(TradeRowButton())
                }
            }
        }
    }

    private func run(_ addr: String?) {
        let a = addr ?? (v.trimmingCharacters(in: .whitespaces).isEmpty ? "0x9c4e…a71b" : v.trimmingCharacters(in: .whitespaces))
        model.send("Reverse engineer this 24% USDC vault: \(a)")
    }
}
