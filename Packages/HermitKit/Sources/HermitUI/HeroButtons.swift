import SwiftUI

/// Hermit's purple, as a lit surface: deep ink-violet at the bottom, brighter violet where the light lands.
enum HermitGradient {
    static let deep = Color(hex: 0x2A0D5E)
    static let mid = Color(hex: 0x4E1F96)
    static let lit = Color(hex: 0x8A5CF0)

    static var fill: LinearGradient {
        LinearGradient(stops: [.init(color: lit, location: 0), .init(color: mid, location: 0.48), .init(color: deep, location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// A slow band of light that crosses the button every few seconds. Off with Reduce Motion.
private struct Sheen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var x: CGFloat = -1
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.45)
                .rotationEffect(.degrees(18))
                .offset(x: x * g.size.width * 1.4)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion, !SnapshotMode.active else { return }
            withAnimation(.easeInOut(duration: 1.6).delay(2.4).repeatForever(autoreverses: false)) { x = 1 }
        }
    }
}

/// The big first step: a full-width gradient card button with an icon, a title, a line under it and an arrow.
/// Used for "Create your wallet" on Home and the Wallets page.
struct GradientCTA: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.22)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(HermitGradient.mid)
                    .frame(width: 34, height: 34).background(.white, in: Circle())
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(HermitGradient.fill)
                    .overlay(Sheen().clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: HermitGradient.mid.opacity(0.35), radius: 18, y: 10)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .combine)
    }
}

/// Gradient pill for a key action that sits inside a card (Download, Create a wallet).
struct GradientPill: ButtonStyle {
    var full = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(enabled ? .white : Theme.disabledText)
            .lineLimit(1)
            .padding(.horizontal, 18).frame(height: 40)
            .frame(maxWidth: full ? .infinity : nil)
            .background {
                if enabled {
                    Capsule().fill(HermitGradient.fill)
                        .overlay(Sheen().clipShape(Capsule()))
                        .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)))
                        .shadow(color: HermitGradient.mid.opacity(configuration.isPressed ? 0.15 : 0.32), radius: 10, y: 5)
                } else {
                    Capsule().fill(Theme.disabledFill).overlay(Capsule().strokeBorder(Theme.border))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
