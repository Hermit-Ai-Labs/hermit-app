import SwiftUI
import HermitWallet
import HermitCore

/// Trade: your positions, the live market terminal (perps, spot, memes) and strategies.
/// Prices are live; orders are signed on this phone and sent to Hyperliquid.
struct TradePage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "markets"
    static let tabs = [("markets", "Markets"), ("positions", "Positions")]

    var body: some View {
        Page(title: "Trade", tabs: Self.tabs, tab: $tab) { t in
            switch t {
            case "markets": TradeMarkets()
            case "strategies": TradeStrategies()
            default: TradePositions()
            }
        }
        .approvalHost(sheetOpen: false) {}
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
    }
}

// MARK: Positions

/// Live from Hyperliquid for the trading wallet: margin, open positions with PnL (Close signs a reduce-only market order),
/// and resting orders (Cancel). Everything is read by address; closing and cancelling ask for Face ID.
struct TradePositions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @State private var error: String?
    private var hl: HyperliquidStore { .shared }
    private var feed: MarketFeed { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hl.hasWallet {
                TradeEmpty(icon: "wallet.bifold", title: "No wallet yet", note: "Create a wallet to trade on Hyperliquid. Keys stay on this phone.")
                Button("Create a wallet") { model.open(.wallets, tab: "create") }.buttonStyle(TradeSmallButton(kind: .primary)).padding(.top, 12)
            } else {
                summary
                TradeSection(title: "Open positions") {
                    let list = hl.account?.positions ?? []
                    if list.isEmpty {
                        if hl.state == .failed { MarketStatus(kind: .failed("Couldn't reach Hyperliquid")) { Task { await hl.refresh() } } }
                        else if hl.account == nil { MarketStatus(kind: .loading("Loading your account")) }
                        else { TradeEmpty(icon: "chart.line.uptrend.xyaxis", title: "No positions", note: "Open one from Markets. It shows here with live PnL.") }
                    }
                    ForEach(list) { p in positionRow(p) }
                }
                TradeSection(title: "Open orders") {
                    let orders = hl.account?.orders ?? []
                    if orders.isEmpty { MarketStatus(kind: .empty("No open orders")) }
                    ForEach(orders) { o in orderRow(o) }
                }
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).padding(.top, 10) }
            }
        }
        .task(id: hl.address) {
            while !Task.isCancelled {
                await hl.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var summary: some View {
        let a = hl.account
        return VStack(alignment: .leading, spacing: 12) {
            TradeStats(items: [
                ("Account value", a.map { "$" + $0.accountValue.tradeGrouped(2) } ?? "—", Theme.text),
                ("Available", a.map { "$" + $0.withdrawable.tradeGrouped(2) } ?? "—", Theme.text),
                ("Unrealized PnL", a.map { pnl($0.positions.reduce(0) { $0 + $1.pnl }) } ?? "—",
                 (a?.positions.reduce(0) { $0 + $1.pnl } ?? 0) >= 0 ? Theme.green : Theme.red),
            ])
            HStack(spacing: 8) {
                Button("Deposit") { hl.openDeposit(model) }.buttonStyle(TradeSmallButton(kind: .primary))
                if let addr = hl.address, let url = URL(string: "https://app.hyperliquid.xyz/explorer/address/\(addr)") {
                    Link(destination: url) { Label("Explorer", systemImage: "arrow.up.right") }.buttonStyle(TradeSmallButton())
                }
            }
        }
    }

    private func pnl(_ v: Double) -> String { (v >= 0 ? "+$" : "−$") + abs(v).tradeGrouped(2) }

    private func positionRow(_ p: Hyperliquid.Position) -> some View {
        let sym = p.coin.split(separator: ":").last.map(String.init) ?? p.coin
        return HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo(sym), name: p.coin, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sym) \(p.size > 0 ? "Long" : "Short") \(p.leverage)x").font(.system(size: 14, weight: .medium))
                Text("\(Hyperliquid.wire(abs(p.size))) at $\(p.entry.tradePx)\(p.liquidation.map { ", liq. $" + $0.tradePx } ?? "")")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(pnl(p.pnl)).font(.system(size: 14, weight: .medium)).foregroundStyle(p.pnl >= 0 ? Theme.green : Theme.red)
                Text(String(format: "%+.1f%%", p.roe * 100)).font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .monospacedDigit()
            Button("Close") { Task { await close(p) } }.buttonStyle(TradeSmallButton())
        }
        .padding(.vertical, 11)
    }

    private func orderRow(_ o: Hyperliquid.OpenOrder) -> some View {
        let sym = o.coin.split(separator: ":").last.map(String.init) ?? o.coin
        return HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo(sym), name: o.coin, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(o.isBuy ? "Buy" : "Sell") \(Hyperliquid.wire(o.size)) \(sym)").font(.system(size: 14, weight: .medium))
                Text("Limit $\(o.price.tradePx)\(o.reduceOnly ? ", reduce only" : "")").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button("Cancel") { Task { await cancel(o) } }.buttonStyle(TradeSmallButton())
        }
        .padding(.vertical, 11)
    }

    private func close(_ p: Hyperliquid.Position) async {
        error = nil
        guard let trader = hl.trader(), let asset = await hl.asset(p.coin) else { return }
        let mid = feed.perps[p.coin]?.px ?? p.entry
        let isBuy = p.size < 0
        let order = Hyperliquid.Order(asset: asset, isBuy: isBuy, price: Hyperliquid.marketPrice(mid: mid, isBuy: isBuy, asset: asset),
                                      size: abs(p.size), reduceOnly: true, tif: .ioc)
        let sym = p.coin.split(separator: ":").last.map(String.init) ?? p.coin
        ask(Approval(kind: "Hyperliquid order", title: "Close \(sym) \(p.size > 0 ? "long" : "short")",
                     lines: [["Size", "\(Hyperliquid.wire(abs(p.size))) \(sym)"], ["Unrealized PnL", pnl(p.pnl)], ["Order", "Market, reduce only"]],
                     checks: ["Signed on this phone with your wallet's key"], success: "\(sym) closed") {
            try await trader.place(order, leverage: nil).summary
        }) { Task { try? await Task.sleep(for: .seconds(1.5)); await hl.refresh() } }
    }

    private func cancel(_ o: Hyperliquid.OpenOrder) async {
        error = nil
        guard let trader = hl.trader(), let asset = await hl.asset(o.coin) else { return }
        do { try await trader.cancel(assetID: asset.id, coin: o.coin, oid: o.oid); await hl.refresh(); model.toast("Order cancelled") }
        catch { self.error = error.localizedDescription }
    }
}

/// Centered empty state: icon, title, one line of context.
struct TradeEmpty: View {
    let icon: String
    let title: String
    let note: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44).background(Theme.subtle, in: Circle())
            Text(title).font(.system(size: 14.5, weight: .medium))
            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

// MARK: Strategies

struct TradeStrategies: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TradeSection(title: "Running", top: 0) {
            Button { model.send("Help me plan a trading strategy") } label: {
                Label("Plan one with Hermit", systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(TradeSmallButton())
        } content: {
            TradeEmpty(icon: "gearshape.2", title: "No strategies running",
                       note: "Automated strategies open together with trading. You can already plan one with Hermit in chat.")
        }
    }
}
