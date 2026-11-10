import SwiftUI

// Shared building blocks for every page. Rules from the demo README: one tab row per page,
// price charts are always candlesticks, numbers come with a chart, purple only for key actions.

/// A page: title (+ optional trailing view), one row of tabs, then the content for the selected tab.
struct Page<Tab: Hashable, Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let tabs: [(Tab, String)]
    @Binding var tab: Tab
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: (Tab) -> Content

    var body: some View {
        if SnapshotMode.active { inner.frame(maxHeight: .infinity, alignment: .top) } else {
            ScrollView { inner }
                .scrollIndicators(.automatic)
                .debugScroll()
                .animation(.easeOut(duration: 0.18), value: tab)
        }
    }

    private var inner: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                        if let subtitle { Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    trailing()
                }
                if tabs.count > 1 {
                    PageTabs(tabs: tabs, selection: $tab).padding(.top, 18)
                }
                content(tab)
                    .padding(.top, 22)
                    .id(tab)
                    .transition(.opacity)
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32).padding(.top, 36).padding(.bottom, 48)
    }
}

extension Page where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, tabs: [(Tab, String)], tab: Binding<Tab>, @ViewBuilder content: @escaping (Tab) -> Content) {
        self.init(title: title, subtitle: subtitle, tabs: tabs, tab: tab, trailing: { EmptyView() }, content: content)
    }
}

/// The single tab row: text tabs with an underline that slides between them.
struct PageTabs<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab
    @Namespace private var ns

    var body: some View {
        // Six Settings tabs don't fit a phone at the usual spacing: tighten first, scroll only if that's not enough,
        // and keep the selected tab on screen.
        ViewThatFits(in: .horizontal) {
            row(22)
            row(16)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { row(16) }
                    .scrollIndicators(.never)
                    .onAppear { proxy.scrollTo(selection, anchor: .center) }
                    .onChange(of: selection) { _, v in withAnimation(.smooth) { proxy.scrollTo(v, anchor: .center) } }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .animation(.snappy(duration: 0.25), value: selection)
    }

    private func row(_ spacing: CGFloat) -> some View {
            HStack(spacing: spacing) {
                ForEach(tabs, id: \.0) { t in
                    Button { selection = t.0 } label: {
                        VStack(spacing: 8) {
                            Text(t.1).font(.system(size: 13.5, weight: selection == t.0 ? .medium : .regular))
                                .foregroundStyle(selection == t.0 ? Theme.text : Theme.muted)
                            ZStack {
                                Rectangle().fill(.clear).frame(height: 2)
                                if selection == t.0 { Rectangle().fill(Theme.text).frame(height: 2).matchedGeometryEffect(id: "u", in: ns) }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(t.0)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Small inline segmented control (for secondary choices; never a second tab row).
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    /// Fits on one line when it can; otherwise it scrolls sideways (All chains, Ethereum, Base, … on a phone).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { bar.padding(.trailing, 1) }
                    .scrollIndicators(.hidden)
                    .onChange(of: selection) { _, v in withAnimation(.smooth) { proxy.scrollTo(v, anchor: .center) } }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { o in
                Button { withAnimation(.snappy(duration: 0.2)) { selection = o.0 } } label: {
                    Text(o.1).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selection == o.0 ? Theme.text : Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(selection == o.0 ? Theme.bg : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .shadow(color: .black.opacity(selection == o.0 ? 0.06 : 0), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .id(o.0)
            }
        }
        .padding(2).background(Theme.hover, in: RoundedRectangle(cornerRadius: 9))
        .fixedSize()
    }
}

/// A big number with a label, optional delta.
struct StatTile: View {
    let label: String
    let value: String
    var delta: String? = nil
    var positive: Bool = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().tracking(-0.3)
            if let delta { Text(delta).font(.system(size: 12.5)).foregroundStyle(positive ? Theme.green : Theme.red) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

/// One OHLC candle.
public struct Candle: Hashable, Sendable {
    public let o, h, l, c: Double
    public init(o: Double, h: Double, l: Double, c: Double) { self.o = o; self.h = h; self.l = l; self.c = c }

    /// Deterministic sample series for mock prices (same input, same chart).
    public static func series(seed: Int, count: Int = 48, start: Double = 100, vol: Double = 0.02, drift: Double = 0.002) -> [Candle] {
        var x = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 1)
        func rnd() -> Double { x = x &* 6364136223846793005 &+ 1442695040888963407; return Double(x >> 11) / Double(1 << 53) }
        var p = start, out: [Candle] = []
        for _ in 0..<count {
            let o = p, move = (rnd() - 0.5 + drift * 10) * vol * 2, c = max(0.0001, o * (1 + move))
            let h = max(o, c) * (1 + rnd() * vol * 0.6), l = min(o, c) * (1 - rnd() * vol * 0.6)
            out.append(Candle(o: o, h: h, l: l, c: c)); p = c
        }
        return out
    }
}

/// Candlestick chart. Price charts are always candles, mini ones in lists included.
struct Candles: View {
    let data: [Candle]
    var marks: [(Double, String)] = []   // horizontal levels (support / resistance)
    var body: some View {
        Canvas { ctx, size in
            guard let lo = data.map(\.l).min(), let hi = data.map(\.h).max(), hi > lo else { return }
            let pad = (hi - lo) * 0.06, mn = lo - pad, mx = hi + pad
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((v - mn) / (mx - mn))) }
            let w = size.width / CGFloat(data.count), bw = max(1, w * 0.62)
            for (i, k) in data.enumerated() {
                let x = w * (CGFloat(i) + 0.5), up = k.c >= k.o, col = up ? Theme.green : Theme.red
                var wick = Path(); wick.move(to: CGPoint(x: x, y: y(k.h))); wick.addLine(to: CGPoint(x: x, y: y(k.l)))
                ctx.stroke(wick, with: .color(col), lineWidth: max(0.8, bw * 0.14))
                let top = y(max(k.o, k.c)), bot = y(min(k.o, k.c))
                ctx.fill(Path(CGRect(x: x - bw / 2, y: top, width: bw, height: max(1, bot - top))), with: .color(col))
            }
            for m in marks {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(m.0))); p.addLine(to: CGPoint(x: size.width, y: y(m.0)))
                ctx.stroke(p, with: .color(Theme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ctx.draw(Text(m.1).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent), at: CGPoint(x: size.width - 4, y: y(m.0) - 8), anchor: .trailing)
            }
        }
    }
}

/// Line / area chart for balances, PnL and APY (not prices).
struct LineChart: View {
    let values: [Double]
    var color: Color = Theme.text
    var fill: Bool = true
    var body: some View {
        GeometryReader { g in
            let mn = values.min() ?? 0, mx = values.max() ?? 1, r = max(mx - mn, 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: g.size.height * (1 - CGFloat((v - mn) / r)) * 0.9 + g.size.height * 0.05)
            }
            ZStack {
                if fill {
                    Path { p in
                        guard let f = pts.first else { return }
                        p.move(to: CGPoint(x: f.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.14), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in p.addLines(pts) }.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// A row in a list: logo, title and subtitle, then trailing text.
struct ListRow<Trailing: View>: View {
    let logo: String?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            if let logo { LogoMark(logo, size: 32) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10)
    }
}

/// Plain white secondary button with a border.
struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(configuration.isPressed ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }
}

/// Purple key action (Approve, Ask, primary brand buttons). Use sparingly.
struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}
