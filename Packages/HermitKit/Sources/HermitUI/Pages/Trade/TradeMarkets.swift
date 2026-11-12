import SwiftUI
import HermitWallet
import HermitCore

/// Markets: one segmented switch for the market type, then the matching screen, then Explore more.
struct TradeMarkets: View {
    @State private var kind = "perps"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: [("perps", "Perps"), ("spot", "Spot"), ("memes", "Memes")], selection: $kind)
                .padding(.bottom, 16)
            Group {
                switch kind {
                case "spot": TradeSpot()
                case "memes": TradeMemes()
                case "predict": TradePredictions()
                default: TradeTerminal()
                }
            }
            .id(kind)
            .transition(.opacity)
            TradeExploreMore(label: "markets", items: TradeData.moreMarkets)
        }
        .animation(.smooth(duration: 0.25), value: kind)
    }
}

// MARK: Perps terminal

/// Hyperliquid perps with Hermit built in: market picker and live stats, Hermit actions, real candles with TP/SL,
/// the live order book and trades, the order form (signed on this device after the approval sheet), and under it your
/// position and orders in this market.
struct TradeTerminal: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var askApproval
    @State private var placing = false
    @State private var withdrawing = false
    @State private var orderError: String?
    private var hl: HyperliquidStore { .shared }
    private var feed: MarketFeed { .shared }

    /// The market you were on, kept across visits and launches (it used to snap back to HYPE every time).
    @AppStorage("hermitTradeCoin") private var coin = "HYPE"
    @State private var pickOpen = false
    @State private var tf = "1H"
    @State private var side = "long"
    @State private var type = "Market"
    @State private var lev: Double = 3
    @State private var margin: Double = 500
    @State private var tpText = ""
    @State private var slText = ""
    @State private var limitText = ""
    @State private var defaultsFor = ""
    @State private var panel = "book"
    @State private var rangeLevels: [TradeLevel] = []
    @State private var ask = ""
    @State private var width: CGFloat = 1000
    @State private var candles: [Candle] = []
    @State private var chartState: FeedState = .loading
    /// Set while the chart shows the candles saved last time, until fresh ones arrive.
    @State private var candlesSaved: Date?
    @State private var book: TradeData.Book?
    @State private var prints: [TradeData.Print] = []
    @State private var bookState: FeedState = .loading
    /// When the book last arrived and how many polls in a row have failed since, so a frozen book isn't called live.
    @State private var bookUpdated: Date?
    @State private var bookFailures = 0
    /// The TP and SL text the defaults last wrote: while the fields still hold them, a leverage change moves them too.
    @State private var autoLevels = ""
    /// The order-done moment, and where it shows: "form" in place of the order button, "position" over the card.
    @State private var done: PerpDone?
    @State private var doneAt = "form"
    /// The close being prepared (0.25, 0.5, 1) and the orders being cancelled, for their spinners.
    @State private var closing: Double?
    @State private var cancelling: Set<Int> = []
    @State private var positionError: String?

    private var mkt: TradeData.Perp? { feed.perps[coin] }
    private var sym: String { coin.split(separator: ":").last.map(String.init) ?? coin }
    private var px: Double { mkt?.px ?? 0 }
    private var wide: Bool { width >= 760 }
    private func parse(_ s: String) -> Double? { TradeAmount.value(s).flatMap { $0 > 0 ? $0 : nil } }
    private var tp: Double? { parse(tpText) }
    private var sl: Double? { parse(slText) }
    private var liq: Double { liqPrice(px, lev: lev, maxLev: mkt?.maxLev ?? 10) }
    /// How far the price can move against an isolated position before liquidation: 1/leverage, less the maintenance
    /// margin Hyperliquid keeps (half the initial margin at the market's top leverage). At 10x on a 10x market, 5%.
    private func liqDistance(lev: Double, maxLev: Int) -> Double { max(0, 1 / max(lev, 1) - 0.5 / Double(max(maxLev, 1))) }
    /// The same formula chat's prepare_trade uses (HermitToolbox.liquidation), so both show one estimate; for a short it
    /// sits a little nearer than entry * (1 + distance).
    private func liqPrice(_ p: Double, lev: Double, maxLev: Int) -> Double {
        HermitToolbox.liquidation(entry: p, leverage: max(lev, 1), mm: 0.5 / Double(max(maxLev, 1)), long: side == "long")
    }
    private var size: Double { margin * lev }
    /// The margin slider ends at what's on Hyperliquid, so it sits where your money is; $5,000 until that's known.
    private var marginTop: Double { hl.account != nil && hl.available >= 5 ? max(10, hl.available.rounded(.down)) : 5000 }

    /// When the account loads (or changes), bring the margin down to what you have, and keep the order above
    /// Hyperliquid's $10 minimum by raising leverage if needed.
    private func fitMargin() {
        guard hl.account != nil, hl.available >= 5 else { return }
        if margin > hl.available { margin = hl.available.rounded(.down) }
        let need = (10 / max(margin, 1)).rounded(.up)
        if margin * lev < 10, need <= Double(max(2, mkt?.maxLev ?? 10)) { lev = need }
    }
    private func move(_ v: Double?) -> Double? { v.flatMap { px > 0 ? abs($0 - px) / px * size : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if feed.perpState == .failed && mkt == nil {
                MarketStatus(kind: .failed("Couldn't reach Hyperliquid")) { Task { await feed.refreshPerps() } }
            }
            hermitBar
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 22) { chart; bookPanel }
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 22) { form; positionPanel }.frame(width: 300)
                }
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 22) { chart; form; positionPanel; bookPanel }.padding(.top, 6)
            }
        }
        .tradeWidth($width)
        .marketPollBackingOff(every: 15, id: 0) { await feed.refreshPerps(); return feed.perpFailures == 0 }
        .marketPollBackingOff(every: 30, id: coin + tf) { await loadCandles() }
        .marketPollBackingOff(every: 5, id: coin) { await loadBook() }
        // The account: every 5 s while there's a position or order in this market to show, else every 20 s (a limit
        // order may fill). Stops when the terminal isn't on screen.
        .marketPollBackingOff(every: hasHere ? 5 : 20, id: "\(hl.address ?? "")|\(hasHere)") { await hl.poll() }
        .onChange(of: mkt?.px != nil, initial: true) { _, has in if has && defaultsFor != coin { setDefaults(side) } }
        .onChange(of: lev) { _, _ in if tpText + "|" + slText == autoLevels { setDefaults(side) } }
        .onChange(of: tf) { candles = []; chartState = .loading; candlesSaved = nil; rangeLevels = [] }
        .sheet(isPresented: $withdrawing) {
            HyperliquidWithdrawSheet().environment(model).tint(Theme.text)
        }
        // Review closes the withdraw sheet first; the approval sheet follows.
        .approvalHost(sheetOpen: withdrawing) { withdrawing = false }
    }

    // MARK: Header: market picker and stats

    private var header: some View {
        let m = mkt
        let stats: [(String, String, Color)] = [
            (m != nil && feed.perpsStale ? (feed.perpsSaved ? "Mark, last known" : "Mark, not updating") : "Mark", m.map { "$" + $0.px.tradePx } ?? "—", Theme.text),
            ("24h", m?.ch.tradePct ?? "—", (m?.ch ?? 0) >= 0 ? Theme.green : Theme.red),
            ("Volume", m?.vol.tradeCompactUSD ?? "—", Theme.text), ("Open interest", m?.oiUSD.tradeCompactUSD ?? "—", Theme.text),
            ("Funding / h", m.map { $0.fundPct.tradeTrim(4) + "%" } ?? "—", (m?.funding ?? 0) >= 0 ? Theme.green : Theme.red),
            ("Venue", coin.hasPrefix("xyz:") ? "trade.xyz" : "Hyperliquid", Theme.text),
        ]
        return Group {
            if wide {
                HStack(spacing: 22) {
                    picker
                    ForEach(stats, id: \.0) { stat($0) }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    picker
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 10) {
                        ForEach(stats, id: \.0) { stat($0) }
                    }
                }
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func stat(_ s: (String, String, Color)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.0).font(.system(size: 11.5)).foregroundStyle(Theme.hint)
            Text(s.1).font(.system(size: 13.5, weight: .medium)).monospacedDigit().foregroundStyle(s.1 == "—" ? Theme.faint : s.2).lineLimit(1)
                .contentTransition(.numericText())
        }
        .fixedSize()
    }

    private var picker: some View {
        Button { pickOpen.toggle() } label: {
            HStack(spacing: 8) {
                MarketLogo(key: TradeData.logo(sym), name: sym, size: 22)
                Text("\(sym)-USD").font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(pickOpen ? 180 : 0))
            }
            .padding(.leading, 6).padding(.trailing, 11).frame(height: 38)
        }
        .buttonStyle(TradePickerStyle())
        .fixedSize()
        #if os(iOS)
        // iPhone: a full sheet with every market. The popover opened upward over the bar and the keyboard hid it.
        .sheet(isPresented: $pickOpen) {
            TradeMarketMenu(current: coin, sheet: true) { m in pick(m.coin); pickOpen = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .glassSheetBackground()
        }
        #else
        .popover(isPresented: $pickOpen, arrowEdge: .bottom) {
            TradeMarketMenu(current: coin) { m in pick(m.coin); pickOpen = false }
        }
        #endif
    }

    // MARK: Hermit actions

    /// Draw range marks the real high and low of the candles on screen; the other two hand the live numbers to Hermit in chat.
    private var hermitBar: some View {
        HStack(alignment: .top, spacing: 10) {
            TradeSpark().padding(.top, 2)
            TradeFlow {
                Button("Draw range") { toggleRange() }.buttonStyle(TradeChip(on: !rangeLevels.isEmpty)).disabled(candles.isEmpty)
                Button("Why is it moving?") {
                    guard let m = mkt else { return }
                    model.send("Why is \(sym) \(m.ch >= 0 ? "up" : "down") \(abs(m.ch).tradeTrim())% in the last 24 hours? It's at $\(m.px.tradePx) on \(m.venue), funding \(m.fundPct.tradeTrim(4))% an hour.")
                }
                .buttonStyle(TradeChip()).disabled(mkt == nil)
                Button("Plan a trade") {
                    guard let m = mkt else { return }
                    model.send("Plan a \(sym) perp trade on \(m.venue) with entry, stop-loss and take-profit. Mark price is $\(m.px.tradePx).")
                }
                .buttonStyle(TradeChip()).disabled(mkt == nil)
            }
        }
        .padding(.vertical, 12)
    }

    private func toggleRange() {
        withAnimation(.smooth(duration: 0.3)) {
            if !rangeLevels.isEmpty { rangeLevels = []; return }
            guard let lo = candles.map(\.l).min(), let hi = candles.map(\.h).max() else { return }
            rangeLevels = [TradeLevel(value: lo, label: "Range low \(lo.tradePx)", color: TradeColor.support),
                           TradeLevel(value: hi, label: "Range high \(hi.tradePx)", color: TradeColor.resistance)]
        }
    }

    // MARK: Chart

    private var levels: [TradeLevel] {
        guard px > 0 else { return [] }
        return (tp.map { [TradeLevel(value: $0, label: "TP \($0.tradePx)", color: Theme.green)] } ?? [])
            + [TradeLevel(value: px, label: "Mark \(px.tradePx)", color: Theme.text)]
            + (sl.map { [TradeLevel(value: $0, label: "SL \($0.tradePx)", color: Theme.red)] } ?? [])
            + rangeLevels
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Segmented(options: TradeData.timeframes.map { ($0.0, $0.0) }, selection: $tf).fixedSize()
                Spacer(minLength: 8)
                if width >= 440 { MarketSource(text: candlesSaved.map { "Hyperliquid candles, saved \(Freshness.ago($0))" } ?? "Hyperliquid candles") }
            }
            Group {
                if !candles.isEmpty {
                    TradeCandleChart(data: candles, levels: levels, padTo: [tp, sl].compactMap { $0 }, rangeLabel: chartSpan)
                        .id(coin + tf)
                        .transition(.opacity)
                } else if chartState == .failed {
                    MarketStatus(kind: .failed("Couldn't load candles")) { Task { await loadCandles() } }
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    MarketStatus(kind: .loading("Loading candles")).frame(maxHeight: .infinity, alignment: .center)
                }
            }
            .frame(height: 280)
            .animation(.smooth(duration: 0.25), value: candles.isEmpty)
        }
    }

    /// What the candles on screen cover: "12 hours", "2 days".
    private var chartSpan: String {
        let t = TradeData.timeframes.first { $0.0 == tf } ?? TradeData.timeframes[1]
        let seconds = Double(candles.count) * t.2, hours = Int((seconds / 3600).rounded())
        if hours < 1 { return "\(Int(seconds / 60)) minutes" }
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours / 24) days"
    }

    @discardableResult private func loadCandles() async -> Bool {
        let t = TradeData.timeframes.first { $0.0 == tf } ?? TradeData.timeframes[1]
        let want = coin + tf, key = "candles-\(coin)-\(tf)"
        // The last candles for this market and timeframe draw at once (while they still cover most of the window);
        // the fresh ones replace them.
        if candles.isEmpty, let s = SnapshotStore.live.load(key, as: [Candle].self, maxAge: t.2 * 30) {
            candles = s.value; chartState = .ready; candlesSaved = s.saved
        }
        do {
            let c = try await TradeAPI.perpCandles(coin, interval: t.1, seconds: t.2)
            guard want == coin + tf else { return true }
            candles = c; chartState = .ready; candlesSaved = nil
            SnapshotStore.live.save(c, key)
            return true
        } catch {
            if candles.isEmpty { chartState = .failed }
            return false
        }
    }

    // MARK: Order book and trades

    @discardableResult private func loadBook() async -> Bool {
        let want = coin
        async let b = try? TradeAPI.book(want)
        async let p = try? TradeAPI.prints(want)
        let (bk, pr) = await (b, p)
        guard want == coin else { return true }
        if let bk { book = bk; bookState = .ready; bookUpdated = Date(); bookFailures = 0 }
        else { bookFailures += 1; if book == nil { bookState = .failed } }
        if let pr { prints = pr }
        return bk != nil
    }

    /// "Live from Hyperliquid" while the book keeps arriving; after two misses in a row, how old it is.
    private var bookSource: String {
        if bookFailures >= 2, let u = bookUpdated { return "Not updating. Last update \(u.formatted(.relative(presentation: .named)))" }
        return "Live from \(coin.hasPrefix("xyz:") ? "trade.xyz" : "Hyperliquid")"
    }

    private var bookPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Segmented(options: [("book", "Order book"), ("trades", "Trades")], selection: $panel).fixedSize()
                Spacer()
                MarketSource(text: bookSource)
            }
            VStack(spacing: 0) {
                if let ob = book, !ob.asks.isEmpty, !ob.bids.isEmpty {
                    let asks = Array(ob.asks.prefix(7).reversed()), bids = Array(ob.bids.prefix(7))
                    let mx = (asks + bids).map(\.sz).max() ?? 1, dp = (bids.first?.px ?? 1).tradeDecimals
                    if panel == "book" {
                        bookHead(["Price", "Size (\(sym))"])
                        ForEach(Array(asks.enumerated()), id: \.offset) { _, a in bookRow(a, sell: true, max: mx, dp: dp) }
                        HStack(spacing: 6) {
                            Text(px > 0 ? px.tradePx : "—").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            if let a = ob.asks.first, let b = ob.bids.first, b.px > 0 {
                                Text("spread " + String(format: "%.3f%%", (a.px - b.px) / b.px * 100)).font(.system(size: 12)).foregroundStyle(Theme.hint)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 6).padding(.vertical, 7)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        .padding(.vertical, 3)
                        ForEach(Array(bids.enumerated()), id: \.offset) { _, b in bookRow(b, sell: false, max: mx, dp: dp) }
                    } else {
                        bookHead(["Price", "Size", "Time"])
                        ForEach(Array(prints.prefix(14).enumerated()), id: \.offset) { _, t in
                            HStack {
                                Text(t.px.tradeGrouped(dp)).foregroundStyle(t.buy ? Theme.green : Theme.red).frame(maxWidth: .infinity, alignment: .leading)
                                Text(Self.size(t.sz)).frame(maxWidth: .infinity, alignment: .trailing)
                                Text(t.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()).foregroundStyle(Theme.hint)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: 12.5)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 3)
                        }
                        if prints.isEmpty { MarketStatus(kind: .empty("No recent trades")) }
                    }
                } else if bookState == .failed {
                    MarketStatus(kind: .failed("Couldn't load the order book")) { Task { await loadBook() } }
                } else {
                    MarketStatus(kind: .loading("Loading order book"))
                }
            }
            .transition(.opacity)
            .id(panel)
        }
    }

    /// Order sizes: whole numbers when big, three significant digits when tiny (BTC).
    static func size(_ v: Double) -> String {
        v >= 100 ? v.tradeGrouped(0) : v >= 1 ? v.tradeTrim(2) : v.formatted(.number.precision(.significantDigits(1...3)))
    }

    private func bookHead(_ cols: [String]) -> some View {
        HStack {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                Text(c).frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.hint).padding(.horizontal, 6).padding(.vertical, 3)
    }

    private func bookRow(_ l: TradeData.BookLevel, sell: Bool, max: Double, dp: Int) -> some View {
        HStack {
            Text(l.px.tradeGrouped(dp)).foregroundStyle(sell ? Theme.red : Theme.green)
            Spacer()
            Text(Self.size(l.sz))
        }
        .font(.system(size: 12.5)).monospacedDigit()
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 2).fill(sell ? TradeColor.redSoft : TradeColor.greenSoft)
                .padding(.vertical, 1)
                .scaleEffect(x: max > 0 ? l.sz / max : 0, anchor: .trailing)
        }
    }

    // MARK: Order form

    /// The full form, sized against live prices. Submitting builds the exact order and opens the approval sheet.
    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            TradeWideSegmented(options: ["Market", "Limit"], selection: $type)
            HStack(spacing: 6) {
                sideButton("long", "Long", Theme.green)
                sideButton("short", "Short", Theme.red)
            }
            if type == "Limit" {
                field("Limit price", color: Theme.muted) { TradeField(placeholder: px > 0 ? px.tradePx : "", text: $limitText) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            slider("Margin", prefix: "$", binding: $margin, range: 5...marginTop, step: 1)
            slider("Leverage", suffix: "x", binding: $lev, range: 1...Double(max(2, mkt?.maxLev ?? 10)), step: 1)
            if hl.account != nil && size < 10 {
                Text("Hyperliquid's smallest order is $10. With $\(margin.tradeGrouped()) of margin that needs \(Int((10 / max(margin, 1)).rounded(.up)))x.")
                    .font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                field("Take profit", color: Theme.green) { TradeField(placeholder: "", text: $tpText) }
                field("Stop loss", color: Theme.red) { TradeField(placeholder: "", text: $slText) }
            }
            TradeTx(lines: [
                ("Size", AnyView(Text("$" + size.tradeGrouped()).contentTransition(.numericText()))),
                ("At TP / SL", AnyView(Text("\(Text(move(tp).map { "+$" + $0.tradeGrouped() } ?? "—").foregroundStyle(Theme.green)) / \(Text(move(sl).map { "−$" + $0.tradeGrouped() } ?? "—").foregroundStyle(Theme.red))"))),
                ("Liquidation, est.", AnyView(Text(px > 0 ? "$" + liq.tradePx : "—"))),
            ])
            if lev > 10 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(Theme.amber).padding(.top, 1)
                    Text("A \(String(format: "%.1f", liqDistance(lev: lev, maxLev: mkt?.maxLev ?? 10) * 100))% move against you liquidates you. 5x or less is safer.").font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TradeColor.amberSoft, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            submit
            askField
        }
        .animation(.snappy(duration: 0.25), value: type)
        .animation(.snappy(duration: 0.25), value: lev > 10)
    }

    // MARK: Placing the order

    private var notional: Double { margin * lev }
    private var orderPrice: Double? { type == "Limit" ? parse(limitText) : (px > 0 ? px : nil) }

    /// Wallet → funded Hyperliquid account → the order. Each step says what's missing instead of a dead button.
    @ViewBuilder private var submit: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hl.hasWallet {
                Button("Create a wallet to trade") { model.open(.wallets, tab: "create") }
                    .buttonStyle(TradeBlockButton(color: Theme.text))
            } else if hl.account == nil {
                Button {} label: {
                    HStack(spacing: 6) {
                        if hl.state != .failed { ProgressView().controlSize(.small) }
                        Text(hl.state == .failed ? "Couldn't reach Hyperliquid" : "Checking your balance")
                    }
                }
                .buttonStyle(TradeBlockButton(color: Theme.text)).disabled(true)
                if hl.state == .failed { Button("Retry") { Task { await hl.refresh() } }.buttonStyle(TradeSmallButton()) }
            } else if hl.available < margin {
                Button { hl.openDeposit(model, amount: margin - hl.available) } label: { Text("Deposit USDC to trade") }
                    .buttonStyle(TradeBlockButton(color: Theme.text))
                Text(hl.account.map { a in
                    a.accountValue - hl.available > 0.5
                        ? "You have $\(a.accountValue.tradeGrouped(2)) on Hyperliquid, $\(hl.available.tradeGrouped(2)) of it free; the rest is backing your open position. Close it to trade with the full balance, or deposit more."
                        : hl.available > 0 ? "You have $\(hl.available.tradeGrouped(2)) on Hyperliquid. Move more from any network, or add it with a QR code."
                        : "Move USDC or any coin you hold on any network, or add some with a QR code. It lands in about a minute."
                } ?? "Move USDC or any coin you hold on any network, or add some with a QR code. It lands in about a minute.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if let d = done, doneAt == "form" {
                PerpDoneView(done: d) { clearDone(d) }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                Button { Task { await review() } } label: {
                    HStack(spacing: 6) {
                        if placing { ProgressView().controlSize(.small).tint(.white) }
                        Text("\(side == "long" ? "Long" : "Short") \(sym)")
                    }
                }
                .buttonStyle(TradeBlockButton(color: side == "long" ? Theme.green : Theme.red))
                .disabled(placing || orderPrice == nil || notional < 10)
                HStack {
                    Text(hl.account.map { "$\($0.withdrawable.tradeGrouped(2)) available on Hyperliquid" } ?? "Checking your Hyperliquid balance")
                    Spacer()
                    if hl.account != nil {
                        if (hl.account?.accountValue ?? 0) > 0 { Button("Withdraw") { withdrawing = true }.buttonStyle(.plain).foregroundStyle(Theme.text) }
                        Button("Deposit") { hl.openDeposit(model) }.buttonStyle(.plain).foregroundStyle(Theme.text)
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            if let orderError {
                Text(orderError).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .task(id: hl.address) { await hl.refresh(); fitMargin() }
        .onChange(of: hl.available) { _, _ in fitMargin() }
        .animation(.smooth(duration: 0.3), value: done)
    }

    /// Builds the exact order, shows it on the review sheet, and signs + sends it only after Approve (Face ID).
    private func review() async {
        orderError = nil
        guard orderPrice != nil, let trader = hl.trader() else { return }
        placing = true
        defer { placing = false }
        // A market order prices off the mark: if the feed has stopped, get a fresh one or don't offer the order.
        if type == "Market", feed.perpsStale {
            await feed.refreshPerps()
            if feed.perpsStale { orderError = "Prices from Hyperliquid aren't updating. Check your connection and try again."; return }
        }
        guard let price = orderPrice else { return }
        // Check the balance again right before review: never offer an order the account can't pay for.
        await hl.refresh()
        guard let acct = hl.account else { orderError = "Couldn't read your Hyperliquid balance. Try again."; return }
        guard acct.withdrawable >= margin else {
            orderError = "You have $\(acct.withdrawable.tradeGrouped(2)) on Hyperliquid; this order needs $\(margin.tradeGrouped()) of margin. Deposit USDC first."
            return
        }
        // In a standard account the main markets and trade.xyz each have their own balance; the order can only use its own.
        let xyz = coin.hasPrefix("xyz:")
        switch await hl.margin(dex: xyz ? "xyz" : nil) {
        case .shared: break
        case .unknown: orderError = "Couldn't read your \(xyz ? "trade.xyz" : "Hyperliquid") balance. Try again."; return
        case .free(let free) where free < margin:
            orderError = xyz
                ? "trade.xyz markets have their own balance on Hyperliquid: $\(free.tradeGrouped(2)) there, and this order needs $\(margin.tradeGrouped()) of margin. Moving USDC to trade.xyz from Hermit is coming soon."
                : "You have $\(free.tradeGrouped(2)) free on Hyperliquid's main markets; this order needs $\(margin.tradeGrouped()) of margin. Deposit USDC first."
            return
        case .free: break
        }
        guard let asset = await hl.asset(coin) else { orderError = "\(sym) isn't tradable on Hyperliquid right now."; return }
        let isBuy = side == "long"
        let size = Hyperliquid.roundSize(notional / price, szDecimals: asset.szDecimals)
        guard size > 0 else { orderError = "That size is too small for \(sym)."; return }
        let limit = type == "Limit" ? Hyperliquid.roundPrice(price, szDecimals: asset.szDecimals)
                                    : Hyperliquid.marketPrice(mid: price, isBuy: isBuy, asset: asset)
        let order = Hyperliquid.Order(asset: asset, isBuy: isBuy, price: limit, size: size, tif: type == "Limit" ? .gtc : .ioc,
                                      takeProfit: tp, stopLoss: sl)
        let leverage = min(Int(lev), asset.maxLeverage)
        let estLiq = liqPrice(price, lev: Double(leverage), maxLev: asset.maxLeverage)
        // A stop on the wrong side fires at once; one past liquidation never fires at all.
        if let sl {
            if isBuy ? sl >= price : sl <= price {
                orderError = "The stop loss has to be \(isBuy ? "below" : "above") the price for a \(isBuy ? "long" : "short")."; return
            }
            if isBuy ? sl <= estLiq : sl >= estLiq {
                orderError = "The stop loss at $\(sl.tradePx) is past the estimated liquidation price, $\(estLiq.tradePx). Move it closer or lower the leverage."
                return
            }
        }
        if let tp, isBuy ? tp <= price : tp >= price {
            orderError = "The take profit has to be \(isBuy ? "above" : "below") the price for a \(isBuy ? "long" : "short")."; return
        }
        var lines: [[String]] = [
            ["Market", "\(sym) perp on \(coin.hasPrefix("xyz:") ? "trade.xyz" : "Hyperliquid")"],
            ["Side", isBuy ? "Long" : "Short"],
            ["Size", "\(Hyperliquid.wire(size)) \(sym), about $\((size * price).tradeGrouped())"],
            ["Margin", "$\(margin.tradeGrouped()) at \(leverage)x"],
            [type == "Limit" ? "Limit price" : "Worst price", "$" + limit.tradePx],
            ["Liquidation, est.", "$" + estLiq.tradePx],
        ]
        if let tp { lines.append(["Take profit", "$" + tp.tradePx]) }
        if let sl { lines.append(["Stop loss", "$" + sl.tradePx]) }
        lines.append(["Fees", "Hyperliquid's taker fee, about 0.045%"])
        // Leverage is set per coin on Hyperliquid, so the order changes it for an open position in this coin too. The
        // same test as `place`: skipped only when the position already has this leverage and margin mode.
        let cur = hl.account?.positions.first { $0.coin == asset.coin }
        var warnings = ["Leveraged trades can lose all their margin"]
        if !(cur?.leverage == leverage && cur?.cross == !asset.onlyIsolated) {
            lines.insert(["Leverage", "Sets \(sym) to \(leverage)x"], at: 4)
            if cur != nil { warnings.append("This also changes the leverage of your open \(sym) position.") }
        }
        let approval = Approval(kind: "Hyperliquid order", title: "\(isBuy ? "Long" : "Short") \(sym)", lines: lines,
                                checks: ["Signed on \(Device.here) with your wallet's key"],
                                success: "\(isBuy ? "Long" : "Short") \(sym) sent", warnings: warnings) {
            // The summary says whether each take profit and stop loss was set ("Stop loss not set: <reason>").
            let r = try await trader.place(order, leverage: leverage, current: cur)
            return r.summary
        }
        let placed = PerpDone(title: "\(isBuy ? "Long" : "Short") \(sym) \(Hyperliquid.wire(size)) placed",
                              note: type == "Limit" ? "It waits at $\(limit.tradePx) until it fills" : "Your position updates below")
        askApproval(approval) {
            showDone(placed, at: "form")
            hl.refreshAfterTrade()
        }
    }

    // MARK: Your position here

    private var herePosition: Hyperliquid.Position? { hl.account?.positions.first { $0.coin == coin && $0.size != 0 } }
    private var hereOrders: [Hyperliquid.OpenOrder] { hl.account?.orders.filter { $0.coin == coin } ?? [] }
    private var hasHere: Bool { herePosition != nil || !hereOrders.isEmpty }

    /// Under the order form: the open position in this market (P&L, the numbers, its TP and SL, Close 25/50/100%), and
    /// this market's other open orders with Cancel. Nothing when there's neither.
    @ViewBuilder private var positionPanel: some View {
        let p = herePosition
        let orders = hereOrders
        // With a position, its TP and SL sit on the card; without one, any left over are listed as orders.
        let listed = p == nil ? orders : orders.filter { !$0.isTrigger }
        let showDoneHere = done != nil && doneAt == "position"
        if p != nil || !orders.isEmpty || showDoneHere || positionError != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(p == nil ? "Your \(sym) orders" : "Your \(sym) position").font(.system(size: 13)).foregroundStyle(Theme.muted)
                if let d = done, doneAt == "position" {
                    PerpDoneView(done: d) { clearDone(d) }
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
                if let p {
                    PerpPositionCard(position: p, protection: orders.filter(\.isTrigger), closing: closing, cancelling: cancelling,
                                     onClose: { f in closeHere(p, f) }, onCancel: { o in cancelHere(o) })
                        .transition(.opacity)
                }
                if !listed.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        if p != nil { Text("Open orders").font(.system(size: 12.5)).foregroundStyle(Theme.hint).padding(.top, 4) }
                        TradeRows(data: listed) { o in
                            PerpOrderRow(order: o, showLogo: false, cancelling: cancelling.contains(o.oid)) { cancelHere(o) }
                        }
                    }
                }
                if let positionError {
                    Text(positionError).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: p)
            .animation(.smooth(duration: 0.3), value: done)
            .animation(.smooth(duration: 0.25), value: orders)
            .transition(.opacity)
        }
    }

    private func showDone(_ d: PerpDone, at place: String) {
        withAnimation(.smooth) { doneAt = place; done = d }
    }

    private func clearDone(_ d: PerpDone) {
        guard done?.id == d.id else { return }
        withAnimation(.smooth) { done = nil }
    }

    private func closeHere(_ p: Hyperliquid.Position, _ f: Double) {
        guard closing == nil else { return }
        positionError = nil
        closing = f
        Task {
            let e = await PerpActions.close(p, fraction: f, ask: askApproval) { d in showDone(d, at: "position") }
            closing = nil
            withAnimation(.smooth) { positionError = e }
        }
    }

    private func cancelHere(_ o: Hyperliquid.OpenOrder) {
        guard !cancelling.contains(o.oid) else { return }
        positionError = nil
        cancelling.insert(o.oid)
        Task {
            let e = await PerpActions.cancel(o, model: model)
            cancelling.remove(o.oid)
            withAnimation(.smooth) { positionError = e }
        }
    }

    private func sideButton(_ s: String, _ title: String, _ color: Color) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { side = s; setDefaults(s) } } label: {
            Text(title).font(.system(size: 14, weight: .medium))
                .foregroundStyle(side == s ? .white : Theme.muted)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(side == s ? color : Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(side == s ? color : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func field<C: View>(_ label: String, color: Color, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(color)
            c()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(_ label: String, prefix: String = "", suffix: String = "", binding: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(Theme.muted)
                Spacer()
                TradeTypedValue(prefix: prefix, suffix: suffix, value: binding, range: range, step: step)
            }
            .font(.system(size: 12.5))
            // The Mac draws a tick per step: a few for leverage, but thousands for margin, which blurred into a black bar.
            // Long ranges slide freely and snap to the step instead.
            if (range.upperBound - range.lowerBound) / step > 24 {
                Slider(value: Binding(get: { binding.wrappedValue },
                                      set: { binding.wrappedValue = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step)) }),
                       in: range).tint(Theme.text).controlSize(.small)
            } else {
                Slider(value: binding, in: range, step: step).tint(Theme.text).controlSize(.small)
            }
        }
    }

    private var askField: some View {
        HStack(spacing: 6) {
            TextField("Ask Hermit about \(sym)", text: $ask).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit(sendAsk)
            Button(action: sendAsk) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(ask.trimmingCharacters(in: .whitespaces).isEmpty ? Color(hex: 0xE3E3E1) : Theme.accent, in: Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(ask.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Ask")
        }
        .padding(.leading, 12).padding(4)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func sendAsk() {
        let q = ask.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        ask = ""
        model.send(q)
    }

    // MARK: Actions

    /// Starting TP and SL around the live mark price, so the chart lines land somewhere sensible.
    private func setDefaults(_ s: String) {
        guard px > 0 else { tpText = ""; slText = ""; autoLevels = ""; return }
        func raw(_ v: Double) -> String { TradeAmount.text(v, maxFraction: max(0, px.tradeDecimals)) }
        // The stop sits well inside liquidation at this leverage (5% at most); take profit 1.6 times as far (8% at most).
        let slDist = min(0.05, 0.6 * liqDistance(lev: lev, maxLev: mkt?.maxLev ?? 10)), tpDist = min(0.08, slDist * 1.6)
        tpText = raw(px * (s == "long" ? 1 + tpDist : 1 - tpDist))
        slText = raw(px * (s == "long" ? 1 - slDist : 1 + slDist))
        autoLevels = tpText + "|" + slText
        defaultsFor = coin
    }

    private func pick(_ c: String) {
        withAnimation(.smooth(duration: 0.25)) {
            coin = c
            candles = []; chartState = .loading; candlesSaved = nil; book = nil; prints = []; bookState = .loading
            rangeLevels = []; limitText = ""; positionError = nil
            lev = min(lev, Double(feed.perps[c]?.maxLev ?? 10))
            setDefaults(side)
        }
    }
}

/// Bordered pill for the market picker with a hover wash.
struct TradePickerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TradeHover { h in
            configuration.label.foregroundStyle(Theme.text)
                .background(configuration.isPressed || h ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The picker's menu: the featured markets, or a search over every Hyperliquid perp. Market / Price / 24h / Funding.
struct TradeMarketMenu: View {
    let current: String
    /// iPhone sheet: full height, every market by volume, bigger rows, no keyboard until the field is tapped.
    var sheet = false
    let onPick: (TradeData.Perp) -> Void
    @State private var q = ""
    @FocusState private var focused: Bool
    private var feed: MarketFeed { .shared }

    var body: some View {
        let list: [TradeData.Perp] = q.isEmpty
            ? (sheet ? Array(feed.perps.values.sorted { $0.vol > $1.vol }.prefix(80)) : TradeData.featuredPerps.compactMap { feed.perps[$0] })
            : Array(feed.perps.values.filter { $0.sym.localizedCaseInsensitiveContains(q) }.sorted { $0.vol > $1.vol }.prefix(30))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField("Search \(feed.perps.isEmpty ? "" : "\(feed.perps.count) ")markets", text: $q).textFieldStyle(.plain).font(.system(size: sheet ? 16 : 13.5)).focused($focused)
                    .autocorrectionDisabled()
                    .onSubmit { if let f = list.first { onPick(f) } }
            }
            .padding(.horizontal, sheet ? 14 : 10).padding(.vertical, sheet ? 12 : 9)
            .background(sheet ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottom) { if !sheet { Rectangle().fill(Theme.border).frame(height: 1) } }
            .padding(.bottom, sheet ? 10 : 4)
            .padding(.top, sheet ? 14 : 0)
            row(cells: [Text("Market"), Text("Price"), Text("24h"), Text("Funding")]).font(.system(size: 12)).foregroundStyle(Theme.hint)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { m in
                        Button { onPick(m) } label: {
                            row(cells: [
                                Text(""), Text("$" + m.px.tradePx),
                                Text(m.ch.tradePct).foregroundStyle(m.ch >= 0 ? Theme.green : Theme.red),
                                Text(m.fundPct.tradeTrim(4) + "%").foregroundStyle(Theme.muted),
                            ], lead: m)
                            .font(.system(size: sheet ? 14.5 : 13)).monospacedDigit()
                            .padding(.vertical, sheet ? 4 : 0)
                            .background(m.coin == current ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TradeMenuRow())
                    }
                }
            }
            .frame(maxHeight: sheet ? .infinity : 360)
            if feed.perps.isEmpty {
                MarketStatus(kind: feed.perpState == .failed ? .failed("Couldn't reach Hyperliquid") : .loading("Loading markets")).padding(.horizontal, 10)
            } else if list.isEmpty {
                Text("No markets").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(16)
            }
        }
        .padding(sheet ? 14 : 6)
        .frame(width: sheet ? nil : 380)
        .frame(maxWidth: sheet ? .infinity : nil, maxHeight: sheet ? .infinity : nil, alignment: .top)
        .background(Theme.bg)
        .onAppear { if !sheet { focused = true } }
    }

    private func row(cells: [Text], lead: TradeData.Perp? = nil) -> some View {
        HStack(spacing: 8) {
            Group {
                if let m = lead {
                    HStack(spacing: 8) {
                        MarketLogo(key: TradeData.logo(m.sym), name: m.sym, size: sheet ? 24 : 18)
                        Text(m.sym).foregroundStyle(Theme.text)
                        if m.coin.hasPrefix("xyz:") { Text("trade.xyz").font(.system(size: 11.5)).foregroundStyle(Theme.hint) }
                    }
                } else { cells[0] }
            }
            .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1.6)
            cells[1].frame(width: 82, alignment: .trailing)
            cells[2].frame(width: 56, alignment: .trailing)
            cells[3].frame(width: 62, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

struct TradeMenuRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TradeHover { h in
            configuration.label.foregroundStyle(Theme.text)
                .background(configuration.isPressed || h ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: Spot

/// Spot on Solana: every liquid, verified token on Jupiter, bought from the wallet.
struct TradeSpot: View { var body: some View { SolanaSwapScreen(memes: false) } }

// MARK: Memes

/// Memes on Solana: Jupiter's verified meme coins, bought from the wallet.
struct TradeMemes: View { var body: some View { SolanaSwapScreen(memes: true) } }

// MARK: Predictions

/// The busiest open Polymarket markets, with live odds. Read-only: a row opens the market on Polymarket, and betting
/// from Hermit says Coming soon.
struct TradePredictions: View {
    private var feed: MarketFeed { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if feed.predictions.isEmpty {
                switch feed.predState {
                case .failed: MarketStatus(kind: .failed("Couldn't reach Polymarket")) { Task { await feed.refreshPredictions() } }
                case .ready: MarketStatus(kind: .empty("No open markets right now"))
                case .loading: MarketStatus(kind: .loading("Loading markets"))
                }
            }
            TradeRows(data: feed.predictions) { m in
                if let url = URL(string: "https://polymarket.com/event/\(m.slug)"), !m.slug.isEmpty {
                    Link(destination: url) { row(m) }.buttonStyle(TradeRowButton())
                } else {
                    row(m)
                }
            }
            if !feed.predictions.isEmpty {
                HStack {
                    MarketSource(text: (feed.predsUpdated.flatMap { Date().timeIntervalSince($0) > 180 ? "Odds from Polymarket, \(Freshness.ago($0))" : nil }
                                        ?? "Live odds from Polymarket") + ", busiest first. Tap one to open it on Polymarket. Betting from Hermit: Coming soon.")
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .marketPoll(every: 60) { await feed.refreshPredictions() }
    }

    private func row(_ m: TradeData.Prediction) -> some View {
        // Green and red only for Yes and No; two teams or names aren't good and bad.
        let yesNo = m.outcomes.map { $0.lowercased() } == ["yes", "no"]
        return HStack(alignment: .top, spacing: 12) {
            LogoMark("Polymarket", size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(m.q).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let e = m.ends { Text("Ends \(e.formatted(.dateTime.month(.abbreviated).day()))") }
                    Spacer()
                    Text("\(m.vol24.tradeCompactUSD) 24h").monospacedDigit()
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 4)
                Capsule().fill(yesNo ? TradeColor.redSoft : Theme.hover).frame(height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(yesNo ? Theme.green : Theme.text.opacity(0.55)).scaleEffect(x: m.prices[0], anchor: .leading)
                    }
                    .padding(.top, 8)
                HStack(spacing: 14) {
                    Text("\(m.outcomes[0]) \(cents(m.prices[0]))").foregroundStyle(yesNo ? Theme.green : Theme.text)
                    Text("\(m.outcomes[1]) \(cents(m.prices[1]))").foregroundStyle(yesNo ? Theme.red : Theme.muted)
                }
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 12)
    }

    private func cents(_ p: Double) -> String { "\(Int((p * 100).rounded()))¢" }
}


/// The number beside a slider, typeable: click or tap it, type, then Return (or tab away). It's clamped to the
/// slider's range and snapped to its step, so what you type is always a valid order.
struct TradeTypedValue: View {
    var prefix = ""
    var suffix = ""
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: String { step >= 1 ? value.tradeGrouped() : String(format: "%.2f", value) }
    private var plain: String { step >= 1 ? String(Int(value.rounded())) : String(format: "%.2f", value) }

    var body: some View {
        HStack(spacing: 1) {
            if !prefix.isEmpty { Text(prefix) }
            TextField("", text: $text)
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .frame(width: CGFloat(max(2, text.count)) * 8.5 + 8)
                .focused($focused)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if f { text = plain } else { commit() } }
            if !suffix.isEmpty { Text(suffix) }
        }
        .fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.text)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(focused ? Theme.bg : Theme.hover.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Theme.text.opacity(0.3) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { text = shown }
        .onChange(of: value) { _, _ in if !focused { text = shown } }
        .help("Type a value")
        .accessibilityLabel("\(prefix)\(shown)\(suffix). Editable.")
    }

    private func commit() {
        let t = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)
        if let v = AmountText.value(t) { value = min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step)) }
        text = shown
    }
}
