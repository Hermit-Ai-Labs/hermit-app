import Foundation

// The last good answer from each network source, kept on this device so a screen shows it at once on the next launch
// (with its age) while a fresh copy loads. Only what the screens already show: market lists, candles, balances,
// activity. Never keys, recovery phrases, chats or API keys. Nothing here leaves the device.

/// A saved answer and when it arrived.
struct SavedSnapshot<Value> {
    let value: Value
    let saved: Date
}
extension SavedSnapshot: Sendable where Value: Sendable {}

/// One small JSON file per source, and per wallet where it matters, in Caches/Hermit/Snapshots. Caches because the
/// system may clear it and it isn't backed up, which suits a copy of data that can be read again.
struct SnapshotStore: Sendable {
    /// nil: a store that keeps nothing (snapshot and unit tests).
    let dir: URL?

    init(dir: URL?) { self.dir = dir }

    static let shared = SnapshotStore(dir: URL.cachesDirectory.appending(path: "Hermit/Snapshots", directoryHint: .isDirectory))
    /// The store screens use. Snapshot tests and unit tests never read or write the real files.
    static var live: SnapshotStore {
        SnapshotMode.active || WalletsViewModel.runningTests ? SnapshotStore(dir: nil) : shared
    }

    /// Bumped when a saved shape changes, so an old file is dropped instead of misread.
    static let version = 1
    /// How long a saved answer is shown by default. Each caller can ask for less.
    static let keep: TimeInterval = 7 * 86_400

    private struct Envelope<V: Codable>: Codable {
        let version: Int
        let saved: Date
        let value: V
    }

    /// "perps.json", "balances.w-<wallet id>.json". Names keep ASCII letters, digits, "-" and "_" only (anything else
    /// becomes "_"), so a coin like "xyz:TSLA" or an odd id can't reach outside the folder.
    static func fileName(_ source: String, wallet: String? = nil) -> String {
        func clean(_ s: String) -> String {
            String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" }.prefix(120))
        }
        return clean(source) + (wallet.map { ".w-" + clean($0) } ?? "") + ".json"
    }

    private func url(_ source: String, wallet: String?) -> URL? {
        dir?.appending(path: Self.fileName(source, wallet: wallet))
    }

    /// The saved answer, or nil when there is none, it's older than `maxAge`, or the file can't be read (a file that
    /// can't be read is deleted, so the next save starts clean).
    func load<V: Codable>(_ source: String, wallet: String? = nil, as: V.Type, maxAge: TimeInterval = SnapshotStore.keep,
                          now: Date = Date()) -> SavedSnapshot<V>? {
        guard let u = url(source, wallet: wallet), let d = try? Data(contentsOf: u) else { return nil }
        guard let e = try? JSONDecoder().decode(Envelope<V>.self, from: d), e.version == Self.version else {
            try? FileManager.default.removeItem(at: u)
            return nil
        }
        guard now.timeIntervalSince(e.saved) < maxAge else { return nil }
        return SavedSnapshot(value: e.value, saved: e.saved)
    }

    /// Saves an answer that just arrived. `at` is when it was fetched, if that was earlier than now.
    @discardableResult
    func save<V: Codable>(_ value: V, _ source: String, wallet: String? = nil, at: Date = Date()) -> Bool {
        guard let dir, let u = url(source, wallet: wallet) else { return false }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(Envelope(version: Self.version, saved: at, value: value)).write(to: u, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func remove(_ source: String, wallet: String? = nil) {
        guard let u = url(source, wallet: wallet) else { return }
        try? FileManager.default.removeItem(at: u)
    }

    /// Everything saved for one wallet, when it's removed from this device.
    func removeAll(wallet: String) {
        guard let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else { return }
        let suffix = Self.fileName("", wallet: wallet)   // ".w-<id>.json"
        for n in names where n.hasSuffix(suffix) { try? FileManager.default.removeItem(at: dir.appending(path: n)) }
    }
}

/// How old something on screen is, in words: "just now", "4 min ago", "3 h ago", "2 days ago".
enum Freshness {
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}
