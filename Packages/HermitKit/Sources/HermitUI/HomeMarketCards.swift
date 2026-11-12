import SwiftUI

/// The market card on Home, in the style picked in Settings → Home (Holo mood unless changed).
/// Live BTC, ETH, SOL and HYPE from Hyperliquid; the 24h lines load once per appearance. Tap opens Trade.
enum MarketCardStyle: String, CaseIterable, Identifiable {
    case holo, stocks, swipe, heatmap, spotlight, headline, rings, moodBar, dial
    var id: String { rawValue }
    var title: String {
        switch self {
        case .holo: "Holo"; case .stocks: "Stocks"; case .swipe: "Swipe"; case .heatmap: "Heatmap"; case .spotlight: "Spotlight"
        case .headline: "Headline"; case .rings: "Rings"; case .moodBar: "Mood bar"; case .dial: "Dial"
        }
    }
    var symbol: String {
        switch self {
        case .holo: "sparkles"; case .stocks: "list.bullet"; case .swipe: "rectangle.split.3x1"; case .heatmap: "square.grid.2x2"
        case .spotlight: "chart.xyaxis.line"; case .headline: "text.quote"; case .rings: "circle.circle"; case .moodBar: "chart.bar"
        case .dial: "gauge.with.needle"
        }
    }
}

struct HomeMarketsCard: View {
    @Environment(AppModel.self) private var model
    let hide: () -> Void
    @AppStorage("home.marketStyle") private var styleRaw = MarketCardStyle.holo.rawValue
    @State private var spark: [String: [Double]] = [:]
    /// The 24h lines were read this appearance (until then the saved ones from last time show).
    @State private var sparkFetched = false
    @State private var spot = 0
    @Environment(\.scenePhase) private var phase
    private var feed: MarketFeed { .shared }
    static let coins = [("BTC", "Bitcoin"), ("ETH", "Ethereum"), ("SOL", "Solana"), ("HYPE", "Hyperliquid")]
    private var style: MarketCardStyle { MarketCardStyle(rawValue: styleRaw) ?? .holo }

    var mood: Double? {
        let ch = Self.coins.compactMap { feed.perps[$0.0]?.ch }
        return ch.isEmpty ? nil : ch.reduce(0, +) / Double(ch.count)
    }

    var body: some View {
        Button { model.open(.trade, tab: "markets") } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if style != .holo && style != .swipe { hideButton(hide).padding(10) }
            }
            .marketPoll(every: 60) { await feed.refreshPerps() }
            .task(id: style) { if [.stocks, .swipe, .spotlight].contains(style) { await loadSparks() } }
            // Restarts when the scene comes back: no stepping while the app is in the background or inactive.
            .task(id: style == .spotlight && phase == .active) {
                guard style == .spotlight, phase == .active, !SnapshotMode.active else { return }
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(4.5)); withAnimation(.smooth) { spot = (spot + 1) % 4 } }
            }
    }

    private func loadSparks() async {
        guard !sparkFetched else { return }
        // Last time's lines draw at once while they're recent; each new one replaces its own as it arrives.
        if spark.isEmpty, let s = SnapshotStore.live.load("home-sparks", as: [String: [Double]].self, maxAge: 3 * 3600) { spark = s.value }
        var got = 0
        await withTaskGroup(of: (String, [Double]).self) { g in
            for (c, _) in Self.coins {
                g.addTask { (c, (try? await TradeAPI.perpCandles(c, interval: "30m", seconds: 1800, count: 48))?.map(\.c) ?? []) }
            }
            for await (c, v) in g where !v.isEmpty { spark[c] = v; got += 1 }
        }
        if got > 0 { sparkFetched = true; SnapshotStore.live.save(spark, "home-sparks") }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .holo: holo
        case .stocks: stocks
        case .swipe: swipe
        case .heatmap: heatmap
        case .spotlight: spotlight
        case .headline: headline
        case .rings: rings
        case .moodBar: moodBar
        case .dial: dial
        }
    }

    // MARK: Pieces

    private func px(_ c: String) -> Double? { feed.perps[c]?.px }
    private func ch(_ c: String) -> Double? { feed.perps[c]?.ch }
    static func price(_ v: Double?) -> String { v.map { "$" + $0.formatted(.number.precision(.fractionLength($0 >= 1000 ? 0 : 2))) } ?? "—" }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%@%.2f%%", $0 >= 0 ? "+" : "−", abs($0)) } ?? "—" }
    private func tint(_ v: Double?) -> Color { (v ?? 0) >= 0 ? Theme.green : Theme.red }
    private func logo(_ c: String, _ s: CGFloat) -> some View { MarketLogo(key: TradeData.logo(c), name: c, size: s) }
    private var moodWord: String {
        guard let m = mood else { return "Loading prices" }
        return m > 2 ? "Strong day across the board" : m > 0.3 ? "Mostly up today" : m < -2 ? "A rough day" : m < -0.3 ? "Mostly down today" : "Quiet, barely moving"
    }
    private func label(_ t: String) -> some View { Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted) }
    private func card<C: View>(padding: CGFloat = 16, @ViewBuilder _ c: () -> C) -> some View {
        c().padding(padding).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // MARK: Styles

    /// Holo: the pastel wash behind; "Crypto today" and the mood word on the left, a tall italic serif number on the right;
    /// frosted coin chips below. Close sits in the card's top-right corner.
    private var holo: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The number sits on the same line as the mood word (last text baselines line up).
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    label("Crypto today")
                    Text(moodWord).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.text)
                }
                Spacer(minLength: 8)
                // Newsreader Regular, upright: a step bolder than the light display cut.
                Text(Self.pct(mood)).font(.serif(54)).tracking(-1).monospacedDigit().foregroundStyle(tint(mood))
                    .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.5)
            }
            .padding(.top, 18).padding(.trailing, 22)   // clear of the close button in the corner
            HStack(spacing: 7) {
                ForEach(Self.coins, id: \.0) { c, _ in
                    VStack(spacing: 6) {
                        logo(c, 28)
                        Text(Self.price(px(c))).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(Self.pct(ch(c))).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(tint(ch(c)))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HoloWash().clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .overlay(alignment: .topTrailing) { hideButton(hide).padding(8) }
    }

    /// Stocks widget: rows with logo, name, 24h line, price and a solid change pill.
    private var stocks: some View {
        card(padding: 14) {
            VStack(spacing: 0) {
                ForEach(Array(Self.coins.enumerated()), id: \.offset) { i, coin in
                    HStack(spacing: 10) {
                        logo(coin.0, 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(coin.0).font(.system(size: 14, weight: .semibold))
                            Text(coin.1).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                        .frame(width: 78, alignment: .leading)
                        LineChart(values: spark[coin.0] ?? [], color: tint(ch(coin.0)), fill: false).frame(height: 24)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Self.price(px(coin.0))).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            Text(Self.pct(ch(coin.0))).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3).background(tint(ch(coin.0)), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .frame(width: 84, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
            .padding(.top, 14)
        }
    }

    /// Swipe: small cards with a filled 24h chart, scrolled sideways.
    private var swipe: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { label("Markets"); Spacer(); hideButton(hide) }.padding(.horizontal, 4)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Self.coins, id: \.0) { c, _ in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) { logo(c, 22); Text(c).font(.system(size: 13.5, weight: .semibold)) }
                            Text(Self.price(px(c))).font(.system(size: 18, weight: .semibold)).monospacedDigit().padding(.top, 6)
                            Text(Self.pct(ch(c))).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint(ch(c)))
                            LineChart(values: spark[c] ?? [], color: tint(ch(c))).frame(height: 32).padding(.top, 4)
                        }
                        .padding(12).frame(width: 148).card()
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
        }
    }

    /// Heatmap: tiles tinted by the day's move; Bitcoin takes the tall tile.
    private var heatmap: some View {
        card(padding: 12) {
            HStack(spacing: 6) {
                tile("BTC", big: true)
                VStack(spacing: 6) { tile("ETH"); tile("SOL"); tile("HYPE") }
            }
            .frame(height: 196)
            .padding(.top, 18)
        }
    }

    private func tile(_ c: String, big: Bool = false) -> some View {
        let v = ch(c) ?? 0, a = min(1, abs(v) / 4)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) { logo(c, big ? 22 : 16); Text(c).font(.system(size: 12.5, weight: .semibold)) }
            Spacer(minLength: 0)
            Text(Self.price(px(c))).font(.system(size: big ? 24 : 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(Self.pct(ch(c))).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(v >= 0 ? Color(hex: 0x0D3A22) : Color(hex: 0x4A120B))
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background((v >= 0 ? Theme.green : Theme.red).opacity(0.10 + a * 0.38), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Spotlight: one coin at a time with its chart; rotates, or tap a logo.
    private var spotlight: some View {
        let (c, name) = Self.coins[spot]
        return card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    logo(c, 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 15, weight: .semibold))
                        Text("\(c), 24h").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(Self.pct(ch(c))).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint(ch(c))).padding(.trailing, 26)
                }
                Text(Self.price(px(c))).font(.system(size: 30, weight: .semibold)).monospacedDigit().padding(.top, 12)
                    .contentTransition(.numericText())
                LineChart(values: spark[c] ?? [], color: tint(ch(c))).frame(height: 52).padding(.top, 6)
                HStack(spacing: 10) {
                    ForEach(Array(Self.coins.enumerated()), id: \.offset) { i, coin in
                        Button { withAnimation(.smooth) { spot = i } } label: {
                            logo(coin.0, 26).opacity(i == spot ? 1 : 0.35)
                                .overlay(Circle().strokeBorder(Theme.text, lineWidth: i == spot ? 1.5 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 12)
            }
        }
    }

    /// Headline: the market in one serif sentence.
    private var headline: some View {
        let btc = ch("BTC") ?? 0
        let up = Self.coins.filter { (ch($0.0) ?? 0) >= 0 }.count
        let lead = Self.coins.max { (ch($0.0) ?? 0) < (ch($1.0) ?? 0) }?.0 ?? "BTC"
        return card {
            VStack(alignment: .leading, spacing: 12) {
                (Text("Bitcoin is ") + Text(btc >= 0 ? "up" : "down").italic() + Text(" \(String(format: "%.2f", abs(btc)))% at \(Self.price(px("BTC"))), and \(up) of 4 majors are green, led by \(lead)."))
                    .font(.display(22)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).padding(.trailing, 22)
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack {
                    ForEach(Self.coins, id: \.0) { c, _ in
                        HStack(spacing: 4) {
                            logo(c, 14)
                            Text(Self.pct(ch(c))).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(tint(ch(c)))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Rings: one ring per coin, filling with the size of its move (5% = full).
    private var rings: some View {
        let colors: [String: Color] = ["BTC": Color(hex: 0xF7931A), "ETH": Color(hex: 0x627EEA), "SOL": Color(hex: 0x14C88A), "HYPE": Color(hex: 0x3FBFAE)]
        return card {
            HStack(spacing: 16) {
                ZStack {
                    ForEach(Array(Self.coins.enumerated()), id: \.offset) { i, coin in
                        let r = CGFloat(112 - i * 24), col = colors[coin.0] ?? Theme.text
                        Circle().stroke(col.opacity(0.16), lineWidth: 9).frame(width: r, height: r)
                        Circle().trim(from: 0, to: min(1, abs(ch(coin.0) ?? 0) / 5))
                            .stroke(col, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: r, height: r)
                            .animation(.smooth(duration: 0.8), value: ch(coin.0))
                    }
                }
                .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Self.coins, id: \.0) { c, _ in
                        HStack(spacing: 7) {
                            Circle().fill(colors[c] ?? Theme.text).frame(width: 7, height: 7)
                            logo(c, 16)
                            Text(c).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 4)
                            Text(Self.pct(ch(c))).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(tint(ch(c)))
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    /// Mood bar: twelve blocks from red to green, then the coins two by two.
    private var moodBar: some View {
        let lit = Int(((max(-4, min(4, mood ?? 0)) + 4) / 8 * 12).rounded())
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    label("Market mood")
                    Spacer()
                    Text(Self.pct(mood)).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(tint(mood)).padding(.trailing, 26)
                }
                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(i < lit ? Color(hue: (8 + Double(i) / 11 * 130) / 360, saturation: 0.62, brightness: 0.82) : Theme.hover)
                            .frame(height: 20)
                    }
                }
                .animation(.smooth(duration: 0.5), value: lit)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(Self.coins, id: \.0) { c, _ in
                        HStack(spacing: 8) {
                            logo(c, 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.price(px(c))).font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                                Text(Self.pct(ch(c))).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint(ch(c)))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Dial: the welcome screen's dial; the needle is the mood.
    private var dial: some View {
        card {
            VStack(spacing: 0) {
                HStack { label("Market mood"); Spacer() }
                MoodDial(value: mood ?? 0).frame(height: 78).padding(.top, 8).animation(.smooth(duration: 0.9), value: mood)
                Text(Self.pct(mood)).font(.display(26)).monospacedDigit().foregroundStyle(tint(mood)).padding(.top, 6)
                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 12)
                HStack(spacing: 4) {
                    ForEach(Self.coins, id: \.0) { c, _ in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) { logo(c, 15); Text(c).font(.system(size: 11, weight: .medium, design: .monospaced)) }
                            Text(Self.price(px(c))).font(.display(16)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            Text(Self.pct(ch(c))).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(tint(ch(c)))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 11)
            }
        }
    }
}

/// Settings → Home: pick the market card. A tidy grid of small tiles, three across.
struct MarketStylePicker: View {
    @AppStorage("home.marketStyle") private var styleRaw = MarketCardStyle.holo.rawValue

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(MarketCardStyle.allCases) { s in
                let on = styleRaw == s.rawValue
                Button { withAnimation(.snappy) { styleRaw = s.rawValue } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: s.symbol).font(.system(size: 14, weight: .medium))
                        Text(s.title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(on ? Theme.text : Theme.muted)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(on ? Theme.bg : Theme.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Theme.text : Theme.border, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
