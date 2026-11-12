import SwiftUI

// The look of Budgets: the Home "Crypto today" card (HoloWash behind, frosted white tiles at 78%, serif figure) made bigger,
// with big coloured buttons. Used by GuardViews.swift only; nothing here carries logic.

/// The pastel holo wash behind a card with a hairline border, like Home's market card but with a larger radius.
struct HoloCardBackground: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background { HoloWash().clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border))
    }
}

/// A frosted white tile on the wash (the coin tiles on Home: white at 78%).
struct HoloTileBackground: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content.background(Color.white.opacity(0.78), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A solid white tile with a hairline, for lists on the sheet's own background.
struct PaperTileBackground: ViewModifier {
    var radius: CGFloat = 20
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(tint?.opacity(0.35) ?? Theme.border))
    }
}

extension View {
    func holoCard(radius: CGFloat = 22) -> some View { modifier(HoloCardBackground(radius: radius)) }
    func holoTile(radius: CGFloat = 18) -> some View { modifier(HoloTileBackground(radius: radius)) }
    func paperTile(radius: CGFloat = 20, tint: Color? = nil) -> some View { modifier(PaperTileBackground(radius: radius, tint: tint)) }
}

/// Big buttons: at least 46 pt high, 16 pt type, 16 pt corners.
struct BudgetButton: ButtonStyle {
    enum Kind { case primary, accent, green, soft, danger }
    var kind: Kind = .primary
    var height: CGFloat = 52
    var fullWidth = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let label = configuration.label
            .font(.system(size: 16, weight: .semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(enabled ? foreground : Theme.disabledText)
            .padding(.horizontal, 16).padding(.vertical, 6)
        return label
            .frame(maxWidth: fullWidth ? CGFloat.infinity : nil, minHeight: height)
            .background(enabled ? fill.opacity(configuration.isPressed ? 0.85 : 1) : Color.black.opacity(0.06), in: shape)
            .overlay(shape.strokeBorder(enabled ? stroke : Color.black.opacity(0.05)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .accent, .green: return .white
        case .soft: return Theme.text
        case .danger: return Theme.red
        }
    }
    private var fill: Color {
        switch kind {
        case .primary: return Theme.text
        case .accent: return Theme.accent
        case .green: return Theme.green
        case .soft: return Color.white
        case .danger: return Theme.red.opacity(0.08)
        }
    }
    private var stroke: Color {
        switch kind {
        case .soft: return Theme.border
        case .danger: return Theme.red.opacity(0.45)
        default: return .clear
        }
    }
}

/// A coloured state chip. The words stay, colour only backs them up.
struct StateChip: View {
    let text: String
    var color: Color = Theme.green
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
            Text(text).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A thin progress bar; the numbers are always written next to it.
struct BudgetBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        Capsule().fill(Theme.hover).frame(height: 10)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: fraction > 0 ? max(10, g.size.width * min(1, fraction)) : 0)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A section title, 20 pt bold, with an optional control on the right.
struct BudgetHeading<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing()
        }
    }
}
extension BudgetHeading where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// One fact on the card: an icon, a figure and what it is.
struct BudgetFactTile: View {
    let symbol: String
    let value: String
    let label: String
    var tint: Color = Theme.text
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104).padding(.vertical, 14).padding(.horizontal, 8)
        .holoTile()
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: Bigger fields for the Budgets forms

struct BudgetFieldBox: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        content.padding(.horizontal, 16).frame(minHeight: 54)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? Theme.text.opacity(0.5) : Theme.border, lineWidth: focused ? 1.5 : 1))
    }
}

struct BudgetFormField<Content: View>: View {
    let label: String
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 13.5)).foregroundStyle(Theme.hint).monospacedDigit().multilineTextAlignment(.trailing)
                }
            }
            content()
        }
    }
}

struct BudgetTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    @FocusState private var focus: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 15.5, design: .monospaced) : .system(size: 17))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($focus)
            .modifier(BudgetFieldBox(focused: focus))
            .animation(.snappy(duration: 0.15), value: focus)
    }
}

/// Same typing rules as AmountTextField (decimal comma, red when it reads as no amount), in a bigger box.
struct BudgetAmountField: View {
    @Binding var text: String
    var body: some View {
        TextField("0", text: $text)
            .textFieldStyle(.plain).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            .foregroundStyle(AmountText.normalize(text) == nil ? Theme.red : Theme.text)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .modifier(BudgetFieldBox())
            .onChange(of: text) { _, new in
                if let n = AmountText.normalize(new), n != new.replacingOccurrences(of: ",", with: "") { text = n }
            }
    }
}

struct BudgetMenuField<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { o in Text(title(o)).tag(o) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(title(selection)).font(.system(size: 17)).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .modifier(BudgetFieldBox())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// A selectable chip, 44 pt high. Selected is black, like SelectChip.
struct BudgetChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: { withAnimation(.snappy(duration: 0.2)) { action() } }) {
            Text(title).font(.system(size: 15, weight: on ? .semibold : .regular)).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(on ? Theme.bg : Theme.text)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(on ? Theme.text : Color.white.opacity(0.85), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Theme.text : Theme.border))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
