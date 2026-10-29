import Foundation

/// One model Hermit can run on this device.
public struct ModelSpec: Identifiable, Hashable, Sendable {
    /// Hugging Face repo, e.g. "ConwayResearch/Underdog-Woof-2B-1.1". Files come from huggingface.co/<id>/resolve/main.
    public let id: String
    /// Short name for the UI: "Woof 2B".
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
    /// The model Hermit chats with by default. Swap this one value for our own fine-tune.
    public static let defaultID = "ConwayResearch/Underdog-Woof-2B-1.1"

    public static let all: [ModelSpec] = [
        ModelSpec(id: "ConwayResearch/Underdog-Woof-2B-1.1", name: "Woof 2B",
                  detail: "Fast and light. Runs on every iPhone and Mac.", approxBytes: 1_437_000_000, minMemoryGB: 6),
        // qwen3_5 architecture, supported by MLXLLM 3.32.
        ModelSpec(id: "ConwayResearch/Underdog-Woof-4B-1.1", name: "Woof 4B",
                  detail: "Sharper answers. Needs a Mac with 16 GB.", approxBytes: 2_410_000_000, minMemoryGB: 16),
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
