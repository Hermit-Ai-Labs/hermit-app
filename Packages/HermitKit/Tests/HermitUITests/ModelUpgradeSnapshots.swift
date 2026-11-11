#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import HermitUI
@testable import HermitModel

/// The upgrade card (ModelUpgradeCard) in its states, at an iPhone's width and a Mac's: upgrade-<state>-<width>.png
/// in SNAPSHOT_DIR. The two models are made up and nothing is downloaded: the store lives in a temporary folder with
/// its own defaults, and its download is a stand-in that never finishes.
@MainActor
final class ModelUpgradeSnapshots: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        HermitFonts.register()
        SnapshotMode.active = true
    }

    private var dir: URL {
        let d = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func shoot<V: View>(_ view: V, _ name: String, _ size: CGSize) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = host
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        win.orderOut(nil)
    }

    /// Lets the main actor's tasks run until `done`, or three seconds.
    private func spin(_ done: () -> Bool) {
        let end = Date().addingTimeInterval(3)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testUpgradeCard() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "hermit-upgrade-shots-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "hermit.upgrade.shots.\(UUID().uuidString)"
        defer {
            try? fm.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Made-up repos with the names a person would see.
        let old = ModelSpec(id: "test/Hermit-A-4B-MLX-4bit", name: "Hermit 1.2", detail: "The model they have.",
                            approxBytes: 2_270_000_000, minMemoryGB: 7)
        let new = ModelSpec(id: "test/Hermit-B-4B-MLX-4bit", name: "Hermit 1.3", detail: "The model that replaced it.",
                            approxBytes: 2_300_000_000, minMemoryGB: 7, toolSet: .v3, whatsNew: ModelSpec.v3News)
        let lite = ModelSpec(id: "test/Hermit-B-Lite-MLX-4bit", name: "Hermit 1.3 Lite", detail: "", approxBytes: 1_000_000_000,
                             minMemoryGB: 5, toolSet: .v3)
        let have = root.appending(path: old.id, directoryHint: .isDirectory)
        try fm.createDirectory(at: have, withIntermediateDirectories: true)
        try "ok".write(to: have.appending(path: ModelStore.readyMarker), atomically: true, encoding: .utf8)

        let lineup = ModelLineup(all: [new, lite, old], fullID: new.id, liteID: lite.id, memoryGB: 16)
        let store = ModelStore(root: root, lineup: lineup, defaults: defaults,
                               fetcher: { _ in try await Task.sleep(for: .seconds(600)) })
        let model = AppModel(models: store)

        func card(_ state: String) throws {
            let upgrade = try XCTUnwrap(store.upgrade, "no upgrade to show for \(state)")
            for (label, width) in [("phone", 358.0), ("mac", 720.0)] {
                try shoot(ModelUpgradeCard(upgrade: upgrade).environment(model).padding(16).background(.white),
                          "upgrade-\(state)-\(label)", CGSize(width: width + 32, height: 220))
            }
        }

        XCTAssertEqual(store.selectedID, old.id)
        try card("offer")

        store.acceptUpgrade()
        spin { if case .downloading = store.state(new.id) { return true }; return false }
        try card("downloading")

        store.cancel(new.id)
        spin { store.state(new.id) == .notDownloaded }
        try card("stopped")
        XCTAssertEqual(store.selectedID, old.id, "the model they have is still the one in use")
    }
}
#endif
