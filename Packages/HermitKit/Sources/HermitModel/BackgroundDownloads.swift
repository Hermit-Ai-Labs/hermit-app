import Foundation
import os

private let log = Logger(subsystem: "my.hermit", category: "model-download")

/// The transfers behind a model download: one URLSession download task per piece (or per small file).
///
/// iPhone: a background URLSession, so iOS itself moves the bytes while Hermit is in another app, the phone is
/// locked, or the app was closed by the system. When transfers finish, iOS wakes Hermit (see `handleEvents`).
/// Mac: an ordinary session inside the app.
///
/// Every task is keyed by "<model>\n<file>\n<piece>" in `taskDescription` ("-" for a file fetched whole), so tasks
/// still running after a relaunch are found again. A finished task's file is moved right away to its landing spot
/// (`landing(for:)`): `<file>.part` for a whole file, `<file>.parts/<NNN>.bin` for a piece. ModelStore checks it
/// and merges it from there. A paused piece keeps its resume data as `<landing>.resume` (plain GETs only; a ranged
/// request starts its piece again, which costs at most one piece).
/// All state is touched on the main thread (the delegate queue is the main queue).
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "my.hermit.ios.model-download"
    static let shared = BackgroundDownloads()
    /// Pieces moving at once. HTTP/2 shares one connection per host, HTTP/1.1 opens up to this many.
    /// `HERMIT_PIECE_CONCURRENCY` changes it for tests.
    static let concurrency = ProcessInfo.processInfo.environment["HERMIT_PIECE_CONCURRENCY"].flatMap(Int.init).map { max(1, min(16, $0)) } ?? 8

    /// Where model folders live; set by ModelStore before the first download.
    var root: URL = URL.applicationSupportDirectory.appending(path: "Hermit/Models", directoryHint: .isDirectory)

    private var session: URLSession!
    /// Tasks the system is still running for us, by key. Filled from the session on launch, then kept up to date.
    private var running: [String: URLSessionDownloadTask] = [:]
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var progress: [String: (Int64) -> Void] = [:]
    /// Bytes reported last per key, to report about every megabyte instead of every packet.
    private var reported: [String: Int64] = [:]
    private var failures: [String: Error] = [:]
    /// What iOS hands us when it wakes the app for finished transfers; called once the events are delivered.
    private var eventsDone: (() -> Void)?
    private var listed = false
    private var listWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
        #if os(iOS)
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        #else
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        #endif
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = Self.concurrency
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for case let t as URLSessionDownloadTask in tasks where t.state == .running || t.state == .suspended {
                    guard let key = t.taskDescription else { continue }
                    // Whole-file tasks from before pieces (two-part keys) are dropped: their files don't fit the new plan.
                    if key.split(separator: "\n", omittingEmptySubsequences: false).count != 3 { t.cancel(); continue }
                    self.running[key] = t
                }
                log.info("transfer session up, \(self.running.count) transfer(s) still running")
                self.listed = true
                self.listWaiters.forEach { $0.resume() }; self.listWaiters = []
            }
        }
    }

    // MARK: Keys and files

    static func key(_ model: String, _ path: String, piece: Int?) -> String { "\(model)\n\(path)\n\(piece.map(String.init) ?? "-")" }

    /// Where a finished transfer's file is put.
    func landing(for key: String) -> URL? {
        let bits = key.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard bits.count == 3 else { return nil }
        let file = root.appending(path: bits[0], directoryHint: .isDirectory).appending(path: bits[1])
        guard let n = Int(bits[2]) else { return file.appendingPathExtension("part") }
        return Self.pieceFile(file, n)
    }

    static func pieceFile(_ file: URL, _ n: Int) -> URL {
        file.appendingPathExtension("parts").appending(path: String(format: "%03d.bin", n))
    }

    private func resumeFile(_ landing: URL) -> URL { landing.appendingPathExtension("resume") }

    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    }

    // MARK: Using it

    /// Waits until the tasks the system kept for us have been listed (right after launch).
    @MainActor func ready() async {
        if listed { return }
        await withCheckedContinuation { listWaiters.append($0) }
    }

    /// Models that still have transfers running in the system, e.g. after the app was relaunched.
    @MainActor func modelsInFlight() async -> Set<String> {
        await ready()
        return Set(running.keys.compactMap { $0.split(separator: "\n").first.map(String.init) })
    }

    /// Bytes the system has already received for a key (known for tasks found after a relaunch).
    @MainActor func receivedSoFar(_ key: String) -> Int64 { running[key]?.countOfBytesReceived ?? 0 }

    /// The request of a transfer still running for the key, e.g. one picked up after a relaunch.
    @MainActor func runningRequest(_ key: String) -> URLRequest? { running[key]?.originalRequest }

    /// Fetches `request` to the key's landing file. Picks up a task the system is still running, a finished file
    /// waiting on disk, or resume data from an earlier pause; otherwise starts fresh. Returns when the file landed.
    /// `expected` is the exact size; anything else is an error.
    @MainActor func fetch(key: String, request: URLRequest, expected: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        await ready()
        guard let landing = landing(for: key) else { return }
        if Self.size(landing) == expected { onBytes(expected); return }   // finished while Hermit wasn't running
        progress[key] = onBytes
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters[key] = c
                if let t = running[key] {
                    // The same piece from another source (after a fallback) is a different request: start over.
                    if t.originalRequest?.url == request.url {
                        onBytes(t.countOfBytesReceived)
                        if t.state == .suspended { t.resume() }
                        return
                    }
                    t.cancel(); running[key] = nil
                }
                let resume = resumeFile(landing)
                var task: URLSessionDownloadTask?
                if let data = try? Data(contentsOf: resume) {
                    try? FileManager.default.removeItem(at: resume)
                    if request.value(forHTTPHeaderField: "Range") == nil { task = session.downloadTask(withResumeData: data) }
                }
                if task?.originalRequest?.url != request.url { task?.cancel(); task = nil }
                try? FileManager.default.removeItem(at: landing)
                let t = task ?? session.downloadTask(with: request)
                t.taskDescription = key
                t.countOfBytesClientExpectsToReceive = expected
                running[key] = t
                t.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.pause(key) }
        }
        let got = Self.size(landing)
        guard got == expected else {
            try? FileManager.default.removeItem(at: landing)
            throw DownloadError.sizeMismatch(key.split(separator: "\n").dropFirst().joined(separator: " piece "))
        }
    }

    /// Stops a transfer and keeps its resume data, so the next download continues from there.
    @MainActor func pause(_ key: String) {
        guard let t = running[key], let landing = landing(for: key) else { return }
        running[key] = nil
        let resume = resumeFile(landing)
        t.cancel { data in
            if let data { try? data.write(to: resume) }
        }
    }

    #if os(macOS)
    /// Mac, as Hermit quits: every running transfer hands over its resume data before the app goes, so the next launch
    /// continues each piece from the byte it stopped at instead of from its start. Waits up to two seconds.
    @MainActor func saveForQuit() {
        let tasks = running
        guard !tasks.isEmpty else { return }
        let left = Countdown(tasks.count)
        for (key, t) in tasks {
            guard let landing = landing(for: key) else { left.tick(); continue }
            let resume = resumeFile(landing)
            t.cancel { data in
                if let data { try? data.write(to: resume) }
                left.tick()
            }
        }
        running = [:]
        let deadline = Date().addingTimeInterval(2)
        while left.value > 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private final class Countdown: @unchecked Sendable {
        private let lock = NSLock(); private var n: Int
        init(_ n: Int) { self.n = n }
        func tick() { lock.lock(); n -= 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
    #endif

    /// Stops and forgets every transfer for a model (when it is deleted).
    @MainActor func discard(model: String) {
        for (key, t) in running where key.hasPrefix(model + "\n") {
            t.cancel(); running[key] = nil
        }
    }

    /// From the app delegate: iOS woke Hermit to deliver finished transfers. The handler runs once they're delivered.
    @MainActor func handleEvents(_ completion: @escaping () -> Void) { eventsDone = completion }

    // MARK: URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Hugging Face and ModelScope redirect to a CDN on another host. Keep the byte range across that hop, or the
        // CDN would send the whole file for one piece.
        var req = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") { req.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(req)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        if totalBytesWritten - (reported[key] ?? 0) >= 1_048_576 || totalBytesWritten == totalBytesExpectedToWrite {
            reported[key] = totalBytesWritten
            progress[key]?(totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so it's moved right here, even if no one is waiting yet.
        guard let key = downloadTask.taskDescription, let landing = landing(for: key) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let ranged = downloadTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil
        // A ranged request answered 200 sent the whole file: useless for one piece, so it isn't kept.
        guard ranged ? status == 206 : (status == 200 || status == 206) else { failures[key] = DownloadError.http(status); return }
        do {
            try FileManager.default.createDirectory(at: landing.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: landing)
            try FileManager.default.moveItem(at: location, to: landing)
        } catch { failures[key] = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        if let error { log.info("transfer ended for \(key.replacingOccurrences(of: "\n", with: " "), privacy: .public): \(error.localizedDescription, privacy: .public)") }
        if running[key] === task { running[key] = nil } else if running[key] != nil { return }   // an older task for the key
        reported[key] = nil
        let waiter = waiters.removeValue(forKey: key)
        if let failure = failures.removeValue(forKey: key) { progress[key] = nil; waiter?.resume(throwing: failure); return }
        guard let error else {
            if let landing = landing(for: key) { progress[key]?(Self.size(landing)) }
            progress[key] = nil
            waiter?.resume(); return
        }
        let ns = error as NSError
        // Keep what came down so the next try continues instead of starting over.
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let landing = landing(for: key) {
            try? data.write(to: resumeFile(landing))
        }
        progress[key] = nil
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { waiter?.resume(throwing: CancellationError()) }
        else if ns.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(ns.code) {
            waiter?.resume(throwing: DownloadError.offline)
        } else { waiter?.resume(throwing: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = eventsDone; eventsDone = nil
        done?()
    }
}
