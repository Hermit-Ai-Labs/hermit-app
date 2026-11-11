import SwiftUI

/// A small dot that slowly pulses to say "live" or "in progress". Still, at full opacity, with Reduce Motion
/// (and in snapshot tests).
struct PulseDot: View {
    var color: Color
    var size: CGFloat = 6
    var low: Double = 0.35
    var seconds: Double = 0.9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion || SnapshotMode.active {
            Circle().fill(color).frame(width: size, height: size)
        } else {
            Circle().fill(color).frame(width: size, height: size)
                .phaseAnimator([1.0, low]) { c, o in c.opacity(o) } animation: { _ in .smooth(duration: seconds) }
        }
    }
}
