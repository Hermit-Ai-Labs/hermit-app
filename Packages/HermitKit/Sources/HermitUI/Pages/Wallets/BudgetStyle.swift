import SwiftUI

// The look of Budgets (GuardViews.swift). Same scale as the rest of Wallets: 14 pt titles, 12.5 pt captions, 11 pt labels
// in tracked capitals, and the Newsreader serif for the one figure on each screen. Blocks are separated by hairlines,
// not boxes. Purple marks what needs you; green and red only say Running and Frozen. Nothing here carries logic.

/// Small tracked capitals above a block ("IN THE VAULT").
struct GuardEyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.hint)
    }
}

/// A block of the Budgets sheet: a hairline across, the label in small capitals with an optional action, then the rows.
struct GuardSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            HStack(spacing: 8) {
                GuardEyebrow(text: title)
                Spacer(minLength: 8)
                trailing()
            }
            .frame(minHeight: 32)
            .padding(.top, 12)
            content()
        }
    }
}

extension GuardSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// A state in a few words ("Paused", "No key"), as small tinted text.
struct GuardChip: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.09), in: Capsule())
    }
}

/// A 6 pt status dot.
struct GuardDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 6, height: 6) }
}

/// Spent today against the daily limit: a 3 pt line, purple, amber from 80%, red at or over the limit.
struct GuardMeter: View {
    /// 0 to 1 is inside the daily limit; above 1 is over it.
    let fraction: Double
    private var tint: Color { fraction >= 1 ? Theme.red : fraction >= 0.8 ? Theme.amber : Theme.accent }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(0.08))
                Capsule().fill(tint).frame(width: fraction > 0 ? max(3, g.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// The vault's figure: the number in the serif, the token after it in small sans, on one baseline.
struct GuardFigure: View {
    let number: String
    let symbol: String
    var size: CGFloat = 30
    /// Other tokens held besides this one, shown as "+2".
    var more = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(number).font(.serif(size)).tracking(-size * 0.02).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
            if more > 0 { Text("+\(more)").font(.system(size: 12.5)).foregroundStyle(Theme.hint).monospacedDigit() }
        }
    }
}

/// The black twin of OutlineButton (same 13 pt type, padding and 9 pt corners), for Unfreeze.
struct GuardSolidButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? Color.white : Theme.disabledText)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(enabled ? Theme.text.opacity(configuration.isPressed ? 0.85 : 1) : Theme.disabledFill, in: RoundedRectangle(cornerRadius: 9))
    }
}


/// A small capsule in Home's pastel colours: the one coloured control on the Security tab, so Budgets is easy to find.
struct HoloPillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                LinearGradient(colors: [Color(hex: 0xE9C5FC), Color(hex: 0xAFE3FD), Color(hex: 0xB3F9D6), Color(hex: 0xFDF7B4)],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(configuration.isPressed ? 0.75 : 1),
                in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.18)))
    }
}
