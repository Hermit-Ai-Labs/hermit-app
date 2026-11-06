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
            // Empty first: what a new user sees.
            try page(.wallets, "tokens")
            try sheet(AddWalletSheet(vm: vm, custody: .local) { _ in }, "add-local")
            // Then a wallet from the BIP-39 test vector phrase (in-memory vault in tests; balances are not fetched).
            if !vm.hasWallet {
                _ = try vm.importWallet(words: Array(repeating: "abandon", count: 11) + ["about"], name: "Test wallet")
            }
            let id = try XCTUnwrap(vm.firstWalletID)
            for t in ["dapps", "gas", "activity", "accounts"] { try page(.wallets, t) }
            try page(.wallets, id)
            try sheet(WalletSendSheet(vm: vm, fromID: id, chain: nil, token: nil), "send", height: 900)
            try sheet(WalletSendSheet(vm: vm, fromID: id, chain: .base, token: "USDC"), "send-mainnet", height: 900)
            try sheet(WalletReceiveSheet(vm: vm, walletID: id, title: "Deposit"), "receive", height: 900)
            try sheet(TransferSheet(vm: vm, fromID: id), "transfer")
            try sheet(HistorySheet(vm: vm, walletID: nil), "history")
            try sheet(RecoveryPhraseSheet(vm: vm, walletID: id), "phrase")
            try sheet(WalletPickerMenuPreview(vm: vm), "picker", height: 520)
        }
        if wanted("settings") { for t in ["profile", "memory", "models", "home"] { try page(.settings, t) } }
        if wanted("connectors") {
            for t in ["apps", "apis", "skills"] { try page(.connectors, t) }
            try sheet(ConnectAppSheet(app: "Discord") {}, "connect-discord", height: 420)
        }
        if wanted("files") {
            try page(.files, "empty")
            // Real files, imported the way the file picker does.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hermit-shot-files")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let notes = tmp.appendingPathComponent("Launch notes.md"), table = tmp.appendingPathComponent("budget.csv")
            try "# Launch notes\n\nShip the Mac app first, then iPhone.\nKeep every money move behind an approval.".write(to: notes, atomically: true, encoding: .utf8)
            try "Month,Rent,Food,Savings\nAugust,2400,610,800\nSeptember,2400,580,900\nOctober,2400,640,850".write(to: table, atomically: true, encoding: .utf8)
            FilesStore.shared.importFiles([notes, table])
            try page(.files, "list")
            FilesStore.shared.open(FilesStore.shared.files[0])
            try page(.files, "viewer")
            FilesStore.shared.open(FilesStore.shared.files[1])
            try page(.files, "viewer-csv")
            FilesStore.shared.closeAll()
            for f in FilesStore.shared.files { FilesStore.shared.delete(f) }
        }
    }
}
#endif
