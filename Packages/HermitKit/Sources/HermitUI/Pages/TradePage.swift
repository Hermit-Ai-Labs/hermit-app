import SwiftUI
import HermitCore

/// Trade: open positions, the market terminal (perps, spot, memes, predictions) and running strategies.
struct TradePage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "positions"
    private var store: TradeEarnStore { .shared }
    static let tabs = [("positions", "Positions"), ("markets", "Markets"), ("strategies", "Strategies")]

    var body: some View {
        Page(title: "Trade", tabs: Self.tabs, tab: $tab) {
            HStack(spacing: 5) {
                Text("$" + TradeData.balance.tradeGrouped()).foregroundStyle(Theme.muted)
                Text("+$740").foregroundStyle(Theme.green)
            }
            .font(.system(size: 14)).monospacedDigit()
        } content: { t in
            switch t {
            case "markets": TradeMarkets()
            case "strategies": TradeStrategies()
            default: TradePositions()
            }
        }
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
        .onChange(of: model.approval == nil) { _, closed in if closed { store.approvalClosed(model) } }
    }
}

// MARK: Positions

struct TradePositions: View {
    @Environment(AppModel.self) private var model
    private var store: TradeEarnStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeStats(items: [("Trading balance", "$14,010", Theme.text), ("Unrealized", "+$740", Theme.green),
                               ("Today", "+$126", Theme.green), ("Margin used", "38%", Theme.text)])
            TradeSection(title: "Open positions") {
                TradeRows(data: store.positions) { p in positionRow(p) }
            }
            TradeSection(title: "Open orders") {
                if store.orders.isEmpty {
                    Text("No open orders").font(.system(size: 13.5)).foregroundStyle(Theme.faint).padding(.vertical, 12)
                }
                TradeRows(data: store.orders) { o in
                    HStack(spacing: 12) {
                        LogoMark(o.sym, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.what).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text("\(o.by) on \(o.when)").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Text(o.px).font(.system(size: 14)).monospacedDigit()
                        Button("Cancel") {
                            store.approve(model, Approval(kind: "Cancel order", title: o.what, lines: [["Price", o.px]], checks: tradeChecks(), success: "Order cancelled")) {
                                store.orders.removeAll { $0.id == o.id }
                            }
                        }
                        .buttonStyle(TradeSmallButton())
                    }
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            TradeSection(title: "History") {
                TradeRows(data: TradeData.fills) { f in
                    HStack(spacing: 12) {
                        LogoMark(f.sym, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.what).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(f.when).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(f.px).font(.system(size: 14)).monospacedDigit()
                            if let pnl = f.pnl { Text(pnl.tradeUSD).font(.system(size: 12.5)).foregroundStyle(pnl >= 0 ? Theme.green : Theme.red) }
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func pct(_ v: Double, _ p: TradeData.Position) -> String {
        (v > p.mark ? "+" : "−") + String(format: "%.1f%%", abs((v - p.mark) / p.mark * 100))
    }
    private func px(_ v: Double) -> String { "$" + v.tradeTrim(2) }

    private func positionRow(_ p: TradeData.Position) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LogoMark(p.sym, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(p.title).font(.system(size: 14, weight: .medium))) \(Text(p.side).font(.system(size: 14)).foregroundStyle(Theme.muted))")
                    .lineLimit(1)
                Text("Entry \(px(p.entry))" + (p.liq.map { ", liq \(px($0))" } ?? ""))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit()
                Text("\(p.by) on \(p.when)").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                TradeFlow {
                    stopTag(p.tp.map { "TP \(px($0)) (\(pct($0, p)))" } ?? "No TP", fg: p.tp == nil ? Theme.faint : Theme.green,
                            bg: p.tp == nil ? Theme.hover : TradeColor.greenSoft)
                    stopTag(p.sl.map { "SL \(px($0)) (\(pct($0, p)))" } ?? "No SL", fg: p.sl == nil ? Theme.faint : Theme.red,
                            bg: p.sl == nil ? Theme.hover : TradeColor.redSoft)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(p.pnl.tradeUSD).font(.system(size: 14, weight: .medium)).monospacedDigit()
                    .foregroundStyle(p.pnl >= 0 ? Theme.green : Theme.red)
                Button("Edit") { editStops(p) }.buttonStyle(TradeSmallButton())
                    .disabled(p.sl == p.entry)
            }
        }
        .padding(.vertical, 12)
        .contextMenu {
            Button("Move stop to breakeven") { editStops(p) }
            Button("Ask Hermit about \(p.sym)") { model.send("How is my \(p.title) position looking?") }
        }
    }

    private func stopTag(_ s: String, fg: Color, bg: Color) -> some View {
        Text(s).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
            .contentTransition(.numericText())
    }

    private func editStops(_ p: TradeData.Position) {
        let a = Approval(kind: "Update orders", title: "Move \(p.title) stop to breakeven",
                         lines: [["Stop-loss", "\(p.sl.map(px) ?? "None") → \(px(p.entry))"], ["Take-profit", p.tp.map(px) ?? "None"], ["Type", "Reduce-only"]],
                         checks: tradeChecks(), success: "Stop updated",
                         receipt: .receipt(title: "\(p.title) stop at breakeven", rows: [["Stop-loss", px(p.entry)], ["Locked in", "No loss possible"]]))
        store.approve(model, a) {
            if let i = store.positions.firstIndex(where: { $0.id == p.id }) { store.positions[i].sl = p.entry }
        }
    }
}

// MARK: Strategies

struct TradeStrategies: View {
    @Environment(AppModel.self) private var model
    @State private var open: TradeData.Strategy?
    private var store: TradeEarnStore { .shared }

    var body: some View {
        TradeSection(title: "Running", top: 0) {
            Button { model.send("Set up a funding arb strategy") } label: {
                Label("New", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(TradeSmallButton())
        } content: {
            TradeRows(data: TradeData.strategies) { st in
                TradeStrategyRow(st: st, paused: store.paused.contains(st.id)) { open = st }
            }
        }
        .sheet(item: $open) { TradeStrategySheet(st: $0) }
    }
}

/// One strategy or bot: logo, name (paused), source, PnL over capital, chevron.
struct TradeStrategyRow: View {
    let st: TradeData.Strategy
    var paused = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LogoMark(st.sym, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(st.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text))\(Text(paused ? " (paused)" : "").font(.system(size: 14)).foregroundStyle(Theme.faint))")
                        .lineLimit(1)
                    Text(st.source).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(st.pnl.tradeUSD).font(.system(size: 14, weight: .medium)).foregroundStyle(st.pnl >= 0 ? Theme.green : Theme.red)
                    Text("$" + st.capital.tradeGrouped()).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                }
                .monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(TradeRowButton())
    }
}
