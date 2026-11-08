import SwiftUI
import HermitCore

// Small building blocks shared by Trade and Earn (kept here so the shared Components file stays untouched).

enum TradeColor {
    static let greenSoft = Color(hex: 0xF0FAF3)
    static let redSoft = Color(hex: 0xFDF2F2)
    static let amberSoft = Color(hex: 0xFEF9EC)
    static let accentSoft = Color(hex: 0xF4F0FA)
    static let support = Color(hex: 0x2563EB)
    static let resistance = Color(hex: 0x7C3AED)
}

// MARK: Number formatting

extension Double {
    /// 14010 -> "14,010"; fixed decimals with grouping.
    func tradeGrouped(_ dp: Int = 0) -> String {
        formatted(.number.grouping(.automatic).precision(.fractionLength(dp)))
    }
    /// Up to `max` decimals, trailing zeros dropped (like JS toLocaleString).
    func tradeTrim(_ max: Int = 2) -> String {
        formatted(.number.grouping(.automatic).precision(.fractionLength(0...max)))
    }
    /// "+$530" / "−$64"
    var tradeUSD: String { (self >= 0 ? "+$" : "−$") + abs(self).tradeGrouped() }
    /// "+5.8%" / "-1.1%"
    var tradePct: String { (self > 0 ? "+" : "") + tradeTrim(2) + "%" }
    /// A price at the precision it trades at: "81,690", "186.62", "1.4213", "0.00001912".
    var tradePx: String {
        let a = abs(self)
        if a >= 1000 { return tradeGrouped(a >= 10000 ? 0 : 1) }
        if a >= 1 { return formatted(.number.grouping(.automatic).precision(.fractionLength(2...(a >= 100 ? 2 : 4)))) }
        return formatted(.number.precision(.significantDigits(4)))
    }
    /// Decimals to show for a price, for the order book and the chart axis.
    var tradeDecimals: Int { let a = abs(self); return a >= 10000 ? 0 : a >= 1000 ? 1 : a >= 100 ? 2 : a >= 1 ? 4 : 6 }
    /// "$4.2B", "$880M", "$12.4K"
    var tradeCompactUSD: String {
        let a = abs(self)
        let (v, u): (Double, String) = a >= 1e12 ? (a / 1e12, "T") : a >= 1e9 ? (a / 1e9, "B") : a >= 1e6 ? (a / 1e6, "M") : a >= 1e3 ? (a / 1e3, "K") : (a, "")
        return "$" + v.formatted(.number.precision(.fractionLength(0...(v < 100 ? 1 : 0)))) + u
    }
}

// MARK: Width

/// Reads the width a view is given, so layouts can switch between the Mac and iPhone arrangement.
struct TradeWidthReader: ViewModifier {
    @Binding var width: CGFloat
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
extension View {
    func tradeWidth(_ w: Binding<CGFloat>) -> some View { modifier(TradeWidthReader(width: w)) }
}

// MARK: Layout

/// Wraps its children onto new lines (chips, tags). Nothing scrolls sideways.
struct TradeFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = Self.size(s, maxW)
            if x > 0, x + sz.width > maxW { y += line + lineSpacing; x = 0; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = Self.size(s, bounds.width)
            if x > bounds.minX, x + sz.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
    }

    /// Natural size, but never wider than the row: a wide item gets the row's width (and scrolls inside, if it can).
    private static func size(_ s: LayoutSubview, _ maxW: CGFloat) -> CGSize {
        let sz = s.sizeThatFits(.unspecified)
        return sz.width <= maxW ? sz : s.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
    }
}

/// Label over value, the plain stats row from the demo. Four across, two by two when narrow.
struct TradeStats: View {
    let items: [(String, String, Color)]
    @State private var width: CGFloat = 800
    var body: some View {
        let cols = width < 460 ? 2 : items.count
        Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: items.count, by: cols)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + cols, items.count), id: \.self) { i in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(items[i].0).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            Text(items[i].1).font(.system(size: 17, weight: .semibold)).tracking(-0.2).monospacedDigit()
                                .foregroundStyle(items[i].2).contentTransition(.numericText())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tradeWidth($width)
    }
}

/// Section heading: small grey title with an optional trailing control.
struct TradeSection<Trailing: View, Content: View>: View {
    let title: String
    var top: CGFloat = 36
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                trailing()
            }
            .frame(minHeight: 28)
            .padding(.bottom, 6)
            content()
        }
        .padding(.top, top)
    }
}
extension TradeSection where Trailing == EmptyView {
    init(title: String, top: CGFloat = 36, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, top: top, trailing: { EmptyView() }, content: content)
    }
}

/// Rows separated by hairlines (first row has none).
struct TradeRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder var row: (Data.Element) -> Row
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { i, e in
                VStack(spacing: 0) {
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    row(e)
                }
            }
        }
    }
}

// MARK: Buttons

/// The demo's small `.btn.sm`: 28 pt tall, bordered. Variants for black, purple and coloured text.
struct TradeSmallButton: ButtonStyle {
    enum Kind { case plain, primary, brand, tint(Color) }
    var kind: Kind = .plain
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg, stroke): (Color, Color, Color) = {
            switch kind {
            case .plain: (configuration.isPressed ? Theme.hover : Theme.bg, Theme.text, Theme.border)
            case .primary: (Theme.text.opacity(configuration.isPressed ? 0.82 : 1), .white, .clear)
            case .brand: (Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), .white, .clear)
            case .tint(let c): (configuration.isPressed ? Theme.hover : Theme.bg, c, Theme.border)
            }
        }()
        return TradeHover { hovering in
            configuration.label.font(.system(size: 12.5, weight: .medium)).foregroundStyle(enabled ? fg : Theme.disabledText).lineLimit(1)
                .padding(.horizontal, 11).frame(height: height)
                .background(!enabled ? Theme.disabledFill : hovering && !configuration.isPressed && stroke != .clear ? Theme.hover : bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(enabled ? stroke : .clear))
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Big full-width action (Long HYPE, Swap): solid colour, 42 pt.
struct TradeBlockButton: ButtonStyle {
    var color: Color = Theme.text
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(enabled ? .white : Theme.disabledText)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(enabled ? color.opacity(configuration.isPressed ? 0.85 : 1) : Theme.disabledFill, in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Pill chip; `on` turns it black (the active Hermit action).
struct TradeChip: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        TradeHover { hovering in
            configuration.label.font(.system(size: 12.5)).lineLimit(1)
                .foregroundStyle(on ? .white : hovering ? Theme.text : Theme.muted)
                .padding(.horizontal, 11).frame(height: 28)
                .background(on ? Theme.text : configuration.isPressed || hovering ? Theme.hover : Theme.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.text : Theme.border))
        }
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        .animation(.snappy(duration: 0.2), value: on)
    }
}

/// A whole list row as a button, with a soft hover wash on the Mac.
struct TradeRowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TradeHover { hovering in
            configuration.label.contentShape(Rectangle())
                .background((configuration.isPressed ? Theme.hover : hovering ? Theme.subtle : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, -8))
        }
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Tracks the pointer for hover states (no-op on iPhone).
struct TradeHover<C: View>: View {
    @ViewBuilder var content: (Bool) -> C
    @State private var hovering = false
    var body: some View {
        content(hovering).onHover { h in withAnimation(.snappy(duration: 0.15)) { hovering = h } }
    }
}

/// Full-width segmented control (Market / Limit) that stretches its options.
struct TradeWideSegmented: View {
    let options: [String]
    @Binding var selection: String
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { withAnimation(.snappy(duration: 0.22)) { selection = o } } label: {
                    Text(o).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == o ? Theme.text : Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background {
                            if selection == o {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.bg).shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(Theme.hover, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Grey label over value pairs (the demo's `.kv`): four across, two when narrow.
struct TradeKV: View {
    let pairs: [(String, String)]
    var colors: [String: Color] = [:]
    @State private var width: CGFloat = 600
    var body: some View {
        let cols = width < 420 ? 2 : 4
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: cols), alignment: .leading, spacing: 12) {
            ForEach(pairs, id: \.0) { k, v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(k).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Text(v).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(colors[k] ?? Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .tradeWidth($width)
    }
}

/// Grey panel of label/value lines (the demo's `.tx`).
struct TradeTx: View {
    let lines: [(String, AnyView)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(spacing: 12) {
                    Text(l.0).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    l.1.monospacedDigit().foregroundStyle(Theme.text)
                }
                .font(.system(size: 13)).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// Text field in a bordered box (TP, SL, limit price, vault address).
struct TradeField: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 40
    var mono = false
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 14).monospaced() : .system(size: 14))
            .monospacedDigit()
            .padding(.horizontal, 11).frame(height: height)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

/// Close button used in the sheets' headers.
struct TradeSheetClose: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28).background(Theme.hover, in: Circle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.cancelAction)
    }
}

extension View {
    /// Sheet sizing: a fixed comfortable width on the Mac, detents on iPhone.
    func tradeSheet(width: CGFloat = 540, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        return self.frame(width: width).frame(minHeight: height ?? 0, idealHeight: height).background(SheetPaper())
        #else
        return self.glassSheetBackground().presentationDetents(height == nil ? [.medium, .large] : [.large])
            .presentationDragIndicator(.visible).presentationCornerRadius(20)
        #endif
    }
}

/// "Explore more ..." button pair at the bottom of Trade and Earn. Picking an item asks Hermit about it.
struct TradeExploreItem: Identifiable, Hashable {
    var id: String { name + (tag ?? "") }
    let name: String
    let logo: String
    let sub: String
    var metric: String? = nil
    var tag: String? = nil
    /// True when `logo` is a protocol name LogoMark knows; otherwise it's a token symbol checked against TradeData.tokenLogos.
    var logoKnown = false
}

struct TradeExploreMore: View {
    let label: String
    let items: [TradeExploreItem]
    @State private var open = false
    var body: some View {
        HStack(spacing: 8) {
            Button { open = true } label: { Text("Explore more \(label)").frame(maxWidth: .infinity) }
                .buttonStyle(TradeSmallButton(height: 40))
            Button { open = true } label: { Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).frame(width: 18) }
                .buttonStyle(TradeSmallButton(height: 40))
                .accessibilityLabel("Search \(label)")
        }
        .padding(.top, 36)
        .sheet(isPresented: $open) { TradeExploreSheet(label: label, items: items) }
    }
}

struct TradeExploreSheet: View {
    let label: String
    let items: [TradeExploreItem]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @FocusState private var focused: Bool

    var body: some View {
        let list = items.filter { q.isEmpty || "\($0.name) \($0.sub) \($0.tag ?? "")".localizedCaseInsensitiveContains(q) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    TextField("Search \(label)", text: $q).textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
                TradeSheetClose { dismiss() }
            }
            .padding(16)
            Divider().overlay(Theme.border)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { i in
                        Button {
                            dismiss(); model.send("Tell me about \(i.name)")
                        } label: {
                            HStack(spacing: 12) {
                                MarketLogo(key: i.logoKnown ? i.logo : TradeData.logo(i.logo), name: i.name, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(i.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                                    Text(i.sub).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let m = i.metric { Text(m).font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit() }
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(TradeRowButton())
                    }
                    if list.isEmpty {
                        Text("No results").foregroundStyle(Theme.muted).padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
        }
        .tradeSheet(width: 520, height: 600)
        .onAppear { focused = true }
    }
}

// MARK: Logos and states

/// A logo only when it's the right one: `key` goes to LogoMark, nil gets a neutral letter mark (never a lookalike).
struct MarketLogo: View {
    let key: String?
    let name: String
    var size: CGFloat = 32
    /// A logo from the web when there's no bundled one (DefiLlama's protocol icon for a pool).
    /// Without it, coins look one up by symbol. The letter shows while it loads or if there is none.
    var remote: URL? = nil

    var body: some View {
        if let key { LogoMark(key, size: size) }
        else if remote == nil, let file = Self.bundled(name) {
            Image.logo(file).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.border.opacity(0.6)))
                .accessibilityHidden(true)
        } else if remote == nil, let a = Self.asset(name) {
            Group {
                if let flag = a.flag { Text(flag).font(.system(size: size * 0.62)) }
                else { Image(systemName: a.symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(a.tint) }
            }
            .frame(width: size, height: size).background(a.tint.opacity(0.13), in: Circle())
            .accessibilityHidden(true)
        } else {
            let urls = remote.map { [$0] } ?? Self.iconCandidates(name)
            if urls.isEmpty { letter } else { RemoteIcon(urls: urls, size: size) { letter } }
        }
    }

    private var letter: some View {
        Text(String(name.filter(\.isLetter).prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Theme.muted)
            .frame(width: size, height: size).background(Theme.hover, in: Circle())
            .accessibilityHidden(true)
    }

    /// "xyz:TSLA" → "TSLA", "kPEPE" → "PEPE", "HYPE / USDC" → "HYPE".
    static func symbol(_ name: String) -> String {
        var sym = String(name.split(separator: " ").first ?? "")
        if let i = sym.lastIndex(of: ":") { sym = String(sym[sym.index(after: i)...]) }
        sym = sym.filter { $0.isLetter || $0.isNumber }
        if sym.count > 2, sym.first == "k", sym.dropFirst().allSatisfy({ $0.isUppercase || $0.isNumber }) { sym.removeFirst() }
        return sym
    }

    /// Logos bundled with the app (every Hyperliquid perp and trade.xyz stock when this build was made), as "mk-<symbol>".
    private static let bundledNames: Set<String> = {
        let urls = Bundle.module.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        return Set(urls.map { $0.deletingPathExtension().lastPathComponent }.filter { $0.hasPrefix("mk-") })
    }()

    static func bundled(_ name: String) -> String? {
        let f = "mk-" + symbol(name).lowercased()
        return bundledNames.contains(f) ? f : nil
    }

    /// Commodities, currencies and indices on trade.xyz have no company logo: a flag or a drawn mark instead.
    static func asset(_ name: String) -> (flag: String?, symbol: String, tint: Color)? {
        let metal = Color(hex: 0xB8902F), oil = Color(hex: 0x2B2B2B), gas = Color(hex: 0x2F6FDB), crop = Color(hex: 0x4E8A2E)
        switch symbol(name).uppercased() {
        case "GOLD": return (nil, "circle.hexagongrid.fill", metal)
        case "SILVER", "PLATINUM", "PALLADIUM", "ALUMINIUM": return (nil, "circle.hexagongrid.fill", Color(hex: 0x8A8F98))
        case "COPPER": return (nil, "circle.hexagongrid.fill", Color(hex: 0xB86B3C))
        case "CL", "BRENTOIL", "HO": return (nil, "drop.fill", oil)
        case "NATGAS", "TTF": return (nil, "flame.fill", gas)
        case "CORN", "WHEAT": return (nil, "leaf.fill", crop)
        case "URANIUM": return (nil, "atom", Color(hex: 0x3C8D5A))
        case "VIX", "VOL": return (nil, "waveform.path.ecg", Theme.red)
        case "DXY": return ("💵", "", crop)
        case "SP500", "XYZ100": return ("🇺🇸", "", gas)
        case "JPY", "JP225": return ("🇯🇵", "", Theme.red)
        case "EUR": return ("🇪🇺", "", gas)
        case "GBP": return ("🇬🇧", "", gas)
        case "KRW", "KR200": return ("🇰🇷", "", gas)
        case "NIFTY": return ("🇮🇳", "", metal)
        case "IBOV": return ("🇧🇷", "", crop)
        default: return nil
        }
    }

    /// CoinCap's icon set, by symbol. Hyperliquid's thousand-unit tokens (kPEPE, kBONK) use the plain symbol.
    static func coinIcon(_ name: String) -> URL? {
        var sym = String(name.split(separator: " ").first ?? "").filter { $0.isLetter || $0.isNumber }
        if sym.count > 2, sym.first == "k", sym.dropFirst().allSatisfy(\.isUppercase) { sym.removeFirst() }
        guard (2...10).contains(sym.count) else { return nil }
        return URL(string: "https://assets.coincap.io/assets/icons/\(sym.lowercased())@2x.png")
    }

    /// Where a market's icon might be, tried in order: CoinCap for crypto, then the stock logo for trade.xyz tickers (NVDA).
    static func iconCandidates(_ name: String) -> [URL] {
        guard let coin = coinIcon(name) else { return [] }
        let sym = String(name.split(separator: " ").first ?? "").filter { $0.isLetter || $0.isNumber }.uppercased()
        let stock = URL(string: "https://financialmodelingprep.com/image-stock/\(sym).png")
        return [coin] + (stock.map { [$0] } ?? [])
    }

    /// DefiLlama's icon for a protocol slug, e.g. "rocket-pool".
    static func protocolIcon(_ project: String) -> URL? {
        URL(string: "https://icons.llamao.fi/icons/protocols/\(project)?w=64&h=64")
    }
}

/// Tries each URL in turn and shows the first image that loads; the placeholder while loading or if none does.
private struct RemoteIcon<Placeholder: View>: View {
    let urls: [URL]
    let size: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var index = 0

    var body: some View {
        AsyncImage(url: urls[min(index, urls.count - 1)], transaction: Transaction(animation: .smooth(duration: 0.2))) { phase in
            switch phase {
            case .success(let img):
                img.resizable().interpolation(.high).scaledToFill()
                    .frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.border.opacity(0.6)))
            case .failure:
                placeholder().onAppear { if index < urls.count - 1 { index += 1 } }
            default:
                placeholder()
            }
        }
        .id(index)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Loading, failed or empty: one quiet line, with Retry when a fetch failed.
struct MarketStatus: View {
    enum Kind { case loading(String), failed(String), empty(String) }
    let kind: Kind
    var retry: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .loading(let t):
                ProgressView().controlSize(.small)
                Text(t).foregroundStyle(Theme.muted)
            case .failed(let t):
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.faint)
                Text(t).foregroundStyle(Theme.muted)
                if let retry { Button("Retry", action: retry).buttonStyle(TradeSmallButton()) }
            case .empty(let t):
                Text(t).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13.5))
        .padding(.vertical, 12)
    }
}

/// The note under a greyed-out action: what isn't wired up yet.
struct TradeSoon: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 11.5))
            Text(text)
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity)
    }
}

/// "Prices from Hyperliquid" style source line.
struct MarketSource: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.faint)
    }
}

/// Hermit's suggestion mark (sparkles in a soft purple circle).
struct TradeSpark: View {
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: "sparkles").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(Theme.accent)
            .frame(width: size, height: size).background(TradeColor.accentSoft, in: Circle())
    }
}
