import SwiftUI
import HermitCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Small building blocks shared by Payments, Calendar and Explore. Prefixed Pay* so they never clash
// with the shared design system in Components.swift.

// MARK: Empty states and unbuilt controls

/// A clean empty state: icon, one line, a short note and a single action.
struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    var text: String? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.faint)
                .padding(.bottom, 4)
            Text(title).font(.system(size: 15, weight: .medium))
            if let text {
                Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            }
            action().padding(.top, 8)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 52)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, text: String? = nil) {
        self.init(symbol: symbol, title: title, text: text) { EmptyView() }
    }
}

extension View {
    /// Greys out a control whose feature isn't built yet. The reason shows on hover.
    func comingSoon(_ note: String = "Coming soon") -> some View {
        disabled(true).help(note)
    }
}

// MARK: Saving

/// Small JSON files in Application Support/Hermit for page state (payees, calendar tasks, the files index).
/// Snapshot runs never read or write them.
enum LocalJSON {
    static var dir: URL? {
        guard !SnapshotMode.active,
              let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Hermit") else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let url = dir?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let url = dir?.appendingPathComponent(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension View {
    /// Reports the width this view gets, for adaptive (iPhone) layouts.
    func payWidth(_ w: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w.wrappedValue = $0 }
    }

    /// 1 px separator above a row (not above the first one).
    func payLine(_ show: Bool) -> some View {
        overlay(alignment: .top) { if show { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    /// White input box with a hairline border, 40 pt tall.
    func payInputBox(height: CGFloat = 40) -> some View {
        padding(.horizontal, 12).frame(height: height)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

enum PayClipboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
    static func paste() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}

// MARK: Layout

/// Wrapping row (chips). Keeps phones from ever scrolling sideways.
struct PayFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + lineSpacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

// MARK: Controls

/// Filter chip: outlined, black when on.
struct PayChip<Label: View>: View {
    let on: Bool
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(.system(size: 12.5, weight: on ? .medium : .regular)).lineLimit(1)
                .foregroundStyle(on ? Color.white : hover ? Theme.text : Theme.muted)
                .padding(.horizontal, 11).frame(height: PayMetrics.chip)
                .background(on ? Theme.text : hover ? Theme.hover : Theme.bg, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.text : Theme.border))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.2), value: on)
        .animation(.snappy(duration: 0.15), value: hover)
    }
}

extension PayChip where Label == Text {
    init(_ title: String, on: Bool, action: @escaping () -> Void) {
        self.init(on: on, action: action) { Text(title) }
    }
}

enum PayMetrics {
    #if os(iOS)
    static let chip: CGFloat = 34
    static let icon: CGFloat = 40
    #else
    static let chip: CGFloat = 28
    static let icon: CGFloat = 30
    #endif
}

/// Full-width row button with a soft hover wash that bleeds a little past the text, like macOS lists.
struct PayRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PayRowBody(configuration: configuration) }
}

private struct PayRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State var hover = false
    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Theme.hover : hover ? Theme.subtle : .clear))
            .padding(.horizontal, -10)
            .onHover { hover = $0 }
            .animation(.snappy(duration: 0.15), value: hover)
    }
}

/// Square icon button (chevrons, close) with a hover circle.
struct PayIconButton: View {
    let symbol: String
    var label = ""
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : Theme.muted)
                .frame(width: PayMetrics.icon, height: PayMetrics.icon)
                .background(hover ? Theme.hover : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

/// Wide footer buttons inside sheets.
struct PayWideButton: ButtonStyle {
    enum Kind { case black, accent, plain, danger }
    var kind: Kind = .black
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fg: Color = switch kind { case .black, .accent: .white; case .plain: Theme.text; case .danger: Theme.red }
        let bg: Color = switch kind {
            case .black: Theme.text; case .accent: Theme.accent; case .plain: Theme.hover; case .danger: Theme.red.opacity(0.08)
        }
        return configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(enabled ? fg : Theme.disabledText)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(enabled ? bg.opacity(configuration.isPressed ? 0.85 : 1) : Theme.disabledFill, in: RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Small pill button for list rows (Review, Pay, Buy).
struct PayPillButton: ButtonStyle {
    enum Kind { case black, accent, outline }
    var kind: Kind = .black
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(kind == .outline ? Theme.text : .white)
            .padding(.horizontal, 12).frame(height: 30)
            .background(kind == .black ? Theme.text : kind == .accent ? Theme.accent : configuration.isPressed ? Theme.hover : Theme.bg,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kind == .outline ? Theme.border : .clear))
            .opacity(configuration.isPressed && kind != .outline ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: Text blocks

struct PaySectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack { Text(title); Spacer(); trailing() }
            .font(.system(size: 13)).foregroundStyle(Theme.muted)
            .frame(minHeight: 28).padding(.bottom, 4)
    }
}

extension PaySectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Labelled form field, like the demo's `.field`.
struct PayField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A dropdown that looks like an input box (Menu under the hood, so it is native on both platforms).
struct PayMenuField<V: Hashable>: View {
    let options: [(V, String)]
    @Binding var selection: V
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button { selection = o.0 } label: {
                    if o.0 == selection { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? "").font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .payInputBox()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Key/value lines in a soft panel (sheet summaries).
struct PayLines: View {
    let lines: [(String, String)]
    var body: some View {
        VStack(spacing: 9) {
            ForEach(lines, id: \.0) { l in
                HStack(alignment: .firstTextBaseline) {
                    Text(l.0).foregroundStyle(Theme.muted)
                    Spacer(minLength: 12)
                    Text(l.1).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .font(.system(size: 13.5))
            }
        }
        .padding(14)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// Green "Running" style status with a softly breathing dot.
struct PayLiveTag: View {
    let text: String
    var color: Color = Theme.green
    var body: some View {
        HStack(spacing: 6) {
            PayPulseDot(color: color)
            Text(text)
        }
        .font(.system(size: 12)).foregroundStyle(color)
    }
}

struct PayPulseDot: View {
    var color: Color = Theme.green
    var size: CGFloat = 6
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background {
                if !SnapshotMode.active {
                    Circle().fill(color.opacity(0.35)).frame(width: size, height: size)
                        .phaseAnimator([false, true]) { v, on in v.scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 1) }
                            animation: { on in on ? .smooth(duration: 1.4) : nil }
                }
            }
    }
}

// MARK: Logos

/// Real logo when one exists; otherwise a symbol (Landlord) or a soft ENS-style gradient avatar.
struct PayLogo: View {
    let name: String
    var size: CGFloat = 32

    static let symbols: [String: String] = ["landlord": "house.fill", "mom": "heart.fill", "my trading": "chart.line.uptrend.xyaxis",
                                            "my vault": "lock.fill", "my main": "wallet.bifold.fill"]

    var body: some View {
        let k = name.lowercased()
        if k == "hermit" || LogoMark.round[k] != nil || LogoMark.apps[k] != nil {
            LogoMark(name, size: size)
        } else if let s = Self.symbols[k] {
            Image(systemName: s).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(Theme.muted)
                .frame(width: size, height: size)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: size * 0.28))
        } else {
            let h = name.unicodeScalars.reduce(5381) { (($0 << 5) &+ $0 &+ Int($1.value)) & 0x7FFFFFFF }
            let palette: [(UInt32, UInt32)] = [(0xC9BFE6, 0x8E73CF), (0xBFD7EA, 0x5B8DB8), (0xF2D0C4, 0xC2734F),
                                               (0xCFE3CF, 0x5E9467), (0xEAD9B8, 0xB08A3E), (0xD9D2E9, 0x6E5A9C)]
            let p = palette[h % palette.count]
            Circle().fill(LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.black.opacity(0.06)))
        }
    }
}
