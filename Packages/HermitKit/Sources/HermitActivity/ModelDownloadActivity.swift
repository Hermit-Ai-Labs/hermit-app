#if os(iOS)
import ActivityKit
import Foundation

/// The Live Activity shown while a model downloads: the app starts and updates it, the HermitWidgets extension draws it
/// on the Lock Screen and in the Dynamic Island.
public struct ModelDownloadAttributes: ActivityAttributes {
    public enum Phase: String, Codable, Hashable, Sendable {
        case downloading, verifying, landed, paused, failed
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase
        public var received: Int64
        public var total: Int64

        public init(phase: Phase, received: Int64, total: Int64) {
            self.phase = phase; self.received = received; self.total = total
        }

        /// 0...1, or 0 while the size isn't known yet.
        public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
        public var percent: Int { Int((fraction * 100).rounded(.down)) }
        /// "540 MB of 1.44 GB", or "" before the size is known.
        public var sizeLine: String {
            guard total > 0 else { return "" }
            let f = ByteCountFormatter(); f.countStyle = .file
            return "\(f.string(fromByteCount: received)) of \(f.string(fromByteCount: total))"
        }
    }

    /// "Woof 2B".
    public var modelName: String

    public init(modelName: String) { self.modelName = modelName }
}
#endif
