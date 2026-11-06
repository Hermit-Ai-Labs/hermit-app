import SwiftUI
import Network

/// Whether this device has a network path right now. Used to show that wallet keys are made offline.
@MainActor @Observable
final class NetworkWatch {
    static let shared = NetworkWatch()
    private(set) var online = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in NetworkWatch.shared.online = up }
        }
        monitor.start(queue: DispatchQueue(label: "hermit.network-watch"))
    }
}

/// "Made on this phone": keys never need the internet. Offline, it confirms it; online, it suggests Airplane Mode.
struct OfflineKeysBadge: View {
    @State private var net = NetworkWatch.shared

    var body: some View {
        let offline = !net.online
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(offline ? Theme.green.opacity(0.12) : Theme.hover)
                Image(systemName: offline ? "airplane" : "iphone")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(offline ? Theme.green : Theme.text)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(offline ? "Offline, and that's fine" : "Made on this phone").font(.system(size: 15, weight: .semibold))
                    Circle().fill(offline ? Theme.green : Theme.faint).frame(width: 6, height: 6)
                    Text(offline ? "No internet" : "Online").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Text(offline
                     ? "Your keys are being made right here. Nothing can leave this phone."
                     : "Hermit makes keys without the internet. For extra peace of mind, turn on Airplane Mode first.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(offline ? Theme.green.opacity(0.05) : Theme.subtle, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(offline ? Theme.green.opacity(0.25) : Theme.border))
        .animation(.smooth(duration: 0.35), value: offline)
    }
}

/// Two buttons side by side when they fit, stacked when they don't (narrow iPhone sheets).
struct ButtonPair<A: View, B: View>: View {
    @ViewBuilder var first: () -> A
    @ViewBuilder var second: () -> B
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { first().fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity); second().fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity) }
            VStack(spacing: 10) { first(); second() }
        }
    }
}
