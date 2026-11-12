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
            default: TradePositions(openMarkets: { withAnimation(.smooth(duration: 0.25)) { tab = "markets" } })
            }
        }
        .approvalHost(sheetOpen: false) {}
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
    }
}

// MARK: Positions

/// Live from Hyperliquid for the trading wallet: the account at a glance, open positions with P&L (a row opens the
/// detail sheet: every number, funding, its orders, Close 25/50/100%), resting orders (Cancel), then the Solana tokens.
/// Everything is read by address; closing goes through the approval sheet, and closing and cancelling ask for Face ID.
struct TradePositions: View {
    @Environment(AppModel.self) private var model
    /// Switches Trade to Markets, for the empty state.
    var openMarkets: (() -> Void)? = nil
    @State private var error: String?
    @State private var open: PerpSheetItem?
    @State private var done: PerpDone?
    @State private var cancelling: Set<Int> = []
    @State private var withdrawing = false
    private var hl: HyperliquidStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hl.hasWallet {
                TradeEmpty(icon: "wallet.bifold", title: "No wallet yet", note: "Create a wallet to trade on Hyperliquid. Keys stay on \(Device.here).",
                           action: ("Create a wallet", { model.open(.wallets, tab: "create") }))
            } else {
                summary
                TradeSection(title: "Hyperliquid positions") {
                    let list = (hl.account?.positions ?? []).filter { $0.size != 0 }
                    if let d = done {
                        PerpDoneView(done: d) { clearDone(d) }
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                    if list.isEmpty { emptyPositions }
                    TradeRows(data: list) { p in
                        Button { open = PerpSheetItem(id: p.coin) } label: { positionRow(p) }
                            .buttonStyle(TradeRowButton())
                    }
                }
                TradeSection(title: "Open orders") {
                    let orders = hl.account?.orders ?? []
                    if orders.isEmpty && hl.account != nil {
                        MarketStatus(kind: .empty("No open orders. Limit orders, take profits and stop losses show here."))
                    }
                    TradeRows(data: orders) { o in
                        PerpOrderRow(order: o, cancelling: cancelling.contains(o.oid)) { cancel(o) }
                    }
                }
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).padding(.top, 10).fixedSize(horizontal: false, vertical: true) }
                TradeSection(title: "Solana tokens") {
                    SpotHoldingsSection()
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: hl.account)
        .animation(.smooth(duration: 0.3), value: done)
        // Every 5 s while this page is on screen; the poll stops when it isn't (and backs off when Hyperliquid is down).
        .marketPollBackingOff(every: 5, id: hl.address ?? "") { await hl.poll() }
        .task { if SnapshotMode.active { await hl.refresh() } }
        .sheet(item: $open) { item in
            PerpPositionSheet(coin: item.id) { d in showDone(d) }
                .environment(model)
                .tint(Theme.text)
        }
        .sheet(isPresented: $withdrawing) {
            HyperliquidWithdrawSheet()
                .environment(model)
                .tint(Theme.text)
        }
        // A close from the sheet closes it first; the approval sheet follows.
        .approvalHost(sheetOpen: open != nil || withdrawing) { open = nil; withdrawing = false }
    }

    private var summary: some View {
        let a = hl.account
        let upnl = a?.positions.reduce(0) { $0 + $1.pnl } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            TradeStats(items: [
                ("Account value", a.map { "$" + $0.accountValue.tradeGrouped(2) } ?? "—", Theme.text),
                ("Free margin", a.map { "$" + $0.withdrawable.tradeGrouped(2) } ?? "—", Theme.text),
                ("Unrealized P&L", a.map { _ in PerpFmt.pnl(upnl) } ?? "—", upnl >= 0 ? Theme.green : Theme.red),
            ])
            HyperliquidWithdrawStatus()
            HStack(spacing: 8) {
                Button("Deposit") { hl.openDeposit(model) }.buttonStyle(TradeSmallButton(kind: .primary))
                if (a?.accountValue ?? 0) > 0 || hl.withdrawal != nil {
                    Button("Withdraw") { withdrawing = true }.buttonStyle(TradeSmallButton())
                }
                if let addr = hl.address, let url = URL(string: "https://app.hyperliquid.xyz/explorer/address/\(addr)") {
                    Link(destination: url) { Label("Explorer", systemImage: "arrow.up.right") }.buttonStyle(TradeSmallButton())
                }
            }
        }
    }

    /// Loading, failed, nothing deposited, or funded with nothing open: each says what to do next.
    @ViewBuilder private var emptyPositions: some View {
        if hl.account == nil {
            if hl.state == .failed { MarketStatus(kind: .failed("Couldn't reach Hyperliquid")) { Task { await hl.refresh() } } }
            else { MarketStatus(kind: .loading("Loading your account")) }
        } else if (hl.account?.accountValue ?? 0) < 0.01 && (hl.account?.orders.isEmpty ?? true) {
            TradeEmpty(icon: "dollarsign.circle", title: "Nothing on Hyperliquid yet",
                       note: "Deposit USDC to trade perps. It lands in about a minute.",
                       action: ("Deposit", { hl.openDeposit(model) }))
        } else {
            TradeEmpty(icon: "chart.line.uptrend.xyaxis", title: "No open positions",
                       note: "Open a long or short from Markets. It shows here with live P&L.",
                       action: openMarkets.map { ("Go to Markets", $0) })
        }
    }

    private func positionRow(_ p: Hyperliquid.Position) -> some View {
        let tint = p.pnl >= 0 ? Theme.green : Theme.red
        return HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo(p.sym), name: p.coin, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.sym).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    Text("\(p.sideText) \(p.leverage)x").font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(p.isLong ? Theme.green : Theme.red)
                }
                Text("\(Hyperliquid.wire(p.coins)) at $\(p.entry.tradePx)\(p.liquidation.map { ", liq. $" + $0.tradePx } ?? "")")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(PerpFmt.pnl(p.pnl)).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text(p.pnlOfMargin.map { PerpFmt.pct($0) } ?? "$" + p.value.tradeGrouped(2))
                    .font(.system(size: 12)).foregroundStyle(p.pnlOfMargin == nil ? Theme.hint : tint)
                    .contentTransition(.numericText())
            }
            .monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityHint("Opens the position")
    }

    private func showDone(_ d: PerpDone) {
        withAnimation(.smooth) { done = d }
    }

    private func clearDone(_ d: PerpDone) {
        guard done?.id == d.id else { return }
        withAnimation(.smooth) { done = nil }
    }

    private func cancel(_ o: Hyperliquid.OpenOrder) {
        guard !cancelling.contains(o.oid) else { return }
        error = nil
        cancelling.insert(o.oid)
        Task {
            let e = await PerpActions.cancel(o, model: model)
            cancelling.remove(o.oid)
            error = e
        }
    }
}

/// Which position's sheet is open (by coin).
struct PerpSheetItem: Identifiable, Hashable { let id: String }

/// Centered empty state: icon, title, one line of context.
struct TradeEmpty: View {
    let icon: String
    let title: String
    let note: String
    /// A button inside the card, centred under the note.
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44).background(Theme.subtle, in: Circle())
            Text(title).font(.system(size: 14.5, weight: .medium))
            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
            if let action {
                Button(action.0, action: action.1).buttonStyle(TradeSmallButton(kind: .primary)).padding(.top, 6)
            }
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
