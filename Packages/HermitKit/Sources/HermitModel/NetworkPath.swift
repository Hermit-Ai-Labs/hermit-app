import Foundation
import Network

/// Whether the device has a usable network path right now, so a failed download can say "No internet connection"
/// only when that's actually true.
final class NetworkPath: @unchecked Sendable {
    static let shared = NetworkPath()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock(); satisfied = path.status == .satisfied; lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "hermit.model.network-path"))
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return satisfied }
}
