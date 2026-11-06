#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import HermitUI
import HermitCore

/// Every tab of Payments, Calendar and Explore at Mac width and iPhone width, plus their sheets.
/// The names start with testPages so `macbuild <wt> shots payments,calendar,explore` picks them up.
@MainActor
final class PayCalExploreSnapshots: XCTestCase {
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

    private func wanted(_ route: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { $0 == route }
    }

    private func shoot<V: View>(_ view: V, _ name: String, _ size: CGSize, settle: Double = 1.0) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.white))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = host
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        win.orderOut(nil)
    }

    private func pages<V: View>(_ route: String, _ tabs: [String], _ make: @escaping () -> V) throws {
        guard wanted(route) else { return }
        for t in tabs {
            let m = AppModel(); m.tabRequest = t
            try shoot(make().environment(m), "tab-\(route)-\(t)", CGSize(width: 1072, height: 1500))
            let p = AppModel(); p.tabRequest = t
            try shoot(make().environment(p), "phone-\(route)-\(t)", CGSize(width: 390, height: 1500))
        }
    }

    func testPagesPayments() throws {
        try pages("payments", ["schedule", "payees", "transfer", "apis"]) { PaymentsPage() }
    }

    func testPagesCalendar() throws {
        try pages("calendar", ["week", "month", "board"]) { CalendarPage() }
    }

    func testPagesExplore() throws {
        try pages("explore", ["new", "trending", "all"]) { ExplorePage() }
    }

    func testPagesSheets() throws {
        guard wanted("payments") || wanted("calendar") else { return }
        let m = AppModel()
        let pay = ScheduledPayment(payee: "Landlord", addr: "landlord.eth", amount: 2400, token: "USDC", note: "Rent",
                                   next: CalendarData.day(3), repeats: .monthly)
        try shoot(PayScheduleSheet(item: pay).environment(m), "sheet-schedule", CGSize(width: 440, height: 640))
        try shoot(PayScheduleSheet(item: nil).environment(m), "sheet-schedule-new", CGSize(width: 440, height: 600))
        try shoot(PayeeSheet(payee: nil).environment(m), "sheet-payee", CGSize(width: 440, height: 360))
        try shoot(PayExploreSheet(label: "services", items: PaymentsData.moreServices).environment(m), "sheet-explore-more", CGSize(width: 520, height: 820))
        let item = CalItem(id: 7, t: "Write the launch post", date: CalendarData.today, time: 600, dur: 60, status: .doing)
        try shoot(CalItemSheet(item: item).environment(m), "sheet-cal-item", CGSize(width: 440, height: 560))
        try shoot(CalItemSheet(item: CalItem(id: 0, t: "", date: CalendarData.today, time: 600)).environment(m), "sheet-cal-new", CGSize(width: 440, height: 520))
        let ev = CalItem(id: -5, t: "Dentist", date: CalendarData.today, time: 900, dur: 45, event: true, hex: 0x2563EB,
                         ekID: "x", calendar: "Home", location: "12 Main St")
        try shoot(CalItemSheet(item: ev).environment(m), "sheet-cal-event", CGSize(width: 440, height: 400))
    }
}
#endif
