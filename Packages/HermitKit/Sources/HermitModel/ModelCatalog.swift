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
    /// Rough download size, shown before the exact file list is known. Type the real total of the release's files
    /// (the sizes in its pin): nothing here is worked out from the parameter count or the quantisation.
    public let approxBytes: Int64
    /// Devices with less memory than this can't run it (8 GB Macs and iPhones get the 2B). Set it for the weights
    /// this release really has: a 6-bit, 8-bit or mixed copy is bigger than a 4-bit one and needs a higher number.
    public let minMemoryGB: Int
    /// False when the MLX library can't run this architecture yet: listed as "Coming soon".
    public let supported: Bool
    /// The tool set the model was trained on, which decides its prompt. `.v2` (Hermit 1.2, Hermit 1.1 Lite, and any
    /// model not marked otherwise) keeps today's system prompt and tool lines byte for byte. Only a model trained on
    /// the 30 tools with packs is marked `.v3`.
    public let toolSet: HermitPrompt.ToolSet
    /// One plain line on what this model does better than the one it replaces, for the upgrade card. Empty shows
    /// `detail` there.
    public let whatsNew: String

    public init(id: String, revision: String = "main", name: String, detail: String, approxBytes: Int64, minMemoryGB: Int,
                supported: Bool = true, toolSet: HermitPrompt.ToolSet = .v2, whatsNew: String = "") {
        self.id = id; self.revision = revision; self.name = name; self.detail = detail; self.approxBytes = approxBytes
        self.minMemoryGB = minMemoryGB; self.supported = supported; self.toolSet = toolSet; self.whatsNew = whatsNew
    }

    /// The release's exact files and hashes, when they're built into the app.
    public var pin: ModelPin? { ModelPins.all[id].flatMap { $0.revision == revision ? $0 : nil } }

    /// The exact download size, when the release's files are built into the app.
    public var pinnedBytes: Int64? {
        pin.map { $0.files.filter { ModelCatalog.wanted($0.path) }.reduce(Int64(0)) { $0 + $1.size } }
    }

    /// Hermit Lite, the small line. Read from the repo name (see `ModelCatalog.isLite`).
    public var isLite: Bool { ModelCatalog.isLite(id) }
}

public enum ModelCatalog {
    /// Hermit 1.2 is Qwen3-4B-Instruct-2507 (Apache-2.0) fine-tuned on Hermit's trading tools, for iPhones and Macs
    /// with 8 GB. Hermit 1.1 Lite, Qwen3-1.7B (Apache-2.0), runs on smaller ones. Both are MLX 4-bit copies on
    /// Hermit's own Hugging Face repos, pinned to a commit and mirrored (see ModelSources).
    ///
    /// These two ids are the models a new install downloads: the full one, and Lite. To move to a new release, add
    /// its spec to `all` and its pin to `ModelPins.all`, then put its id here. Nothing else changes: a person who
    /// has the older model keeps it and is offered the new one once (`ModelStore.upgrade`), so the older spec and
    /// pin stay in the lists. Lite's repo name must contain "lite" (`isLite`).
    public static let fullID = "rahulol/Hermit-1.2-4B-MLX-4bit"
    public static let liteID = "aiquantgod/Hermit-1.3-Lite-MLX-6bit"
    /// The model a new install starts with on this device.
    public static var defaultID: String { defaultModel(memoryGB: deviceMemoryGB) }
    /// The full model where it fits (its `minMemoryGB`; iPhone 15 Pro and later report about 7.5 GB, so 7 is the
    /// line for Hermit 1.2), Lite on anything smaller.
    public static func defaultModel(memoryGB: Int) -> String { lineup(memoryGB: memoryGB).defaultID }

    public static let all: [ModelSpec] = [
        // ==== HERMIT 1.3: PASTE THE TWO SPECS HERE ===========================================================
        // One spec per model, above the older ones so they are listed first. For each: the repo id, the 40-character
        // Hugging Face commit it was published at, and `approxBytes` = the sizes in its pin added up (the pin is what
        // scripts/publish-model.py prints; paste it into ModelPins.swift). Both are `toolSet: .v3` (the 30 tools
        // with packs). Then set `fullID` and `liteID` above to the two new ids. The shape, with nothing filled in:
        //
        //   ModelSpec(id: "<owner>/<Hermit 1.3 repo>", revision: "<commit>", name: "Hermit 1.3",
        //             detail: "Hermit's full model, trained on its trading tools. Private, offline.",
        //             approxBytes: <bytes>, minMemoryGB: 7, toolSet: .v3, whatsNew: ModelSpec.v3News),
        //   ModelSpec(id: "<owner>/<Hermit 1.3 Lite repo, with Lite in its name>", revision: "<commit>",
        //             name: "Hermit 1.3 Lite", detail: ModelSpec.liteDetail,
        //             approxBytes: <bytes>, minMemoryGB: 5, toolSet: .v3, whatsNew: ModelSpec.v3News),
        //
        // `minMemoryGB` 7 and 5 are today's values for 4-bit weights of these two base models (each is the weights
        // plus about 4 GB). A release quantised at 5, 6 or 8 bits, or mixed, is bigger: raise the number with it.
        // HermitModelTests (testShippedCatalog) then checks the ids, the pins, the sizes and the Lite name.
        ModelSpec(id: "aiquantgod/Hermit-1.3-Lite-MLX-6bit", revision: "446752a7c51e8640621478dd5618e9e259550a71", name: "Hermit 1.3 Lite",
                  detail: ModelSpec.liteDetail, approxBytes: 1_409_000_000, minMemoryGB: 5, toolSet: .v3, whatsNew: ModelSpec.v3News),
        // ==== END OF THE HERMIT 1.3 BLOCK ====================================================================

        // Older models stay listed so the files people already have keep working and can still be picked or removed.
        // Both are `toolSet: .v2` (the default).
        // Hermit 1.2 rev b (get_quote + restraint), HF main as of 2026-11-09.
        ModelSpec(id: "rahulol/Hermit-1.2-4B-MLX-4bit", revision: "6183aaf929d66dc50f4b7c547d140fca57be54e6", name: "Hermit 1.2",
                  detail: "Hermit's full model, trained on its trading tools. Private, offline.", approxBytes: 2_270_000_000, minMemoryGB: 7),
        ModelSpec(id: "rahulol/Hermit-1.1-Lite-MLX-4bit", revision: "52b8428909ab484f23945d317a32d4a63da57f49", name: "Hermit 1.1 Lite",
                  detail: ModelSpec.liteDetail, approxBytes: 980_000_000, minMemoryGB: 5),
    ]

    /// The spec for an id, or a plain one built from the repo name if it isn't in the list.
    public static func spec(_ id: String) -> ModelSpec { all.first { $0.id == id } ?? unlisted(id) }

    /// A plain spec for a repo that isn't in the list, named after the repo.
    static func unlisted(_ id: String) -> ModelSpec {
        ModelSpec(id: id, name: String(id.split(separator: "/").last ?? Substring(id)), detail: "", approxBytes: 0, minMemoryGB: 0)
    }

    public static var deviceMemoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Whether this device has the memory for the model.
    public static func fits(_ spec: ModelSpec) -> Bool { deviceMemoryGB >= spec.minMemoryGB }

    /// The catalog as it applies to a device with this much memory.
    public static func lineup(memoryGB: Int) -> ModelLineup {
        ModelLineup(all: all, fullID: fullID, liteID: liteID, memoryGB: memoryGB)
    }

    /// Hermit Lite is told by its repo name: "lite" in the part after the owner, any case. It decides two things:
    /// the prompt family (Lite is Qwen3-1.7B, which gets an empty think block; `LocalEngine.family`) and which model
    /// replaces which (Lite is replaced by the newer Lite, the full model by the newer full model).
    public static func isLite(_ id: String) -> Bool {
        (id.split(separator: "/").last.map(String.init) ?? id).lowercased().contains("lite")
    }

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

    /// What a model trained on the v3 tools can do that Hermit 1.2 and 1.1 Lite can't, for the upgrade card.
    /// Only what both the full model and Lite got (stop orders are the full model's alone).
    static let v3News = "Sets up more for you from chat: token buys and sells, closing a position, scheduled payments and automations."
}
