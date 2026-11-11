import SwiftUI
import HermitCore

// Small parts every chat card is built from: a header row, a footer with buttons, key/value lines,
// stat grids, status tags and chips. Same look as the demo's .ccard.

extension Tone {
    var color: Color {
        switch self {
        case .text: Theme.text
        case .accent: Theme.accent
        case .lilac: Color(hex: 0x8E73CF)
        case .green: Theme.green
        case .red: Theme.red
        case .amber: Theme.amber
        }
    }
}

extension Theme {
    static let greenSoft = Color(hex: 0x15803D, opacity: 0.09)
    static let redSoft = Color(hex: 0xC53030, opacity: 0.08)
    static let amberSoft = Color(hex: 0xA16207, opacity: 0.1)
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// A chat card: optional header, body, optional footer with a hairline above it.
struct ChatCard<Head: View, Content: View, Foot: View>: View {
    @ViewBuilder var head: () -> Head
    @ViewBuilder var content: () -> Content
    @ViewBuilder var foot: () -> Foot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Head.self != EmptyView.self {
                HStack(alignment: .center, spacing: 10) { head() }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            if Foot.self != EmptyView.self {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 8) { foot() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.text)
        .card()
    }
}

extension ChatCard where Foot == EmptyView {
    init(@ViewBuilder head: @escaping () -> Head, @ViewBuilder content: @escaping () -> Content) {
        self.init(head: head, content: content, foot: { EmptyView() })
    }
}

extension ChatCard where Head == EmptyView, Foot == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.init(head: { EmptyView() }, content: content, foot: { EmptyView() })
    }
}

/// Header title: medium weight, one line.
struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 13.5, weight: .medium)).lineLimit(1) }
}

/// Label on the left, value on the right.
struct TxLine: View {
    let key: String
    let value: String
    var mono = false
    init(_ key: String, _ value: String, mono: Bool = false) { self.key = key; self.value = value; self.mono = mono }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
                .font(mono ? Theme.mono : .system(size: 13))
        }
        .font(.system(size: 13))
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// Small stats in columns: label above, value below.
struct KVGrid: View {
    let pairs: [[String]]
    var tones: [String: Tone] = [:]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
            ForEach(pairs, id: \.self) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.first ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(p.last ?? "").font(.system(size: 14, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(tones[p.first ?? ""]?.color ?? Theme.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Status pill with a dot: Healthy, Live, Auto-approved.
struct StatusTag: View {
    let text: String
    var tone: Tone = .green
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(tone == .text ? Theme.muted : tone.color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(soft, in: Capsule())
    }
    private var soft: Color {
        switch tone {
        case .green: Theme.greenSoft
        case .red: Theme.redSoft
        case .amber: Theme.amberSoft
        default: Theme.hover
        }
    }
}

/// Small chip button inside cards. `on` fills it black (or red for shorts).
struct SmallChip: ButtonStyle {
    var on = false
    var tone: Tone = .text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: on ? .medium : .regular)).lineLimit(1)
            .foregroundStyle(on ? .white : Theme.text)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(on ? tone.color.opacity(configuration.isPressed ? 0.85 : 1) : (configuration.isPressed ? Theme.hover : Theme.bg), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Purple key action with an optional symbol (Turn on, Send to 48 wallets, Get API key).
struct BrandButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var full = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(enabled ? .white : Theme.disabledText)
            .frame(maxWidth: full ? .infinity : nil)
            .padding(.horizontal, 14).padding(.vertical, full ? 12 : 8)
            .background(enabled ? Theme.accent.opacity(configuration.isPressed ? 0.85 : 1) : Theme.disabledFill, in: RoundedRectangle(cornerRadius: full ? 11 : 9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// White secondary button with a border and a press scale.
struct PlainCardButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(configuration.isPressed ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Round icon in a soft square, for apps and file types without a logo.
struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 32
    var tint: Color = Theme.text
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .regular)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Theme.border))
    }
}

/// Lays out children left to right and wraps onto new lines (chips, tags).
struct Flow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x > 0 && x + w > width { y += line + lineSpacing; x = 0; line = 0 }
            x += w + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
            x += w + spacing; line = max(line, size.height)
        }
    }
}

/// Markdown **bold** inline, as the agent writes it.
func rich(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: approxTildes(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// A lone ~ means "about" ("(~$1,130)"), never strikethrough: two of them in a reply used to strike out the text
/// between. Only ~~text~~ still strikes through.
func approxTildes(_ s: String) -> String {
    guard s.contains("~") else { return s }
    let c = Array(s)
    var out = ""
    for i in c.indices {
        if c[i] == "~", (i == 0 || c[i - 1] != "~"), (i == c.count - 1 || c[i + 1] != "~"), (i == 0 || c[i - 1] != "\\") {
            out += "\\~"
        } else {
            out.append(c[i])
        }
    }
    return out
}

extension Double {
    /// Prices with as many decimals as they need: $0.0334, $24.06, $3,498.
    var price: String {
        if self < 0.001 { return String(format: "$%.7f", self) }
        if self < 1 { return String(format: "$%.4f", self) }
        if self < 100 { return String(format: "$%.2f", self) }
        return "$" + formatted(.number.precision(.fractionLength(0)))
    }
}
