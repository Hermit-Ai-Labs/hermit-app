import SwiftUI
import HermitCore

/// Markets: one segmented switch for the market type, then the matching screen, then Explore more.
struct TradeMarkets: View {
    @State private var kind = "perps"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Segmented(options: [("perps", "Perps"), ("spot", "Spot"), ("memes", "Memes"), ("predict", "Predictions")], selection: $kind)
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
/// the live order book and trades, and the order form (greyed until trading is wired to an exchange).
struct TradeTerminal: View {
    @Environment(AppModel.self) private var model
    private var feed: MarketFeed { .shared }

    @State private var coin = "HYPE"
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
    @State private var book: TradeData.Book?
    @State private var prints: [TradeData.Print] = []
    @State private var bookState: FeedState = .loading

    private var mkt: TradeData.Perp? { feed.perps[coin] }
    private var sym: String { coin.split(separator: ":").last.map(String.init) ?? coin }
    private var px: Double { mkt?.px ?? 0 }
    private var wide: Bool { width >= 760 }
    private func parse(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")).flatMap { $0 > 0 ? $0 : nil } }
    private var tp: Double? { parse(tpText) }
    private var sl: Double? { parse(slText) }
    private var liq: Double { side == "long" ? px * (1 - 0.9 / lev) : px * (1 + 0.9 / lev) }
    private var size: Double { margin * lev }
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
                    form.frame(width: 300)
                }
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 22) { chart; form; bookPanel }.padding(.top, 6)
            }
        }
        .tradeWidth($width)
        .marketPoll(every: 15) { await feed.refreshPerps() }
        .marketPoll(every: 30, id: coin + tf) { await loadCandles() }
        .marketPoll(every: 5, id: coin) { await loadBook() }
        .onChange(of: mkt?.px != nil, initial: true) { _, has in if has && defaultsFor != coin { setDefaults(side) } }
        .onChange(of: tf) { candles = []; chartState = .loading; rangeLevels = [] }
    }

    // MARK: Header: market picker and stats

    private var header: some View {
        let m = mkt
        let stats: [(String, String, Color)] = [
            ("Mark", m.map { "$" + $0.px.tradePx } ?? "—", Theme.text),
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
            Text(s.0).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
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
        .popover(isPresented: $pickOpen, arrowEdge: .bottom) {
            TradeMarketMenu(current: coin) { m in pick(m.coin); pickOpen = false }
                .presentationCompactAdaptation(.popover)
        }
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
                if width >= 440 { MarketSource(text: "Hyperliquid candles") }
            }
            Group {
                if !candles.isEmpty {
                    TradeCandleChart(data: candles, levels: levels, padTo: [tp, sl].compactMap { $0 })
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

    private func loadCandles() async {
        let t = TradeData.timeframes.first { $0.0 == tf } ?? TradeData.timeframes[1]
        let want = coin + tf
        do {
            let c = try await TradeAPI.perpCandles(coin, interval: t.1, seconds: t.2)
            guard want == coin + tf else { return }
            candles = c; chartState = .ready
        } catch {
            if candles.isEmpty { chartState = .failed }
        }
    }

    // MARK: Order book and trades

    private func loadBook() async {
        let want = coin
        async let b = try? TradeAPI.book(want)
        async let p = try? TradeAPI.prints(want)
        let (bk, pr) = await (b, p)
        guard want == coin else { return }
        if let bk { book = bk; bookState = .ready } else if book == nil { bookState = .failed }
        if let pr { prints = pr }
    }

    private var bookPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Segmented(options: [("book", "Order book"), ("trades", "Trades")], selection: $panel).fixedSize()
                Spacer()
                MarketSource(text: "Live from \(coin.hasPrefix("xyz:") ? "trade.xyz" : "Hyperliquid")")
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
                                Text("spread " + String(format: "%.3f%%", (a.px - b.px) / b.px * 100)).font(.system(size: 12)).foregroundStyle(Theme.faint)
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
                                Text(t.time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()).foregroundStyle(Theme.faint)
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
        .font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.horizontal, 6).padding(.vertical, 3)
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

    /// The full form so you can size a trade against live prices. Submitting isn't wired to an exchange yet.
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
            slider("Margin", value: "$" + margin.tradeGrouped(), binding: $margin, range: 50...5000, step: 10)
            slider("Leverage", value: "\(Int(lev))x", binding: $lev, range: 1...Double(max(2, mkt?.maxLev ?? 10)), step: 1)
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
                    Text("A \(String(format: "%.1f", 90 / lev))% move against you liquidates you. 5x or less is safer.").font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TradeColor.amberSoft, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            VStack(spacing: 8) {
                Button {} label: { Text("\(side == "long" ? "Long" : "Short") \(sym)") }
                    .buttonStyle(TradeBlockButton(color: side == "long" ? Theme.green : Theme.red))
                    .disabled(true)
                TradeSoon(text: "Trading opens soon")
            }
            askField
        }
        .animation(.snappy(duration: 0.25), value: type)
        .animation(.snappy(duration: 0.25), value: lev > 10)
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

    private func slider(_ label: String, value: String, binding: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(Theme.muted)
                Spacer()
                Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.text).contentTransition(.numericText())
            }
            .font(.system(size: 12.5))
            Slider(value: binding, in: range, step: step).tint(Theme.text).controlSize(.small)
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
        guard px > 0 else { tpText = ""; slText = ""; return }
        func raw(_ v: Double) -> String { v.formatted(.number.grouping(.never).precision(.fractionLength(0...max(0, px.tradeDecimals)))) }
        tpText = raw(px * (s == "long" ? 1.08 : 0.92))
        slText = raw(px * (s == "long" ? 0.95 : 1.05))
        defaultsFor = coin
    }

    private func pick(_ c: String) {
        withAnimation(.smooth(duration: 0.25)) {
            coin = c
            candles = []; chartState = .loading; book = nil; prints = []; bookState = .loading
            rangeLevels = []; limitText = ""
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
    let onPick: (TradeData.Perp) -> Void
    @State private var q = ""
    @FocusState private var focused: Bool
    private var feed: MarketFeed { .shared }

    var body: some View {
        let list: [TradeData.Perp] = q.isEmpty
            ? TradeData.featuredPerps.compactMap { feed.perps[$0] }
            : Array(feed.perps.values.filter { $0.sym.localizedCaseInsensitiveContains(q) }.sorted { $0.vol > $1.vol }.prefix(30))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField("Search \(feed.perps.isEmpty ? "" : "\(feed.perps.count) ")markets", text: $q).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused)
                    .onSubmit { if let f = list.first { onPick(f) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .padding(.bottom, 4)
            row(cells: [Text("Market"), Text("Price"), Text("24h"), Text("Funding")]).font(.system(size: 12)).foregroundStyle(Theme.faint)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { m in
                        Button { onPick(m) } label: {
                            row(cells: [
                                Text(""), Text("$" + m.px.tradePx),
                                Text(m.ch.tradePct).foregroundStyle(m.ch >= 0 ? Theme.green : Theme.red),
                                Text(m.fundPct.tradeTrim(4) + "%").foregroundStyle(Theme.muted),
                            ], lead: m)
                            .font(.system(size: 13)).monospacedDigit()
                            .background(m.coin == current ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TradeMenuRow())
                    }
                }
            }
            .frame(maxHeight: 360)
            if feed.perps.isEmpty {
                MarketStatus(kind: feed.perpState == .failed ? .failed("Couldn't reach Hyperliquid") : .loading("Loading markets")).padding(.horizontal, 10)
            } else if list.isEmpty {
                Text("No markets").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(16)
            }
        }
        .padding(6)
        .frame(width: 380)
        .background(Theme.bg)
        .onAppear { focused = true }
    }

    private func row(cells: [Text], lead: TradeData.Perp? = nil) -> some View {
        HStack(spacing: 8) {
            Group {
                if let m = lead {
                    HStack(spacing: 8) {
                        MarketLogo(key: TradeData.logo(m.sym), name: m.sym, size: 18)
                        Text(m.sym).foregroundStyle(Theme.text)
                        if m.coin.hasPrefix("xyz:") { Text("trade.xyz").font(.system(size: 11.5)).foregroundStyle(Theme.faint) }
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

// MARK: Token rows (spot and memes)

/// One token: logo, name, mini candles, price and 24h change. The whole row selects it.
struct TradeTokenRow<Trailing: View>: View {
    let token: TradeData.Token
    let selected: Bool
    var showMini = true
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    private var feed: MarketFeed { .shared }

    var body: some View {
        let t = feed.tickers[token.sym]
        Button(action: action) {
            HStack(spacing: 12) {
                MarketLogo(key: TradeData.logo(token.sym), name: token.sym)
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(t.map { "\(token.sym), \($0.vol.tradeCompactUSD) 24h" } ?? token.sym).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if showMini, let c = feed.minis[token.sym], c.count > 2 { TradeMiniCandles(data: c) }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(t.map { "$" + $0.px.tradePx } ?? "—").font(.system(size: 14)).foregroundStyle(t == nil ? Theme.faint : Theme.text)
                    Text(t?.ch.tradePct ?? "—").font(.system(size: 12.5)).foregroundStyle(t == nil ? Theme.faint : t!.ch >= 0 ? Theme.green : Theme.red)
                }
                .monospacedDigit().frame(minWidth: 76, alignment: .trailing)
                trailing()
            }
            .padding(.vertical, 12)
            .background(alignment: .leading) {
                if selected { Capsule().fill(Theme.text).frame(width: 3, height: 22).offset(x: -10) }
            }
        }
        .buttonStyle(TradeRowButton())
    }
}

/// Quiet status for the shared ticker feed: loading, or failed with Retry, or the source once it's in.
struct TradeTickerStatus: View {
    private var feed: MarketFeed { .shared }
    var body: some View {
        if feed.tickers.isEmpty {
            MarketStatus(kind: feed.tickerState == .failed ? .failed("Couldn't load prices") : .loading("Loading prices")) {
                Task { await feed.refreshTickers() }
            }
        }
    }
}

// MARK: Spot

struct TradeSpot: View {
    @State private var to = TradeData.spotTokens[1]
    @State private var amtText = "1000"
    @State private var width: CGFloat = 900
    private var feed: MarketFeed { .shared }

    private var amt: Double { Double(amtText.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private var px: Double? { feed.tickers[to.sym]?.px }
    private var out: String {
        guard let px, px > 0, amt > 0 else { return "—" }
        let o = amt / px
        return o < 1 ? o.formatted(.number.precision(.significantDigits(4))) : o.tradeTrim(4)
    }

    var body: some View {
        Group {
            if width >= 680 {
                HStack(alignment: .top, spacing: 32) { list.frame(maxWidth: .infinity); swap.frame(maxWidth: .infinity) }
            } else {
                VStack(spacing: 24) { list; swap }
            }
        }
        .tradeWidth($width)
        .marketPoll(every: 30) { await feed.refreshTickers() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeTickerStatus()
            TradeRows(data: TradeData.spotTokens.map { TradeRowItem(token: $0) }) { i in
                TradeTokenRow(token: i.token, selected: to == i.token, showMini: width >= 420) { withAnimation(.snappy) { to = i.token } } trailing: { EmptyView() }
            }
            if !feed.tickers.isEmpty { MarketSource(text: "Prices from \(feed.tickerSource)").padding(.top, 8) }
        }
    }

    private var swap: some View {
        VStack(spacing: 8) {
            ZStack {
                VStack(spacing: 8) {
                    box("You pay") {
                        TextField("0", text: $amtText).textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                        token("USDC")
                    }
                    box("You receive, about") {
                        Text(out).font(.system(size: 24, weight: .semibold)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(out == "—" ? Theme.faint : Theme.text)
                            .contentTransition(.numericText()).frame(maxWidth: .infinity, alignment: .leading)
                        token(to.sym)
                    }
                }
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28).background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            HStack {
                Text("1 \(to.sym) = \(px.map { "$" + $0.tradePx } ?? "—")")
                Spacer()
                Text("Before fees and slippage")
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.horizontal, 2).padding(.vertical, 4)
            Button {} label: { Text("Swap") }
                .buttonStyle(TradeBlockButton(color: Theme.text))
                .disabled(true)
            TradeSoon(text: "Swaps open soon")
        }
    }

    private func box<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) { c() }
        }
        .padding(14)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func token(_ s: String) -> some View {
        HStack(spacing: 6) { MarketLogo(key: TradeData.logo(s), name: s, size: 20); Text(s).font(.system(size: 14, weight: .medium)) }.fixedSize()
    }
}

/// TradeRows wants Identifiable rows.
struct TradeRowItem: Identifiable { var id: String { token.sym }; let token: TradeData.Token }

// MARK: Memes

/// Big meme coins with live prices; pick one for its candles and 24h range.
struct TradeMemes: View {
    @Environment(AppModel.self) private var model
    @State private var sel = TradeData.memeTokens[0]
    @State private var candles: [Candle] = []
    @State private var chartState: FeedState = .loading
    @State private var width: CGFloat = 900
    private var feed: MarketFeed { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeTickerStatus()
            TradeRows(data: TradeData.memeTokens.map { TradeRowItem(token: $0) }) { i in
                TradeTokenRow(token: i.token, selected: sel == i.token, showMini: width >= 480) { pick(i.token) } trailing: {
                    Button("Buy") {}.buttonStyle(TradeSmallButton()).disabled(true)
                }
            }
            HStack {
                if !feed.tickers.isEmpty { MarketSource(text: "Prices from \(feed.tickerSource)") }
                Spacer()
                TradeSoon(text: "Buying opens soon").fixedSize()
            }
            .padding(.top, 8)
            detail.padding(.top, 36)
        }
        .tradeWidth($width)
        .marketPoll(every: 30) { await feed.refreshTickers() }
        .marketPoll(every: 60, id: sel.sym) { await loadCandles() }
    }

    private var detail: some View {
        let t = feed.tickers[sel.sym]
        return TradeSection(title: "\(sel.name), 1H candles", top: 0) {
            Button { model.send("What's going on with \(sel.name) (\(sel.sym))?") } label: { Label("Ask Hermit", systemImage: "sparkles") }
                .buttonStyle(TradeSmallButton())
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    if !candles.isEmpty {
                        TradeCandleChart(data: candles).id(sel.sym).transition(.opacity)
                    } else if chartState == .failed {
                        MarketStatus(kind: .failed("Couldn't load candles")) { Task { await loadCandles() } }
                    } else {
                        MarketStatus(kind: .loading("Loading candles"))
                    }
                }
                .frame(height: 220)
                TradeKV(pairs: [("Price", t.map { "$" + $0.px.tradePx } ?? "—"), ("24h high", t.map { "$" + $0.high.tradePx } ?? "—"),
                                ("24h low", t.map { "$" + $0.low.tradePx } ?? "—"), ("24h volume", t?.vol.tradeCompactUSD ?? "—")])
            }
        }
    }

    private func pick(_ t: TradeData.Token) {
        guard t != sel else { return }
        withAnimation(.smooth(duration: 0.3)) { sel = t; candles = []; chartState = .loading }
    }

    private func loadCandles() async {
        let want = sel
        do {
            let c = try await TradeAPI.spotCandles(want, interval: "1h", count: 60)
            guard want == sel else { return }
            candles = c; chartState = .ready
        } catch { if candles.isEmpty { chartState = .failed } }
    }
}

// MARK: Predictions

/// The busiest open Polymarket markets, with live odds.
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
            TradeRows(data: feed.predictions) { m in row(m) }
            if !feed.predictions.isEmpty {
                HStack {
                    MarketSource(text: "Live odds from Polymarket, busiest first")
                    Spacer()
                    TradeSoon(text: "Betting opens soon").fixedSize()
                }
                .padding(.top, 8)
            }
        }
        .marketPoll(every: 60) { await feed.refreshPredictions() }
    }

    private func row(_ m: TradeData.Prediction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LogoMark("Polymarket", size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(m.q).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let e = m.ends { Text("Ends \(e.formatted(.dateTime.month(.abbreviated).day()))") }
                    Spacer()
                    Text("\(m.vol24.tradeCompactUSD) 24h").monospacedDigit()
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 4)
                Capsule().fill(TradeColor.redSoft).frame(height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.green).scaleEffect(x: m.prices[0], anchor: .leading)
                    }
                    .padding(.top, 8)
                HStack(spacing: 8) {
                    Button("\(m.outcomes[0]) \(cents(m.prices[0]))") {}.buttonStyle(TradeSmallButton(kind: .tint(Theme.green)))
                    Button("\(m.outcomes[1]) \(cents(m.prices[1]))") {}.buttonStyle(TradeSmallButton(kind: .tint(Theme.red)))
                }
                .disabled(true)
                .padding(.top, 10)
            }
        }
        .padding(.vertical, 12)
    }

    private func cents(_ p: Double) -> String { "\(Int((p * 100).rounded()))¢" }
}
