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
            VStack(alignment: .leading, spacing: 5) {
                // Status on its own line so the title never has to share (and lose) the width.
                HStack(spacing: 5) {
                    Circle().fill(offline ? Theme.green : Theme.faint).frame(width: 6, height: 6)
                    Text(offline ? "No internet" : "Online").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.bg, in: Capsule()).overlay(Capsule().strokeBorder(Theme.border))
                .fixedSize()
                Text(offline ? "Offline, and that's fine" : "Made on this phone").font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
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

/// Two buttons: side by side on the Mac, stacked full width on the iPhone.
struct ButtonPair<A: View, B: View>: View {
    @ViewBuilder var first: () -> A
    @ViewBuilder var second: () -> B
    var body: some View {
        #if os(iOS)
        // Full-width and stacked on the phone: two side-by-side buttons never fit their labels at 393pt.
        VStack(spacing: 10) { first(); second() }
        #else
        HStack(spacing: 10) { first(); second() }
        #endif
    }
}
