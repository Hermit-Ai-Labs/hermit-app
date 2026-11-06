import ActivityKit
import HermitActivity
import SwiftUI
import WidgetKit

/// The iPhone app's widget extension. For now it only draws the model-download Live Activity.
@main
struct HermitWidgets: WidgetBundle {
    var body: some Widget { ModelDownloadLiveActivity() }
}

private enum Palette {
    static let paper = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF2 / 255)
    static let ink = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)
    static let muted = Color(red: 0x6B / 255, green: 0x6B / 255, blue: 0x68 / 255)
    /// Hermit purple: the progress, and nothing else.
    static let purple = Color(red: 0x4E / 255, green: 0x1F / 255, blue: 0x96 / 255)
    /// The same purple lifted so it reads on the black Dynamic Island.
    static let purpleOnBlack = Color(red: 0xA9 / 255, green: 0x8A / 255, blue: 0xF0 / 255)
}

private extension ModelDownloadAttributes.ContentState {
    /// The line under the model name.
    var headline: String {
        switch phase {
        case .downloading: "Landing on your phone"
        case .background: "Downloading in the background"
        case .verifying: "Checking the files"
        case .landed: "Landed. Hermit works offline now."
        case .paused: "Paused. Open Hermit to continue."
        case .failed: "Download stopped. Open Hermit to retry."
        }
    }
    var done: Bool { phase == .landed }
    var shownFraction: Double { done ? 1 : fraction }
}

struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
            LockScreenFlight(name: context.attributes.modelName, state: context.state)
                .activityBackgroundTint(Palette.paper)
                .activitySystemActionForegroundColor(Palette.ink)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: s.done ? "checkmark" : "airplane").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.purpleOnBlack)
                        Text(context.attributes.modelName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.done ? "Landed" : "\(s.percent)%").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Palette.purpleOnBlack).contentTransition(.numericText())
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The island's bottom corners are deeply rounded: keep the route and text well inside them, centred.
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "cloud").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                            FlightPath(fraction: s.shownFraction, ink: .white.opacity(0.4), progress: Palette.purpleOnBlack, plane: .white)
                                .frame(height: 22)
                            Image(systemName: "iphone").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        }
                        Text(s.sizeLine.isEmpty ? s.headline : "\(s.headline)  ·  \(s.sizeLine)")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 4).padding(.bottom, 6)
                }
            } compactLeading: {
                Image(systemName: s.done ? "checkmark" : "airplane").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.purpleOnBlack)
            } compactTrailing: {
                Text(s.done ? "Done" : "\(s.percent)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white).contentTransition(.numericText())
            } minimal: {
                ProgressView(value: s.shownFraction) {
                    Image(systemName: "airplane").font(.system(size: 9, weight: .bold))
                }
                .progressViewStyle(.circular).tint(Palette.purpleOnBlack)
            }
            .contentMargins(.horizontal, 18, for: .expanded)
            .contentMargins(.bottom, 14, for: .expanded)
        }
    }
}

/// Lock Screen and banner: the model name, where it is, the flight from the cloud to the phone, and the bytes.
private struct LockScreenFlight: View {
    let name: String
    let state: ModelDownloadAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 19, weight: .regular, design: .serif)).foregroundStyle(Palette.ink)
                Spacer()
                Text(state.done ? "100%" : "\(state.percent)%").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.purple).contentTransition(.numericText())
            }
            HStack(spacing: 10) {
                Endpoint(symbol: "cloud", label: "Cloud")
                FlightPath(fraction: state.shownFraction, ink: Palette.muted.opacity(0.6), progress: Palette.purple, plane: Palette.ink)
                    .frame(height: 28)
                Endpoint(symbol: "iphone", label: "Offline")
            }
            HStack {
                Text(state.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text(state.sizeLine).monospacedDigit().foregroundStyle(Palette.muted)
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }
}

private struct Endpoint: View {
    let symbol: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.muted)
        }
        .frame(width: 44)
    }
}

/// A dotted route with the flown part drawn solid, and the plane at the current progress.
private struct FlightPath: View {
    let fraction: Double
    let ink: Color
    let progress: Color
    let plane: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, mid = g.size.height / 2
            let x = max(0, min(w, w * fraction))
            ZStack(alignment: .leading) {
                Path { p in p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: w, y: mid)) }
                    .stroke(ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1.5, 5]))
                Path { p in p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: x, y: mid)) }
                    .stroke(progress, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Image(systemName: "airplane")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(plane)
                    .position(x: min(max(x, 10), w - 10), y: mid)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int(fraction * 100)) percent downloaded")
    }
}
