#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import HermitUI
import HermitCore

/// Every tab of the Wallets, Settings, Connectors and Files pages, plus their sheets drawn on their own:
/// tab-<route>-<tab>.png and sheet-<name>.png. Honours SNAPSHOT_ONLY like testPages.
@MainActor
final class PageTabSnapshots: XCTestCase {
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
    private var only: [String]? { ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"]?.split(separator: ",").map(String.init) }
    private func wanted(_ r: String) -> Bool { only == nil || only!.contains(r) }

    private func shoot<V: View>(_ view: V, _ name: String, _ size: CGSize, settle: Double = 1.0) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
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

    private func page(_ r: Route, _ tab: String) throws {
        let m = AppModel(); m.route = r; m.tabRequest = tab
        try shoot(RootView(model: m), "tab-\(r.rawValue)-\(tab)", CGSize(width: 1320, height: 900))
    }

    private func sheet<V: View>(_ v: V, _ name: String, height: CGFloat = 760) throws {
        try shoot(v.environment(AppModel()).background(.white), "sheet-\(name)", CGSize(width: 460, height: height))
    }

    func testPagesTabs() throws {
        let vm = WalletsViewModel.shared
        if wanted("wallets") {
            for t in ["dapps", "gas", "activity", "accounts", "trading"] { try page(.wallets, t) }
            try sheet(SendSheet(vm: vm, fromID: "main", chain: nil, token: nil), "send", height: 900)
            try sheet(ReceiveSheet(vm: vm, walletID: "main", title: "Deposit"), "receive")
            try sheet(TransferSheet(vm: vm, fromID: "main"), "transfer")
            try sheet(BridgeSheet(vm: vm, walletID: "main", token: "USDC"), "bridge")
            try sheet(GasTopUpSheet(vm: vm, chain: .monad), "gas-topup")
            try sheet(AddWalletSheet(vm: vm, custody: .privy) { _ in }, "add-privy")
            try sheet(TokenSheet(group: vm.tokenGroups(wallet: nil, chain: nil).first { $0.symbol == "USDC" }!, vm: vm) { _ in }, "token", height: 820)
            try sheet(HistorySheet(vm: vm, walletID: nil), "history", height: 900)
            try sheet(WalletPickerMenuPreview(vm: vm), "picker", height: 520)
        }
        if wanted("settings") { for t in ["memory", "models", "home"] { try page(.settings, t) } }
        if wanted("connectors") {
            for t in ["apis", "skills"] { try page(.connectors, t) }
            try sheet(ConnectAppSheet(app: "Discord") {}, "connect-discord")
            try sheet(ConnectAppSheet(app: "Telegram") {}, "connect-telegram")
        }
        if wanted("files") {
            FilesStore.shared.open(FilesStore.shared.files[0])
            try page(.files, "viewer")
            FilesStore.shared.open(FilesStore.shared.files[6])
            try page(.files, "viewer-csv")
            FilesStore.shared.closeAll()
            try sheet(RecordSheet { _ in }, "record", height: 420)
        }
    }
}
#endif
