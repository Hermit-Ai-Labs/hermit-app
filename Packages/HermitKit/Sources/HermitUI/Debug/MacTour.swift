#if DEBUG && os(macOS)
import AppKit
import SwiftUI
import CoreGraphics

/// Debug Mac builds only: one background launch that screenshots every page and quits, without showing anything.
///   open -g -j Hermit.app --args -hermitTour all        (or a comma list of shot names)
/// The window is moved off-screen below the desktop level, so it never covers anything or takes focus, and the app
/// captures its own windows (no Screen Recording permission needed). Nothing is saved: the tour's AppModel doesn't
/// persist. PNGs land in <container>/tmp/shots/<name>.png; scripts/mac-shots.sh copies them out.
@MainActor
public enum MacTour {
    /// The model the app's RootView uses during a tour; nil otherwise (RootView makes its own).
    public static let model: AppModel? = {
        guard UserDefaults.standard.string(forKey: "hermitTour") != nil else { return nil }
        let m = AppModel()
        m.persist = false
        if m.user.isEmpty { m.user = "Anon" }
        return m
    }()

    /// `wait` overrides -hermitTourWait for slow steps (a model reply, a web page).
    struct Step { var name: String; var route: Route; var tab: String? = nil; var size = CGSize(width: 1320, height: 822); var wait: Double? = nil }

    static let narrow = CGSize(width: 900, height: 640)
    static let steps: [Step] = [
        Step(name: "welcome", route: .home, tab: "welcome"),
        Step(name: "home", route: .home),
        Step(name: "chat", route: .home, tab: "help"),
        // A message with a generated CSV (Debug/DebugFixtures.swift) and the model's answer; run with -hermitMode cloud.
        Step(name: "chat-attach", route: .home, tab: "attach-csv", wait: 35),
        Step(name: "projects", route: .projects),
        Step(name: "automations", route: .automations),
        Step(name: "trade-markets", route: .trade, tab: "markets"),
        Step(name: "trade-positions", route: .trade, tab: "positions"),
        Step(name: "trade-strategies", route: .trade, tab: "strategies"),
        Step(name: "earn-save", route: .earn, tab: "save"),
        Step(name: "earn-explore", route: .earn, tab: "explore"),
        Step(name: "earn-airdrops", route: .earn, tab: "airdrops"),
        Step(name: "earn-reverse", route: .earn, tab: "reverse"),
        Step(name: "earn-positions", route: .earn, tab: "positions"),
        Step(name: "payments-schedule", route: .payments, tab: "schedule"),
        Step(name: "payments-payees", route: .payments, tab: "payees"),
        Step(name: "payments-transfer", route: .payments, tab: "transfer"),
        Step(name: "payments-apis", route: .payments, tab: "apis"),
        Step(name: "explore", route: .explore),
        // Hermit's browser on Uniswap. Nothing is connected or approved, and the tour's wallet is the test one.
        Step(name: "browser", route: .explore, tab: "browser", wait: 18),
        Step(name: "calendar", route: .calendar),
        Step(name: "wallets", route: .wallets),
        Step(name: "sheet-create-wallet", route: .wallets, tab: "create"),
        Step(name: "sheet-import-wallet", route: .wallets, tab: "import"),
        Step(name: "sheet-add-funds", route: .wallets, tab: "deposit"),
        Step(name: "connectors", route: .connectors),
        Step(name: "files", route: .files),
        Step(name: "settings-profile", route: .settings, tab: "profile"),
        Step(name: "settings-safety", route: .settings, tab: "safety"),
        Step(name: "settings-memory", route: .settings, tab: "memory"),
        Step(name: "settings-models", route: .settings, tab: "models"),
        Step(name: "settings-home", route: .settings, tab: "home"),
        Step(name: "narrow-home", route: .home, size: narrow),
        Step(name: "narrow-trade", route: .trade, tab: "markets", size: narrow),
        Step(name: "narrow-earn", route: .earn, tab: "defi", size: narrow),
        Step(name: "narrow-wallets", route: .wallets, size: narrow),
        Step(name: "narrow-settings", route: .settings, tab: "models", size: narrow),
    ]

    public static func startIfRequested() {
        guard let want = UserDefaults.standard.string(forKey: "hermitTour"), let model else { return }
        let names = want == "all" ? nil : Set(want.split(separator: ",").map(String.init))
        let wait = UserDefaults.standard.double(forKey: "hermitTourWait") > 0 ? UserDefaults.standard.double(forKey: "hermitTourWait") : 4
        Task { @MainActor in
            log("tour start: \(want)")
            // Wait for the WindowGroup window, then park it where nobody sees it.
            var win: NSWindow?
            for _ in 0..<100 { win = mainWindow(); if win != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
            log("windows: " + NSApp.windows.map { "\($0.className) \($0.frame) visible=\($0.isVisible)" }.joined(separator: "; "))
            guard let win else { log("no main window"); NSApp.terminate(nil); return }
            unclamp(win)
            hide(win)
            NSApp.unhideWithoutActivation()
            let user = model.user
            for step in steps where names?.contains(step.name) ?? true {
                reset(model)
                try? await Task.sleep(for: .milliseconds(400))
                if win.frame.size != step.size { win.setFrame(CGRect(origin: parkedOrigin(step.size), size: step.size), display: true) }
                model.user = step.tab == "welcome" ? "" : user
                switch step.tab {
                case "help": model.showHelp()
                case "welcome": break
                case "attach-csv": DebugFixtures.ask("What's in this file?", attach: "csv", model: model)
                case "browser": DappBrowser.shared.open(URL(string: "https://app.uniswap.org/swap")!, dapp: ExploreData.dapps.first { $0.url?.host() == "app.uniswap.org" }, model: model)
                default: model.open(step.route, tab: step.tab)
                }
                try? await Task.sleep(for: .seconds(step.wait ?? wait))
                // A sheet can nudge its parent back toward the screen: park it again (attached sheets move with it).
                if win.frame.origin != parkedOrigin(win.frame.size) {
                    win.setFrame(CGRect(origin: parkedOrigin(win.frame.size), size: win.frame.size), display: true)
                }
                for w in NSApp.windows where w !== win && w.isVisible { hide(w, keepOrigin: true) }
                try? await Task.sleep(for: .milliseconds(150))
                capture(win, name: step.name)
            }
            // Leave the saved window frame where a normal launch expects it (still below the desktop while it moves).
            if let screen = NSScreen.main?.visibleFrame {
                let size = CGSize(width: min(1320, screen.width), height: min(822, screen.height))
                win.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
            }
            NSApp.terminate(nil)
        }
    }

    /// AppKit pulls a titled window back onto a screen when it's moved off one. For the tour window only, swap in a
    /// subclass whose constrainFrameRect leaves the frame alone, so it really stays off-screen.
    private static func unclamp(_ win: NSWindow) {
        let base: AnyClass = type(of: win)
        let name = "HermitTourUnclamped_" + NSStringFromClass(base)
        var sub: AnyClass? = NSClassFromString(name)
        if sub == nil, let made = objc_allocateClassPair(base, name, 0) {
            let sel = #selector(NSWindow.constrainFrameRect(_:to:))
            let block: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
            if let m = class_getInstanceMethod(base, sel) {
                class_addMethod(made, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m))
            }
            objc_registerClassPair(made)
            sub = made
        }
        if let sub { object_setClass(win, sub) }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.styleMask.contains(.titled) && $0.frame.width > 500 }
    }

    /// Far below and left of every screen. If the window server won't capture a window there, the tour falls back to
    /// the screen's corner, still below the desktop picture (so it stays invisible).
    static var onScreen = false
    private static func parkedOrigin(_ size: CGSize) -> CGPoint {
        onScreen ? (NSScreen.main?.visibleFrame.origin ?? .zero) : CGPoint(x: -12000, y: -12000)
    }

    private static func hide(_ w: NSWindow, keepOrigin: Bool = false) {
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        w.ignoresMouseEvents = true
        w.collectionBehavior.insert(.transient)
        if !keepOrigin { w.setFrame(CGRect(origin: parkedOrigin(w.frame.size), size: w.frame.size), display: false) }
    }

    private static func reset(_ m: AppModel) {
        m.approval = nil; m.fundGoal = nil
        if DappBrowser.shared.session != nil { DappBrowser.shared.close() }
        if m.inChat { m.messages = []; m.currentID = nil }
        m.route = .files   // a neutral page, so the next page appears fresh and reads its tab request
    }

    /// Fallback when the window server won't hand over the window: draw the window's own view tree.
    private static func render(_ win: NSWindow) -> CGImage? {
        guard let v = win.contentView?.superview ?? win.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        log("rendered with cacheDisplay")
        return rep.cgImage
    }

    static func log(_ line: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shots/tour.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func capture(_ win: NSWindow, name: String) {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: CreateImage.self)
        func shot(_ w: NSWindow) -> CGImage? {
            fn(.null, 1 << 3 /* including window */, UInt32(w.windowNumber), 1 << 0 | 1 << 3 /* no framing, best resolution */)?.takeRetainedValue()
        }
        var img0 = shot(win)
        if (img0 == nil || img0!.width < 100), !onScreen {
            onScreen = true
            win.setFrame(CGRect(origin: parkedOrigin(win.frame.size), size: win.frame.size), display: true)
            img0 = shot(win)
        }
        log("\(name): cg=\(img0.map { "\($0.width)x\($0.height)" } ?? "nil") frame=\(win.frame) onScreen=\(onScreen)")
        guard let base = img0 ?? render(win) else { log("\(name): no image"); return }
        let scale = CGFloat(base.width) / win.frame.width
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // Sheets, popovers and menus: every other visible window of ours that overlaps, drawn on top.
        for w in NSApp.windows where w !== win && w.isVisible && w.frame.intersects(win.frame) {
            guard let img = shot(w) else { continue }
            let r = CGRect(x: (w.frame.minX - win.frame.minX) * scale, y: (w.frame.minY - win.frame.minY) * scale,
                           width: CGFloat(img.width), height: CGFloat(img.height))
            ctx.draw(img, in: r)
        }
        guard let out = ctx.makeImage() else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
#endif
