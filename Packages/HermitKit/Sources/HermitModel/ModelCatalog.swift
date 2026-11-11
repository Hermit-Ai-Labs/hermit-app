import Foundation
import HermitCore

/// One model Hermit can run on this device.
public struct ModelSpec: Identifiable, Hashable, Sendable {
    /// Hugging Face repo, e.g. "rahulol/Hermit-1.1-4B-MLX-4bit". Also the folder name on the mirror and on this device.
    public let id: String
    /// The Hugging Face commit this app ships with. Its files are pinned in `ModelPins` and mirrored at
    /// models.hermit.my/<id>/<revision>/, so a later push to the repo never changes what this app downloads.
    public let revision: String
    /// Short name for the UI: "Hermit 1.1".
    public let name: String
    /// One plain line under the name.
    public let detail: String
    /// Rough download size, shown before the exact file list is known.
    public let approxBytes: Int64
    /// Devices with less memory than this can't run it (8 GB Macs and iPhones get the 2B).
    public let minMemoryGB: Int
    /// False when the MLX library can't run this architecture yet: listed as "Coming soon".
    public let supported: Bool
    /// The tool set the model was trained on, which decides its prompt. `.v2` (Hermit 1.2, Hermit 1.1 Lite, and any
    /// model not marked otherwise) keeps today's system prompt and tool lines byte for byte. Only a model trained on
    /// the 30 tools with packs is marked `.v3`.
    public let toolSet: HermitPrompt.ToolSet

    public init(id: String, revision: String = "main", name: String, detail: String, approxBytes: Int64, minMemoryGB: Int,
                supported: Bool = true, toolSet: HermitPrompt.ToolSet = .v2) {
        self.id = id; self.revision = revision; self.name = name; self.detail = detail; self.approxBytes = approxBytes
        self.minMemoryGB = minMemoryGB; self.supported = supported; self.toolSet = toolSet
    }

    /// The release's exact files and hashes, when they're built into the app.
    public var pin: ModelPin? { ModelPins.all[id].flatMap { $0.revision == revision ? $0 : nil } }
}

public enum ModelCatalog {
    /// Hermit 1.2 is Qwen3-4B-Instruct-2507 (Apache-2.0) fine-tuned on Hermit's trading tools, for iPhones and Macs
    /// with 8 GB. Hermit 1.1 Lite, Qwen3-1.7B (Apache-2.0), runs on smaller ones. Both are MLX 4-bit copies on
    /// Hermit's own Hugging Face repos, pinned to a commit and mirrored (see ModelSources).
    public static let fullID = "rahulol/Hermit-1.2-4B-MLX-4bit"
    public static let liteID = "rahulol/Hermit-1.1-Lite-MLX-4bit"
    /// iPhone 15 Pro and later report about 7.5 GB, so 7 is the line.
    public static var defaultID: String { deviceMemoryGB >= 7 ? fullID : liteID }

    public static let all: [ModelSpec] = [
        // Both are `toolSet: .v2` (the default). The Hermit 1.3 specs, trained on the v3 tools, are added after training
        // with `toolSet: .v3`.
        // Hermit 1.2 rev b (get_quote + restraint), HF main as of 2026-11-09.
        ModelSpec(id: fullID, revision: "6183aaf929d66dc50f4b7c547d140fca57be54e6", name: "Hermit 1.2",
                  detail: "Hermit's full model, trained on its trading tools. Private, offline.", approxBytes: 2_270_000_000, minMemoryGB: 7),
        ModelSpec(id: liteID, revision: "52b8428909ab484f23945d317a32d4a63da57f49", name: "Hermit 1.1 Lite",
                  detail: ModelSpec.liteDetail, approxBytes: 980_000_000, minMemoryGB: 5),
    ]

    /// The spec for an id, or a plain one built from the repo name if it isn't in the list.
    public static func spec(_ id: String) -> ModelSpec {
        all.first { $0.id == id } ?? ModelSpec(id: id, name: String(id.split(separator: "/").last ?? Substring(id)),
                                               detail: "", approxBytes: 0, minMemoryGB: 0)
    }

    public static var deviceMemoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Whether this device has the memory for the model.
    public static func fits(_ spec: ModelSpec) -> Bool { deviceMemoryGB >= spec.minMemoryGB }

    /// Files the app needs from the repo. Weights, configs, tokenizer and the chat template.
    static func wanted(_ path: String) -> Bool {
        !path.contains("/") && (path.hasSuffix(".safetensors") || path.hasSuffix(".json") || path.hasSuffix(".jinja"))
    }
}

extension ModelSpec {
    #if os(macOS)
    static let liteDetail = "Smaller and quicker. Leaves more memory for your other apps."
    #else
    static let liteDetail = "Smaller and quicker. Runs on every iPhone."
    #endif
}
