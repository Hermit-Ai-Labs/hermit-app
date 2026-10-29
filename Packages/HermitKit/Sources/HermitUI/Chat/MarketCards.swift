import SwiftUI
import HermitCore

/// Candles with a price axis and coloured level lines (stop, entry, target). Prices are always candles.
struct LevelCandles: View {
    let data: [Candle]
    var marks: [ChartMark] = []
    var axis = true

    var body: some View {
        Canvas { ctx, size in
            let levels = marks.map(\.value)
            guard let lo0 = data.map(\.l).min(), let hi0 = data.map(\.h).max() else { return }
            let lo = min(lo0, levels.min() ?? lo0), hi = max(hi0, levels.max() ?? hi0)
            guard hi > lo else { return }
            let pad = (hi - lo) * 0.08, mn = lo - pad, mx = hi + pad
            let axisW: CGFloat = axis ? 44 : 0
            let plotW = size.width - axisW
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((v - mn) / (mx - mn))) }
            if axis {
                for k in 0..<4 {
                    let v = mn + (mx - mn) * (Double(k) + 0.5) / 4
                    var grid = Path(); grid.move(to: CGPoint(x: 0, y: y(v))); grid.addLine(to: CGPoint(x: plotW, y: y(v)))
                    ctx.stroke(grid, with: .color(Theme.border), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    ctx.draw(Text(Self.label(v, span: mx - mn)).font(.system(size: 10)).foregroundStyle(Theme.faint),
                             at: CGPoint(x: size.width, y: y(v)), anchor: .trailing)
                }
            }
            let w = plotW / CGFloat(data.count), bw = max(1, w * 0.6)
            for (i, k) in data.enumerated() {
                let x = w * (CGFloat(i) + 0.5), up = k.c >= k.o, col = up ? Theme.green : Theme.red
                var wick = Path(); wick.move(to: CGPoint(x: x, y: y(k.h))); wick.addLine(to: CGPoint(x: x, y: y(k.l)))
                ctx.stroke(wick, with: .color(col), lineWidth: max(0.8, bw * 0.14))
                let top = y(max(k.o, k.c)), bot = y(min(k.o, k.c))
                ctx.fill(Path(CGRect(x: x - bw / 2, y: top, width: bw, height: max(1, bot - top))), with: .color(col))
            }
            for m in marks {
                let col = m.tone.color
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(m.value))); p.addLine(to: CGPoint(x: plotW, y: y(m.value)))
                ctx.stroke(p, with: .color(col.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let label = ctx.resolve(Text(m.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
                let ts = label.measure(in: size)
                let r = CGRect(x: 2, y: y(m.value) - ts.height / 2 - 2, width: ts.width + 10, height: ts.height + 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(col))
                ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY))
            }
        }
    }

    static func label(_ v: Double, span: Double) -> String {
        if span < 0.01 { return String(format: "%.4f", v) }
        if span < 1 { return String(format: "%.3f", v) }
        if span < 20 { return String(format: "%.2f", v) }
        return v.formatted(.number.precision(.fractionLength(0)))
    }

    /// Candles scaled so the last close lands on `price`.
    static func series(seed: Int, price: Double, count: Int = 48, vol: Double = 0.03, drift: Double = 0.004) -> [Candle] {
        let base = Candle.series(seed: seed, count: count, start: 100, vol: vol, drift: drift)
        let k = price / (base.last?.c ?? 100)
        return base.map { Candle(o: $0.o * k, h: $0.h * k, l: $0.l * k, c: $0.c * k) }
    }
}

/// A token with candles, timeframe switch and the numbers that matter.
struct TokenCard: View {
    let spec: TokenSpec
    @State private var tf = "4H"
    static let frames = ["1H", "4H", "1D", "1W"]

    var body: some View {
        let seed = spec.seed + (Self.frames.firstIndex(of: tf) ?? 0)
        ChatCard {
            LogoMark(spec.sym, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.name).font(.system(size: 13.5, weight: .medium))
                HStack(spacing: 6) {
                    Text(spec.price.price).monospacedDigit()
                    Text(String(format: "%@%.1f%%", spec.change >= 0 ? "+" : "−", abs(spec.change))).foregroundStyle(spec.change >= 0 ? Theme.green : Theme.red)
                }
                .font(.system(size: 12.5))
            }
            Spacer(minLength: 8)
            Segmented(options: Self.frames.map { ($0, $0) }, selection: $tf).fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                LevelCandles(data: LevelCandles.series(seed: seed, price: spec.price, vol: 0.04, drift: 0.006), marks: spec.marks)
                    .frame(height: 190)
                    .id(tf).transition(.opacity)
                    .animation(.smooth(duration: 0.25), value: tf)
                KVGrid(pairs: spec.stats)
            }
        }
    }
}

struct PriceCard: View {
    let title, total: String
    let days, seed: Int
    var body: some View {
        ChatCard {
            CardTitle(title)
            Spacer()
            Text(total).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(total.hasPrefix("−") ? Theme.red : Theme.green)
        } content: {
            VStack(spacing: 6) {
                LevelCandles(data: Candle.series(seed: seed, count: days * 2, start: 100, vol: 0.025, drift: 0.005), axis: false).frame(height: 150)
                HStack { Text("\(days) days ago"); Spacer(); Text("Today") }.font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
        }
    }
}

/// Profit over time (a balance, so a line).
struct PnlCard: View {
    let title, total: String
    let days, seed: Int
    var body: some View {
        let series = Candle.series(seed: seed, count: max(days, 12), start: 100, vol: 0.05, drift: 0.012).enumerated().map { $1.c + Double($0) * 4 }
        ChatCard {
            CardTitle(title)
            Spacer()
            Text(total).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(total.hasPrefix("−") ? Theme.red : Theme.green)
        } content: {
            VStack(spacing: 6) {
                LineChart(values: series).frame(height: 110)
                HStack { Text("\(days) days ago"); Spacer(); Text("Today") }.font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
        }
    }
}

/// Holder clusters: linked wallets share a colour, lines show funding links.
struct HoldersCard: View {
    let verdict: String
    let clusters: [Cluster]
    let legend: [[String]]
    var body: some View {
        ChatCard {
            CardTitle("Holders")
            Spacer()
            StatusTag(text: verdict, tone: verdict == "Healthy" ? .green : .amber)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                BubbleMap(clusters: clusters).frame(height: 220)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                Flow(spacing: 16, lineSpacing: 6) {
                    ForEach(legend, id: \.self) { l in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(hex: UInt32(l[0], radix: 16) ?? 0)).frame(width: 8, height: 8)
                            Text(l[1]).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }
}

struct BubbleMap: View {
    let clusters: [Cluster]
    var seed = 7
    var body: some View {
        Canvas { ctx, size in
            var s = UInt64(seed)
            func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
            struct Node { var p: CGPoint; var r: CGFloat; var c: Color; var retail: Bool }
            var nodes: [Node] = [], links: [(Int, Int)] = []
            let scale = min(1, size.height / 220)
            for cl in clusters {
                let cx = cl.x * size.width, cy = cl.y * size.height, first = nodes.count
                for i in 0..<cl.n {
                    let a = Double(i) * 2.4 + r()
                    let dist = i == 0 ? 0 : (14 + sqrt(Double(i)) * 16) * scale
                    let rad = i == 0 ? cl.size : max(4, cl.size * (0.25 + r() * 0.4))
                    nodes.append(Node(p: CGPoint(x: cx + cos(a) * dist, y: cy + sin(a) * dist), r: rad * scale, c: Color(hex: cl.hex), retail: false))
                    if i > 0 { links.append((first, nodes.count - 1)) }
                }
            }
            for _ in 0..<40 {
                nodes.append(Node(p: CGPoint(x: 16 + r() * (size.width - 32), y: 14 + r() * (size.height - 28)), r: 3 + r() * 6, c: Color(hex: 0xD9D4CB), retail: true))
            }
            for (a, b) in links {
                var p = Path(); p.move(to: nodes[a].p); p.addLine(to: nodes[b].p)
                ctx.stroke(p, with: .color(nodes[a].c.opacity(0.45)), lineWidth: 1)
            }
            for n in nodes {
                let rect = CGRect(x: n.p.x - n.r, y: n.p.y - n.r, width: n.r * 2, height: n.r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(n.c.opacity(n.retail ? 0.7 : 0.85)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1)
            }
        }
    }
}

struct KolCard: View {
    let onboarded: Int
    let rows: [Kol]
    var body: some View {
        ChatCard {
            CardTitle("KOLs and smart money")
            Spacer()
            Text("\(onboarded) onboarded").font(.system(size: 12)).foregroundStyle(Theme.muted)
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, k in
                    HStack(spacing: 12) {
                        Text(String(k.handle.replacingOccurrences(of: "@", with: "").prefix(1)).uppercased())
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Color(hex: k.hex), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(k.handle).font(.system(size: 13.5, weight: .medium))
                                Text(k.followers).font(.system(size: 12)).foregroundStyle(Theme.faint)
                            }
                            Text(k.note).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        StatusTag(text: k.state, tone: k.state == "Bought" ? .green : k.state == "Sold" ? .red : .text)
                    }
                    .padding(.vertical, 9)
                    if i < rows.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
    }
}

/// A perp order you can tune before placing it: margin and leverage sliders, live liquidation price.
struct PerpTicket: View {
    let base: Approval
    @Environment(AppModel.self) private var model
    @State private var lev: Double = 5
    @State private var margin: Double = 1000
    let entry = 24.06

    var body: some View {
        let liq = entry * (1 - 0.9 / lev)
        let size = margin * lev
        ChatCard {
            LogoMark("HYPE", size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Long HYPE").font(.system(size: 13.5, weight: .medium))
                Text(entry.price).font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit()
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                LevelCandles(data: LevelCandles.series(seed: 31, price: entry, vol: 0.05, drift: 0.008),
                             marks: [ChartMark(27.5, "Target", .green), ChartMark(24.06, "Entry", .text), ChartMark(22, "Stop", .red)])
                    .frame(height: 180)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { marginSlider; levSlider }
                    VStack(spacing: 14) { marginSlider; levSlider }
                }
                KVGrid(pairs: [["Size", Money.usd(size)], ["Liquidation", liq.price], ["Loss at stop", Money.usd(size * 2.06 / entry)], ["Reward / risk", "1.67"]],
                       tones: ["Liquidation": .red])
            }
        } foot: {
            Button {
                var lines = base.lines
                lines = [["Margin", Money.usd(margin)], ["Leverage", "\(Int(lev))x"], ["Liquidation", liq.price], ["Stop / target", "$22.00 / $27.50"]]
                model.approval = Approval(kind: base.kind, title: "Long HYPE \(Int(lev))x", lines: lines, checks: base.checks, success: base.success,
                                          live: LiveTrade(sym: "HYPE", title: "HYPE-PERP", side: "Long \(Int(lev))x", entry: entry, tp: 27.5, sl: 22, liq: liq, size: size))
            } label: {
                Label("Place order", systemImage: "touchid")
            }
            .buttonStyle(BlackButton())
        }
    }

    private var marginSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Margin").foregroundStyle(Theme.muted); Spacer(); Text(Money.usd(margin)).monospacedDigit().contentTransition(.numericText()) }
                .font(.system(size: 12.5))
            Slider(value: $margin, in: 100...5000, step: 100).tint(Theme.text).controlSize(.small)
        }
    }

    private var levSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Leverage").foregroundStyle(Theme.muted); Spacer(); Text("\(Int(lev))x").monospacedDigit().contentTransition(.numericText()) }
                .font(.system(size: 12.5))
            Slider(value: $lev, in: 1...20, step: 1).tint(Theme.text).controlSize(.small)
        }
    }
}

/// Posted after a trade is approved: candles with entry, TP and SL lines, ticking every second.
struct LiveTradeCard: View {
    let trade: LiveTrade
    @State private var data: [Candle] = []

    private var long: Bool { !trade.side.lowercased().contains("short") }
    private var vol: Double { trade.entry < 1 ? 0.012 : 0.006 }

    var body: some View {
        let px = data.last?.c ?? trade.entry
        let pnl = (px - trade.entry) / trade.entry * trade.size * (long ? 1 : -1)
        ChatCard {
            LogoMark(trade.sym, size: 24)
            Text(trade.title).font(.system(size: 13.5, weight: .medium))
            Text(trade.side).font(.system(size: 13)).foregroundStyle(Theme.muted)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                    .phaseAnimator([1.0, 0.35]) { c, o in c.opacity(o) } animation: { _ in .smooth(duration: 0.9) }
                Text("Live").font(.system(size: 12))
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(px.price).font(.system(size: 20, weight: .semibold)).monospacedDigit().contentTransition(.numericText(value: px))
                    Spacer()
                    Text("\(pnl >= 0 ? "+" : "−")$\(String(format: "%.2f", abs(pnl)))").font(.system(size: 14, weight: .medium)).monospacedDigit()
                        .foregroundStyle(pnl >= 0 ? Theme.green : Theme.red).contentTransition(.numericText(value: pnl))
                }
                LevelCandles(data: data.isEmpty ? seed() : data, marks: marks).frame(height: 190)
                KVGrid(pairs: [["To TP", trade.tp.map { String(format: "%.1f%%", abs($0 - px) / px * 100) } ?? "None"],
                               ["To SL", trade.sl.map { String(format: "%.1f%%", abs(px - $0) / px * 100) } ?? "None"],
                               ["Liquidation", trade.liq?.price ?? "None"]],
                       tones: ["To TP": .green, "To SL": .red])
            }
        }
        .task {
            if data.isEmpty { data = seed() }
            guard !SnapshotMode.active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let last = data.last else { continue }
                let drift = (long ? 1 : -1) * trade.entry * vol * 0.12
                let c = last.c + drift + (Double.random(in: -0.5...0.5)) * trade.entry * vol
                let next = Candle(o: last.c, h: max(last.c, c) + Double.random(in: 0...0.4) * trade.entry * vol,
                                  l: min(last.c, c) - Double.random(in: 0...0.4) * trade.entry * vol, c: c)
                withAnimation(.smooth(duration: 0.3)) { data = Array(data.dropFirst()) + [next] }
            }
        }
    }

    private var marks: [ChartMark] {
        var m: [ChartMark] = []
        if let tp = trade.tp { m.append(ChartMark(tp, "TP \(tp.price)", .green)) }
        m.append(ChartMark(trade.entry, "Entry \(trade.entry.price)", .text))
        if let sl = trade.sl { m.append(ChartMark(sl, "SL \(sl.price)", .red)) }
        return m
    }

    private func seed() -> [Candle] {
        let base = Candle.series(seed: trade.sym.count * 7, count: 40, start: 100, vol: vol, drift: long ? 0.004 : -0.004)
        let k = trade.entry / (base.last?.c ?? 100)
        return base.map { Candle(o: $0.o * k, h: $0.h * k, l: $0.l * k, c: $0.c * k) }
    }
}

/// Ranked headlines; each carries a ready trade you can edit before approving.
struct NewsCard: View {
    let items: [NewsItem]
    var body: some View {
        ChatCard {
            CardTitle("Top stories")
            Spacer()
            Text("Last 6 hours").font(.system(size: 12)).foregroundStyle(Theme.faint)
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, n in
                    NewsRow(item: n).padding(.vertical, 12)
                    if i < items.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
    }
}

struct NewsRow: View {
    let item: NewsItem
    @Environment(AppModel.self) private var model
    @State private var lev: Int
    @State private var tp: Double
    @State private var sl: Double
    @State private var editing = false

    init(item: NewsItem) {
        self.item = item
        let long = item.move >= 0
        _lev = State(initialValue: item.impact == "High" ? 3 : 2)
        _tp = State(initialValue: Self.round(item.price * (long ? 1.08 : 0.94), item.price))
        _sl = State(initialValue: Self.round(item.price * (long ? 0.97 : 1.03), item.price))
    }

    static func round(_ v: Double, _ px: Double) -> Double { px < 100 ? (v * 100).rounded() / 100 : v.rounded() }
    private var long: Bool { item.move >= 0 }
    private var side: String { long ? "Long" : "Short" }
    private func pct(_ v: Double) -> String { String(format: "%@%.1f%%", v > item.price ? "+" : "−", abs((v - item.price) / item.price * 100)) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LogoMark(item.sym, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text("\(item.source), \(item.ago)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 2)
                HStack(spacing: 12) {
                    Text("\(item.impact) impact").foregroundStyle(item.impact == "High" ? Theme.red : Theme.amber)
                    Text("\(item.sym) \(item.move >= 0 ? "+" : "−")\(String(format: "%.1f", abs(item.move)))%").foregroundStyle(long ? Theme.green : Theme.red)
                }
                .font(.system(size: 12.5)).padding(.top, 6)
                tradeLine.padding(.top, 8)
                HStack(spacing: 6) {
                    Button("Details") { model.ask(item.ask) }.buttonStyle(SmallChip())
                    Button("\(side) \(item.sym) \(lev)x") { trade() }.buttonStyle(SmallChip(on: true, tone: long ? .text : .red))
                }
                .padding(.top, 8)
            }
        }
    }

    private var tradeLine: some View {
        HStack(spacing: 8) {
            if editing {
                Picker("Leverage", selection: $lev) { ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)x").tag($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                field("TP", $tp, Theme.green)
                field("SL", $sl, Theme.red)
            } else {
                Text("\(side) \(lev)x").foregroundStyle(Theme.muted)
                pill("TP \(tp.price) (\(pct(tp)))", Theme.green, Theme.greenSoft)
                pill("SL \(sl.price) (\(pct(sl)))", Theme.red, Theme.redSoft)
            }
            Spacer(minLength: 4)
            Button(editing ? "Done" : "Edit") { withAnimation(.snappy) { editing.toggle() } }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.accent)
        }
        .font(.system(size: 12)).monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 9))
    }

    private func pill(_ s: String, _ fg: Color, _ bg: Color) -> some View {
        Text(s).foregroundStyle(fg).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 7).padding(.vertical, 2).background(bg, in: RoundedRectangle(cornerRadius: 5))
    }

    private func field(_ label: String, _ value: Binding<Double>, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(tint)
            TextField(label, value: value, format: .number).textFieldStyle(.plain).frame(width: 62)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        }
    }

    private func trade() {
        let px = item.price
        let liq = px * (long ? 1 - 0.9 / Double(lev) : 1 + 0.9 / Double(lev))
        model.approval = Approval(
            kind: "Perp order on Hyperliquid", title: "\(side) \(item.sym) \(lev)x",
            lines: [["Margin", "$500"], ["Size", Money.usd(500 * Double(lev))], ["Entry", px.price], ["Take profit", "\(tp.price) (\(pct(tp)))"], ["Stop loss", "\(sl.price) (\(pct(sl)))"]],
            checks: Approval.checks(["Stop triggers before liquidation", item.impact == "High" ? "News confirmed by 3+ sources" : "Single-source story, sized down"]),
            success: "Order filled",
            live: LiveTrade(sym: item.sym, title: "\(item.sym)-PERP", side: "\(side) \(lev)x", entry: px, tp: tp, sl: sl, liq: liq, size: 500 * Double(lev)))
    }
}

struct ApiBuyCard: View {
    let approval: Approval
    @Environment(AppModel.self) private var model
    var body: some View {
        let done = model.approvedIDs.contains(approval.title)
        ChatCard {
            LogoMark("OpenAI", size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenAI GPT-5").font(.system(size: 13.5, weight: .medium))
                Text(done ? "Connected" : "$20 in credits").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if done { StatusTag(text: "Active") }
        } content: {
            Text("hermit.tools.add(\"openai\", key=vault://openai)").font(Theme.mono)
                .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        } foot: {
            Button { model.approval = approval } label: { Label(done ? "Connected" : "Buy and connect", systemImage: done ? "checkmark" : "touchid") }
                .buttonStyle(BlackButton()).disabled(done)
        }
    }
}
