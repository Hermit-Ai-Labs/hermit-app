import Foundation
import Observation

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
    private static let selectedKey = "hermit.model.selected"
    private static let readyMarker = ".hermit-ready"

    public init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Hermit/Models", directoryHint: .isDirectory)
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey) ?? ModelCatalog.defaultID
        let spec = ModelCatalog.spec(saved)
        selectedID = spec.supported && ModelCatalog.fits(spec) ? saved : ModelCatalog.defaultID
        for spec in ModelCatalog.all { states[spec.id] = isComplete(spec.id) ? .ready : .notDownloaded }
        if states[selectedID] == nil { states[selectedID] = isComplete(selectedID) ? .ready : .notDownloaded }
    }

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

    /// The model name next to the send button: "Woof 2B", or "Woof 2B 42%" while it downloads.
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
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.fetch(id)
                self.states[id] = .ready
            } catch is CancellationError {
                self.states[id] = .notDownloaded
            } catch {
                self.states[id] = .failed(error.localizedDescription)
            }
            self.tasks[id] = nil
        }
    }

    /// Stops a download. What came down so far stays on disk, so the next download picks up from there.
    public func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Removes the model from this device.
    public func delete(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
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

        let files = try await Self.listFiles(id)
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

            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
            guard size == file.size else { try? FileManager.default.removeItem(at: part); throw DownloadError.sizeMismatch(file.path) }
            if let sha = file.sha256 {
                states[id] = .verifying
                let actual = try await Task.detached(priority: .utility) { try FileDownload.sha256(of: part) }.value
                guard actual == sha else { try? FileManager.default.removeItem(at: part); throw DownloadError.checksum(file.path) }
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            done += file.size
            report(id, done)
        }
        let manifest = files.map { "\($0.path) \($0.size) \($0.sha256 ?? "-")" }.joined(separator: "\n")
        try manifest.write(to: dir.appending(path: Self.readyMarker), atomically: true, encoding: .utf8)
    }

    private func report(_ id: String, _ bytes: Int64) {
        received[id] = bytes
        if case .downloading = state(id) { states[id] = .downloading(progress(id)) }
    }

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
