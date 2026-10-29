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

/// The checks every money move runs through (demo: baseChecks). Extras go before the daily limit.
func tradeChecks(_ extra: [String] = []) -> [String] {
    ["Requested by you, not by a web page or email", "Simulation matches summary", "Contract verified and audited",
     "Exact-amount token approval"] + extra + ["Within daily limit"]
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
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { y += line + lineSpacing; x = 0; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
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
            configuration.label.font(.system(size: 12.5, weight: .medium)).foregroundStyle(fg).lineLimit(1)
                .padding(.horizontal, 11).frame(height: height)
                .background(hovering && !configuration.isPressed && stroke != .clear ? Theme.hover : bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(stroke))
        }
        .opacity(enabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Big full-width action (Long HYPE, Swap): solid colour, 42 pt.
struct TradeBlockButton: ButtonStyle {
    var color: Color = Theme.text
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(color.opacity(configuration.isPressed ? 0.85 : enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 10))
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
                    l.1.monospacedDigit()
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
        return self.frame(width: width).frame(minHeight: height ?? 0, idealHeight: height).background(Theme.bg)
        #else
        return self.background(Theme.bg).presentationDetents(height == nil ? [.medium, .large] : [.large])
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
                                LogoMark(i.logo, size: 30)
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

/// "Ask" answer sheet: the question, Hermit's short answer, then continue in chat.
struct TradeAskSheet: View {
    let q: String
    let a: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 26).background(TradeColor.accentSoft, in: Circle())
                    Text("Ask Hermit").font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                TradeSheetClose { dismiss() }
            }
            HStack {
                Spacer(minLength: 60)
                Text(q).font(.system(size: 14)).padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 13))
            }
            Group {
                if shown {
                    Text(a).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking").foregroundStyle(Theme.muted) }
                        .font(.system(size: 13)).transition(.opacity)
                }
            }
            .frame(minHeight: 60, alignment: .topLeading)
            HStack(spacing: 10) {
                Button("Close") { dismiss() }.buttonStyle(SheetButton(primary: false))
                Button("Continue in chat") { dismiss(); model.send(q) }.buttonStyle(SheetButton(primary: true))
            }
        }
        .padding(22)
        .tradeSheet(width: 440)
        .task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.smooth(duration: 0.3)) { shown = true }
        }
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
