import SwiftUI

/// A labelled horizontal level on the terminal chart (TP, entry, SL, support, resistance).
struct TradeLevel: Hashable {
    let value: Double
    let label: String
    let color: Color
}

/// The terminal's price chart: candles (drawn exactly like the shared `Candles`) plus a dashed grid, a price axis
/// and coloured, labelled levels. The range widens for a TP or SL a little outside recent prices; one far outside would
/// squash the candles into a thin band, so it's pinned to the chart's edge with an arrow instead.
struct TradeCandleChart: View {
    let data: [Candle]
    var levels: [TradeLevel] = []
    var padTo: [Double] = []
    /// What the candles on screen span, for VoiceOver ("2 days").
    var rangeLabel: String = "the chart"

    /// VoiceOver: the last close, and the move from the first open to it.
    private var spoken: String {
        guard let first = data.first, let last = data.last, first.o > 0 else { return "" }
        let changePct = (last.c - first.o) / first.o * 100
        return "\(last.c.tradePx), \(changePct >= 0 ? "up" : "down") \(String(format: "%.1f", abs(changePct))) percent over \(rangeLabel)"
    }

    var body: some View {
        Canvas { ctx, size in
            guard let clo = data.map(\.l).min(), let chi = data.map(\.h).max() else { return }
            let r = max(chi - clo, abs(chi) * 0.002)
            let near = padTo.filter { $0 >= clo - r * 0.5 && $0 <= chi + r * 0.5 }
            guard let lo = ([clo] + near).min(), let hi = ([chi] + near).max(), hi > lo else { return }
            let axis: CGFloat = 58, w = size.width - axis
            let pad = (hi - lo) * 0.04, mn = lo - pad, mx = hi + pad
            func y(_ v: Double) -> CGFloat { 8 + (size.height - 22) * (1 - CGFloat((v - mn) / (mx - mn))) }

            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let v = mn + (mx - mn) * t, yy = y(v)
                var p = Path(); p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy))
                ctx.stroke(p, with: .color(Theme.border), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                let label = v.tradePx
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
                let above = m.value > mx, below = m.value < mn
                let yy = above ? y(mx) : below ? y(mn) : y(m.value)
                var p = Path(); p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: w, y: yy))
                ctx.stroke(p, with: .color(m.color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let text = ctx.resolve(Text((above ? "↑ " : below ? "↓ " : "") + m.label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white))
                let ts = text.measure(in: CGSize(width: 300, height: 20))
                let rect = CGRect(x: 4, y: max(2, yy - 17), width: ts.width + 12, height: 15)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(m.color))
                ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
        .accessibilityLabel("Price chart")
        .accessibilityValue(spoken)
    }
}
