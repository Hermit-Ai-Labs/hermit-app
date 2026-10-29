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

/// Hyperliquid-style terminal with Hermit built in: market picker and stats, Hermit actions, candles with TP/entry/SL,
/// order book and trades, and the order form.
struct TradeTerminal: View {
    @Environment(AppModel.self) private var model
    private var store: TradeEarnStore { .shared }

    @State private var mkt = TradeData.perps[3]
    @State private var pickOpen = false
    @State private var venue = "Best price"
    @State private var tf = "1H"
    @State private var side = "long"
    @State private var type = "Market"
    @State private var lev: Double = 5
    @State private var margin: Double = 500
    @State private var tpText = ""
    @State private var slText = ""
    @State private var limitText = ""
    @State private var panel = "book"
    @State private var aiLevels: [TradeLevel] = []
    @State private var answer: (q: String, a: String)?
    @State private var ask = ""
    @State private var width: CGFloat = 1000

    private var wide: Bool { width >= 760 }
    private var dp: Int { mkt.dp }
    private var route: String { mkt.venue ?? (venue == "Best price" ? "Hyperliquid" : venue) }
    private var tp: Double { Double(tpText.replacingOccurrences(of: ",", with: "")) ?? mkt.px }
    private var sl: Double { Double(slText.replacingOccurrences(of: ",", with: "")) ?? mkt.px }
    private var liq: Double { side == "long" ? mkt.px * (1 - 0.9 / lev) : mkt.px * (1 + 0.9 / lev) }
    private var size: Double { margin * lev }
    private var gain: Double { abs(tp - mkt.px) / mkt.px * size }
    private var loss: Double { abs(sl - mkt.px) / mkt.px * size }
    private func fmt(_ v: Double) -> String { v.tradeGrouped(dp) }
    private func raw(_ v: Double) -> String { String(format: "%.\(dp)f", v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            hermitBar
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 22) { chart; book }
                        .frame(maxWidth: .infinity)
                    form.frame(width: 300)
                }
                .padding(.top, 6)
            } else {
                VStack(alignment: .leading, spacing: 22) { chart; form; book }.padding(.top, 6)
            }
        }
        .tradeWidth($width)
        .onAppear { if tpText.isEmpty { setDefaults(side) } }
    }

    // MARK: Header: market picker and stats

    private var header: some View {
        let stats: [(String, String, Color)] = [
            ("Mark", "$" + fmt(mkt.px), Theme.text), ("24h", mkt.ch.tradePct, mkt.ch >= 0 ? Theme.green : Theme.red),
            ("Volume", mkt.vol, Theme.text), ("Open interest", mkt.oi, Theme.text),
            ("Funding", mkt.fund.tradeTrim(4) + "%", mkt.fund >= 0 ? Theme.green : Theme.red), ("Venue", route, Theme.text),
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
            Text(s.1).font(.system(size: 13.5, weight: .medium)).monospacedDigit().foregroundStyle(s.2).lineLimit(1)
                .contentTransition(.numericText())
        }
        .fixedSize()
    }

    private var picker: some View {
        Button { pickOpen.toggle() } label: {
            HStack(spacing: 8) {
                LogoMark(mkt.sym, size: 22)
                Text("\(mkt.sym)-USD").font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(pickOpen ? 180 : 0))
            }
            .padding(.leading, 6).padding(.trailing, 11).frame(height: 38)
        }
        .buttonStyle(TradePickerStyle())
        .fixedSize()
        .popover(isPresented: $pickOpen, arrowEdge: .bottom) {
            TradeMarketMenu(current: mkt.sym) { m in pick(m, side) ; pickOpen = false }
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Hermit actions

    private var hermitBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                TradeSpark().padding(.top, 2)
                TradeFlow {
                    ForEach(["Draw key levels", "Why is it moving?", "Plan a trade", "Size to 1% risk"], id: \.self) { q in
                        Button(q) { runHermit(q) }.buttonStyle(TradeChip(on: answer?.q == q))
                    }
                }
            }
            .padding(.vertical, 12)
            if let answer {
                VStack(alignment: .leading, spacing: 3) {
                    Text(answer.q).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.accent)
                    Text(answer.a).font(.system(size: 13.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(TradeColor.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 14)
                .id(answer.q + mkt.sym)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.smooth(duration: 0.3), value: answer?.q)
    }

    private func runHermit(_ q: String) {
        let p = mkt.px
        var a = ""
        withAnimation(.smooth(duration: 0.3)) {
            switch q {
            case "Draw key levels":
                let s = p * 0.93, r = p * 1.085
                aiLevels = [TradeLevel(value: s, label: "Support \(raw(s))", color: TradeColor.support),
                            TradeLevel(value: r, label: "Resistance \(raw(r))", color: TradeColor.resistance)]
                a = "Support at $\(raw(s)) (last week's breakout), resistance at $\(raw(r)) (October high). Both are on the chart."
            case "Why is it moving?":
                a = mkt.ch >= 0
                    ? "\(mkt.sym) is up \(mkt.ch.tradeTrim())% on rising open interest and positive funding (\(mkt.fund.tradeTrim(4))%/h). Longs are paying, so the move is crowded. Late longs risk a flush back to support."
                    : "\(mkt.sym) is down \(abs(mkt.ch).tradeTrim())%. Funding turned negative, so shorts are paying. Spot selling, not liquidations, is driving it."
            case "Plan a trade":
                side = "long"; lev = 3
                tpText = raw(p * 1.08); slText = raw(p * 0.925)
                aiLevels = [TradeLevel(value: p * 0.93, label: "Support", color: TradeColor.support)]
                a = "Long at 3x with a stop just under support and take-profit below resistance. Risk is about 1% of your trading balance. I filled the order form; check it and tap Long."
            default:
                margin = 460; lev = 4
                a = "Risking $140 (1% of $14,010) with your stop 8% away means $1,750 size: $460 margin at about 4x. Margin is set."
            }
            answer = (q, a)
        }
    }

    // MARK: Chart

    private var levels: [TradeLevel] {
        [TradeLevel(value: tp, label: "TP \(tpText)", color: Theme.green),
         TradeLevel(value: mkt.px, label: "Entry \(mkt.px.tradeTrim(2))", color: Theme.text),
         TradeLevel(value: sl, label: "SL \(slText)", color: Theme.red)] + aiLevels
    }

    private var chart: some View {
        let t = TradeData.timeframes.first { $0.0 == tf }!
        let seed = Int(mkt.sym.unicodeScalars.first!.value) + t.2
        let data = TradeData.candles(54, mkt.px * (1 - t.1 * 4), t.1, seed, mkt.ch > 0 ? 0.06 : -0.03)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Segmented(options: TradeData.timeframes.map { ($0.0, $0.0) }, selection: $tf)
                Spacer(minLength: 8)
                Menu {
                    Picker("Venue", selection: $venue) {
                        ForEach(["Best price"] + TradeData.venues, id: \.self) { v in
                            if v == "Best price" { Text(v).tag(v) } else { Label { Text(v) } icon: { LogoMark(v, size: 16) }.tag(v) }
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 6) {
                        if mkt.venue != nil || venue != "Best price" { LogoMark(route, size: 16) }
                        Text(mkt.venue ?? venue).font(.system(size: 13))
                        Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 11).frame(height: 30)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()
                .disabled(mkt.venue != nil)
            }
            TradeCandleChart(data: data, levels: levels, padTo: [tp, sl], decimals: dp)
                .frame(height: 280)
                .id(mkt.sym + tf)
                .transition(.opacity)
                .animation(.smooth(duration: 0.25), value: tf)
        }
    }

    // MARK: Order book and trades

    private struct Level { let px, sz: Double }
    private var bookData: (asks: [Level], bids: [Level], max: Double) {
        let seed = Double(mkt.sym.unicodeScalars.first!.value)
        func r(_ i: Double) -> Double { (sin(seed * 9.3 + i * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) }
        let px = mkt.px
        let tick = px > 1000 ? px * 0.0001 : px > 50 ? px * 0.0002 : px * 0.0004
        func lvl(_ side: Double, _ i: Int) -> Level {
            Level(px: px + side * tick * (Double(i) + 0.5), sz: ((abs(r(Double(i) * side + 3)) * 40 + 4) * 10).rounded() / 10)
        }
        let asks = (0..<7).map { lvl(1, $0) }.reversed() as [Level]
        let bids = (0..<7).map { lvl(-1, $0) }
        return (asks, bids, (asks + bids).map(\.sz).max() ?? 1)
    }
    private var bdp: Int { mkt.px >= 10000 ? 0 : mkt.px >= 1000 ? 1 : mkt.px >= 100 ? 2 : 3 }

    private var book: some View {
        let ob = bookData
        return VStack(alignment: .leading, spacing: 10) {
            Segmented(options: [("book", "Order book"), ("trades", "Trades")], selection: $panel)
            VStack(spacing: 0) {
                if panel == "book" {
                    bookHead(["Price", "Size (\(mkt.sym))"])
                    ForEach(Array(ob.asks.enumerated()), id: \.offset) { _, a in bookRow(a, sell: true, max: ob.max) }
                    HStack(spacing: 6) {
                        Text(fmt(mkt.px)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        Text("spread " + String(format: "%.3f%%", (ob.asks[6].px - ob.bids[0].px) / mkt.px * 100))
                            .font(.system(size: 12)).foregroundStyle(Theme.faint)
                        Spacer()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 7)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    .padding(.vertical, 3)
                    ForEach(Array(ob.bids.enumerated()), id: \.offset) { _, b in bookRow(b, sell: false, max: ob.max) }
                } else {
                    bookHead(["Price", "Size", "Time"])
                    ForEach(Array((ob.bids + ob.asks).prefix(12).enumerated()), id: \.offset) { i, t in
                        HStack {
                            Text(t.px.tradeGrouped(bdp)).foregroundStyle(i % 3 != 0 ? Theme.green : Theme.red).frame(maxWidth: .infinity, alignment: .leading)
                            Text(t.sz.tradeTrim(1)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("15:" + String(format: "%02d", 42 - i)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.system(size: 12.5)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 3)
                    }
                }
            }
            .transition(.opacity)
            .id(panel)
        }
    }

    private func bookHead(_ cols: [String]) -> some View {
        HStack {
            ForEach(Array(cols.enumerated()), id: \.offset) { i, c in
                Text(c).frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.faint).padding(.horizontal, 6).padding(.vertical, 3)
    }

    private func bookRow(_ l: Level, sell: Bool, max: Double) -> some View {
        HStack {
            Text(l.px.tradeGrouped(bdp)).foregroundStyle(sell ? Theme.red : Theme.green)
            Spacer()
            Text(l.sz.tradeTrim(1))
        }
        .font(.system(size: 12.5)).monospacedDigit()
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 2).fill(sell ? TradeColor.redSoft : TradeColor.greenSoft)
                .padding(.vertical, 1)
                .scaleEffect(x: l.sz / max, anchor: .trailing)
        }
    }

    // MARK: Order form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            TradeWideSegmented(options: ["Market", "Limit"], selection: $type)
            HStack(spacing: 6) {
                sideButton("long", "Long", Theme.green)
                sideButton("short", "Short", Theme.red)
            }
            if type == "Limit" {
                field("Limit price", color: Theme.muted) { TradeField(placeholder: raw(mkt.px), text: $limitText) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            slider("Margin", value: "$" + margin.tradeGrouped(), binding: $margin, range: 50...5000, step: 10)
            slider("Leverage", value: "\(Int(lev))x", binding: $lev, range: 1...25, step: 1)
            HStack(spacing: 12) {
                field("Take profit", color: Theme.green) { TradeField(placeholder: "", text: $tpText) }
                field("Stop loss", color: Theme.red) { TradeField(placeholder: "", text: $slText) }
            }
            TradeTx(lines: [
                ("Size", AnyView(Text("$" + size.tradeGrouped()).contentTransition(.numericText()))),
                ("At TP / SL", AnyView(Text("\(Text("+$" + gain.tradeGrouped()).foregroundStyle(Theme.green)) / \(Text("−$" + loss.tradeGrouped()).foregroundStyle(Theme.red))"))),
                ("Liquidation", AnyView(Text("$" + fmt(liq)))),
                ("Risk", AnyView(Text(String(format: "%.1f%% of balance", loss / TradeData.balance * 100)))),
            ])
            if lev > 10 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Theme.amber).padding(.top, 1)
                    Text("A \(String(format: "%.1f", 90 / lev))% move liquidates you. 5x or less is safer.").font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TradeColor.amberSoft, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            Button(action: placeOrder) {
                Label("\(side == "long" ? "Long" : "Short") \(mkt.sym)", systemImage: "touchid")
            }
            .buttonStyle(TradeBlockButton(color: side == "long" ? Theme.green : Theme.red))
            .keyboardShortcut(.return, modifiers: .command)
            askField
        }
        .animation(.snappy(duration: 0.25), value: type)
        .animation(.snappy(duration: 0.25), value: lev > 10)
    }

    private func sideButton(_ s: String, _ title: String, _ color: Color) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { pick(mkt, s) } } label: {
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
                Text(value).fontWeight(.semibold).monospacedDigit().contentTransition(.numericText())
            }
            .font(.system(size: 12.5))
            Slider(value: binding, in: range, step: step).tint(Theme.text).controlSize(.small)
        }
    }

    private var askField: some View {
        HStack(spacing: 6) {
            TextField("Ask Hermit about \(mkt.sym)", text: $ask).textFieldStyle(.plain).font(.system(size: 13))
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

    private func setDefaults(_ s: String) {
        tpText = raw(mkt.px * (s == "long" ? 1.14 : 0.86))
        slText = raw(mkt.px * (s == "long" ? 0.92 : 1.08))
    }

    private func pick(_ m: TradeData.Perp, _ s: String) {
        withAnimation(.smooth(duration: 0.25)) {
            mkt = m; side = s
            setDefaults(s)
            aiLevels = []; answer = nil; limitText = ""
        }
    }

    private func placeOrder() {
        let title = "\(side == "long" ? "Long" : "Short") \(mkt.sym) \(Int(lev))x"
        let a = Approval(kind: "Perp order on \(route)", title: title,
                         lines: [["Type", type], ["Margin", "$" + margin.tradeGrouped()], ["Size", "$" + size.tradeGrouped()],
                                 ["Take profit", "$" + tpText], ["Stop loss", "$" + slText], ["Liquidation", "$" + fmt(liq)]],
                         checks: tradeChecks([lev > 10 ? "Leverage over your 10x limit" : "Leverage within your limit", "Stop triggers before liquidation"]),
                         success: "Order filled",
                         receipt: .receipt(title: title, rows: [["Venue", route], ["Entry", "$" + fmt(mkt.px)], ["Size", "$" + size.tradeGrouped()], ["Stop", "$" + slText]]))
        let pos = TradeData.Position(sym: mkt.sym, title: "\(mkt.sym)-PERP", side: "\(side == "long" ? "Long" : "Short") \(Int(lev))x",
                                     entry: mkt.px, mark: mkt.px, liq: (liq * pow(10, Double(dp))).rounded() / pow(10, Double(dp)),
                                     tp: tp, sl: sl, pnl: 0, by: "You", when: "just now")
        store.approve(model, a, toast: "\(title) filled. See Positions") { store.positions.insert(pos, at: 0) }
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

/// The picker's menu: search, then Market / Price / 24h / Funding.
struct TradeMarketMenu: View {
    let current: String
    let onPick: (TradeData.Perp) -> Void
    @State private var q = ""
    @FocusState private var focused: Bool

    var body: some View {
        let list = TradeData.perps.filter { q.isEmpty || $0.sym.localizedCaseInsensitiveContains(q) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField("Search markets", text: $q).textFieldStyle(.plain).font(.system(size: 13.5)).focused($focused)
                    .onSubmit { if let f = list.first { onPick(f) } }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .padding(.bottom, 4)
            row(cells: [Text("Market"), Text("Price"), Text("24h"), Text("Funding")]).font(.system(size: 12)).foregroundStyle(Theme.faint)
            ForEach(list) { m in
                Button { onPick(m) } label: {
                    row(cells: [
                        Text(""), Text("$" + m.px.tradeTrim(2)),
                        Text(m.ch.tradePct).foregroundStyle(m.ch >= 0 ? Theme.green : Theme.red),
                        Text(m.fund.tradeTrim(4) + "%").foregroundStyle(Theme.muted),
                    ], lead: m)
                    .font(.system(size: 13)).monospacedDigit()
                    .background(m.sym == current ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(TradeMenuRow())
            }
            if list.isEmpty { Text("No markets").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(16) }
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
                        LogoMark(m.sym, size: 18)
                        Text(m.sym).foregroundStyle(Theme.text)
                        if let v = m.venue { Text(v).font(.system(size: 11.5)).foregroundStyle(Theme.faint) }
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

struct TradeSpot: View {
    @Environment(AppModel.self) private var model
    private var store: TradeEarnStore { .shared }
    @State private var to = TradeData.spot[0]
    @State private var amtText = "1000"
    @State private var width: CGFloat = 900

    private var amt: Double { Double(amtText.replacingOccurrences(of: ",", with: "")) ?? 0 }
    private var out: String { let o = amt / to.px; return o < 1 ? String(format: "%.4f", o) : o.tradeTrim(2) }

    var body: some View {
        Group {
            if width >= 680 {
                HStack(alignment: .top, spacing: 32) { list.frame(maxWidth: .infinity); swap.frame(maxWidth: .infinity) }
            } else {
                VStack(spacing: 24) { list; swap }
            }
        }
        .tradeWidth($width)
    }

    private var list: some View {
        TradeRows(data: TradeData.spot) { t in
            let i = TradeData.spot.firstIndex(of: t) ?? 0
            Button { withAnimation(.snappy) { to = t } } label: {
                HStack(spacing: 12) {
                    LogoMark(t.sym, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        Text(t.sym).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    if width >= 420 { TradeMiniCandles(data: TradeData.candles(22, t.px, 0.03, 70 + i, t.ch > 0 ? 0.05 : -0.04)) }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$" + t.px.tradeTrim(2)).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Text(t.ch.tradePct).font(.system(size: 12.5)).foregroundStyle(t.ch >= 0 ? Theme.green : Theme.red)
                    }
                    .monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                        .opacity(to == t ? 1 : 0)
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(TradeRowButton())
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
                    box("You receive") {
                        Text(out).font(.system(size: 24, weight: .semibold)).monospacedDigit().lineLimit(1)
                            .contentTransition(.numericText()).frame(maxWidth: .infinity, alignment: .leading)
                        token(to.sym)
                    }
                }
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28).background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            HStack {
                Text("Best route across 6 DEXs")
                Spacer()
                Text("Fee $0.04")
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.horizontal, 2).padding(.vertical, 4)
            Button(action: doSwap) { Label("Swap", systemImage: "touchid") }
                .buttonStyle(TradeBlockButton(color: Theme.text))
                .disabled(amt <= 0)
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
        HStack(spacing: 6) { LogoMark(s, size: 20); Text(s).font(.system(size: 14, weight: .medium)) }.fixedSize()
    }

    private func doSwap() {
        let routeName = to.sym == "SOL" ? "Jupiter" : to.sym == "HYPE" ? "Hyperliquid" : "Uniswap via 1inch"
        let pay = amt.tradeTrim(2) + " USDC"
        let a = Approval(kind: "Swap", title: "Buy \(to.sym)",
                         lines: [["Pay", pay], ["Receive", "≈ \(out) \(to.sym)"], ["Route", routeName], ["Price impact", "0.02%"]],
                         checks: tradeChecks(), success: "Bought \(out) \(to.sym)",
                         receipt: .receipt(title: "Bought \(out) \(to.sym)", rows: [["Paid", pay], ["Price", "$" + to.px.tradeTrim(2)], ["Wallet", "Main"]]))
        store.approve(model, a)
    }
}

// MARK: Memes

struct TradeMemes: View {
    @Environment(AppModel.self) private var model
    private var store: TradeEarnStore { .shared }
    @State private var sel = TradeData.memes[0]
    @State private var width: CGFloat = 900

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeRows(data: TradeData.memes) { m in row(m) }
            let wide = width >= 640
            let grid = wide ? [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), alignment: .top)] : [GridItem(.flexible())]
            LazyVGrid(columns: grid, alignment: .leading, spacing: 28) {
                TradeSection(title: "\(sel.sym) holders", top: 0) { holders }
                TradeSection(title: "Hermit's take", top: 0) {
                    Text(take).font(.system(size: 14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 36)
            .animation(.smooth(duration: 0.3), value: sel)
        }
        .tradeWidth($width)
    }

    private func row(_ m: TradeData.Meme) -> some View {
        let i = TradeData.memes.firstIndex(of: m) ?? 0
        return Button { withAnimation(.smooth(duration: 0.3)) { sel = m } } label: {
            HStack(spacing: 12) {
                LogoMark(m.sym, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(m.sym).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        HStack(spacing: 5) { Circle().fill(m.color).frame(width: 6, height: 6); Text(m.label) }
                            .font(.system(size: 12)).foregroundStyle(m.color)
                    }
                    Text("\(m.holders) holders").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                if width >= 480 { TradeMiniCandles(data: TradeData.candles(22, 1, 0.08, 40 + i, m.ch > 0 ? 0.08 : -0.06)) }
                Text(m.ch.tradePct).font(.system(size: 14)).monospacedDigit().foregroundStyle(m.ch >= 0 ? Theme.green : Theme.red)
                    .frame(minWidth: 56, alignment: .trailing)
                Button("Buy") { buy(m) }.buttonStyle(TradeSmallButton()).disabled(m.score == .fail)
            }
            .padding(.vertical, 12)
            .background(alignment: .leading) {
                if sel == m { Capsule().fill(Theme.text).frame(width: 3, height: 22).offset(x: -10) }
            }
        }
        .buttonStyle(TradeRowButton())
    }

    private var holders: some View {
        let clusters: [TradeBubbleMap.Cluster] = sel.score == .fail
            ? [.init(x: 0.35, y: 0.5, n: 14, size: 34, color: Theme.red, label: "Dev-linked 61%"), .init(x: 0.75, y: 0.45, n: 4, size: 12, color: Theme.amber, label: "Snipers 8%")]
            : [.init(x: 0.22, y: 0.45, n: 8, size: 26, color: Theme.text, label: "Exchanges"), .init(x: 0.55, y: 0.5, n: 6, size: 16, color: Theme.green, label: "Smart money"),
               .init(x: 0.82, y: 0.45, n: 4, size: 12, color: Color(hex: 0x8E73CF), label: "Team")]
        return VStack(alignment: .leading, spacing: 10) {
            TradeBubbleMap(seed: sel.sym.count * 3, clusters: clusters).id(sel.sym).transition(.opacity)
            TradeFlow(spacing: 16) {
                ForEach(clusters, id: \.label) { c in
                    HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(c.color).frame(width: 10, height: 10); Text(c.label) }
                        .font(.system(size: 12.5))
                }
            }
        }
    }

    private var take: AttributedString {
        let s: String = switch sel.score {
        case .fail: "Avoid. **61% of supply sits with deployer-funded wallets**, and liquidity is unlocked. Automations won't buy it."
        case .warn: "Crowded. The top 10 hold 38% and KOLs are selling. Keep it small."
        case .pass: "Healthy holders and deep liquidity. KOLs have pushed it, so expect swings."
        }
        return (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    private func buy(_ m: TradeData.Meme) {
        let a = Approval(kind: "Swap", title: "Buy $100 of \(m.sym)", lines: [["Pay", "100 USDC"], ["Route", "Jupiter"], ["Take profit", "2x"]],
                         checks: tradeChecks([m.score == .warn ? "Holder concentration: top 10 hold 38%" : "Holder concentration"]),
                         success: "Bought \(m.sym)")
        store.approve(model, a)
    }
}

// MARK: Predictions

struct TradePredictions: View {
    @Environment(AppModel.self) private var model
    private var store: TradeEarnStore { .shared }

    var body: some View {
        TradeRows(data: TradeData.predictions) { m in
            HStack(alignment: .top, spacing: 12) {
                LogoMark(m.venue, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.q).font(.system(size: 14, weight: .medium)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("\(m.venue), ends \(m.ends)")
                        Spacer()
                        Text(m.vol).monospacedDigit()
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 4)
                    Capsule().fill(Theme.hover).frame(height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.green).scaleEffect(x: Double(m.yes) / 100, anchor: .leading)
                        }
                        .padding(.top, 8)
                    HStack(spacing: 8) {
                        Button("Yes \(m.yes)¢") { bet(m, "Yes") }.buttonStyle(TradeSmallButton(kind: .tint(Theme.green)))
                        Button("No \(100 - m.yes)¢") { bet(m, "No") }.buttonStyle(TradeSmallButton(kind: .tint(Theme.red)))
                    }
                    .padding(.top, 10)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func bet(_ m: TradeData.Prediction, _ side: String) {
        let price = side == "Yes" ? m.yes : 100 - m.yes
        let a = Approval(kind: "Prediction on \(m.venue)", title: "\(side) on \"\(m.q)\"",
                         lines: [["Stake", "100 USDC"], ["Price", "\(price)¢"], ["Pays if right", "$\(Int((10000 / Double(price)).rounded()))"], ["Resolves", m.ends]],
                         checks: tradeChecks(["Market resolution source checked"]), success: "Position placed")
        store.approve(model, a)
    }
}
