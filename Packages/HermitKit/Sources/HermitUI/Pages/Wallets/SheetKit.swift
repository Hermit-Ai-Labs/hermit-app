import SwiftUI
import CoreImage.CIFilterBuiltins
import HermitCore
import HermitWallet

// Small building blocks for the Wallets, Settings, Connectors and Files pages:
// the sheet frame, form fields, selectable rows, list rows with hover, the QR code and the approval hand-off.

// MARK: Sheet

/// A sheet: title row with close (and optional back), scrolling body, optional footer.
/// Centered dialog on the Mac (sized to its content), a bottom sheet on iPhone.
struct SheetChrome<Content: View, Foot: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 460
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var foot: () -> Foot
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 320
    @State private var headHeight: CGFloat = 62
    @State private var footHeight: CGFloat = 0

    private var hasFoot: Bool { Foot.self != EmptyView.self }
    /// The home indicator already leaves room under the button on iPhone.
    #if os(iOS)
    private let footBottom: CGFloat = 20
    #else
    private let footBottom: CGFloat = 20
    #endif
    private var fittedHeight: CGFloat { ceil(headHeight + contentHeight + (hasFoot ? footHeight : 0)) }
    #if os(iOS)
    private var fitsScreen: Bool { fittedHeight <= SheetMetrics.maxHeight }
    #else
    private var fitsScreen: Bool { contentHeight <= 580 }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 28, height: 28).background(Theme.hover, in: Circle())
                    }
                    .buttonStyle(PressStyle()).keyboardShortcut(.cancelAction)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28).background(Theme.hover, in: Circle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 22).padding(.top, SheetMetricsTop.value).padding(.bottom, 14)
            .animation(.snappy, value: onBack == nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }

            scroll

            if hasFoot {
                HStack(spacing: 8) { foot() }
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, footBottom)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1).opacity(fitsScreen ? 0 : 1) }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footHeight = $0 }
            }
        }
        #if os(macOS)
        .background(Theme.bg)
        .frame(width: width)
        #else
        // iOS 26 sheets float above the home indicator: lay out to the sheet's own bottom edge and pad it ourselves,
        // so the height we ask for is exactly what's drawn (no extra band under the last row).
        .ignoresSafeArea(.container, edges: .bottom)
        // Exactly as tall as what's in it: title row, content, button row and the home indicator. No empty band at the bottom.
        // Content taller than the screen gets the full sheet and scrolls.
        .presentationDetents([.height(min(fittedHeight, SheetMetrics.maxHeight))])
        .presentationDragIndicator(.visible)
        #endif
        .presentationCornerRadius(20)
        .glassSheetBackground()
    }

    @ViewBuilder private var scroll: some View {
        let inner = VStack(alignment: .leading, spacing: 14) { content() }
            .padding(.horizontal, 22).padding(.bottom, hasFoot ? 6 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        if SnapshotMode.active { inner.fixedSize(horizontal: false, vertical: true) } else {
            ScrollView { inner }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                #if os(macOS)
                .frame(height: min(contentHeight, 580))
                #endif
        }
    }
}

extension SheetChrome where Foot == EmptyView {
    init(title: String, subtitle: String? = nil, width: CGFloat = 460, onBack: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, width: width, onBack: onBack, content: content, foot: { EmptyView() })
    }
}

/// Black full-width primary button for sheet footers (purple stays for Approve and key brand actions).
struct WideButton: ButtonStyle {
    var kind: Kind = .black
    enum Kind { case black, accent, plain }
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(!enabled ? Theme.disabledText : kind == .plain ? Theme.text : .white)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(enabled ? fill.opacity(configuration.isPressed ? 0.85 : 1) : Theme.disabledFill, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(enabled && kind == .plain ? Theme.border : .clear))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
    private var fill: Color { kind == .black ? Theme.text : kind == .accent ? Theme.accent : Theme.bg }
}

// MARK: Fields

/// A labelled form field.
struct FormField<Content: View>: View {
    let label: String
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12.5)).foregroundStyle(Theme.faint).monospacedDigit() }
            }
            content()
        }
    }
}

/// The boxed look shared by text inputs and menu pickers.
struct FieldBox: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content.padding(.horizontal, 12).frame(minHeight: 40)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Theme.text.opacity(0.5) : Color.white.opacity(0.75)))
    }
}

struct BoxedTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    @FocusState private var focus: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 13.5, design: .monospaced) : .system(size: 14))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($focus)
            .modifier(FieldBox(focused: focus))
            .animation(.snappy(duration: 0.15), value: focus)
    }
}

struct AmountField: View {
    @Binding var value: Double
    var suffix: String? = nil
    @FocusState private var focus: Bool
    var body: some View {
        HStack {
            TextField("0", value: $value, format: .number.precision(.fractionLength(0...6)).locale(Locale(identifier: "en_US")))
                .textFieldStyle(.plain).font(.system(size: 14)).monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .focused($focus)
            if let suffix { Text(suffix).font(.system(size: 13)).foregroundStyle(Theme.faint) }
        }
        .modifier(FieldBox(focused: focus))
    }
}

/// A native menu that looks like a field: the current value, its logo, and a chevron.
struct MenuField<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String
    var logo: ((T) -> String?)? = nil
    var symbol: ((T) -> String?)? = nil

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { o in Text(title(o)).tag(o) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                if let l = logo?(selection) { LogoMark(l, size: 18) }
                if let s = symbol?(selection) { Image(systemName: s).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Text(title(selection)).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .modifier(FieldBox())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Selectable chip (quick amounts, filters). Selected is black.
struct SelectChip: View {
    let title: String
    var logo: String? = nil
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: { withAnimation(.snappy(duration: 0.2)) { action() } }) {
            HStack(spacing: 6) {
                if let logo { LogoMark(logo, size: 15) }
                Text(title).font(.system(size: 12.5, weight: on ? .medium : .regular)).lineLimit(1)
            }
            .foregroundStyle(on ? Theme.bg : Theme.text)
            .padding(.horizontal, 11).frame(height: 30)
            .background(on ? Theme.text : Theme.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Theme.text : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// Lays chips out in rows that wrap (never sideways scrolling).
struct WrapRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > 0 && x + z.width > maxW { y += row + spacing; x = 0; row = 0 }
            x += z.width + spacing; row = max(row, z.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let z = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + z.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(z))
            x += z.width + spacing; row = max(row, z.height)
        }
    }
}

/// A big selectable row with a border (top-up sources, whitelist, add-wallet options).
struct SelectRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var mono = false
    var on = false
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false

    var body: some View {
        Button(action: { withAnimation(.snappy(duration: 0.2)) { action() } }) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                            .foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                trailing()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(hover && !on ? Theme.subtle : Theme.bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Theme.text : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}

extension SelectRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, mono: Bool = false, on: Bool = false, action: @escaping () -> Void, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle, mono: mono, on: on, action: action, leading: leading, trailing: { EmptyView() })
    }
}

/// Square app-style icon for an SF Symbol (wallet types, file kinds).
struct WalletSymbolTile: View {
    let symbol: String
    var size: CGFloat = 34
    var tint: Color = Theme.text
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .regular)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Theme.border))
    }
}

/// A key-value block (receipts, details) in a soft panel.
struct DetailLines: View {
    let lines: [(String, String)]
    var monoKeys: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(l.0).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    Text(l.1).multilineTextAlignment(.trailing).monospacedDigit()
                        .font(monoKeys.contains(l.0) ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                }
                .font(.system(size: 13.5)).padding(.vertical, 9)
                if i < lines.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

struct NoteBox: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.muted
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint).padding(.top, 1)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Small coloured tag ("24h hold", "Ready", "Active").
struct PillTag: View {
    let text: String
    var color: Color = Theme.green
    var dot = false
    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }
}

// MARK: Lists

/// Plain list row button with a soft hover highlight that bleeds past the text edges.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }
    struct RowBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(configuration.isPressed ? Theme.hover : hover ? Theme.subtle : .clear))
                .padding(.horizontal, -10)
                .onHover { h in withAnimation(.snappy(duration: 0.12)) { hover = h } }
        }
    }
}

/// 1 pt list separator.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

/// Rows separated by hairlines.
struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item)
                if i < items.count - 1 { Hairline() }
            }
        }
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.muted).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Section label above a block ("Whitelist", "Gas").
struct SectionLabel<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
            Spacer()
            trailing()
        }
    }
}
extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

// MARK: Wallet bits

/// Token logo with the chain's logo as a small badge.
struct TokenLogo: View {
    let symbol: String
    var chain: Chain? = nil
    var size: CGFloat = 32
    var body: some View {
        LogoMark(symbol, size: size)
            .overlay(alignment: .bottomTrailing) {
                if let chain, chain.logo.lowercased() != symbol.lowercased(), !(chain == .solana && symbol == "SOL") {
                    LogoMark(chain.logo, size: size * 0.44)
                        .padding(1.5).background(Theme.bg, in: Circle())
                        .offset(x: size * 0.1, y: size * 0.08)
                }
            }
    }
}

/// Overlapping chain logos ("on Base, Ethereum and Solana").
struct ChainStack: View {
    let chains: [Chain]
    var size: CGFloat = 16
    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(chains) { c in LogoMark(c.logo, size: size).padding(1).background(Theme.bg, in: Circle()) }
        }
    }
}

/// Binance-style round action: icon in a soft circle, label under it.
struct RoundAction: View {
    let title: String
    let symbol: String
    var accent = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent ? .white : Theme.text)
                    .frame(width: 46, height: 46)
                    .background(accent ? Theme.accent : (hover ? Theme.border : Theme.hover), in: Circle())
                Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(minWidth: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}

/// A real QR code for an address (Core Image), drawn crisp.
struct AddressQR: View {
    let text: String
    var body: some View {
        Self.image(text).interpolation(.none).resizable().scaledToFit()
            .accessibilityLabel("QR code for \(text)")
    }
    static func image(_ s: String) -> Image {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return Image(systemName: "qrcode") }
        return Image(decorative: cg, scale: 1)
    }
}

/// System clipboard.
enum Clip {
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

// MARK: Approval hand-off

/// Opens the shared approval sheet for a money move and runs `then` only if it was approved.
/// Pages close their own sheet first; the approval sheet follows once it has gone.
struct AskApproval {
    var run: @MainActor (Approval, @escaping @MainActor () -> Void) -> Void = { _, _ in }
    @MainActor func callAsFunction(_ a: Approval, then: @escaping @MainActor () -> Void = {}) { run(a, then) }
}

private struct AskApprovalKey: EnvironmentKey { static let defaultValue = AskApproval() }
extension EnvironmentValues {
    var askApproval: AskApproval {
        get { self[AskApprovalKey.self] }
        set { self[AskApprovalKey.self] = newValue }
    }
}

/// Install once per page. `closeSheets` dismisses the page's own sheet before the approval sheet comes up.
struct ApprovalHost: ViewModifier {
    @Environment(AppModel.self) private var model
    let closeSheets: () -> Void
    let sheetOpen: Bool
    @State private var pending: (id: String, count: Int, run: @MainActor () -> Void)?

    func body(content: Content) -> some View {
        content
            .environment(\.askApproval, AskApproval { a, then in
                let wait = sheetOpen
                closeSheets()
                Task { @MainActor in
                    if wait { try? await Task.sleep(for: .milliseconds(450)) }
                    pending = (a.id, model.approvalCount, then)
                    model.approval = a
                }
            })
            .onChange(of: model.approval == nil) { _, closed in
                guard closed, let p = pending else { return }
                pending = nil
                // approvalCount only moves when the sheet was approved, not cancelled.
                if model.approvalCount > p.count { p.run() }
            }
    }
}

extension View {
    func approvalHost(sheetOpen: Bool, close: @escaping () -> Void) -> some View {
        modifier(ApprovalHost(closeSheets: close, sheetOpen: sheetOpen))
    }
}

#if os(iOS)
/// A bottom sheet exactly as tall as what's in it (plus the home indicator); taller than the screen, it opens full height
/// and scrolls. For sheets that don't use SheetChrome (the approval sheet, flow cards).
struct FitSheet: ViewModifier {
    @State private var height: CGFloat = 420
    func body(content: Content) -> some View {
        let fitted = ceil(height + 20)
        ScrollView {
            content.padding(.top, 10).padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .ignoresSafeArea(.container, edges: .bottom)
        .presentationDetents([.height(min(fitted, SheetMetrics.maxHeight))])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .glassSheetBackground()
    }
}

enum SheetMetrics {
    /// The tallest a sheet gets: the screen less the status bar and a peek of the page behind.
    @MainActor static var maxHeight: CGFloat { UIScreen.main.bounds.height - 64 }
}
#endif

extension View {
    /// See FitSheet. No-op on the Mac, where sheets size to their content anyway.
    @ViewBuilder func fitSheet() -> some View {
        #if os(iOS)
        modifier(FitSheet())
        #else
        self
        #endif
    }
}

extension View {
    /// Liquid glass, paper tint (design A3): the app blurred through a frosted pane tinted to Hermit's paper, bright top edge. iPhone only;
    /// the Mac keeps paper.
    @ViewBuilder func glassSheetBackground() -> some View {
        #if os(iOS)
        presentationBackground {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(red: 244 / 255, green: 242 / 255, blue: 236 / 255).opacity(0.66)   // design A3: glass tinted to Hermit's paper
                LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12))
            }
        }
        #else
        presentationBackground(Theme.bg)
        #endif
    }
}
