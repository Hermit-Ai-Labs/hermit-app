import XCTest
@testable import HermitUI

/// The on-device copies screens show at launch: round trip, age, per-wallet files, bad files ignored. No network.
final class SnapshotStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "hermit-snapshots-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private struct Row: Codable, Equatable { let symbol: String; let px: Double }

    func testRoundTripKeepsValueAndDate() {
        let store = SnapshotStore(dir: dir)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.save([Row(symbol: "BTC", px: 101_000.5)], "perps", at: at))
        let back = store.load("perps", as: [Row].self, maxAge: .infinity)
        XCTAssertEqual(back?.value, [Row(symbol: "BTC", px: 101_000.5)])
        XCTAssertEqual(back?.saved.timeIntervalSince1970 ?? 0, at.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMissingAndTooOldAreNil() {
        let store = SnapshotStore(dir: dir)
        XCTAssertNil(store.load("nothing", as: [Row].self))
        let now = Date()
        store.save([Row(symbol: "ETH", px: 1)], "perps", at: now.addingTimeInterval(-7200))
        XCTAssertNil(store.load("perps", as: [Row].self, maxAge: 3600, now: now))
        XCTAssertNotNil(store.load("perps", as: [Row].self, maxAge: 3 * 3600, now: now))
    }

    func testCorruptFileIsIgnoredAndRemoved() throws {
        let store = SnapshotStore(dir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: SnapshotStore.fileName("perps"))
        try Data("{not json".utf8).write(to: file)
        XCTAssertNil(store.load("perps", as: [Row].self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        // The next save starts clean.
        store.save([Row(symbol: "SOL", px: 2)], "perps")
        XCTAssertEqual(store.load("perps", as: [Row].self)?.value, [Row(symbol: "SOL", px: 2)])
    }

    func testWrongShapeIsIgnored() {
        let store = SnapshotStore(dir: dir)
        store.save(["a": 1.0], "perps")
        XCTAssertNil(store.load("perps", as: [Row].self))
    }

    func testWalletsHaveTheirOwnFiles() {
        let store = SnapshotStore(dir: dir)
        let a = UUID().uuidString, b = UUID().uuidString
        store.save([Row(symbol: "USDC", px: 1)], "balances", wallet: a)
        store.save([Row(symbol: "SOL", px: 150)], "balances", wallet: b)
        store.save([Row(symbol: "BTC", px: 1)], "perps")
        XCTAssertEqual(store.load("balances", wallet: a, as: [Row].self)?.value.first?.symbol, "USDC")
        XCTAssertEqual(store.load("balances", wallet: b, as: [Row].self)?.value.first?.symbol, "SOL")
        XCTAssertNil(store.load("balances", as: [Row].self))

        store.save([Row(symbol: "X", px: 1)], "activity", wallet: a)
        store.removeAll(wallet: a)
        XCTAssertNil(store.load("balances", wallet: a, as: [Row].self))
        XCTAssertNil(store.load("activity", wallet: a, as: [Row].self))
        XCTAssertNotNil(store.load("balances", wallet: b, as: [Row].self))
        XCTAssertNotNil(store.load("perps", as: [Row].self))
    }

    func testFileNamesStayInTheFolder() {
        XCTAssertEqual(SnapshotStore.fileName("candles-xyz:TSLA-1H"), "candles-xyz_TSLA-1H.json")
        XCTAssertEqual(SnapshotStore.fileName("balances", wallet: "../../etc"), "balances.w-______etc.json")
        XCTAssertFalse(SnapshotStore.fileName("../x/y").contains("/"))
    }

    func testStoreWithoutFolderKeepsNothing() {
        let store = SnapshotStore(dir: nil)
        XCTAssertFalse(store.save([Row(symbol: "BTC", px: 1)], "perps"))
        XCTAssertNil(store.load("perps", as: [Row].self))
        // Tests never touch the real files.
        XCTAssertNil(SnapshotStore.live.dir)
    }

    func testAgeInWords() {
        let now = Date()
        XCTAssertEqual(Freshness.ago(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(Freshness.ago(now.addingTimeInterval(-150), now: now), "2 min ago")
        XCTAssertEqual(Freshness.ago(now.addingTimeInterval(-3 * 3600 - 5), now: now), "3 h ago")
        XCTAssertEqual(Freshness.ago(now.addingTimeInterval(-86_400 - 5), now: now), "1 day ago")
        XCTAssertEqual(Freshness.ago(now.addingTimeInterval(-3 * 86_400), now: now), "3 days ago")
        XCTAssertEqual(Freshness.ago(now.addingTimeInterval(60), now: now), "just now")
    }
}
