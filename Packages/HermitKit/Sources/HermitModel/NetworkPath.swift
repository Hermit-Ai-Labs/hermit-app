import Foundation
import Network

/// Whether the device has a usable network path right now, and whether it's metered (cellular or a hotspot), so a
/// failed download can say "No internet connection" only when that's true, and the first download can wait for Wi-Fi.
final class NetworkPath: @unchecked Sendable {
    static let shared = NetworkPath()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true
    private var expensive = false
    private var known = false
    private var watchers: [@Sendable () -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            satisfied = path.status == .satisfied
            expensive = path.isExpensive
            known = true
            let w = watchers
            lock.unlock()
            w.forEach { $0() }
        }
        monitor.start(queue: DispatchQueue(label: "hermit.model.network-path"))
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return satisfied }
    /// Cellular data or a personal hotspot.
    var isExpensive: Bool { lock.lock(); defer { lock.unlock() }; return satisfied && expensive }
    /// Online on Wi-Fi or Ethernet.
    var isUnmetered: Bool { lock.lock(); defer { lock.unlock() }; return satisfied && !expensive }

    /// Runs `body` on every path change (on a background queue).
    func onChange(_ body: @escaping @Sendable () -> Void) { lock.lock(); watchers.append(body); lock.unlock() }

    /// The first path update, so a decision at launch isn't made on the default values.
    func settled() async {
        for _ in 0..<20 {
            lock.lock(); let k = known; lock.unlock()
            if k { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
