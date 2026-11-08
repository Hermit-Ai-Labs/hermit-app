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
        // One compact row: icon, a short title with the live status, one line under it.
        HStack(spacing: 11) {
            Image(systemName: offline ? "airplane" : Device.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(offline ? Theme.green : Theme.text)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(offline ? Theme.green.opacity(0.12) : Theme.bg, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Made on \(Device.here)").font(.system(size: 13.5, weight: .semibold))
                    Circle().fill(offline ? Theme.green : Theme.faint).frame(width: 5, height: 5)
                    Text(offline ? "Offline" : "Online").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                Text(offline ? "Nothing can leave \(Device.here)." : Device.offlineTip)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(offline ? Theme.green.opacity(0.05) : Theme.subtle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(offline ? Theme.green.opacity(0.25) : Theme.border))
        .animation(.smooth(duration: 0.35), value: offline)
        .accessibilityElement(children: .combine)
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
