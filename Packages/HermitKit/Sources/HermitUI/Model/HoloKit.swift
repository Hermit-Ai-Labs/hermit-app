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
    var body: some View {
        HoloClock { t in
            GeometryReader { g in
                let x = 0.5 + 0.35 * cos(t * 0.5), y = 0.5 + 0.30 * sin(t * 0.65)
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

/// The download button: one icon that keeps changing between four holo looks (ring, disc, glow, foil),
/// crossfading every few seconds. Purple arrow, white on the disc.
struct HoloIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    private static let hold = 2.6, fade = 0.9

    var body: some View {
        Button(action: action) {
            HoloClock { t in
                let cycle = Self.hold * 4
                let pos = t.truncatingRemainder(dividingBy: cycle) / Self.hold   // 0..<4
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
