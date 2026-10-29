import SwiftUI

/// A labelled horizontal level on the terminal chart (TP, entry, SL, support, resistance).
struct TradeLevel: Hashable {
    let value: Double
    let label: String
    let color: Color
}

/// The terminal's price chart: candles (drawn exactly like the shared `Candles`) plus a dashed grid, a price axis
/// and coloured, labelled levels. The range widens so TP and SL lines outside recent prices still show.
struct TradeCandleChart: View {
    let data: [Candle]
    var levels: [TradeLevel] = []
    var padTo: [Double] = []
    var decimals: Int = 2

    var body: some View {
        Canvas { ctx, size in
            let lows = data.map(\.l) + padTo, highs = data.map(\.h) + padTo
            guard let lo = lows.min(), let hi = highs.max(), hi > lo else { return }
            let axis: CGFloat = 46, w = size.width - axis
            let pad = (hi - lo) * 0.04, mn = lo - pad, mx = hi + pad
            func y(_ v: Double) -> CGFloat { 8 + (size.height - 22) * (1 - CGFloat((v - mn) / (mx - mn))) }

            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let v = mn + (mx - mn) * t, yy = y(v)
                var p = Path(); p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy))
                ctx.stroke(p, with: .color(Theme.border), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                let label = v < 10 ? String(format: "%.3f", v) : v.tradeGrouped(0)
                ctx.draw(Text(label).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.faint),
                         at: CGPoint(x: w + 6, y: yy), anchor: .leading)
            }

            let step = w / CGFloat(data.count), bw = max(1, step * 0.64)
            for (i, k) in data.enumerated() {
                let x = step * (CGFloat(i) + 0.5), col = k.c >= k.o ? Theme.green : Theme.red
                var wick = Path(); wick.move(to: CGPoint(x: x, y: y(k.h))); wick.addLine(to: CGPoint(x: x, y: y(k.l)))
                ctx.stroke(wick, with: .color(col), lineWidth: 1)
                let top = y(max(k.o, k.c)), bot = y(min(k.o, k.c))
                ctx.fill(Path(roundedRect: CGRect(x: x - bw / 2, y: top, width: bw, height: max(1, bot - top)), cornerRadius: 1), with: .color(col))
            }

            for m in levels {
                let yy = y(m.value)
                var p = Path(); p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy))
                ctx.stroke(p, with: .color(m.color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let text = ctx.resolve(Text(m.label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white))
                let ts = text.measure(in: CGSize(width: 300, height: 20))
                let rect = CGRect(x: 4, y: max(2, yy - 17), width: ts.width + 12, height: 15)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(m.color))
                ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
        .accessibilityLabel("Price chart")
    }
}

/// Small candles for list rows (prices are always candles).
struct TradeMiniCandles: View {
    let data: [Candle]
    var body: some View { Candles(data: data).frame(width: 84, height: 28).accessibilityHidden(true) }
}

/// Holder bubble map: clusters of linked wallets over a field of loose holders (Charts.jsx BubbleMap).
struct TradeBubbleMap: View {
    struct Cluster { let x, y: Double; let n: Int; let size: Double; let color: Color; let label: String }
    let seed: Int
    let clusters: [Cluster]

    var body: some View {
        Canvas { ctx, size in
            let w = 640.0, h = 220.0
            let sx = size.width / w, sy = size.height / h
            var r = TradeData.RNG(seed)
            struct Node { let x, y, s: Double; let c: Color; let faint: Bool }
            var nodes: [Node] = [], links: [(Int, Int)] = []
            for cl in clusters {
                let cx = cl.x * w, cy = cl.y * h, first = nodes.count
                for i in 0..<cl.n {
                    let a = Double(i) * 2.4 + r.next()
                    let dist = i == 0 ? 0 : 14 + Double(i).squareRoot() * 16
                    let s = i == 0 ? cl.size : max(4, cl.size * (0.25 + r.next() * 0.4))
                    nodes.append(Node(x: cx + cos(a) * dist, y: cy + sin(a) * dist, s: s, c: cl.color, faint: false))
                    if i > 0 { links.append((first, nodes.count - 1)) }
                }
            }
            for _ in 0..<40 {
                nodes.append(Node(x: 20 + r.next() * (w - 40), y: 16 + r.next() * (h - 32), s: 3 + r.next() * 6, c: Color(hex: 0xD9D4CB), faint: true))
            }
            let k = min(sx, sy)
            for (a, b) in links {
                var p = Path()
                p.move(to: CGPoint(x: nodes[a].x * sx, y: nodes[a].y * sy)); p.addLine(to: CGPoint(x: nodes[b].x * sx, y: nodes[b].y * sy))
                ctx.stroke(p, with: .color(nodes[a].c.opacity(0.45)), lineWidth: 1)
            }
            for n in nodes {
                let rr = n.s * k
                let rect = CGRect(x: n.x * sx - rr, y: n.y * sy - rr, width: rr * 2, height: rr * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(n.c.opacity(n.faint ? 0.7 : 0.85)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1)
            }
        }
        .aspectRatio(640 / 220, contentMode: .fit)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Holder map")
    }
}

/// How a strategy works, as a minimal timeline: a dot per step, a green shield for the safety check.
/// Horizontal when there is room, vertical on phones.
struct TradeFlowDiagram: View {
    let steps: [TradeData.Step]
    @State private var width: CGFloat = 520

    var body: some View {
        Group {
            if width / CGFloat(max(steps.count, 1)) >= 92 { horizontal } else { vertical }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tradeWidth($width)
    }

    private func dot(_ s: TradeData.Step) -> some View {
        ZStack {
            if s.guardStep {
                Circle().fill(Theme.green)
                Image(systemName: "checkmark.shield.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().fill(Theme.text).frame(width: 8, height: 8)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func text(_ s: TradeData.Step) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.t).font(.system(size: 13, weight: .medium)).foregroundStyle(s.guardStep ? Theme.green : Theme.text)
            Text(s.d).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var horizontal: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 0) {
                        dot(s)
                        if i < steps.count - 1 { Rectangle().fill(Color(hex: 0xD4D4D2)).frame(height: 1) } else { Spacer(minLength: 0) }
                    }
                    text(s).padding(.trailing, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        dot(s)
                        if i < steps.count - 1 { Rectangle().fill(Color(hex: 0xD4D4D2)).frame(width: 1).frame(maxHeight: .infinity) }
                    }
                    text(s).padding(.bottom, i < steps.count - 1 ? 16 : 0)
                }
            }
        }
    }
}
