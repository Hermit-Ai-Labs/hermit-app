import SwiftUI

/// The holo foil from copycat (sol.copycat.my): five pastel hues, glitter, colour-dodged over a surface.
enum Holo {
    static let colors: [Color] = [
        Color(hue: 320 / 360, saturation: 0.90, brightness: 0.97),
        Color(hue: 200 / 360, saturation: 0.80, brightness: 0.98),
        Color(hue: 55 / 360, saturation: 0.75, brightness: 0.99),
        Color(hue: 150 / 360, saturation: 0.65, brightness: 0.93),
        Color(hue: 280 / 360, saturation: 0.70, brightness: 0.98),
    ]
    static var loop: [Color] { colors + [colors[0]] }
}

/// Seconds since a fixed point, for the slow drifts. Frozen with Reduce Motion and in snapshots.
private struct HoloClock<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: (Double) -> Content
    var body: some View {
        if reduceMotion || SnapshotMode.active {
            content(0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in content(ctx.date.timeIntervalSinceReferenceDate) }
        }
    }
}

/// The foil layer: glitter plus a rainbow that drifts slowly across the card, colour-dodged.
struct HoloFoil: View {
    var strength: Double = 0.5
    /// Each foil drifts on its own path and speed, so two cards never shimmer in step.
    @State private var drift = (phase: Double.random(in: 0..<(2 * .pi)), speed: Double.random(in: 0.7...1.4),
                                rx: Double.random(in: 0.25...0.40), ry: Double.random(in: 0.20...0.35))
    var body: some View {
        HoloClock { t in
            GeometryReader { g in
                let k = t * 0.5 * drift.speed + drift.phase
                let x = 0.5 + drift.rx * cos(k), y = 0.5 + drift.ry * sin(k * 1.3)
                ZStack {
                    Image.hermit("holo-glitter").resizable(resizingMode: .tile)
                    RadialGradient(colors: Holo.colors, center: UnitPoint(x: x, y: y), startRadius: 0,
                                   endRadius: max(g.size.width, g.size.height) * 1.1)
                        .blendMode(.screen)
                }
                .compositingGroup()
                .brightness(-0.12).contrast(1.5)
            }
        }
        .blendMode(.colorDodge)
        .opacity(strength)
        .allowsHitTesting(false)
    }
}

/// The pastel holo wash from the site's Holo mood card: pink, sky, lemon, mint and lavender in one radial gradient whose
/// centre drifts corner to corner every nine seconds, laid over white at 60%. Frozen with Reduce Motion.
struct HoloWash: View {
    static let pastels: [Color] = [Color(hex: 0xFBBBE6), Color(hex: 0xAFE3FD), Color(hex: 0xFDF7B4), Color(hex: 0xB3F9D6), Color(hex: 0xE9C5FC)]
    var body: some View {
        HoloClock { t in
            GeometryReader { g in
                let k = (sin(t * 2 * .pi / 18) + 1) / 2          // 0…1…0 over 18 s (9 s each way)
                RadialGradient(stops: [.init(color: Self.pastels[0], location: 0), .init(color: Self.pastels[1], location: 0.3),
                                       .init(color: Self.pastels[2], location: 0.55), .init(color: Self.pastels[3], location: 0.75),
                                       .init(color: Self.pastels[4], location: 1)],
                               center: UnitPoint(x: 0.2 + 0.6 * k, y: 0.1 + 0.8 * k), startRadius: 0,
                               endRadius: max(g.size.width, g.size.height) * 1.1)
                    .opacity(0.6)
            }
        }
        .background(Color.white)
        .allowsHitTesting(false)
    }
}

/// The download button: one icon that keeps changing between four holo looks (ring, disc, glow, foil),
/// crossfading every few seconds. Purple arrow, white on the disc.
struct HoloIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    private static let hold = 2.6, fade = 0.9
    /// Where in the four-look cycle this icon starts, so icons on one screen don't swap together.
    @State private var offset = Double.random(in: 0..<(2.6 * 4))

    var body: some View {
        Button(action: action) {
            HoloClock { t in
                let cycle = Self.hold * 4
                let pos = (t + offset).truncatingRemainder(dividingBy: cycle) / Self.hold   // 0..<4
                let i = Int(pos), f = pos - Double(i)
                let mix = max(0, (f - (1 - Self.fade / Self.hold)) / (Self.fade / Self.hold))   // fades in the last part
                let spin = Angle.degrees((t * 45).truncatingRemainder(dividingBy: 360))
                ZStack {
                    look(i % 4, spin: spin).opacity(1 - mix)
                    look((i + 1) % 4, spin: spin).opacity(mix)
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder private func look(_ n: Int, spin: Angle) -> some View {
        let ring = AngularGradient(colors: Holo.loop, center: .center, angle: spin)
        switch n {
        case 0: // Holo ring: white button, thin turning ring.
            ZStack {
                Circle().fill(.white)
                Circle().strokeBorder(ring, lineWidth: 2)
                arrow(Theme.accent)
            }
        case 1: // Holo disc: the whole button is holo, glass highlight, white arrow.
            ZStack {
                Circle().fill(ring)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.75), .white.opacity(0)], center: UnitPoint(x: 0.35, y: 0.25),
                                             startRadius: 0, endRadius: 14))
                Circle().fill(Theme.accent.opacity(0.18))
                arrow(.white)
            }
            .shadow(color: Color(hex: 0xA06EF0).opacity(0.35), radius: 6, y: 3)
        case 2: // Holo glow: white button on a soft holo glow.
            ZStack {
                Circle().fill(ring).padding(-4).blur(radius: 6).opacity(0.85)
                Circle().fill(.white)
                Circle().strokeBorder(Theme.accent.opacity(0.12))
                arrow(Theme.accent)
            }
        default: // Foiled: lavender with the foil running through it.
            ZStack {
                Circle().fill(Theme.accent.opacity(0.10))
                HoloFoil(strength: 0.75).clipShape(Circle())
                Circle().strokeBorder(Theme.accent.opacity(0.2))
                arrow(Theme.accent)
            }
        }
    }

    private func arrow(_ c: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(c)
    }
}

/// The progress bar as a holo strip, with a shine that runs along it.
struct HoloBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width * min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(0.07))
                HoloClock { t in
                    let shine = (t * 0.45).truncatingRemainder(dividingBy: 1.6) - 0.3
                    ZStack(alignment: .leading) {
                        LinearGradient(colors: Holo.loop, startPoint: .leading, endPoint: .trailing)
                        LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(w * 0.4, 12))
                            .offset(x: w * shine)
                    }
                }
                .frame(width: w)
                .clipShape(Capsule())
                .animation(.smooth(duration: 0.5), value: value)
            }
        }
        .frame(height: 4)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

/// A first-step card in the Fly offline style: crab tile, title and one line, the live holo icon, foil over a pale violet
/// card. The whole card is the button. Used for Create your wallet (design A from the wallet round).
struct HoloPromptCard: View {
    let image: String
    let title: String
    let subtitle: String
    let symbol: String
    /// Narrow places (the Mac sidebar): a smaller tile and holo icon so the title and line fit untruncated.
    var compact = false
    let action: () -> Void

    var body: some View {
        let tile: CGFloat = compact ? 34 : 44
        Button(action: action) {
            HStack(spacing: compact ? 9 : 12) {
                Image.hermit(image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: tile - 4).offset(y: 3)
                    .frame(width: tile, height: tile)
                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
                VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                    Text(title).font(.system(size: compact ? 13 : 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Text(subtitle).font(.system(size: compact ? 11.5 : 12.5)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
                }
                .layoutPriority(1)
                Spacer(minLength: compact ? 4 : 8)
                HoloIconButton(symbol: symbol, label: title, action: action).accessibilityHidden(true)
                    .scaleEffect(compact ? 0.76 : 1).frame(width: compact ? 29 : 38, height: compact ? 29 : 38)
            }
            .padding(compact ? 9 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(colors: [.white, Color(hex: 0xF7F4FF), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
                    HoloFoil(strength: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("\(title). \(subtitle)")
    }
}
