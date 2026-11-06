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

/// A mesh gradient made the way copycat's hero is (gradient.skin style): soft elliptical blobs of colour over a base,
/// each fading from strong to clear at 32% and 68% of its radius. Positions and radii are fractions of the view.
struct MeshBlobs: View {
    struct Blob { let x, y, rx, ry: CGFloat; let color: Color; let strength: Double }
    let base: Color
    let blobs: [Blob]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            for b in blobs {
                ctx.drawLayer { l in
                    l.translateBy(x: b.x * size.width, y: b.y * size.height)
                    l.scaleBy(x: max(b.rx * size.width, 1), y: max(b.ry * size.height, 1))
                    let g = Gradient(stops: [.init(color: b.color.opacity(b.strength), location: 0),
                                             .init(color: b.color.opacity(b.strength * 0.55), location: 0.32),
                                             .init(color: b.color.opacity(0), location: 0.68)])
                    l.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                           with: .radialGradient(g, center: .zero, startRadius: 0, endRadius: 1))
                }
            }
        }
    }

    /// Light: white with lavender, lilac, peach, rose and cream. Dark text sits on it.
    static let dawn = MeshBlobs(base: .white, blobs: [
        Blob(x: 0.52, y: 0.30, rx: 0.34, ry: 0.75, color: .white, strength: 0.95),
        Blob(x: 0.03, y: 0.08, rx: 0.40, ry: 0.56, color: Color(hex: 0xE4D8FF), strength: 0.95),
        Blob(x: 0.29, y: 0.38, rx: 0.34, ry: 0.64, color: Color(hex: 0xD3C2FF), strength: 0.85),
        Blob(x: 0.12, y: 0.63, rx: 0.50, ry: 0.50, color: Color(hex: 0xFFE2CC), strength: 0.85),
        Blob(x: 0.25, y: 0.96, rx: 0.48, ry: 0.36, color: Color(hex: 0xFBD0E6), strength: 0.90),
        Blob(x: 0.95, y: 0.10, rx: 0.44, ry: 0.63, color: Color(hex: 0xC9B3FF), strength: 0.90),
        Blob(x: 0.72, y: 0.22, rx: 0.43, ry: 0.56, color: Color(hex: 0xFFE7D2), strength: 0.80),
        Blob(x: 0.94, y: 0.55, rx: 0.44, ry: 0.60, color: Color(hex: 0xB79BFF), strength: 0.85),
        Blob(x: 0.80, y: 1.04, rx: 0.51, ry: 0.49, color: Color(hex: 0xFFD3C2), strength: 0.90),
    ])

    /// Dark: deep violet lit from inside with violet, orchid and a touch of rose. White text sits on it.
    static let dusk = MeshBlobs(base: Color(hex: 0x2A0D5E), blobs: [
        Blob(x: 0.10, y: 0.05, rx: 0.55, ry: 0.90, color: Color(hex: 0x8A5CF0), strength: 0.95),
        Blob(x: 0.55, y: 0.20, rx: 0.45, ry: 0.80, color: Color(hex: 0x6A35D1), strength: 0.90),
        Blob(x: 0.95, y: 0.15, rx: 0.40, ry: 0.80, color: Color(hex: 0xC05CF0), strength: 0.70),
        Blob(x: 0.80, y: 1.05, rx: 0.50, ry: 0.70, color: Color(hex: 0xF07AB4), strength: 0.45),
        Blob(x: 0.25, y: 1.00, rx: 0.50, ry: 0.60, color: Color(hex: 0x4E1F96), strength: 0.90),
    ])
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
                Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(HermitGradient.mid)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white))
                    .shadow(color: HermitGradient.mid.opacity(0.12), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.62))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LinearGradient(colors: [Color(hex: 0x3A3A3A), Color(hex: 0x0A0A0A)], startPoint: .top, endPoint: .bottom)))
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)).padding(1.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                MeshBlobs.dawn
                    .overlay(Sheen())
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1))
                    .shadow(color: Color(hex: 0x8A5CF0).opacity(0.22), radius: 22, y: 12)
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
                    MeshBlobs.dusk.overlay(Sheen()).clipShape(Capsule())
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
