import Foundation
import Observation
import os

private let downloadLog = Logger(subsystem: "my.hermit", category: "model-download")
#if os(iOS)
import HermitActivity
import UIKit
#else
import AppKit
#endif

/// Downloads, checks and deletes on-device models, and says which one Hermit uses.
/// Files live in Application Support/Hermit/Models/<repo id>, are kept out of backups and resume after a quit.
///
/// How a download goes (both apps):
/// 1. The file list with sizes and SHA-256 comes built into the app (`ModelPins`), so no API call is needed.
/// 2. Every source (models.hermit.my, ModelScope, Hugging Face) gets a tiny probe at once; the fastest that answers
///    is used, the others are the fallback for any piece that fails or doesn't match its hash (`SourceRace`).
/// 3. Big files come down as 128 MiB pieces, 8 at a time, each its own transfer: in the iPhone's background session,
///    so they keep going while Hermit is suspended. Each piece is hash-checked and written into place (no second
///    copy of the file), and a relaunch only fetches the pieces that are missing.
/// 4. Each whole file is checked against its SHA-256 before it's used.
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
    /// iPhone on mobile data at first launch: the model waiting for the "Download now / Wait for Wi-Fi" answer.
    public private(set) var cellularAsk: String?
    /// The first download is waiting for Wi-Fi (the user picked "Wait for Wi-Fi"); it starts by itself on Wi-Fi.
    public private(set) var waitingForWiFi: String?
    /// The source the current download uses, for the logs and the model sheet.
    public private(set) var source: [String: ModelSource] = [:]

    public let root: URL
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deleteObservers: [(String) -> Void] = []
    /// Set when the app goes to the background, so every remaining piece is handed to iOS at once (it can't start
    /// new ones for us while Hermit is suspended).
    @ObservationIgnored private var releaseAll = false
    #if os(iOS)
    /// Background time and the Live Activity while a download runs.
    @ObservationIgnored private let keepAlive = DownloadKeepAlive()
    #endif
    private static let selectedKey = "hermit.model.selected"
    /// The model the user asked to download and hasn't finished, so a relaunch picks the download up again.
    private static let downloadingKey = "hermit.model.downloading"
    /// Set once the first-launch download was started (or offered): it never starts by itself again.
    private static let autoStartedKey = "hermit.model.autoStarted"
    /// The model waiting for Wi-Fi, kept across launches.
    private static let wifiKey = "hermit.model.waitForWiFi"
    private static let readyMarker = ".hermit-ready"
    /// The file list for a model that isn't pinned in the app, kept so a relaunch can continue without the network.
    private static let filesCache = ".hermit-files.json"
    /// Room kept free on top of the bytes still to come (the piece being merged, the system's own needs).
    private static let spaceMargin: Int64 = 400_000_000

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
        BackgroundDownloads.shared.root = self.root
        let testing = NSClassFromString("XCTestCase") != nil
        if let w = UserDefaults.standard.string(forKey: Self.wifiKey), known.contains(w), states[w] != .ready, !testing { waitForWiFi(w) }
        #if os(iOS)
        // iOS may have kept transfers going while Hermit wasn't running: attach to them, and continue a download the
        // user started that hasn't landed yet.
        Task { [weak self] in
            var ids = await BackgroundDownloads.shared.modelsInFlight()
            if let pending = UserDefaults.standard.string(forKey: Self.downloadingKey) { ids.insert(pending) }
            guard let self else { return }
            // Transfers iOS kept for a model that's no longer in the catalog (MiniCPM before Hermit 1.1) are cancelled,
            // not resumed: they'd fail into a retired folder forever and hold up the real download.
            let known = Set(ModelCatalog.all.map(\.id))
            for id in ids where !known.contains(id) { BackgroundDownloads.shared.discard(model: id) }
            for id in ids where known.contains(id) && self.state(id) != .ready { self.download(id) }
        }
        // Back in front: a download the user started that isn't running (interrupted while Hermit was away) continues
        // by itself, without a Try again tap.
        resumeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releaseAll = false
                self?.resumeInterrupted()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll = true }
        }
        #else
        // Mac: a download the user started and quit before it finished continues on the next launch (finished pieces
        // stay on disk), like the iPhone app.
        if let pending = UserDefaults.standard.string(forKey: Self.downloadingKey), known.contains(pending),
           states[pending] != .ready, !testing {
            Task { @MainActor [weak self] in self?.download(pending) }
        }
        // Quitting mid-download keeps each running piece's progress (resume data) for the next launch.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundDownloads.shared.saveForQuit() }
        }
        #endif
    }

    #if os(macOS)
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    #endif

    #if os(iOS)
    @ObservationIgnored private var resumeObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    private func resumeInterrupted() {
        guard let id = UserDefaults.standard.string(forKey: Self.downloadingKey), tasks[id] == nil, state(id) != .ready else { return }
        if case .failed = state(id), !NetworkPath.shared.isOnline { return }
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

    // MARK: First launch

    /// The first time Hermit opens, the selected model starts downloading without a tap: right away on Wi-Fi (or a
    /// Mac), after one question on mobile data. Never again after that, and never over a download that's running or
    /// finished; a paused or deleted model stays that way.
    public func autoStart() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.autoStartedKey) else { return }
        d.set(true, forKey: Self.autoStartedKey)
        let id = selectedID
        guard state(id) == .notDownloaded, tasks[id] == nil, d.string(forKey: Self.downloadingKey) == nil else { return }
        Task { @MainActor [weak self] in
            await NetworkPath.shared.settled()
            guard let self, self.state(id) == .notDownloaded, self.tasks[id] == nil else { return }
            #if os(iOS)
            if NetworkPath.shared.isExpensive { self.cellularAsk = id; return }
            if !NetworkPath.shared.isOnline { self.waitForWiFi(id); return }
            #endif
            self.download(id)
        }
    }

    /// The answer to "Download Hermit's AI now?" on mobile data.
    public func answerCellular(downloadNow: Bool) {
        guard let id = cellularAsk else { return }
        cellularAsk = nil
        if downloadNow { download(id) } else { waitForWiFi(id) }
    }

    /// Starts the download by itself once the phone is on Wi-Fi (or any network that isn't metered).
    private func waitForWiFi(_ id: String) {
        waitingForWiFi = id
        UserDefaults.standard.set(id, forKey: Self.wifiKey)
        guard !wifiWatching else { checkWiFi(); return }
        wifiWatching = true
        NetworkPath.shared.onChange { [weak self] in
            Task { @MainActor in self?.checkWiFi() }
        }
        checkWiFi()
    }
    @ObservationIgnored private var wifiWatching = false

    private func checkWiFi() {
        guard let id = waitingForWiFi, NetworkPath.shared.isUnmetered else { return }
        download(id)
    }

    private func clearWiFiWait() {
        waitingForWiFi = nil
        UserDefaults.standard.removeObject(forKey: Self.wifiKey)
    }

    // MARK: Changing

    public func select(_ id: String) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        if states[id] == nil { states[id] = isComplete(id) ? .ready : .notDownloaded }
    }

    /// Starts (or resumes) a download. Safe to call twice.
    public func download(_ id: String) {
        if cellularAsk == id { cellularAsk = nil }
        if waitingForWiFi == id { clearWiFiWait() }
        UserDefaults.standard.set(true, forKey: Self.autoStartedKey)
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
                } catch DownloadError.noSpace(let need, let free) {
                    // Retrying won't make room: say so at once.
                    self.states[id] = .failed(DownloadError.noSpace(need, free).localizedDescription)
                    self.clearDownloading(id)
                    self.keepAliveFinish(id, .failed)
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
        case DownloadError.http(let code): return "The download server answered \(code). Try again in a little while."
        case DownloadError.sizeMismatch, DownloadError.checksum, DownloadError.noSpace: return error.localizedDescription
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
        BackgroundDownloads.shared.discard(model: id)
        clearDownloading(id)
        if waitingForWiFi == id { clearWiFiWait() }
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

    /// The release to download: built in (pinned), else the mirror's manifest, else the Hugging Face tree listing.
    private func manifest(_ spec: ModelSpec, _ dir: URL) async throws -> (ModelPin, [ModelSource]) {
        if let pin = spec.pin { return (pin, ModelSource.allCases) }
        let cache = dir.appending(path: Self.filesCache)
        if let data = try? Data(contentsOf: cache), let m = try? JSONDecoder().decode(CachedManifest.self, from: data) {
            return (m.pin, m.sources)
        }
        let found: CachedManifest
        if let m = await Self.mirrorManifest(spec) {
            found = CachedManifest(pin: m, sources: ModelSource.allCases)
        } else {
            let files = try await Self.listFiles(spec.id, revision: spec.revision)
            let pin = ModelPin(revision: spec.revision, pieceSize: Self.pieceSize,
                               files: files.map { .init(path: $0.path, size: $0.size, sha256: $0.sha256 ?? "") })
            found = CachedManifest(pin: pin, sources: [.huggingface])
        }
        try? JSONEncoder().encode(found).write(to: cache)
        return (found.pin, found.sources)
    }

    private struct CachedManifest: Codable { let pin: ModelPin; let sources: [ModelSource] }
    static let pieceSize: Int64 = 128 << 20

    private func fetch(_ id: String) async throws {
        let dir = directory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rootValues = URLResourceValues(); rootValues.isExcludedFromBackup = true
        var rootURL = root; try? rootURL.setResourceValues(rootValues)

        let spec = ModelCatalog.spec(id)
        let (pin, candidates) = try await manifest(spec, dir)
        let files = pin.files.filter { ModelCatalog.wanted($0.path) }
        let total = files.reduce(0) { $0 + $1.size }
        totals[id] = total
        let bg = BackgroundDownloads.shared
        await bg.ready()

        // What's on disk already: finished files, and pieces merged or landed while Hermit wasn't running.
        var have: Int64 = 0
        var jobs: [PieceJob] = []
        var pieced: [ModelPin.File] = []
        let assembler = PieceAssembler.shared
        for file in files {
            let dest = dir.appending(path: file.path)
            if BackgroundDownloads.size(dest) == file.size { have += file.size; continue }
            try? FileManager.default.removeItem(at: dest.appendingPathExtension("resume"))   // the old whole-file scheme
            if file.size > pin.pieceSize {
                try await adoptOldPart(file, dest)
                if BackgroundDownloads.size(dest) == file.size { have += file.size; continue }
                pieced.append(file)
                let merged = await assembler.merged(dest)
                for (i, offset) in stride(from: Int64(0), to: file.size, by: Int(pin.pieceSize)).enumerated() {
                    let length = min(pin.pieceSize, file.size - offset)
                    if merged.contains(i) { have += length; continue }
                    jobs.append(PieceJob(file: file, piece: i, offset: offset, length: length,
                                         sha256: file.pieces?[safe: i]))
                }
            } else {
                jobs.append(PieceJob(file: file, piece: nil, offset: 0, length: file.size, sha256: file.sha256.isEmpty ? nil : file.sha256))
            }
        }

        // Room for what's still to come, checked before a single byte.
        let still = total - have
        if still > 0, let free = FileDownload.freeSpace(at: dir) {
            let landed = jobs.reduce(Int64(0)) { sum, j in
                sum + max(0, BackgroundDownloads.size(landing(dir, j)))
            }
            let need = still - landed + Self.spaceMargin
            if free < need { throw DownloadError.noSpace(need, free) }
        }

        let tally = ByteTally()
        tally.base = have
        for job in jobs { tally.counts[job.key(id)] = bg.receivedSoFar(job.key(id)) }
        report(id, tally.sum)

        if !jobs.isEmpty {
            let order = await SourceRace.rank(model: id, pin: pin, revision: pin.revision, files: files, candidates: candidates)
            source[id] = nil
            downloadLog.info("downloading \(id, privacy: .public): \(jobs.count) transfers from \(order.map(\.rawValue).joined(separator: ","), privacy: .public)")
            try await run(jobs, id: id, dir: dir, pin: pin, order: order, tally: tally)
        }

        // Every piece is in: each big file gets its final check, then takes its place.
        for file in pieced {
            try Task.checkCancellation()
            let dest = dir.appending(path: file.path)
            guard BackgroundDownloads.size(dest) != file.size else { continue }
            let part = PieceAssembler.partFile(dest)
            do { try await verifyAndPlace(id, file, part: part, dest: dest) }
            catch { await assembler.reset(dest); throw error }
            await assembler.finish(dest)
        }
        report(id, total)
        try writeReadyMarker(files, dir)
    }

    /// One transfer: a piece of a big file, or a small file whole.
    private struct PieceJob: Sendable {
        let file: ModelPin.File
        let piece: Int?
        let offset: Int64
        let length: Int64
        let sha256: String?
        func key(_ model: String) -> String { BackgroundDownloads.key(model, file.path, piece: piece) }
    }

    private func landing(_ dir: URL, _ job: PieceJob) -> URL {
        let file = dir.appending(path: job.file.path)
        return job.piece.map { BackgroundDownloads.pieceFile(file, $0) } ?? file.appendingPathExtension("part")
    }

    /// Runs the transfers, `concurrency` at a time while Hermit is in front, every remaining one at once when it goes
    /// to the background (iOS can't start new transfers for a suspended app).
    private func run(_ jobs: [PieceJob], id: String, dir: URL, pin: ModelPin, order: [ModelSource], tally: ByteTally) async throws {
        var queue = jobs[...]
        try await withThrowingTaskGroup(of: Bool.self) { group in
            var active = 0
            func addNext() {
                guard let job = queue.popFirst() else { return }
                active += 1
                group.addTask { @MainActor [weak self] in
                    try await self?.transfer(job, id: id, dir: dir, pin: pin, order: order, tally: tally)
                    return true
                }
            }
            for _ in 0..<BackgroundDownloads.concurrency { addNext() }
            // Wakes the loop when the app goes to the background, so the rest can be handed over.
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    if self?.releaseAll ?? true { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                return false
            }
            for try await finished in group {
                if finished { active -= 1; addNext() } else { while !queue.isEmpty { addNext() } }
                if active == 0 && queue.isEmpty { group.cancelAll() }   // stops the background watcher
            }
        }
    }

    /// One piece (or small file) from the best source, falling back to the next on an error or a bad hash.
    private func transfer(_ job: PieceJob, id: String, dir: URL, pin: ModelPin, order: [ModelSource], tally: ByteTally) async throws {
        let bg = BackgroundDownloads.shared
        let key = job.key(id)
        let file = dir.appending(path: job.file.path)
        var lastError: Error = DownloadError.http(0)
        var tries: [(ModelSource?, URLRequest?)] = []
        // A transfer iOS kept running across a relaunch goes first, from wherever it was coming from.
        if let running = bg.runningRequest(key) { tries.append((nil, running)) }
        for source in order {
            tries.append((source, source.request(model: id, revision: pin.revision, path: job.file.path, piece: job.piece,
                                                 offset: job.offset, length: job.length)))
        }
        for (from, request) in tries {
            guard let request else { continue }
            try Task.checkCancellation()
            do {
                try await bg.fetch(key: key, request: request, expected: job.length) { [weak self] n in
                    tally.counts[key] = n
                    self?.report(id, tally.sum)
                }
            } catch let e as CancellationError { throw e }
            catch DownloadError.offline { throw DownloadError.offline }
            catch {
                downloadLog.error("\(key.replacingOccurrences(of: "\n", with: " "), privacy: .public) from \(request.url?.host() ?? "-", privacy: .public): \(String(describing: error), privacy: .public)")
                lastError = error; tally.counts[key] = 0; report(id, tally.sum); continue
            }
            if let piece = job.piece {
                let ok = try await PieceAssembler.shared.merge(file: file, index: piece, offset: job.offset, length: job.length, sha256: job.sha256)
                guard ok else {
                    downloadLog.error("piece \(piece) of \(job.file.path, privacy: .public) from \(request.url?.host() ?? "-", privacy: .public) failed its hash")
                    lastError = DownloadError.checksum(job.file.path); tally.counts[key] = 0; report(id, tally.sum); continue
                }
            } else {
                do { try await verifyAndPlace(id, job.file, part: file.appendingPathExtension("part"), dest: file) }
                catch { lastError = error; tally.counts[key] = 0; report(id, tally.sum); continue }
            }
            tally.counts[key] = nil
            tally.base += job.length
            if let from, job.piece != nil || source[id] == nil { source[id] = from }
            report(id, tally.sum)
            return
        }
        throw lastError
    }

    /// A .part left by the old one-file-at-a-time download: kept if it's the whole file and checks out, else removed.
    private func adoptOldPart(_ file: ModelPin.File, _ dest: URL) async throws {
        let part = PieceAssembler.partFile(dest)
        guard FileManager.default.fileExists(atPath: part.path),
              !FileManager.default.fileExists(atPath: PieceAssembler.stateFile(dest).path) else { return }
        if BackgroundDownloads.size(part) == file.size, (try? await verifyAndPlace(nil, file, part: part, dest: dest)) != nil { return }
        try? FileManager.default.removeItem(at: part)
    }

    /// Size and SHA-256 check, then the .part file takes the file's place.
    private func verifyAndPlace(_ id: String?, _ file: ModelPin.File, part: URL, dest: URL) async throws {
        let size = BackgroundDownloads.size(part)
        guard size == file.size else { try? FileManager.default.removeItem(at: part); throw DownloadError.sizeMismatch(file.path) }
        if !file.sha256.isEmpty {
            if let id, file.size > 64 << 20 { states[id] = .verifying; keepAliveUpdate(id) }
            let actual = try await Task.detached(priority: .userInitiated) { try FileDownload.sha256(of: part) }.value
            if let id, states[id] == .verifying { states[id] = .downloading(progress(id)) }
            guard actual == file.sha256 else { try? FileManager.default.removeItem(at: part); throw DownloadError.checksum(file.path) }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
    }

    private func writeReadyMarker(_ files: [ModelPin.File], _ dir: URL) throws {
        let manifest = files.map { "\($0.path) \($0.size) \($0.sha256.isEmpty ? "-" : $0.sha256)" }.joined(separator: "\n")
        try manifest.write(to: dir.appending(path: Self.readyMarker), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appending(path: Self.filesCache))
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

    /// The release's manifest.json on the mirror (models.hermit.my/<id>/<revision>/manifest.json), for a model whose
    /// files aren't built into the app.
    nonisolated static func mirrorManifest(_ spec: ModelSpec) async -> ModelPin? {
        guard let url = URL(string: "\(ModelSource.mirrorHost)/\(spec.id)/\(spec.revision)/manifest.json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONDecoder().decode(ModelPin.self, from: data), m.revision == spec.revision else { return nil }
        return m
    }

    /// The files to fetch, with sizes and checksums, from the Hugging Face tree API.
    nonisolated static func listFiles(_ id: String, revision: String = "main") async throws -> [RepoFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(id)/tree/\(revision)")!
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(from: url) } catch { throw DownloadError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DownloadError.http(status) }
        return try JSONDecoder().decode([RepoFile].self, from: data)
            .filter { $0.type == "file" && ModelCatalog.wanted($0.path) }
            .sorted { $0.size < $1.size }   // small files first, weights last
    }
}

/// Bytes per transfer while several run at once; only touched on the main actor.
@MainActor private final class ByteTally: @unchecked Sendable {
    /// Bytes finished and in place.
    var base: Int64 = 0
    /// Bytes so far per running transfer.
    var counts: [String: Int64] = [:]
    var sum: Int64 { base + counts.values.reduce(0, +) }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
