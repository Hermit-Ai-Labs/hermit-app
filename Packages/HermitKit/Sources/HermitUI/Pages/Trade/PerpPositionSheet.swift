import SwiftUI
import HermitWallet
import HermitCore

// One Hyperliquid position, everywhere it shows: the card under the order form, the rows and detail sheet on
// Positions, the order-done moment, and the close and cancel paths they share. Every number is read from Hyperliquid
// by address (HyperliquidStore); closing signs a reduce-only market order after the approval sheet and Face ID.

// MARK: Formatting

enum PerpFmt {
    /// "xyz:TSLA" → "TSLA".
    static func sym(_ coin: String) -> String { coin.split(separator: ":").last.map(String.init) ?? coin }
    static func venue(_ coin: String) -> String { coin.hasPrefix("xyz:") ? "trade.xyz" : "Hyperliquid" }
    /// "$1,234.56"
    static func usd(_ v: Double) -> String { (v < 0 ? "−$" : "$") + abs(v).tradeGrouped(2) }
    /// "+$12.30" / "−$4.10"
    static func pnl(_ v: Double) -> String { (v >= 0 ? "+$" : "−$") + abs(v).tradeGrouped(2) }
    /// "+4.2%" / "−1.1%"
    static func pct(_ v: Double) -> String { (v >= 0 ? "+" : "−") + abs(v).tradeTrim(2) + "%" }
}

extension Hyperliquid.Position {
    var isLong: Bool { size > 0 }
    var sideText: String { isLong ? "Long" : "Short" }
    var sym: String { PerpFmt.sym(coin) }
    var coins: Double { abs(size) }
    /// The mark price Hyperliquid valued the position at (positionValue / size).
    var markPx: Double? { coins > 0 && value > 0 ? value / coins : nil }
    /// Unrealized P&L as a share of the margin it uses, in percent.
    var pnlOfMargin: Double? { margin > 0 ? pnl / margin * 100 : nil }
}

extension Hyperliquid.OpenOrder {
    /// "Take profit" or "Stop loss" for a trigger order; nil for a plain limit order.
    var protectionKind: String? {
        guard isTrigger else { return nil }
        let t = orderType.lowercased()
        if t.contains("take profit") { return "Take profit" }
        if t.contains("stop") { return "Stop loss" }
        return "Trigger"
    }
}

// MARK: Close and cancel

/// What the done moment says: "Long SOL 0.35 placed", "Closed SOL 0.35".
struct PerpDone: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let note: String
}

@MainActor
enum PerpActions {
    /// Closes `fraction` of a position (0.25, 0.5 or 1) with a reduce-only immediate-or-cancel market order. It reads
    /// the position and price again first, builds the exact order, and opens the approval sheet; `done` runs only once
    /// it was approved and sent. Returns what to tell the user when no review could be opened.
    static func close(_ p: Hyperliquid.Position, fraction: Double, ask: AskApproval,
                      done: @escaping @MainActor (PerpDone) -> Void) async -> String? {
        let hl = HyperliquidStore.shared, feed = MarketFeed.shared
        let sym = p.sym
        guard let trader = hl.trader() else { return "Pick a wallet to trade with first." }
        guard let asset = await hl.asset(p.coin) else { return "\(sym) isn't tradable on Hyperliquid right now." }
        // The position may have changed or closed since the screen last updated: size the close from a fresh read.
        guard await hl.poll() else { return "Couldn't read your Hyperliquid position. Check your connection and try again." }
        guard let cur = hl.account?.positions.first(where: { $0.coin == p.coin }), cur.size != 0 else {
            return "Your \(sym) position is already closed."
        }
        // A market order prices off the live price; if the feed has stopped, the mark Hyperliquid just valued it at.
        if feed.perpsStale || feed.perps[p.coin] == nil { await feed.refreshPerps() }
        guard let mid = (feed.perpsStale ? nil : feed.perps[p.coin]?.px) ?? cur.markPx, mid > 0 else {
            return "Prices from Hyperliquid aren't updating. Check your connection and try again."
        }
        let full = fraction >= 1
        let size = full ? cur.coins : Hyperliquid.roundSize(cur.coins * fraction, szDecimals: asset.szDecimals)
        let share = Int((fraction * 100).rounded())
        guard size > 0 else { return "\(share)% is smaller than the smallest \(sym) order. Close more of it." }
        if !full && size * mid < 10 {
            return "\(share)% is about $\((size * mid).tradeGrouped(2)), and Hyperliquid's smallest order is $10. Close more of it."
        }
        let isBuy = cur.size < 0
        let limit = Hyperliquid.marketPrice(mid: mid, isBuy: isBuy, asset: asset)
        let order = Hyperliquid.Order(asset: asset, isBuy: isBuy, price: limit, size: size, reduceOnly: true, tif: .ioc)
        let side = cur.isLong ? "long" : "short"
        let amount = "\(Hyperliquid.wire(size)) \(sym)"
        let partPnl = cur.pnl * size / cur.coins
        var lines: [[String]] = [
            ["Position", "\(sym) \(side) \(cur.leverage)x on \(PerpFmt.venue(cur.coin))"],
            ["Close", full ? "All of it, \(amount)" : "\(share)%, \(amount)"],
            ["Worth about", "$" + (size * mid).tradeGrouped(2)],
            [full ? "Unrealized P&L" : "P&L on this part", PerpFmt.pnl(partPnl)],
            ["Order", "Market, reduce only"],
            ["Worst price", "$" + limit.tradePx],
        ]
        if !full { lines.append(["Left open", "\(Hyperliquid.wire(max(0, cur.coins - size))) \(sym)"]) }
        let approval = Approval(kind: "Hyperliquid order", title: full ? "Close \(sym) \(side)" : "Close \(share)% of \(sym) \(side)",
                                lines: lines, checks: ["Signed on \(Device.here) with your wallet's key"],
                                success: full ? "\(sym) closed" : "Closed \(share)% of \(sym)") {
            try await trader.place(order, leverage: nil).summary
        }
        ask(approval) {
            done(PerpDone(title: full ? "Closed \(sym) \(Hyperliquid.wire(size))" : "Closed \(share)% of \(sym)",
                          note: full ? "Your \(sym) \(side) is closed" : "\(Hyperliquid.wire(max(0, cur.coins - size))) \(sym) still open"))
            hl.refreshAfterTrade()
        }
        return nil
    }

    /// Cancels one resting or trigger order (Face ID or Touch ID unlocks the key). Returns an error to show, or nil.
    static func cancel(_ o: Hyperliquid.OpenOrder, model: AppModel) async -> String? {
        let hl = HyperliquidStore.shared
        guard let trader = hl.trader() else { return "Pick a wallet to trade with first." }
        guard let asset = await hl.asset(o.coin) else { return "Couldn't find \(PerpFmt.sym(o.coin)) on Hyperliquid. Try again." }
        do {
            try await trader.cancel(assetID: asset.id, coin: o.coin, oid: o.oid)
            model.toast(o.protectionKind.map { "\($0) cancelled" } ?? "Order cancelled")
            hl.refreshAfterTrade()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: Done moment

/// A short "it went through" in place: a green ring draws, the check pops, the coin sound plays, then it hands back.
/// Reduce Motion: it simply appears.
struct PerpDoneView: View {
    let done: PerpDone
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var check = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Theme.green.opacity(0.18), lineWidth: 3)
                Circle().trim(from: 0, to: ring).stroke(Theme.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.green)
                    .scaleEffect(check ? 1 : 0.3).opacity(check ? 1 : 0)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(done.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if !done.note.isEmpty {
                    Text(done.note).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TradeColor.greenSoft, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.green.opacity(0.18)))
        .accessibilityElement(children: .combine)
        .task(id: done.id) {
            CoinSound.play()
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #elseif os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            #endif
            if reduceMotion || SnapshotMode.active {
                ring = 1; check = true
            } else {
                withAnimation(.smooth(duration: 0.45)) { ring = 1 }
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation(.bouncy) { check = true }
            }
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { onFinish() }
        }
        // Left the screen mid-moment: don't play it again on the way back.
        .onDisappear { onFinish() }
    }
}

// MARK: Pieces

/// Grey label over a value, in a grid. Values roll with `.numericText()` when they change.
struct PerpStatGrid: View {
    let items: [(String, String, Color)]
    var columns = 2
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: columns),
                  alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).font(.system(size: 11.5)).foregroundStyle(Theme.hint)
                    Text(item.1).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(item.1 == "—" ? Theme.faint : item.2)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The stats every position view shows.
func perpStats(_ p: Hyperliquid.Position, valueLabel: String = "Value") -> [(String, String, Color)] {
    [
        ("Size", "\(Hyperliquid.wire(p.coins)) \(p.sym)", Theme.text),
        (valueLabel, "$" + p.value.tradeGrouped(2), Theme.text),
        ("Entry", "$" + p.entry.tradePx, Theme.text),
        ("Mark", p.markPx.map { "$" + $0.tradePx } ?? "—", Theme.text),
        ("Liquidation", p.liquidation.map { $0 > 0 ? "$" + $0.tradePx : "None" } ?? "None", p.liquidation == nil ? Theme.muted : Theme.text),
        ("Margin used", "$" + p.margin.tradeGrouped(2), Theme.text),
    ]
}

/// A take profit or stop loss on a position, with Cancel.
struct PerpProtectionRow: View {
    let order: Hyperliquid.OpenOrder
    let cancelling: Bool
    let onCancel: () -> Void
    var body: some View {
        let kind = order.protectionKind ?? "Trigger"
        HStack(spacing: 8) {
            Circle().fill(kind == "Take profit" ? Theme.green : kind == "Stop loss" ? Theme.red : Theme.muted).frame(width: 7, height: 7)
            Text(kind).foregroundStyle(Theme.muted)
            Text("$" + order.triggerPx.tradePx).fontWeight(.medium).monospacedDigit()
            if !(order.size == 0 || order.isPositionTpsl) {
                Text("\(Hyperliquid.wire(order.size)) \(PerpFmt.sym(order.coin))").foregroundStyle(Theme.hint).monospacedDigit()
            }
            Spacer(minLength: 6)
            cancelButton(cancelling, onCancel)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4)
    }
}

/// One open order (limit, or a trigger not tied to a position here), with Cancel.
struct PerpOrderRow: View {
    let order: Hyperliquid.OpenOrder
    var showLogo = true
    let cancelling: Bool
    let onCancel: () -> Void
    var body: some View {
        let o = order, sym = PerpFmt.sym(order.coin)
        HStack(spacing: 12) {
            if showLogo { MarketLogo(key: TradeData.logo(sym), name: o.coin, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                // A take profit or stop loss waits for its trigger; size 0 means the whole position.
                if o.isTrigger {
                    Text("\(o.protectionKind ?? o.orderType) \(sym)").font(.system(size: 14, weight: .medium))
                    Text("Triggers at $\(o.triggerPx.tradePx)" + (o.size == 0 || o.isPositionTpsl ? ", whole position" : ", \(Hyperliquid.wire(o.size)) \(sym)"))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                } else {
                    Text("\(o.isBuy ? "Buy" : "Sell") \(Hyperliquid.wire(o.size)) \(sym)").font(.system(size: 14, weight: .medium))
                    Text("Limit $\(o.price.tradePx)\(o.reduceOnly ? ", reduce only" : "")").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
            }
            .monospacedDigit()
            Spacer(minLength: 8)
            cancelButton(cancelling, onCancel)
        }
        .padding(.vertical, showLogo ? 11 : 7)
    }
}

@MainActor @ViewBuilder
private func cancelButton(_ busy: Bool, _ action: @escaping () -> Void) -> some View {
    if busy {
        ProgressView().controlSize(.small).frame(width: 64, height: 26)
    } else {
        Button("Cancel", action: action).buttonStyle(TradeSmallButton(height: 26))
    }
}

/// Close 25%, 50% or 100%. A spinner on the one being prepared; all wait while it is.
struct PerpCloseButtons: View {
    let busy: Double?
    let onClose: (Double) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text("Close").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.trailing, 4)
            ForEach([0.25, 0.5, 1.0], id: \.self) { f in
                Button { onClose(f) } label: {
                    HStack(spacing: 5) {
                        if busy == f { ProgressView().controlSize(.mini) }
                        Text("\(Int(f * 100))%")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TradeSmallButton(kind: f >= 1 ? .primary : .plain, height: 32))
                .disabled(busy != nil)
                .accessibilityLabel(f >= 1 ? "Close all of it" : "Close \(Int(f * 100)) percent")
            }
        }
    }
}

// MARK: Card under the order form

/// The open position in the market on screen: side and leverage, P&L, the numbers, its TP and SL, and Close.
struct PerpPositionCard: View {
    let position: Hyperliquid.Position
    /// Its take profit and stop loss orders.
    let protection: [Hyperliquid.OpenOrder]
    var closing: Double?
    var cancelling: Set<Int> = []
    let onClose: (Double) -> Void
    let onCancel: (Hyperliquid.OpenOrder) -> Void

    var body: some View {
        let p = position
        let tint = p.pnl >= 0 ? Theme.green : Theme.red
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                MarketLogo(key: TradeData.logo(p.sym), name: p.coin, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(p.sideText) \(p.leverage)x").font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(p.isLong ? Theme.green : Theme.red)
                    Text("\(p.sym), \(p.cross ? "cross" : "isolated") margin").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(PerpFmt.pnl(p.pnl)).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                        .contentTransition(.numericText())
                    Text(p.pnlOfMargin.map { PerpFmt.pct($0) + " of margin" } ?? "Unrealized")
                        .font(.system(size: 12)).foregroundStyle(p.pnlOfMargin == nil ? Theme.hint : tint)
                        .contentTransition(.numericText())
                }
                .monospacedDigit()
            }
            PerpStatGrid(items: perpStats(p))
            VStack(alignment: .leading, spacing: 2) {
                if protection.isEmpty {
                    Text("No take profit or stop loss").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
                } else {
                    ForEach(protection) { o in
                        PerpProtectionRow(order: o, cancelling: cancelling.contains(o.oid)) { onCancel(o) }
                    }
                }
            }
            PerpCloseButtons(busy: closing, onClose: onClose)
        }
        .padding(14)
        .card()
        .animation(.smooth(duration: 0.3), value: p)
        .animation(.smooth(duration: 0.25), value: protection)
    }
}

// MARK: Detail sheet

/// Everything about one position: P&L, every number, funding, its orders, Close 25/50/100%, and the explorer.
/// It reads the live position from HyperliquidStore, so it updates with the page's poll behind it.
struct PerpPositionSheet: View {
    let coin: String
    /// The page shows the done moment once a close went through (this sheet has closed for the review by then).
    let onDone: (PerpDone) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @Environment(\.dismiss) private var dismiss
    @State private var closing: Double?
    @State private var cancelling: Set<Int> = []
    @State private var error: String?
    @State private var funding: Double?
    @State private var fundingRead = false
    private var hl: HyperliquidStore { .shared }
    private var feed: MarketFeed { .shared }

    private var sym: String { PerpFmt.sym(coin) }
    private var position: Hyperliquid.Position? { hl.account?.positions.first { $0.coin == coin && $0.size != 0 } }
    private var orders: [Hyperliquid.OpenOrder] { hl.account?.orders.filter { $0.coin == coin } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ThinScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let p = position { details(p) } else { closedState }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
        }
        .tradeSheet(width: 540, height: 680)
        .animation(.smooth(duration: 0.3), value: position)
        .animation(.smooth(duration: 0.25), value: orders)
        .marketPollBackingOff(every: 15, id: 0) { await feed.refreshPerps(); return feed.perpFailures == 0 }
        .marketPoll(every: 20, id: coin) {
            let f = await hl.fundingSinceOpen(coin)
            withAnimation(.smooth) { funding = f; fundingRead = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo(sym), name: coin, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sym) perp").font(.system(size: 17, weight: .semibold))
                Text(position.map { "\($0.sideText) \($0.leverage)x, \($0.cross ? "cross" : "isolated") on \(PerpFmt.venue(coin))" } ?? PerpFmt.venue(coin))
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer()
            TradeSheetClose { dismiss() }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var closedState: some View {
        TradeEmpty(icon: "checkmark.circle", title: "No open \(sym) position",
                   note: "It's closed, or the order hasn't filled yet. Open one from Markets.",
                   action: ("Done", { dismiss() }))
    }

    @ViewBuilder private func details(_ p: Hyperliquid.Position) -> some View {
        let tint = p.pnl >= 0 ? Theme.green : Theme.red
        let protection = orders.filter(\.isTrigger)
        let plain = orders.filter { !$0.isTrigger }
        VStack(alignment: .leading, spacing: 4) {
            Text("Unrealized P&L").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Text(PerpFmt.pnl(p.pnl)).font(.system(size: 30, weight: .semibold)).tracking(-0.4).monospacedDigit()
                .foregroundStyle(tint).contentTransition(.numericText())
            Text(p.pnlOfMargin.map { PerpFmt.pct($0) + " of the margin it uses" } ?? "No margin reported")
                .font(.system(size: 13)).foregroundStyle(p.pnlOfMargin == nil ? Theme.hint : tint).monospacedDigit()
                .contentTransition(.numericText())
        }
        PerpStatGrid(items: perpStats(p, valueLabel: "Notional") + more(p), columns: statColumns).padding(.top, 18)
        fundingLine(p).padding(.top, 12)

        TradeSection(title: "Take profit and stop loss", top: 26) {
            if protection.isEmpty {
                Text("None set for this position.").font(.system(size: 13)).foregroundStyle(Theme.hint).padding(.vertical, 4)
            }
            ForEach(protection) { o in
                PerpProtectionRow(order: o, cancelling: cancelling.contains(o.oid)) { cancel(o) }
            }
        }
        if !plain.isEmpty {
            TradeSection(title: "Open \(sym) orders", top: 22) {
                TradeRows(data: plain) { o in
                    PerpOrderRow(order: o, showLogo: false, cancelling: cancelling.contains(o.oid)) { cancel(o) }
                }
            }
        }
        TradeSection(title: "Close", top: 22) {
            VStack(alignment: .leading, spacing: 8) {
                PerpCloseButtons(busy: closing) { f in close(p, f) }
                Text("A market order, reduce only. You review it before anything is signed.")
                    .font(.system(size: 12)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let error {
            Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12).transition(.opacity)
        }
        if let addr = hl.address, let url = URL(string: "https://app.hyperliquid.xyz/explorer/address/\(addr)") {
            Link(destination: url) { Label("View on Hyperliquid explorer", systemImage: "arrow.up.right") }
                .buttonStyle(TradeSmallButton(height: 34)).padding(.top, 22)
        }
    }

    private var statColumns: Int {
        #if os(macOS)
        return 3
        #else
        return 2
        #endif
    }

    /// The sheet's extra numbers: ROE, the funding rate and what's been paid since it opened.
    private func more(_ p: Hyperliquid.Position) -> [(String, String, Color)] {
        let rate = feed.perps[coin]?.funding
        let paid: (String, Color) = {
            guard fundingRead else { return ("—", Theme.text) }
            guard let f = funding else { return ("Not available", Theme.muted) }
            if abs(f) < 0.005 { return ("$0.00", Theme.text) }
            return f > 0 ? ("Paid $" + f.tradeGrouped(2), Theme.red) : ("Got $" + abs(f).tradeGrouped(2), Theme.green)
        }()
        return [
            ("ROE", PerpFmt.pct(p.roe * 100), p.roe >= 0 ? Theme.green : Theme.red),
            ("Funding / h", rate.map { ($0 * 100).tradeTrim(4) + "%" } ?? "—", Theme.text),
            ("Funding since open", paid.0, paid.1),
        ]
    }

    /// What the current funding rate costs or pays this position each hour. Longs pay shorts when the rate is positive.
    @ViewBuilder private func fundingLine(_ p: Hyperliquid.Position) -> some View {
        if let rate = feed.perps[coin]?.funding {
            let hourly = abs(rate * p.value)
            let pays = p.isLong ? rate > 0 : rate < 0
            Text(hourly < 0.005 ? "Funding is about $0 an hour at the current rate."
                 : "At the current rate you \(pays ? "pay" : "earn") about $\(hourly.tradeGrouped(2)) an hour in funding.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close(_ p: Hyperliquid.Position, _ f: Double) {
        guard closing == nil else { return }
        error = nil
        closing = f
        Task {
            let e = await PerpActions.close(p, fraction: f, ask: ask) { d in onDone(d) }
            closing = nil
            withAnimation(.smooth) { error = e }
        }
    }

    private func cancel(_ o: Hyperliquid.OpenOrder) {
        guard !cancelling.contains(o.oid) else { return }
        error = nil
        cancelling.insert(o.oid)
        Task {
            let e = await PerpActions.cancel(o, model: model)
            cancelling.remove(o.oid)
            withAnimation(.smooth) { error = e }
        }
    }
}
