import Foundation
import HermitCore

/// The agent the app talks to. Money moves and demo flows go to the scripted agent so the approval sheets keep
/// working; everything else goes to the on-device model. Until the model is downloaded it offers the download.
public final class HybridAgent: Agent, @unchecked Sendable {
    private let store: ModelStore
    private let scripted = ScriptedAgent()
    public let local: LocalAgent

    @MainActor
    public init(store: ModelStore? = nil) {
        let store = store ?? .shared
        self.store = store
        local = LocalAgent(store: store)
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if store.readyModel != nil && !underTest { local.warmUp() }
    }

    /// The button title that starts the download, e.g. "Download Woof 2B".
    public static func downloadTitle(_ spec: ModelSpec) -> String { "Download \(spec.name)" }

    public func reset() { local.reset() }

    public func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        if ScriptedAgent.matches(prompt) { return scripted.reply(to: prompt) }
        return AsyncStream { cont in
            let task = Task { [store, local] in
                let (spec, state) = await MainActor.run { (store.selected, store.selectedState) }
                let size = ByteCountFormatter.string(fromByteCount: spec.approxBytes, countStyle: .file)

                if prompt == Self.downloadTitle(spec) {
                    await MainActor.run { store.download(spec.id) }
                    cont.yield(.text("Downloading \(spec.name) (\(size)). It keeps going while you use the app, and once it's here I answer right on this device, even offline."))
                    cont.finish(); return
                }
                switch state {
                case .ready:
                    for await event in local.reply(to: prompt) {
                        if Task.isCancelled { break }
                        cont.yield(event)
                    }
                case .downloading(let p):
                    cont.yield(.text("\(spec.name) is still downloading (\(Int(p * 100))%). Ask me again when it's done."))
                case .verifying:
                    cont.yield(.text("\(spec.name) is downloaded and I'm checking the files. One moment."))
                case .notDownloaded, .failed:
                    cont.yield(.text("To answer that here on your device I need \(spec.name), a \(size) download. After that it runs fully offline and nothing you type leaves this device."))
                    cont.yield(.actions([Action(Self.downloadTitle(spec))]))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
