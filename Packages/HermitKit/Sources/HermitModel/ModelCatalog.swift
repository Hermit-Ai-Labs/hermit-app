import Foundation

/// One model Hermit can run on this device.
public struct ModelSpec: Identifiable, Hashable, Sendable {
    /// Hugging Face repo, e.g. "rahulol/Hermit-MiniCPM5-2B-MLX-4bit". Files come from huggingface.co/<id>/resolve/main.
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
    /// The model Hermit chats with: Hermit 1.1, our MLX 4-bit build of MiniCPM5 2B (SonGT1/MiniCPM5-abliterated-2B, Apache-2.0).
    public static let defaultID = "rahulol/Hermit-MiniCPM5-2B-MLX-4bit"

    public static let all: [ModelSpec] = [
        // Llama architecture, 4.5 bits per weight, about 1.5 GB of memory while it answers.
        ModelSpec(id: defaultID, name: "Hermit 1.1",
                  detail: "Hermit's own model. Fast, private, runs on every iPhone and Mac.", approxBytes: 1_426_101_824, minMemoryGB: 6),
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
