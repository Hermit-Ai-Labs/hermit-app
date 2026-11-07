import Foundation
import Observation
import os

private let downloadLog = Logger(subsystem: "my.hermit", category: "model-download")
#if os(iOS)
import HermitActivity
import UIKit
#endif

/// Downloads, checks and deletes on-device models, and says which one Hermit uses.
/// Files live in Application Support/Hermit/Models/<repo id>, are kept out of backups and resume after a quit.
@MainActor @Observable
public final class ModelStore {
    public static let shared = ModelStore()

    public enum State: Equatable, Sendable {
        case notDownloaded
        case downloading(Double)   // 0...1
        case verifying
        case ready
        case failed(String)
    }

    public private(set) var states: [String: State] = [:]
    /// The model chat uses. Falls back to the default if this device can't run the saved choice.
    public private(set) var selectedID: String
    /// Bytes downloaded so far per model, for "540 MB of 1.4 GB".
    public private(set) var received: [String: Int64] = [:]
    public private(set) var totals: [String: Int64] = [:]

    public let root: URL
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deleteObservers: [(String) -> Void] = []
    #if os(iOS)
    /// Background time and the Live Activity while a download runs.
    @ObservationIgnored private let keepAlive = DownloadKeepAlive()
    #endif
    private static let selectedKey = "hermit.model.selected"
    /// The model the user asked to download and hasn't finished, so a relaunch picks the download up again.
    private static let downloadingKey = "hermit.model.downloading"
    private static let readyMarker = ".hermit-ready"
    /// The file list as fetched when the download started, so a relaunch can continue without the network.
    private static let filesCache = ".hermit-files.json"

    /// Deletes downloaded models that aren't in the catalog any more (folders are named after the repo id).
    private static func removeRetired(root: URL, keep: Set<String>) {
        let fm = FileManager.default
        guard let owners = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for owner in owners {
            guard let repos = try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil) else { continue }
            for repo in repos where !keep.contains("\(owner.lastPathComponent)/\(repo.lastPathComponent)") {
                try? fm.removeItem(at: repo)
            }
        }
    }

    public init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Hermit/Models", directoryHint: .isDirectory)
        // A model that's no longer in the catalog (Woof, before Hermit 1.1) falls back to the default, and its files go.
        let known = Set(ModelCatalog.all.map(\.id))
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap { known.contains($0) ? $0 : nil } ?? ModelCatalog.defaultID
        let spec = ModelCatalog.spec(saved)
        selectedID = spec.supported && ModelCatalog.fits(spec) ? saved : ModelCatalog.defaultID
        if let d = UserDefaults.standard.string(forKey: Self.downloadingKey), !known.contains(d) {
            UserDefaults.standard.removeObject(forKey: Self.downloadingKey)
        }
        Self.removeRetired(root: self.root, keep: known)
        for spec in ModelCatalog.all { states[spec.id] = isComplete(spec.id) ? .ready : .notDownloaded }
        if states[selectedID] == nil { states[selectedID] = isComplete(selectedID) ? .ready : .notDownloaded }
        #if os(iOS)
        BackgroundDownloads.shared.root = self.root
        // iOS may have kept transfers going while Hermit wasn't running: attach to them, and continue a download the
        // user started that hasn't landed yet.
        Task { [weak self] in
            var ids = await BackgroundDownloads.shared.modelsInFlight()
            if let pending = UserDefaults.standard.string(forKey: Self.downloadingKey) { ids.insert(pending) }
            guard let self else { return }
            for id in ids where self.state(id) != .ready { self.download(id) }
        }
        // Back in front: a download the user started that isn't running (interrupted while Hermit was away) continues
        // by itself, without a Try again tap.
        resumeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeInterrupted() }
        }
        #endif
    }

    #if os(iOS)
    @ObservationIgnored private var resumeObserver: NSObjectProtocol?

    private func resumeInterrupted() {
        guard let id = UserDefaults.standard.string(forKey: Self.downloadingKey), tasks[id] == nil, state(id) != .ready else { return }
        download(id)
    }
    #endif

    #if os(iOS)
    // MARK: App delegate hooks (iPhone)

    /// From didFinishLaunching: registers the background-time handler (it must be registered during launch) and
    /// creates the store, which re-attaches to transfers iOS kept going while Hermit wasn't running.
    public static func appDidLaunch() {
        DownloadKeepAlive.registerAtLaunch()
        _ = shared
    }

    /// From handleEventsForBackgroundURLSession: iOS woke Hermit because transfers finished. `completion` runs once
    /// they're delivered, after which iOS may suspend Hermit again.
    public static func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundDownloads.identifier else { completion(); return }
        _ = shared
        BackgroundDownloads.shared.handleEvents(completion)
    }
    #endif

    // MARK: Reading

    public var selected: ModelSpec { ModelCatalog.spec(selectedID) }
    public var selectedState: State { state(selectedID) }
    public func state(_ id: String) -> State { states[id] ?? .notDownloaded }

    /// The folder holding a model's files.
    public func directory(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// The selected model's folder once it is downloaded and checked.
    public var readyModel: (spec: ModelSpec, directory: URL)? {
        selectedState == .ready ? (selected, directory(selectedID)) : nil
    }

    /// The model name next to the send button: "Hermit 1.1", or "Hermit 1.1 42%" while it downloads.
    public var label: String {
        if case .downloading(let p) = selectedState { return "\(selected.name) \(Int(p * 100))%" }
        return selected.name
    }

    // MARK: Changing

    public func select(_ id: String) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        if states[id] == nil { states[id] = isComplete(id) ? .ready : .notDownloaded }
    }

    /// Starts (or resumes) a download. Safe to call twice.
    public func download(_ id: String) {
        guard tasks[id] == nil, state(id) != .ready else { return }
        states[id] = .downloading(progress(id))
        UserDefaults.standard.set(id, forKey: Self.downloadingKey)
        #if os(iOS)
        keepAlive.begin(id: id, name: ModelCatalog.spec(id).name, received: received[id] ?? 0, total: totals[id] ?? 0)
        #endif
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            // A dropped connection or a suspended app is not a failure: try again on our own, and wait for the network
            // while there is none. "Download stopped" only shows after the retries are used up.
            var failures = 0
            while true {
                do {
                    try await self.fetch(id)
                    self.states[id] = .ready
                    self.clearDownloading(id)
                    self.keepAliveFinish(id, .landed)
                } catch is CancellationError {
                    self.states[id] = .notDownloaded
                    self.clearDownloading(id)
                    self.keepAliveFinish(id, .paused)
                } catch {
                    downloadLog.error("download of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    if await Self.waitForNetwork() {
                        failures += 1
                        if failures < Self.retryDelays.count + 1 {
                            self.states[id] = .downloading(self.progress(id))
                            try? await Task.sleep(for: .seconds(Self.retryDelays[failures - 1]))
                            if !Task.isCancelled { continue }
                        }
                    }
                    if Task.isCancelled {
                        self.states[id] = .notDownloaded
                        self.clearDownloading(id)
                        self.keepAliveFinish(id, .paused)
                    } else {
                        self.states[id] = .failed(Self.explain(error))
                        self.clearDownloading(id)
                        self.keepAliveFinish(id, .failed)
                    }
                }
                break
            }
            self.tasks[id] = nil
        }
    }

    /// Seconds to wait before each retry; after the last one the download shows as stopped.
    private static let retryDelays: [Double] = [2, 8, 30]

    /// False if there's still no network after waiting up to a minute (the failure is then "No internet connection").
    private static func waitForNetwork() async -> Bool {
        for _ in 0..<30 {
            if NetworkPath.shared.isOnline { return true }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return true }
        }
        return NetworkPath.shared.isOnline
    }

    /// What actually went wrong, in plain words. "No internet connection" only when the device really has no network.
    private static func explain(_ error: Error) -> String {
        if !NetworkPath.shared.isOnline { return "No internet connection." }
        switch error {
        case DownloadError.offline: return "The connection kept dropping. Try again on a steadier network."
        case DownloadError.http(let code): return "Hugging Face answered \(code). Try again in a little while."
        case DownloadError.sizeMismatch, DownloadError.checksum: return "\(error.localizedDescription) Try again."
        case let e as URLError: return "The download kept failing: \(e.localizedDescription)"
        default: return error.localizedDescription
        }
    }

    private func clearDownloading(_ id: String) {
        if UserDefaults.standard.string(forKey: Self.downloadingKey) == id { UserDefaults.standard.removeObject(forKey: Self.downloadingKey) }
    }

    /// Stops a download. What came down so far stays on disk, so the next download picks up from there.
    public func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Removes the model from this device.
    public func delete(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        #if os(iOS)
        BackgroundDownloads.shared.discard(model: id)
        #endif
        clearDownloading(id)
        for observer in deleteObservers { observer(id) }
        try? FileManager.default.removeItem(at: directory(id))
        received[id] = nil
        states[id] = .notDownloaded
    }

    /// Called before a model's files are removed, so a loaded copy can be let go.
    public func onDelete(_ observer: @escaping (String) -> Void) { deleteObservers.append(observer) }

    // MARK: Download

    private func progress(_ id: String) -> Double {
        guard let total = totals[id], total > 0 else { return 0 }
        return min(1, Double(received[id] ?? 0) / Double(total))
    }

    private func isComplete(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(id).appending(path: Self.readyMarker).path)
    }

    private func fetch(_ id: String) async throws {
        let dir = directory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rootValues = URLResourceValues(); rootValues.isExcludedFromBackup = true
        var rootURL = root; try? rootURL.setResourceValues(rootValues)

        #if os(iOS)
        try await fetchInBackground(id, dir)
        #else
        try await fetchInApp(id, dir)
        #endif
    }

    /// The model's file list: cached in its folder once fetched, so a download can continue after a relaunch offline.
    private func fileList(_ id: String, _ dir: URL) async throws -> [RepoFile] {
        let cache = dir.appending(path: Self.filesCache)
        if let data = try? Data(contentsOf: cache), let files = try? JSONDecoder().decode([RepoFile].self, from: data), !files.isEmpty {
            return files
        }
        let files = try await Self.listFiles(id)
        try? JSONEncoder().encode(files).write(to: cache)
        return files
    }

    /// Size and SHA-256 check, then the .part file takes the file's place.
    private func verifyAndPlace(_ id: String, _ file: RepoFile, part: URL, dest: URL) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        guard size == file.size else { try? FileManager.default.removeItem(at: part); throw DownloadError.sizeMismatch(file.path) }
        if let sha = file.sha256 {
            states[id] = .verifying
            keepAliveUpdate(id)
            let actual = try await Task.detached(priority: .utility) { try FileDownload.sha256(of: part) }.value
            guard actual == sha else { try? FileManager.default.removeItem(at: part); throw DownloadError.checksum(file.path) }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
    }

    private func writeReadyMarker(_ files: [RepoFile], _ dir: URL) throws {
        let manifest = files.map { "\($0.path) \($0.size) \($0.sha256 ?? "-")" }.joined(separator: "\n")
        try manifest.write(to: dir.appending(path: Self.readyMarker), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appending(path: Self.filesCache))
    }

    #if os(iOS)
    /// iPhone: every missing file is handed to the background session at once, while the app is in front (transfers
    /// started from the background can be held back by iOS). The system finishes them even if Hermit is suspended or
    /// closed; then each file is checked and moved into place.
    private func fetchInBackground(_ id: String, _ dir: URL) async throws {
        let files = try await fileList(id, dir)
        totals[id] = files.reduce(0) { $0 + $1.size }
        let bg = BackgroundDownloads.shared
        var have: Int64 = 0
        var pending: [RepoFile] = []
        for file in files {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: file.path).path)[.size] as? Int64) ?? -1
            if size == file.size { have += file.size } else { pending.append(file) }
        }
        let bytes = ByteTally()
        for file in pending { bytes.counts[file.path] = bg.receivedSoFar(BackgroundDownloads.key(id, file.path)) }
        let base = have
        report(id, base + bytes.sum)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in pending {
                let url = URL(string: "https://huggingface.co/\(id)/resolve/main/\(file.path)")!
                group.addTask { @MainActor [weak self] in
                    try await bg.fetch(key: BackgroundDownloads.key(id, file.path), url: url, expected: file.size) { n in
                        bytes.counts[file.path] = n
                        self?.report(id, base + bytes.sum)
                    }
                }
            }
            try await group.waitForAll()
        }
        for file in pending {
            try Task.checkCancellation()
            let dest = dir.appending(path: file.path)
            try await verifyAndPlace(id, file, part: dir.appending(path: file.path + ".part"), dest: dest)
        }
        report(id, totals[id] ?? 0)
        try writeReadyMarker(files, dir)
    }
    #endif

    /// Mac: one file after another inside the app, resuming with HTTP ranges.
    private func fetchInApp(_ id: String, _ dir: URL) async throws {
        let files = try await fileList(id, dir)
        let total = files.reduce(0) { $0 + $1.size }
        totals[id] = total
        var done: Int64 = 0

        for file in files {
            try Task.checkCancellation()
            let dest = dir.appending(path: file.path)
            let existing = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
            if existing == file.size { done += file.size; report(id, done); continue }

            let part = dir.appending(path: file.path + ".part")
            let base = done
            states[id] = .downloading(progress(id))
            let url = URL(string: "https://huggingface.co/\(id)/resolve/main/\(file.path)")!
            try await FileDownload(url: url, part: part, expected: file.size) { [weak self] bytes in
                Task { @MainActor in self?.report(id, base + bytes) }
            }.run()

            try await verifyAndPlace(id, file, part: part, dest: dest)
            done += file.size
            report(id, done)
        }
        try writeReadyMarker(files, dir)
    }

    private func report(_ id: String, _ bytes: Int64) {
        received[id] = bytes
        if case .downloading = state(id) { states[id] = .downloading(progress(id)) }
        keepAliveUpdate(id)
    }

    #if os(iOS)
    private func keepAliveUpdate(_ id: String) {
        keepAlive.update(id: id, phase: state(id) == .verifying ? .verifying : .downloading, received: received[id] ?? 0, total: totals[id] ?? 0)
    }
    private func keepAliveFinish(_ id: String, _ phase: ModelDownloadAttributes.Phase) { keepAlive.finish(id: id, phase: phase) }
    #else
    private func keepAliveUpdate(_ id: String) {}
    private enum FinishPhase { case landed, paused, failed }
    private func keepAliveFinish(_ id: String, _ phase: FinishPhase) {}
    #endif

    /// The files to fetch, with sizes and checksums, from the Hugging Face tree API.
    nonisolated static func listFiles(_ id: String) async throws -> [RepoFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(id)/tree/main")!
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(from: url) } catch { throw DownloadError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DownloadError.http(status) }
        return try JSONDecoder().decode([RepoFile].self, from: data)
            .filter { $0.type == "file" && ModelCatalog.wanted($0.path) }
            .sorted { $0.size < $1.size }   // small files first, weights last
    }
}

#if os(iOS)
/// Bytes per file while several download at once; only touched on the main actor.
@MainActor private final class ByteTally: @unchecked Sendable {
    var counts: [String: Int64] = [:]
    var sum: Int64 { counts.values.reduce(0, +) }
}
#endif
