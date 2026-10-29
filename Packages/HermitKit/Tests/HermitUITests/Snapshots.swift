#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import HermitUI
import HermitCore

/// Renders the real screens to PNG so they can be reviewed without a Mac at hand.
/// CI sets SNAPSHOT_DIR and uploads the folder.
@MainActor
final class Snapshots: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        HermitFonts.register()
    }

    private var dir: URL {
        let d = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func shoot<V: View>(_ view: V, _ name: String, _ size: CGSize, settle: Double = 1.2, before: (() -> Void)? = nil) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = host
        win.orderFrontRegardless()
        before?()
        wait(settle)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        win.orderOut(nil)
    }

    func testHome() throws {
        try shoot(RootView(), "mac-home", CGSize(width: 1320, height: 822))
    }

    func testChat() throws {
        let model = AppModel()
        try shoot(RootView(model: model), "mac-chat", CGSize(width: 1320, height: 822), settle: 4.5) {
            model.send("Pay alice.eth 200 USDC on Friday")
        }
    }

    func testApproval() throws {
        let a = ScriptedAgent.payAlice
        try shoot(ApprovalSheet(approval: a, onApproved: {}), "mac-approval", CGSize(width: 420, height: 560), settle: 3)
    }

    func testMark() throws {
        try shoot(HermitMark(height: 120).padding(30).background(.white), "mark", CGSize(width: 260, height: 180))
    }
}
#endif
