import XCTest
import HermitCore
@testable import HermitModel

// Made-up models, never published: an older and a newer full model, an older and a newer Lite. The newer ones are
// trained on the v3 tools and are not 4-bit, like a real release might be.
private let old = ModelSpec(id: "test/Hermit-9.0-4B-MLX-4bit", revision: "r1", name: "Hermit 9.0", detail: "The older full model.",
                            approxBytes: 2_000_000_000, minMemoryGB: 7)
private let newFull = ModelSpec(id: "test/Hermit-9.1-4B-MLX-6bit", revision: "r2", name: "Hermit 9.1", detail: "The newer full model.",
                            approxBytes: 3_100_000_000, minMemoryGB: 7, toolSet: .v3, whatsNew: "Knows more tools.")
private let oldLite = ModelSpec(id: "test/Hermit-9.0-Lite-MLX-4bit", revision: "r1", name: "Hermit 9.0 Lite", detail: "The older Lite.",
                                approxBytes: 900_000_000, minMemoryGB: 5)
private let newLite = ModelSpec(id: "test/Hermit-9.1-Lite-MLX-mixed", revision: "r2", name: "Hermit 9.1 Lite", detail: "The newer Lite.",
                                approxBytes: 1_200_000_000, minMemoryGB: 5, toolSet: .v3)

/// The catalog before the newer models became the defaults (`flipped: false`) and after.
private func lineup(memory: Int = 8, flipped: Bool = true, full: ModelSpec = newFull) -> ModelLineup {
    ModelLineup(all: [full, newLite, old, oldLite], fullID: flipped ? full.id : old.id, liteID: flipped ? newLite.id : oldLite.id,
                memoryGB: memory)
}

/// A download that runs until `finish` is set, then leaves a complete, checked model behind, as the real one does.
@MainActor private final class FakeDownload {
    var finish = false
    var started: [String] = []
    let root: URL
    init(root: URL) { self.root = root }

    func run(_ id: String) async throws {
        started.append(id)
        while !finish { try await Task.sleep(for: .milliseconds(10)) }
        try ModelUpgradeTests.write(id, in: root, complete: true)
    }
}

/// One model answering "Ok.", to take a chat through its first message.
private struct OkModel: TurnGenerator {
    func generate(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in c.yield("Ok."); c.finish() }
    }
}

/// What happens to a person who has a model when a build makes a newer one the default; which model a device starts
/// with; and which prompt a model gets. Stores here live in a temporary folder with their own defaults, and no test
/// touches the network.
@MainActor
final class ModelUpgradeTests: XCTestCase {
    private struct Device {
        let root: URL
        let defaults: UserDefaults
    }
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        for r in roots { try? FileManager.default.removeItem(at: r) }
        for s in suites { UserDefaults.standard.removePersistentDomain(forName: s) }
        roots = []; suites = []
    }

    /// A device with nothing on it.
    private func device() -> Device {
        let root = FileManager.default.temporaryDirectory.appending(path: "hermit-model-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = "hermit.model.tests.\(UUID().uuidString)"
        roots.append(root); suites.append(suite)
        return Device(root: root, defaults: UserDefaults(suiteName: suite)!)
    }

    /// A model's folder with a weights file. `complete` adds the marker the store writes after every file passed its check.
    static func write(_ id: String, in root: URL, complete: Bool) throws {
        let dir = root.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "weights".write(to: dir.appending(path: "model.safetensors"), atomically: true, encoding: .utf8)
        if complete { try "ok".write(to: dir.appending(path: ModelStore.readyMarker), atomically: true, encoding: .utf8) }
    }

    private func install(_ spec: ModelSpec, on d: Device) throws { try Self.write(spec.id, in: d.root, complete: true) }

    private func has(_ spec: ModelSpec, on d: Device) -> Bool {
        FileManager.default.fileExists(atPath: d.root.appending(path: spec.id, directoryHint: .isDirectory).path)
    }

    /// Opens the app on a device: a new store over the same folder and defaults, like a launch.
    private func open(_ d: Device, _ l: ModelLineup? = nil, fetcher: (@MainActor (String) async throws -> Void)? = nil) -> ModelStore {
        ModelStore(root: d.root, lineup: l ?? lineup(), defaults: d.defaults, fetcher: fetcher)
    }

    private func eventually(_ what: String, seconds: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                            _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(done(), what, file: file, line: line)
    }

    private func isDownloading(_ s: ModelStore, _ spec: ModelSpec) -> Bool {
        if case .downloading = s.state(spec.id) { return true }
        return false
    }

    private func hasFailed(_ s: ModelStore, _ spec: ModelSpec) -> Bool {
        if case .failed = s.state(spec.id) { return true }
        return false
    }

    // MARK: The default by memory

    func testDefaultByMemory() {
        XCTAssertEqual(lineup(memory: 16).defaultID, newFull.id)
        XCTAssertEqual(lineup(memory: 8).defaultID, newFull.id)
        XCTAssertEqual(lineup(memory: 7).defaultID, newFull.id, "an 8 GB iPhone reports about 7.5")
        XCTAssertEqual(lineup(memory: 6).defaultID, newLite.id)
        XCTAssertEqual(lineup(memory: 4).defaultID, newLite.id)
        // A full model with bigger weights (8-bit, say) moves the line with its own minMemoryGB.
        let heavy = ModelSpec(id: "test/Hermit-9.1-4B-MLX-8bit", name: "Hermit 9.1", detail: "", approxBytes: 4_300_000_000,
                              minMemoryGB: 12, toolSet: .v3)
        XCTAssertEqual(lineup(memory: 8, full: heavy).defaultID, newLite.id)
        XCTAssertEqual(lineup(memory: 12, full: heavy).defaultID, heavy.id)
        XCTAssertFalse(lineup(memory: 8, full: heavy).fits(heavy))
    }

    /// The app's own catalog: whatever the two defaults are, they are listed, pinned and told apart by name.
    func testShippedCatalog() throws {
        let all = ModelCatalog.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "no model twice")
        let full = try XCTUnwrap(all.first { $0.id == ModelCatalog.fullID }, "fullID must be in ModelCatalog.all")
        let lite = try XCTUnwrap(all.first { $0.id == ModelCatalog.liteID }, "liteID must be in ModelCatalog.all")
        XCTAssertFalse(full.isLite)
        XCTAssertTrue(lite.isLite, "Lite's repo name must contain \"lite\": it picks the prompt family and the upgrade line")
        XCTAssertLessThan(lite.minMemoryGB, full.minMemoryGB)
        for spec in [full, lite] {
            XCTAssertTrue(spec.supported)
            let exact = try XCTUnwrap(spec.pinnedBytes, "\(spec.name) has no pin for its revision in ModelPins.all")
            // The size the UI shows before a download is typed by hand: keep it within 5% of the real files.
            XCTAssertLessThan(abs(Double(spec.approxBytes - exact)), Double(exact) * 0.05, "approxBytes of \(spec.name)")
        }
        // The default follows the full model's own memory line.
        XCTAssertEqual(ModelCatalog.defaultModel(memoryGB: 64), full.id)
        XCTAssertEqual(ModelCatalog.defaultModel(memoryGB: full.minMemoryGB), full.id)
        XCTAssertEqual(ModelCatalog.defaultModel(memoryGB: full.minMemoryGB - 1), lite.id)
        // Hermit 1.2 and 1.1 Lite stay listed with their revision, pin and v2 prompt, so the files people have stay valid.
        for (id, revision) in [("rahulol/Hermit-1.2-4B-MLX-4bit", "6183aaf929d66dc50f4b7c547d140fca57be54e6"),
                               ("rahulol/Hermit-1.1-Lite-MLX-4bit", "52b8428909ab484f23945d317a32d4a63da57f49")] {
            let spec = try XCTUnwrap(all.first { $0.id == id }, "\(id) must stay in the catalog")
            XCTAssertEqual(spec.revision, revision)
            XCTAssertEqual(spec.toolSet, .v2)
            XCTAssertNotNil(spec.pin)
        }
    }

    // MARK: Which model the app opens with

    func testInitialSelection() {
        let l = lineup()
        // Nothing saved, nothing downloaded: the default.
        XCTAssertEqual(l.initialSelection(saved: nil, isReady: { _ in false }), newFull.id)
        // Nothing saved (the first model was never picked by hand), the older model is on the device: it stays.
        XCTAssertEqual(l.initialSelection(saved: nil, isReady: { $0 == old.id }), old.id)
        // Both older models are there: the one in the default's line.
        XCTAssertEqual(l.initialSelection(saved: nil, isReady: { $0 == old.id || $0 == oldLite.id }), old.id)
        XCTAssertEqual(lineup(memory: 6).initialSelection(saved: nil, isReady: { $0 == oldLite.id }), oldLite.id)
        // The default is there: the default.
        XCTAssertEqual(l.initialSelection(saved: nil, isReady: { _ in true }), newFull.id)
        // A saved choice that is on the device wins, as before.
        XCTAssertEqual(l.initialSelection(saved: oldLite.id, isReady: { _ in true }), oldLite.id)
        // A saved older model that was removed from the device is not downloaded again: its replacement is the one to
        // get (Lite stays Lite). Before the defaults change, and for the newest model, the saved choice stands.
        XCTAssertEqual(l.initialSelection(saved: old.id, isReady: { _ in false }), newFull.id)
        XCTAssertEqual(lineup(memory: 16).initialSelection(saved: oldLite.id, isReady: { _ in false }), newLite.id)
        XCTAssertEqual(lineup(flipped: false).initialSelection(saved: old.id, isReady: { _ in false }), old.id)
        XCTAssertEqual(l.initialSelection(saved: newFull.id, isReady: { _ in false }), newFull.id)
        // Unless it is on its way: a download the person started keeps its model.
        XCTAssertEqual(l.initialSelection(saved: old.id, pending: old.id, isReady: { _ in false }), old.id)
        // Nothing saved, nothing ready, and the first download (of the older model) was interrupted before this build:
        // it resumes by itself, so that model stays the one in use instead of landing beside an empty default.
        XCTAssertEqual(l.initialSelection(saved: nil, pending: old.id, isReady: { _ in false }), old.id)
        XCTAssertEqual(l.initialSelection(saved: nil, pending: "test/Gone", isReady: { _ in false }), newFull.id)
        // A model that is ready still wins over one that is only on its way.
        XCTAssertEqual(l.initialSelection(saved: nil, pending: oldLite.id, isReady: { $0 == old.id }), old.id)
        // A saved choice this device can't run, or that left the catalog, doesn't.
        XCTAssertEqual(lineup(memory: 6).initialSelection(saved: old.id, isReady: { _ in false }), newLite.id)
        XCTAssertEqual(l.initialSelection(saved: "test/Gone", isReady: { $0 == old.id }), old.id)
    }

    // MARK: The decision

    func testUpgradeDecision() {
        let l = lineup()
        func decide(_ selected: ModelSpec, ready: Set<String>, accepted: String? = nil, dismissed: Set<String> = []) -> ModelUpgrade? {
            l.upgrade(selectedID: selected.id, isReady: { ready.contains($0) }, accepted: accepted, dismissed: dismissed)
        }
        XCTAssertEqual(decide(old, ready: [old.id]), ModelUpgrade(from: old, to: newFull, phase: .offered))
        XCTAssertEqual(decide(oldLite, ready: [oldLite.id]), ModelUpgrade(from: oldLite, to: newLite, phase: .offered), "Lite stays Lite")
        XCTAssertNil(decide(old, ready: [old.id], dismissed: [newFull.id]), "Not now: never offered again")
        XCTAssertNil(decide(old, ready: [old.id], dismissed: [newLite.id, newFull.id]), "an answer for the other line doesn't undo it")
        XCTAssertEqual(decide(old, ready: [old.id], dismissed: ["test/Something-else"])?.phase, .offered, "a later model is offered")
        XCTAssertEqual(decide(old, ready: [old.id], accepted: newFull.id)?.phase, .inProgress)
        XCTAssertEqual(decide(old, ready: [old.id, newFull.id], accepted: newFull.id)?.phase, .landed)
        XCTAssertNil(decide(old, ready: [old.id, newFull.id]), "downloaded by hand: nothing to offer")
        XCTAssertNil(decide(old, ready: []), "no working model: the first-run card, not an upgrade")
        XCTAssertNil(decide(newFull, ready: [newFull.id]), "already on the newest")
        // Before the defaults change, nobody is offered anything.
        let before = lineup(flipped: false)
        XCTAssertNil(before.upgrade(selectedID: old.id, isReady: { $0 == old.id }, accepted: nil, dismissed: []))
        XCTAssertNil(before.upgrade(selectedID: oldLite.id, isReady: { $0 == oldLite.id }, accepted: nil, dismissed: []))
        // A newer model this device can't run is not offered.
        let heavy = ModelSpec(id: "test/Hermit-9.1-4B-MLX-8bit", name: "Hermit 9.1", detail: "", approxBytes: 4_300_000_000,
                              minMemoryGB: 12, toolSet: .v3)
        XCTAssertNil(lineup(memory: 8, full: heavy).upgrade(selectedID: old.id, isReady: { $0 == old.id }, accepted: nil, dismissed: []))
    }

    // MARK: A person who has the older model

    func testTheModelTheyHaveKeepsAnswering() throws {
        // Before the build with the newer default: the usual first model, never picked by hand.
        let d = device()
        try install(old, on: d)
        let before = open(d, lineup(flipped: false))
        XCTAssertEqual(before.selectedID, old.id)
        XCTAssertNil(before.upgrade)
        // The build that makes the newer model the default.
        let s = open(d)
        XCTAssertEqual(s.selectedID, old.id, "the default changed; the model in use did not")
        XCTAssertEqual(s.readyModel?.spec.id, old.id)
        XCTAssertEqual(s.readyModel?.spec.toolSet, .v2)
        XCTAssertEqual(s.upgrade, ModelUpgrade(from: old, to: newFull, phase: .offered))
        XCTAssertEqual(s.listed.map(\.id), [newFull.id, newLite.id, old.id], "the older model they have is listed, the one they don't isn't")

        // The same without the earlier launch: a person whose first launch of any build with this code is the new one.
        let direct = device()
        try install(old, on: direct)
        let t = open(direct)
        XCTAssertEqual(t.selectedID, old.id)
        XCTAssertEqual(t.upgrade?.to, newFull)

        // A new install gets the newer model and no card.
        let fresh = open(device())
        XCTAssertEqual(fresh.selectedID, newFull.id)
        XCTAssertNil(fresh.readyModel)
        XCTAssertNil(fresh.upgrade)
        XCTAssertEqual(fresh.listed.map(\.id), [newFull.id, newLite.id])

        // A small phone on the older Lite is offered the newer Lite.
        let small = device()
        try install(oldLite, on: small)
        let u = open(small, lineup(memory: 6))
        XCTAssertEqual(u.selectedID, oldLite.id)
        XCTAssertEqual(u.upgrade, ModelUpgrade(from: oldLite, to: newLite, phase: .offered))

        // Someone who chose Lite on a big Mac stays on Lite and is offered the newer Lite, not the full model.
        let mac = device()
        try install(old, on: mac); try install(oldLite, on: mac)
        let m = open(mac, lineup(memory: 16, flipped: false))
        m.select(oldLite.id)
        let n = open(mac, lineup(memory: 16))
        XCTAssertEqual(n.selectedID, oldLite.id)
        XCTAssertEqual(n.upgrade?.to, newLite)
    }

    func testOfferedOnceThenNotNow() throws {
        let d = device()
        try install(old, on: d)
        let s = open(d)
        XCTAssertEqual(s.upgrade?.phase, .offered)
        s.declineUpgrade()
        XCTAssertNil(s.upgrade)
        XCTAssertEqual(s.readyModel?.spec.id, old.id)
        XCTAssertTrue(has(old, on: d))
        // Every later launch: still not offered, still answering with the model they have.
        let again = open(d)
        XCTAssertNil(again.upgrade)
        XCTAssertEqual(again.selectedID, old.id)
        XCTAssertTrue(again.listed.contains(newFull), "it can still be downloaded from Settings, Models")
        // A model after that one is a new offer.
        let later = ModelSpec(id: "test/Hermit-9.2-4B-MLX-4bit", name: "Hermit 9.2", detail: "", approxBytes: 2_000_000_000,
                              minMemoryGB: 7, toolSet: .v3)
        let next = open(d, ModelLineup(all: [later, newFull, newLite, old, oldLite], fullID: later.id, liteID: newLite.id, memoryGB: 8))
        XCTAssertEqual(next.upgrade, ModelUpgrade(from: old, to: later, phase: .offered))
    }

    func testTheSwitchWaitsForTheVerifiedDownload() async throws {
        let d = device()
        try install(old, on: d)
        let fake = FakeDownload(root: d.root)
        let s = open(d, fetcher: { id in try await fake.run(id) })
        var moved: [String] = []
        s.onUpgraded = { from, to in moved = [from.id, to.id] }

        s.acceptUpgrade()
        XCTAssertEqual(s.upgrade?.phase, .inProgress)
        await eventually("the download starts") { fake.started == [newFull.id] }
        // While it downloads nothing has changed for the person.
        XCTAssertTrue(isDownloading(s, newFull))
        XCTAssertEqual(s.selectedID, old.id)
        XCTAssertEqual(s.readyModel?.spec.id, old.id)
        XCTAssertTrue(has(old, on: d))
        XCTAssertEqual(moved, [])

        fake.finish = true
        await eventually("the new model takes over") { s.selectedID == newFull.id }
        XCTAssertEqual(s.readyModel?.spec.id, newFull.id)
        XCTAssertEqual(s.readyModel?.spec.toolSet, .v3)
        XCTAssertNil(s.upgrade)
        XCTAssertNil(s.upgradeAccepted)
        XCTAssertFalse(has(old, on: d), "the old files go once the new model is in use")
        XCTAssertEqual(s.state(old.id), .notDownloaded)
        XCTAssertEqual(moved, [old.id, newFull.id])

        // The next launch: the new model, no card, and the old one is no longer listed.
        let again = open(d)
        XCTAssertEqual(again.selectedID, newFull.id)
        XCTAssertEqual(again.selectedState, .ready)
        XCTAssertNil(again.upgrade)
        XCTAssertEqual(again.listed.map(\.id), [newFull.id, newLite.id])
    }

    func testAnInterruptedDownloadLeavesTheOldModelWorking() async throws {
        let d = device()
        try install(old, on: d)
        // A download that never finishes, then gets paused.
        let fake = FakeDownload(root: d.root)
        let s = open(d, fetcher: { id in try await fake.run(id) })
        s.acceptUpgrade()
        await eventually("the download starts") { self.isDownloading(s, newFull) }
        s.cancel(newFull.id)
        await eventually("the download stops") { s.state(newFull.id) == .notDownloaded }
        XCTAssertEqual(s.selectedID, old.id)
        XCTAssertEqual(s.readyModel?.spec.id, old.id)
        XCTAssertTrue(has(old, on: d))
        XCTAssertEqual(s.upgrade?.phase, .inProgress, "the card stays, with Resume")

        // The app is closed with half the files on disk and no ready marker, then opened again.
        try Self.write(newFull.id, in: d.root, complete: false)
        let again = open(d)
        XCTAssertEqual(again.state(newFull.id), .notDownloaded, "files without the marker are not a model")
        XCTAssertEqual(again.selectedID, old.id)
        XCTAssertEqual(again.readyModel?.spec.id, old.id)
        XCTAssertEqual(again.upgrade?.phase, .inProgress)

        // A download that fails for good (no space): the same.
        let failing = open(d, fetcher: { _ in throw DownloadError.noSpace(1, 0) })
        failing.download(newFull.id)
        await eventually("the download fails") { self.hasFailed(failing, newFull) }
        XCTAssertEqual(failing.selectedID, old.id)
        XCTAssertEqual(failing.readyModel?.spec.id, old.id)
        XCTAssertTrue(has(old, on: d))
        XCTAssertEqual(failing.upgrade?.phase, .inProgress, "the card stays, with Try again")

        // Not now from there calls it off; the old model is untouched.
        failing.declineUpgrade()
        XCTAssertNil(failing.upgrade)
        XCTAssertNil(failing.upgradeAccepted)
        XCTAssertEqual(failing.readyModel?.spec.id, old.id)
    }

    func testTheSwitchWaitsForTheChatToEnd() async throws {
        let d = device()
        try install(old, on: d)
        let fake = FakeDownload(root: d.root)
        fake.finish = true
        let s = open(d, fetcher: { id in try await fake.run(id) })
        // A chat is under way on the old model when the download lands.
        s.chatBegan()
        s.acceptUpgrade()
        await eventually("the download lands") { s.state(newFull.id) == .ready }
        XCTAssertEqual(s.selectedID, old.id, "the model doesn't change inside a chat")
        XCTAssertEqual(s.readyModel?.spec.id, old.id)
        XCTAssertTrue(has(old, on: d), "and its files stay while it answers")
        XCTAssertEqual(s.upgrade?.phase, .landed)
        // New chat.
        s.chatEnded()
        XCTAssertEqual(s.selectedID, newFull.id)
        XCTAssertFalse(has(old, on: d))
        XCTAssertNil(s.upgrade)
    }

    func testALandedUpgradeTakesOverAtLaunch() async throws {
        let d = device()
        try install(old, on: d)
        let fake = FakeDownload(root: d.root)
        fake.finish = true
        let s = open(d, fetcher: { id in try await fake.run(id) })
        s.chatBegan()
        s.acceptUpgrade()
        await eventually("the download lands") { s.state(newFull.id) == .ready }
        XCTAssertEqual(s.selectedID, old.id)
        // The app is quit with that chat still open. The next launch starts on the new model.
        let again = open(d)
        XCTAssertEqual(again.selectedID, newFull.id)
        XCTAssertEqual(again.selectedState, .ready)
        XCTAssertFalse(has(old, on: d))
        XCTAssertNil(again.upgrade)
    }

    func testOldFilesOnlyGoOnceTheNewModelIsThere() throws {
        // A quit right between "use the new model" and "remove the old one": the next launch finishes the job.
        let d = device()
        try install(old, on: d); try install(newFull, on: d)
        d.defaults.set(newFull.id, forKey: ModelStore.selectedKey)
        d.defaults.set(old.id, forKey: ModelStore.upgradeRemoveKey)
        let s = open(d)
        XCTAssertEqual(s.selectedID, newFull.id)
        XCTAssertFalse(has(old, on: d))
        XCTAssertTrue(has(newFull, on: d))

        // The same note, but the new model's files are not there: the old model is the only one that works, so it stays.
        let e = device()
        try install(old, on: e)
        try Self.write(newFull.id, in: e.root, complete: false)
        e.defaults.set(newFull.id, forKey: ModelStore.selectedKey)
        e.defaults.set(old.id, forKey: ModelStore.upgradeRemoveKey)
        let t = open(e)
        XCTAssertTrue(has(old, on: e))
        XCTAssertEqual(t.state(old.id), .ready)
        XCTAssertNil(e.defaults.string(forKey: ModelStore.upgradeRemoveKey), "and it is not removed later behind the user's back")
        XCTAssertTrue(has(old, on: e))
        _ = open(e)
        XCTAssertTrue(has(old, on: e))
    }

    func testDownloadedByHandIsTheUsersChoice() throws {
        // Not now on the card, then the newer model downloaded in Settings: nothing switches or goes by itself.
        let d = device()
        try install(old, on: d)
        open(d).declineUpgrade()
        try install(newFull, on: d)
        let s = open(d)
        XCTAssertEqual(s.selectedID, old.id)
        XCTAssertNil(s.upgrade)
        s.select(newFull.id)   // "Use"
        XCTAssertEqual(s.readyModel?.spec.id, newFull.id)
        XCTAssertTrue(has(old, on: d), "the old model stays until the user removes it")
        XCTAssertEqual(open(d).selectedID, newFull.id)
    }

    // MARK: Found in review

    /// "Not now" is remembered for every model it was said to, not only the last one: with both older models on a
    /// device, answering for Lite must not bring the full model's card back.
    func testNotNowHoldsForBothLines() throws {
        let d = device()
        try install(old, on: d); try install(oldLite, on: d)
        let big = lineup(memory: 16)
        let s = open(d, big)
        XCTAssertEqual(s.upgrade?.to, newFull)
        s.declineUpgrade()
        XCTAssertNil(s.upgrade)
        s.select(oldLite.id)   // "Use" on the older Lite
        XCTAssertEqual(s.upgrade, ModelUpgrade(from: oldLite, to: newLite, phase: .offered))
        s.declineUpgrade()
        XCTAssertNil(s.upgrade)
        s.select(old.id)
        XCTAssertNil(s.upgrade, "the first answer still holds")
        // And after a launch, on either model.
        let again = open(d, big)
        XCTAssertEqual(again.selectedID, old.id)
        XCTAssertNil(again.upgrade)
        again.select(oldLite.id)
        XCTAssertNil(again.upgrade)
        XCTAssertEqual(again.upgradeDismissed, [newFull.id, newLite.id])
    }

    /// Download was tapped for the newer full model, then the person picked Lite by hand while it came down. The
    /// landed download must not take over from the model they chose, and must not remove it.
    func testAModelPickedByHandIsNotReplaced() async throws {
        let d = device()
        try install(old, on: d); try install(oldLite, on: d)
        let fake = FakeDownload(root: d.root)
        let s = open(d, lineup(memory: 16), fetcher: { id in try await fake.run(id) })
        var moved = 0
        s.onUpgraded = { _, _ in moved += 1 }
        s.acceptUpgrade()
        await eventually("the download starts") { fake.started == [newFull.id] }
        s.select(oldLite.id)   // "Use" on Lite, in Settings
        fake.finish = true
        await eventually("the download lands") { s.state(newFull.id) == .ready }
        XCTAssertEqual(s.selectedID, oldLite.id, "the model picked by hand stays the one in use")
        XCTAssertEqual(s.readyModel?.spec.id, oldLite.id)
        XCTAssertTrue(has(oldLite, on: d), "and its files stay")
        XCTAssertTrue(has(old, on: d))
        XCTAssertTrue(has(newFull, on: d), "the download is kept, with Use in Settings")
        XCTAssertNil(s.upgradeAccepted)
        XCTAssertEqual(moved, 0)
        // The next launch doesn't do it either.
        let again = open(d, lineup(memory: 16))
        XCTAssertEqual(again.selectedID, oldLite.id)
        XCTAssertTrue(has(oldLite, on: d))
        XCTAssertTrue(has(old, on: d))
    }

    /// The newer model was downloaded, then removed by hand before it took over: that is an answer, the card
    /// doesn't come back to offer the model that was just removed.
    func testRemovingTheNewModelByHandIsAnAnswer() async throws {
        let d = device()
        try install(old, on: d)
        let fake = FakeDownload(root: d.root)
        fake.finish = true
        let s = open(d, fetcher: { id in try await fake.run(id) })
        s.chatBegan()
        s.acceptUpgrade()
        await eventually("the download lands") { s.state(newFull.id) == .ready }
        XCTAssertEqual(s.upgrade?.phase, .landed)
        s.delete(newFull.id)   // the bin in Settings, Models
        XCTAssertNil(s.upgrade)
        XCTAssertNil(s.upgradeAccepted)
        s.chatEnded()
        XCTAssertEqual(s.selectedID, old.id)
        XCTAssertEqual(s.readyModel?.spec.id, old.id)
        XCTAssertTrue(has(old, on: d))
        let again = open(d)
        XCTAssertEqual(again.selectedID, old.id)
        XCTAssertNil(again.upgrade)

        // The same for one downloaded in Settings without ever answering the card.
        let e = device()
        try install(old, on: e)
        XCTAssertEqual(open(e).upgrade?.phase, .offered)
        try install(newFull, on: e)
        let t = open(e)
        XCTAssertEqual(t.selectedID, old.id)
        XCTAssertNil(t.upgrade)
        t.delete(newFull.id)
        XCTAssertNil(t.upgrade)
        XCTAssertEqual(t.upgradeDismissed, [newFull.id])
        XCTAssertNil(open(e).upgrade)
        // Removing the model in use, or an older one, is not an answer to anything.
        let f = device()
        try install(old, on: f); try install(oldLite, on: f)
        let u = open(f, lineup(memory: 16))
        u.delete(oldLite.id)
        XCTAssertEqual(u.upgradeDismissed, [])
        XCTAssertEqual(u.upgrade?.phase, .offered)
    }

    /// The first download of the older model was interrupted (or was waiting for Wi-Fi) when the build with the newer
    /// default arrived. It continues by itself, so its model is the one in use: the app never ends up with a finished
    /// model on disk and "not downloaded" on screen.
    func testAnInterruptedFirstDownloadKeepsItsModel() throws {
        let d = device()
        try Self.write(old.id, in: d.root, complete: false)
        d.defaults.set(old.id, forKey: ModelStore.downloadingKey)
        // The stand-in download stops at once wherever a launch resumes it, so nothing here reaches the network.
        let s = open(d, fetcher: { _ in throw CancellationError() })
        XCTAssertEqual(s.selectedID, old.id)
        XCTAssertNil(s.readyModel)
        XCTAssertNil(s.upgrade, "no card until the model they are getting works")
        // It lands; from the next launch on it is the saved choice, and the newer model is offered once.
        try install(old, on: d)
        d.defaults.removeObject(forKey: ModelStore.downloadingKey)
        let again = open(d)
        XCTAssertEqual(again.selectedID, old.id)
        XCTAssertEqual(again.readyModel?.spec.id, old.id)
        XCTAssertEqual(d.defaults.string(forKey: ModelStore.selectedKey), old.id)
        XCTAssertEqual(again.upgrade, ModelUpgrade(from: old, to: newFull, phase: .offered))

        // A person who removed their older model and then got this build is asked for the newer one, not for the
        // older one first and the newer one right after.
        let e = device()
        e.defaults.set(old.id, forKey: ModelStore.selectedKey)
        let t = open(e)
        XCTAssertEqual(t.selectedID, newFull.id)
        XCTAssertNil(t.upgrade)
        XCTAssertEqual(e.defaults.string(forKey: ModelStore.selectedKey), old.id, "nothing is written down until a model is on the device")
    }

    // MARK: Which prompt a model gets

    func testLiteIsToldByItsRepoName() throws {
        XCTAssertTrue(ModelCatalog.isLite("aiquantgod/Hermit-1.3-Lite-MLX-4bit"))
        XCTAssertTrue(ModelCatalog.isLite("aiquantgod/hermit-1.3-lite-mlx-mixed"))
        XCTAssertTrue(ModelCatalog.isLite("rahulol/Hermit-1.1-Lite-MLX-4bit"))
        XCTAssertFalse(ModelCatalog.isLite("aiquantgod/Hermit-1.3-4B-MLX-4bit"))
        XCTAssertFalse(ModelCatalog.isLite("aiquantgod/Hermit-1.3-4B-MLX-6bit"))
        XCTAssertFalse(ModelCatalog.isLite("rahulol/Hermit-1.2-4B-MLX-4bit"))
        XCTAssertFalse(ModelCatalog.isLite("satellite/Hermit-1.3-4B-MLX-4bit"), "only the repo name counts, not the owner")

        // The engine's family: Lite by name whatever template it ships; a full model by its template.
        let dir = device().root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(LocalEngine.family(id: "aiquantgod/Hermit-1.3-Lite-MLX-4bit", directory: dir), .thinking)
        XCTAssertEqual(LocalEngine.family(id: newLite.id, directory: dir), .thinking)
        XCTAssertEqual(LocalEngine.family(id: "aiquantgod/Hermit-1.3-4B-MLX-4bit", directory: dir), .instruct)
        XCTAssertEqual(LocalEngine.family(id: newFull.id, directory: dir), .instruct)
        try "{%- if enable_thinking is false %}".write(to: dir.appending(path: "chat_template.jinja"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalEngine.family(id: newFull.id, directory: dir), .thinking, "a full model whose own template has the think switch")
    }

    /// The chat as LocalAgent sets it up for the model that answers, taken through its first message.
    private func chat(for spec: ModelSpec, first: String) async throws -> ToolChat {
        let dir = device().root
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chat = ToolChat(config: .init(family: .instruct))
        await LocalAgent.configure(chat, family: LocalEngine.family(id: spec.id, directory: dir), spec: spec)
        let (events, cont) = AsyncStream<AgentEvent>.makeStream()
        await chat.reply(to: first, generator: OkModel(), toolbox: nil, cont: cont)
        cont.finish()
        _ = events
        return chat
    }

    func testAV3ModelGetsTheV3PromptAndPacks() async throws {
        // The full model: the v3 prompt, the core tools plus the pack its first message asks for, the bigger prompt cap.
        let full = try await chat(for: newFull, first: "long SOL 3x")
        let c = await full.config
        XCTAssertEqual(c.toolSet, .v3)
        XCTAssertEqual(c.family, .instruct)
        XCTAssertEqual(c.maxPromptChars, 32_000)
        let packs = await full.packs
        XCTAssertEqual(packs, ["trade"])
        let names = HermitPrompt.names(c.tools ?? [])
        XCTAssertEqual(names.count, 20, "12 core tools and the 8 of the trade pack")
        XCTAssertTrue(names.contains("set_tp_sl"))
        let system = await full.messages[0]
        XCTAssertEqual(system, .system(HermitPrompt.system(HermitPrompt.agentSystem(for: .v3), name: "", memory: [])))

        // Lite: the same v3 prompt in the thinking family, one short pack, 16 tools, the old cap.
        let lite = try await chat(for: newLite, first: "long SOL 3x")
        let l = await lite.config
        XCTAssertEqual(l.toolSet, .v3)
        XCTAssertEqual(l.family, .thinking)
        XCTAssertEqual(l.maxPromptChars, 22_000)
        let liteNames = HermitPrompt.names(l.tools ?? [])
        XCTAssertEqual(liteNames.count, 16)
        XCTAssertFalse(liteNames.contains("set_tp_sl"))
        let litePrompt = await lite.prompt()
        XCTAssertTrue(litePrompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"), "Lite's empty think block")
    }

    func testAV2ModelIsUntouched() async throws {
        for spec in [old, oldLite] {
            let family: HermitPrompt.Family = spec.isLite ? .thinking : .instruct
            // Before any message: exactly the prompt a chat that knows nothing about tool sets renders.
            let dir = device().root
            let fresh = ToolChat(config: .init(family: .instruct))
            await LocalAgent.configure(fresh, family: LocalEngine.family(id: spec.id, directory: dir), spec: spec)
            let plain = ToolChat(config: .init(family: family))
            let a = await fresh.prompt(), b = await plain.prompt()
            XCTAssertEqual(a, b)
            // After a message that would pick packs for a v3 model: still today's 15 tools, no packs.
            let used = try await chat(for: spec, first: "long SOL 3x and buy WIF")
            let c = await used.config
            XCTAssertEqual(c.toolSet, .v2)
            XCTAssertEqual(c.family, family)
            XCTAssertEqual(c.tools ?? [], HermitPrompt.toolLines)
            XCTAssertEqual(c.maxPromptChars, 22_000)
            let packs = await used.packs
            XCTAssertEqual(packs, [])
        }
    }
}
