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

    var body: some View {
        Canvas { ctx, size in
            let lows = data.map(\.l) + padTo, highs = data.map(\.h) + padTo
            guard let lo = lows.min(), let hi = highs.max(), hi > lo else { return }
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
