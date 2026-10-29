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
        SnapshotMode.active = true
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

    private func filledModel() -> AppModel {
        let m = AppModel()
        m.messages = [
            Message(role: .user, text: "Pay alice.eth 200 USDC on Friday"),
            Message(role: .assistant, text: "alice.eth is the same address you've paid 3 times before. I'll send **200 USDC** on Friday at 09:00.",
                    steps: 2, card: .bars(title: "Paid to alice.eth", rows: [BarRow("Aug", 800, "$800"), BarRow("Sep", 1200, "$1,200"),
                                                                              BarRow("Oct", 1200, "$1,200"), BarRow("Friday", 200, "$200", highlight: true)]),
                    actions: [Action("Schedule", approval: ScriptedAgent.payAlice)]),
        ]
        return m
    }

    func testChatFilled() throws {
        try shoot(RootView(model: filledModel()), "mac-chat-filled", CGSize(width: 1320, height: 822), settle: 2)
    }

    func testMessagesPlain() throws {
        let m = filledModel()
        try shoot(VStack(alignment: .leading, spacing: 22) { ForEach(m.messages) { MessageView(message: $0) } }
                    .padding(28).frame(maxHeight: .infinity, alignment: .top).background(.white).environment(m),
                  "mac-messages-plain", CGSize(width: 760, height: 520), settle: 2)
    }

    /// Every page at Mac window size: page-<route>.png. Filter with SNAPSHOT_ONLY=trade,earn to render a few.
    func testPages() throws {
        let only = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"]?.split(separator: ",").map(String.init)
        for r in Route.allCases where r != .home && (only == nil || only!.contains(r.rawValue)) {
            let m = AppModel(); m.route = r
            try shoot(RootView(model: m), "page-\(r.rawValue)", CGSize(width: 1320, height: 900), settle: 1.2)
        }
        try ShellShots.run(only)
    }

    func testSidebarPlain() throws {
        try shoot(Sidebar().environment(AppModel()), "mac-sidebar-plain", CGSize(width: 260, height: 822))
    }
}
#endif
