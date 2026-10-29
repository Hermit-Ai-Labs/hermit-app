import SwiftUI
import HermitModel

/// The download ring: a thin track, an arc that follows progress on a spring, and an icon that morphs between
/// states (arrow to download, stop while downloading, a check that pops in when ready).
struct ModelRing: View {
    let state: ModelStore.State
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(arcColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.4), value: arc)
            icon
                .font(.system(size: size * 0.32, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
    }

    private var arc: CGFloat {
        switch state {
        case .downloading(let p): max(0.02, p)
        case .verifying: 1
        case .ready: 1
        default: 0
        }
    }

    private var arcColor: Color { state == .ready ? Theme.green : state == .verifying ? Theme.faint : Theme.text }

    @ViewBuilder private var icon: some View {
        switch state {
        case .notDownloaded: Image(systemName: "arrow.down").foregroundStyle(Theme.text)
        case .downloading: Image(systemName: "stop.fill").font(.system(size: size * 0.22)).foregroundStyle(Theme.text)
        case .verifying: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "checkmark").foregroundStyle(Theme.green).transition(.scale.combined(with: .opacity))
        case .failed: Image(systemName: "arrow.clockwise").foregroundStyle(Theme.red)
        }
    }
}

extension ModelStore {
    /// "540 MB of 1.4 GB" while downloading, the size otherwise.
    func sizeLine(_ spec: ModelSpec) -> String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let total = totals[spec.id] ?? spec.approxBytes
        switch state(spec.id) {
        case .downloading: return "\(fmt(received[spec.id] ?? 0)) of \(fmt(total))"
        case .verifying: return "Checking the files"
        case .ready: return "On this device, \(fmt(total))"
        case .failed(let why): return why
        case .notDownloaded:
            if let got = received[spec.id], got > 0 { return "Paused at \(fmt(got)) of \(fmt(total))" }
            return fmt(total)
        }
    }

    /// The ring's tap: start, pause or retry.
    func toggle(_ id: String) {
        switch state(id) {
        case .downloading: cancel(id)
        case .notDownloaded, .failed: download(id)
        default: break
        }
    }
}
