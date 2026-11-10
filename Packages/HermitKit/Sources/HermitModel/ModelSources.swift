import Foundation
import os

private let log = Logger(subsystem: "my.hermit", category: "model-download")

/// Where model bytes can come from. Every source serves the same files (checked against `ModelPin`), so a piece
/// that fails from one is fetched from the next.
///   mirror       models.hermit.my, Hermit's Cloudflare R2 bucket. Big files are stored as 128 MiB pieces so every
///                piece sits in Cloudflare's edge cache near the phone (US, India, Hong Kong, Taiwan, Europe...).
///   modelscope   ModelScope (Alibaba), served from mainland China, where Hugging Face is blocked and Cloudflare
///                doesn't serve from inside the country.
///   huggingface  the original repo, pinned to the release's commit. The fallback everywhere.
public enum ModelSource: String, CaseIterable, Sendable, Codable {
    case mirror, modelscope, huggingface

    public static let mirrorHost = "https://models.hermit.my"
    /// The ModelScope namespace the models are published under (scripts/publish-modelscope.py).
    public static let modelscopeOwner = "HermitAiLabs"

    /// The URL and byte range for a piece of a file. `piece` is nil for a file fetched whole.
    func request(model: String, revision: String, path: String, piece: Int?, offset: Int64, length: Int64) -> URLRequest? {
        let repo = model.split(separator: "/").last.map(String.init) ?? model
        let url: URL?
        var range = piece != nil
        switch self {
        case .mirror:
            // Pieces are their own objects on the mirror: a plain GET, cached at the edge, resumable by URLSession.
            if let piece { url = URL(string: "\(Self.mirrorHost)/\(model)/\(revision)/\(path).parts/\(String(format: "%03d", piece)).bin"); range = false }
            else { url = URL(string: "\(Self.mirrorHost)/\(model)/\(revision)/\(path)") }
        case .modelscope:
            url = URL(string: "https://www.modelscope.cn/models/\(Self.modelscopeOwner)/\(repo)/resolve/master/\(path)")
        case .huggingface:
            url = URL(string: "https://huggingface.co/\(model)/resolve/\(revision)/\(path)")
        }
        guard let url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 60)
        if range { r.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range") }
        return r
    }

    public var host: String {
        switch self {
        case .mirror: "models.hermit.my"
        case .modelscope: "modelscope.cn"
        case .huggingface: "huggingface.co"
        }
    }

    /// The order to try when probes give no answer: ModelScope first in mainland China, else the mirror.
    static var regionalOrder: [ModelSource] {
        isMainlandChina ? [.modelscope, .mirror, .huggingface] : [.mirror, .huggingface, .modelscope]
    }

    /// A guess from the phone's region and time zone, used only to order sources the probes couldn't tell apart.
    static var isMainlandChina: Bool {
        if Locale.current.region?.identifier == "CN" { return true }
        return ["Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin"].contains(TimeZone.current.identifier)
    }

    /// `HERMIT_MODEL_SOURCES=huggingface,mirror` (environment or defaults) fixes the order, for tests and timings.
    static var forced: [ModelSource]? {
        let raw = ProcessInfo.processInfo.environment["HERMIT_MODEL_SOURCES"] ?? UserDefaults.standard.string(forKey: "hermitModelSources")
        guard let raw, !raw.isEmpty else { return nil }
        let list = raw.split(separator: ",").compactMap { ModelSource(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return list.isEmpty ? nil : list
    }
}

/// Picks the fastest source for this phone: every source gets the same small range request (the first 512 KB of
/// the biggest file) at once, and they're ranked by how quickly the bytes came back. Sources that didn't answer, or
/// answered wrong, go last in the regional order, so they're still tried if everything else fails.
enum SourceRace {
    static let probeBytes: Int64 = 512 << 10

    static func rank(model: String, pin: ModelPin?, revision: String, files: [ModelPin.File],
                     candidates: [ModelSource]) async -> [ModelSource] {
        if let forced = ModelSource.forced { return forced }
        guard let big = files.max(by: { $0.size < $1.size }) else { return candidates }
        let length = min(probeBytes, big.size)
        let isPieced = (pin?.pieceSize).map { big.size > $0 } ?? false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let timings = await withTaskGroup(of: (ModelSource, Double?).self) { group in
            for source in candidates {
                group.addTask {
                    guard var r = source.request(model: model, revision: revision, path: big.path,
                                                 piece: isPieced ? 0 : nil, offset: 0, length: big.size) else { return (source, nil) }
                    r.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
                    r.timeoutInterval = 6
                    let start = ContinuousClock.now
                    guard let (data, response) = try? await session.data(for: r),
                          let status = (response as? HTTPURLResponse)?.statusCode,
                          status == 206 || status == 200, Int64(data.count) >= length else { return (source, nil) }
                    let d = ContinuousClock.now - start
                    return (source, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
                }
            }
            var out: [ModelSource: Double] = [:]
            for await (s, t) in group { if let t { out[s] = t } }
            return out
        }
        let regional = ModelSource.regionalOrder
        let answered = timings.keys.sorted { timings[$0]! < timings[$1]! }
        let rest = regional.filter { candidates.contains($0) && timings[$0] == nil }
        let ranked = answered + rest
        log.info("source race: \(ranked.map { "\($0.rawValue)=\(timings[$0].map { String(format: "%.2fs", $0) } ?? "-")" }.joined(separator: " "), privacy: .public)")
        return ranked
    }
}
