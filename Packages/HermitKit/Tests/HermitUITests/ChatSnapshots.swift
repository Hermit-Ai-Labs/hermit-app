#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import HermitUI
import HermitCore

/// Chat scenarios, project and automation pages, sign-in and the iPhone layout, rendered to PNG.
/// Run from `testPages` with SNAPSHOT_ONLY keys: chat, phone, login, project, automation.
@MainActor
enum ShellShots {
    static var dir: URL {
        let d = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func shoot<V: View>(_ view: V, _ name: String, _ size: CGSize, settle: Double = 1.0, before: (() -> Void)? = nil) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).foregroundStyle(Theme.text).environment(\.colorScheme, .light))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = host
        win.orderFrontRegardless()
        before?()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        win.orderOut(nil)
    }

    /// A finished reply to a scenario, as the chat shows it once streaming is done.
    static func exchange(_ s: Scenario, attachment: Attachment? = nil) -> [Message] {
        [Message(role: .user, text: s.prompt, attachment: attachment),
         Message(role: .assistant, steps: s.tools.count, tools: s.tools, blocks: s.blocks)]
    }

    static func messages(_ ms: [Message], model: AppModel, width: CGFloat = 760) -> some View {
        VStack(alignment: .leading, spacing: 22) { ForEach(ms) { MessageView(message: $0) } }
            .padding(28).frame(width: width).frame(maxHeight: .infinity, alignment: .top)
            .background(.white).environment(model)
    }

    static func run(_ only: [String]?) throws {
        func want(_ k: String) -> Bool { only == nil || only!.contains(k) }
        let tall = CGSize(width: 760, height: 2000)

        if want("chat") {
            for (s, h) in [(Scenario.news, 1500.0), (.meme, 1650), (.yield, 900), (.multisend, 980), (.budgetAPI, 1700), (.flap, 900),
                           (.inject, 640), (.oppsDefi, 2000), (.airdrop, 900), (.build, 1150), (.perpHYPE, 820), (.reverse, 1300), (.inbox, 860)] {
                let m = AppModel()
                try shoot(messages(exchange(s), model: m), "chat-\(s.id)", CGSize(width: tall.width, height: h))
            }
            // Memory, an attached invoice, an action reply and a receipt with a live trade.
            let m = AppModel()
            let mem = ScriptedAgent.memoryScript("Always show Bollinger Bands on charts")
            let inv = ScriptedAgent.script(for: "What's in it?", attachment: SampleFiles.all[1])
            let ms = [Message(role: .user, text: "Add always show Bollinger Bands on charts to your long-term memory"),
                      Message(role: .assistant, steps: 1, tools: mem.tools, blocks: mem.blocks),
                      Message(role: .user, text: "What's in Invoice_Figma_2291.pdf?", attachment: SampleFiles.all[1]),
                      Message(role: .assistant, steps: 2, tools: inv.tools, blocks: inv.blocks),
                      Message(role: .user, text: "Run daily"),
                      Message(role: .assistant, text: "Run daily set. I will finish open Monad quests every day at 08:00 with gas capped at $1 a day.", note: true),
                      Message(role: .assistant, blocks: [.card(.liveTrade(LiveTrade(sym: "ETH", title: "ETH-PERP", side: "Long 3x", entry: 3498, tp: 3780, sl: 3390, liq: 2450, size: 3000)))])]
            try shoot(messages(ms, model: m), "chat-mixed", CGSize(width: 760, height: 1250))

            // The whole window mid-conversation, inside a project.
            let w = AppModel()
            w.openConversation("news-sell")
            try shoot(RootView(model: w), "mac-chat-project", CGSize(width: 1320, height: 822))
        }

        if want("project") {
            let m = AppModel()
            m.openProject("Dev: HYPE news bot")
            try shoot(RootView(model: m), "mac-project", CGSize(width: 1320, height: 900))
            let n = AppModel()
            n.newChat(project: "HYPE perp scripts")
            try shoot(RootView(model: n), "mac-project-newchat", CGSize(width: 1320, height: 900))
        }

        if want("automation") {
            let m = AppModel()
            m.open(.automations)
            m.automationOpen = .existing("Weekly ETH DCA")
            try shoot(RootView(model: m), "mac-automation-thread", CGSize(width: 1320, height: 822), settle: 1.2)
            let d = AppModel()
            d.open(.automations)
            d.automationOpen = .new("Buy $50 of ETH every Monday")
            try shoot(RootView(model: d), "mac-automation-draft", CGSize(width: 1320, height: 822), settle: 1.5)
        }

        if want("login") {
            try shoot(LoginView {}, "mac-login", CGSize(width: 1320, height: 860))
            try shoot(LoginView {}, "phone-login", CGSize(width: 402, height: 874))
        }

        if want("phone") {
            let size = CGSize(width: 402, height: 874)
            try shoot(RootView(model: AppModel(), phone: true), "phone-home", size)
            let c = AppModel()
            c.messages = exchange(.yield)
            try shoot(RootView(model: c, phone: true), "phone-chat", size)
            let n = AppModel()
            n.messages = exchange(.news)
            try shoot(messages(n.messages, model: n, width: 402).environment(\.compact, true), "phone-chat-news", CGSize(width: 402, height: 1700))
            let p = AppModel()
            p.open(.projects)
            try shoot(RootView(model: p, phone: true), "phone-projects", size)
            let pd = AppModel()
            pd.openProject("Stablecoin yield ladder")
            try shoot(RootView(model: pd, phone: true), "phone-project", size)
            let a = AppModel()
            a.open(.automations)
            try shoot(RootView(model: a, phone: true), "phone-automations", size)
            let dr = AppModel()
            dr.drawerOpen = true
            try shoot(RootView(model: dr, phone: true), "phone-drawer", size)
        }
    }
}
#endif
