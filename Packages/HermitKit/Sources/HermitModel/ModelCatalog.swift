import Foundation

/// One model Hermit can run on this device.
public struct ModelSpec: Identifiable, Hashable, Sendable {
    /// Hugging Face repo, e.g. "rahulol/Hermit-1.1-4B-MLX-4bit". Files come from huggingface.co/<id>/resolve/main.
    public let id: String
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

    public init(id: String, name: String, detail: String, approxBytes: Int64, minMemoryGB: Int, supported: Bool = true) {
        self.id = id; self.name = name; self.detail = detail; self.approxBytes = approxBytes
        self.minMemoryGB = minMemoryGB; self.supported = supported
    }
}

public enum ModelCatalog {
    /// Hermit 1.2 is Qwen3-4B-Instruct-2507 (Apache-2.0) fine-tuned on Hermit's trading tools, for iPhones and Macs
    /// with 8 GB. Hermit 1.1 Lite, Qwen3-1.7B (Apache-2.0), runs on smaller ones. Both are MLX 4-bit copies on
    /// Hermit's own Hugging Face repos.
    public static let fullID = "rahulol/Hermit-1.2-4B-MLX-4bit"
    public static let liteID = "rahulol/Hermit-1.1-Lite-MLX-4bit"
    /// iPhone 15 Pro and later report about 7.5 GB, so 7 is the line.
    public static var defaultID: String { deviceMemoryGB >= 7 ? fullID : liteID }

    public static let all: [ModelSpec] = [
        ModelSpec(id: fullID, name: "Hermit 1.2",
                  detail: "Hermit's full model, trained on its trading tools. Private, offline.", approxBytes: 2_270_000_000, minMemoryGB: 7),
        ModelSpec(id: liteID, name: "Hermit 1.1 Lite",
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
