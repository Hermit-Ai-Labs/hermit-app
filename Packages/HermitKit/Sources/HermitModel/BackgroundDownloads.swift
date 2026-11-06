#if os(iOS)
import Foundation
import os

private let log = Logger(subsystem: "my.hermit", category: "model-download")

/// iPhone model downloads through a background URLSession: iOS itself moves the bytes, so a download keeps going while
/// Hermit is in another app, the phone is locked, or the app was closed by the system. When it finishes, iOS wakes
/// Hermit (see `handleEvents`) and the file is moved into the model folder as `<file>.part`; ModelStore then checks
/// its size and SHA-256 and puts it in place.
///
/// One task per file, keyed by "<model id>\n<file path>" in `taskDescription`, so tasks still running after a
/// relaunch are found again. Paused or failed transfers keep their resume data next to the file as `<file>.resume`.
/// All state is touched on the main thread (the session's delegate queue is the main queue).
final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "my.hermit.ios.model-download"
    static let shared = BackgroundDownloads()

    /// Where model folders live; set by ModelStore before the first download.
    var root: URL = URL.applicationSupportDirectory.appending(path: "Hermit/Models", directoryHint: .isDirectory)

    private var session: URLSession!
    /// Tasks iOS is still running for us, by key. Filled from the session on launch, then kept up to date.
    private var running: [String: URLSessionDownloadTask] = [:]
    private var waiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var progress: [String: (Int64) -> Void] = [:]
    /// Bytes reported last per key, to report about every megabyte instead of every packet.
    private var reported: [String: Int64] = [:]
    /// What iOS hands us when it wakes the app for finished transfers; called once the events are delivered.
    private var eventsDone: (() -> Void)?
    private var listed = false
    private var listWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 24
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for case let t as URLSessionDownloadTask in tasks where t.state == .running || t.state == .suspended {
                    if let key = t.taskDescription { self.running[key] = t }
                }
                log.info("background session up, \(self.running.count) transfer(s) still running")
                self.listed = true
                self.listWaiters.forEach { $0.resume() }; self.listWaiters = []
            }
        }
    }

    // MARK: Keys and files

    static func key(_ model: String, _ path: String) -> String { "\(model)\n\(path)" }

    private func part(_ key: String) -> URL? {
        let bits = key.split(separator: "\n", maxSplits: 1).map(String.init)
        guard bits.count == 2 else { return nil }
        return root.appending(path: bits[0], directoryHint: .isDirectory).appending(path: bits[1] + ".part")
    }

    private func resumeFile(_ part: URL) -> URL { part.deletingPathExtension().appendingPathExtension("resume") }

    private static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    }

    // MARK: Using it

    /// Waits until the tasks iOS kept for us have been listed (right after launch).
    @MainActor func ready() async {
        if listed { return }
        await withCheckedContinuation { listWaiters.append($0) }
    }

    /// Models that still have transfers running in the system, e.g. after the app was relaunched.
    @MainActor func modelsInFlight() async -> Set<String> {
        await ready()
        return Set(running.keys.compactMap { $0.split(separator: "\n").first.map(String.init) })
    }

    /// Bytes iOS has already received for a key (known for tasks found after a relaunch).
    @MainActor func receivedSoFar(_ key: String) -> Int64 { running[key]?.countOfBytesReceived ?? 0 }

    /// Downloads `url` to `<file>.part` for the key. Picks up a task iOS is still running, a finished file waiting on
    /// disk, or resume data from an earlier pause; otherwise starts fresh. Returns when the .part file is complete.
    @MainActor func fetch(key: String, url: URL, expected: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        await ready()
        guard let part = part(key) else { return }
        if Self.size(part) == expected { onBytes(expected); return }   // finished while Hermit wasn't running
        log.info("fetch \(key.replacingOccurrences(of: "\n", with: " "), privacy: .public)")
        progress[key] = onBytes
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters[key] = c
                if let t = running[key] {
                    onBytes(t.countOfBytesReceived)
                    if t.state == .suspended { t.resume() }
                    return
                }
                let resume = resumeFile(part)
                let task: URLSessionDownloadTask
                if let data = try? Data(contentsOf: resume) {
                    try? FileManager.default.removeItem(at: resume)
                    task = session.downloadTask(withResumeData: data)
                } else {
                    try? FileManager.default.removeItem(at: part)   // a partial file from the old range-based download
                    task = session.downloadTask(with: url)
                }
                task.taskDescription = key
                task.countOfBytesClientExpectsToReceive = expected
                running[key] = task
                task.resume()
                log.info("started transfer for \(key.replacingOccurrences(of: "\n", with: " "), privacy: .public)")
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.pause(key) }
        }
    }

    /// Stops a transfer and keeps its resume data, so the next download continues from there.
    @MainActor func pause(_ key: String) {
        guard let t = running[key], let part = part(key) else { return }
        running[key] = nil
        let resume = resumeFile(part)
        t.cancel { data in
            if let data { try? data.write(to: resume) }
        }
    }

    /// Stops and forgets every transfer for a model (when it is deleted).
    @MainActor func discard(model: String) {
        for (key, t) in running where key.hasPrefix(model + "\n") {
            t.cancel(); running[key] = nil
            if let part = part(key) { try? FileManager.default.removeItem(at: resumeFile(part)) }
        }
    }

    /// From the app delegate: iOS woke Hermit to deliver finished transfers. The handler runs once they're delivered.
    @MainActor func handleEvents(_ completion: @escaping () -> Void) { eventsDone = completion }

    // MARK: URLSessionDownloadDelegate (main queue)

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
        guard let key = downloadTask.taskDescription, let part = part(key) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else { failures[key] = DownloadError.http(status); return }
        do {
            try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch { failures[key] = error }
    }

    private var failures: [String: Error] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        log.info("transfer ended for \(key.replacingOccurrences(of: "\n", with: " "), privacy: .public): \(error.map { "\($0)" } ?? "ok", privacy: .public)")
        if running[key] === task { running[key] = nil }
        reported[key] = nil
        let waiter = waiters.removeValue(forKey: key)
        if let failure = failures.removeValue(forKey: key) { waiter?.resume(throwing: failure); return }
        guard let error else {
            if let part = part(key) { progress[key]?(Self.size(part)) }
            progress[key] = nil
            waiter?.resume(); return
        }
        let ns = error as NSError
        // Keep what came down so the next try continues instead of starting over.
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let part = part(key) {
            try? data.write(to: resumeFile(part))
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
#endif
