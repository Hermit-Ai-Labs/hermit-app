import Foundation
import CryptoKit

/// A file in a Hugging Face repo, as the tree API lists it. `sha256` is set for LFS files (the weights).
struct RepoFile: Decodable, Sendable {
    let type: String
    let path: String
    let size: Int64
    let lfs: LFS?
    struct LFS: Decodable, Sendable { let oid: String; let size: Int64 }
    var sha256: String? { lfs?.oid }
}

enum DownloadError: LocalizedError {
    case http(Int)
    case sizeMismatch(String)
    case checksum(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .http(let code): "The server answered \(code)."
        case .sizeMismatch(let f): "\(f) came down the wrong size."
        case .checksum(let f): "\(f) failed its checksum."
        case .offline: "No internet connection."
        }
    }
}

/// Streams one file to `<dest>.part` with HTTP Range resume, so a download survives quitting the app.
/// `onBytes` gets the bytes on disk for this file, at most every 1 MB.
final class FileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let part: URL
    private let expected: Int64
    private let onBytes: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var reported: Int64 = 0
    private var failure: Error?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?

    init(url: URL, part: URL, expected: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.part = part; self.expected = expected; self.onBytes = onBytes
    }

    func run() async throws {
        let fm = FileManager.default
        var have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if have > expected { try? fm.removeItem(at: part); have = 0 }
        onBytes(have)
        if have == expected { return }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        handle = try FileHandle(forWritingTo: part)
        written = have

        var request = URLRequest(url: url, timeoutInterval: 60)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = c
                let t = session.dataTask(with: request)
                task = t
                lock.unlock()
                if Task.isCancelled { t.cancel() } else { t.resume() }
            }
        } onCancel: {
            lock.lock(); let t = task; lock.unlock()
            t?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206: try handle?.seekToEnd()
            case 200: try handle?.truncate(atOffset: 0); written = 0   // the server ignored the range: start over
            default: throw DownloadError.http(status)
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { failure = error; dataTask.cancel(); return }
        written += Int64(data.count)
        if written - reported >= 1_048_576 || written == expected { reported = written; onBytes(written) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        onBytes(written)
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let failure { c?.resume(throwing: failure) }
        else if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { c?.resume(throwing: CancellationError()) }
            else if ns.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(ns.code) {
                c?.resume(throwing: DownloadError.offline)
            } else { c?.resume(throwing: error) }
        } else { c?.resume() }
    }

    /// SHA-256 of a file, read in 8 MB chunks so a 2 GB file doesn't sit in memory.
    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
