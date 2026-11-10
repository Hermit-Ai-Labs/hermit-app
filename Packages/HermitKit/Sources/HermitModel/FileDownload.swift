import Foundation
import CryptoKit

/// A file in a Hugging Face repo, as the tree API lists it. `sha256` is set for LFS files (the weights).
struct RepoFile: Codable, Sendable {
    let type: String
    let path: String
    let size: Int64
    let lfs: LFS?
    struct LFS: Codable, Sendable { let oid: String; let size: Int64 }
    var sha256: String? { lfs?.oid }
}

enum DownloadError: LocalizedError {
    case http(Int)
    case sizeMismatch(String)
    case checksum(String)
    case offline
    /// Bytes still needed, bytes free.
    case noSpace(Int64, Int64)

    var errorDescription: String? {
        switch self {
        case .http(let code): "The server answered \(code)."
        case .sizeMismatch(let f): "\(f) came down the wrong size."
        case .checksum(let f): "\(f) failed its checksum."
        case .offline: "No internet connection."
        case .noSpace(let need, let free):
            "Not enough space. Hermit needs \(Self.gb(need)) free and this \(Self.device) has \(Self.gb(free)). Free up some space, then try again."
        }
    }

    static func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
    #if os(iOS)
    static let device = "iPhone"
    #else
    static let device = "Mac"
    #endif
}

enum FileDownload {
    /// SHA-256 of a file (or of `length` bytes from `offset`), read in 8 MB chunks so a 2 GB file doesn't sit in memory.
    static func sha256(of url: URL, offset: Int64 = 0, length: Int64? = nil) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        var hasher = SHA256()
        var left = length ?? Int64.max
        while left > 0, let chunk = try h.read(upToCount: Int(min(8 << 20, left))), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
            left -= Int64(chunk.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Free bytes on the volume holding `url`, as the system counts them for things the user asked for.
    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        if let important = v.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Puts finished pieces into their file, off the main thread, one file at a time.
///
/// Each piece is read once: hashed (against the pin, when there is one) and written at its offset into
/// `<file>.part` in the same pass, then deleted. The .part file is written sparsely, so the disk only ever holds the
/// bytes that came down plus the piece being merged: no second full copy. Merged pieces are listed in
/// `<file>.pieces` so a relaunch only fetches what's missing.
actor PieceAssembler {
    static let shared = PieceAssembler()

    struct Done: Codable { var pieces: Set<Int> }

    static func stateFile(_ file: URL) -> URL { file.appendingPathExtension("pieces") }
    static func partFile(_ file: URL) -> URL { file.appendingPathExtension("part") }

    /// The pieces already merged into `<file>.part`. A .part with no list belongs to an older download and goes.
    func merged(_ file: URL) -> Set<Int> {
        let state = Self.stateFile(file)
        if let data = try? Data(contentsOf: state), let done = try? JSONDecoder().decode(Done.self, from: data),
           FileManager.default.fileExists(atPath: Self.partFile(file).path) {
            return done.pieces
        }
        try? FileManager.default.removeItem(at: state)
        return []
    }

    /// Merges one landed piece. Returns false (and deletes it) if its hash is wrong, so it's fetched again.
    func merge(file: URL, index: Int, offset: Int64, length: Int64, sha256: String?) throws -> Bool {
        let piece = BackgroundDownloads.pieceFile(file, index)
        let fm = FileManager.default
        guard BackgroundDownloads.size(piece) == length else { try? fm.removeItem(at: piece); return false }
        let part = Self.partFile(file)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let src = try FileHandle(forReadingFrom: piece)
        defer { try? src.close() }
        // Hash first, then write: a bad piece never touches the .part file.
        if let sha256 {
            var hasher = SHA256()
            while let chunk = try src.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard got == sha256 else { try? fm.removeItem(at: piece); return false }
            try src.seek(toOffset: 0)
        }
        let dst = try FileHandle(forWritingTo: part)
        defer { try? dst.close() }
        try dst.seek(toOffset: UInt64(offset))
        while let chunk = try src.read(upToCount: 8 << 20), !chunk.isEmpty { try dst.write(contentsOf: chunk) }
        try dst.synchronize()
        var done = merged(file)
        done.insert(index)
        try JSONEncoder().encode(Done(pieces: done)).write(to: Self.stateFile(file), options: .atomic)
        try? fm.removeItem(at: piece)
        return true
    }

    /// After the last piece: the bookkeeping goes, and the .part file is ready for its final check.
    func finish(_ file: URL) {
        try? FileManager.default.removeItem(at: Self.stateFile(file))
        try? FileManager.default.removeItem(at: file.appendingPathExtension("parts"))
    }

    /// Forget everything for a file (after a failed final check).
    func reset(_ file: URL) {
        finish(file)
        try? FileManager.default.removeItem(at: Self.partFile(file))
    }
}
