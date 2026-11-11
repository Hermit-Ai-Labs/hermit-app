import SwiftUI
import Observation
import UserNotifications
import HermitCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Runs scheduled automations on this device, with nothing on a server.
///
/// While Hermit is open it checks at least every 30 seconds (and wakes right at the next slot). An automation that is on
/// and whose next run has passed runs once: its prompt goes to Hermit in a new saved chat in the background
/// (`AppModel.runInBackground`), never moving the user off their screen, and only while Hermit is free. The run is
/// logged in the automation's thread, with a toast and a local notification. Money moves are only ever prepared: the
/// review waits in the run's chat for the user's own tap and Face ID or Touch ID.
///
/// When Hermit isn't running, a local notification fires at each automation's next slot (rescheduled whenever
/// automations change or run). Opening the app then runs whatever was due, once. Tapping a notification opens its chat.
@MainActor @Observable
public final class AutomationScheduler {
    public static let shared = AutomationScheduler()

    /// The automation answering right now, for its row.
    private(set) var running: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var rescheduleTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// A notification tapped for an automation that hadn't run yet: its chat opens once the run is done.
    @ObservationIgnored private var openWhenDone: String?
    /// A notification tapped before the app's model was there (a launch from the notification).
    @ObservationIgnored private var pendingTap: (name: String, chat: String?)?

    private init() {}

    /// "this Mac" or "this iPhone": where automations run.
    static var here: String {
        #if os(macOS)
        return "this Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }

    /// The app's model starts the scheduler (AppModel.init, real launches only: not snapshots, the tour or tests).
    /// A second window's model is ignored, so nothing runs twice.
    func attach(_ m: AppModel) {
        guard model == nil else { return }
        model = m
        AutomationNotificationHandler.install()
        let center = NotificationCenter.default
        #if os(iOS)
        // iOS stops the GPU when Hermit leaves the screen: a run in progress stops cleanly and runs again on return.
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AutomationScheduler.shared.model?.cancelBackgroundRun()
                AutomationScheduler.shared.reschedule()
            }
        })
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(center.addObserver(forName: active, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AutomationScheduler.shared.tick() }
        })
        loop?.cancel()
        loop = Task {
            // Give the saved chats and the model a moment after launch, then run anything due while the app was closed.
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                handlePendingTap()
                tick()
                try? await Task.sleep(for: .seconds(secondsToNextCheck()))
            }
        }
        reschedule()
    }

    /// Seconds to the next check: right after the next slot, at most 30, sooner while one is due and waiting.
    private func secondsToNextCheck() -> Double {
        guard let model = self.model else { return 30 }
        let now = Date()
        // One without a prompt never runs, so it doesn't keep the loop checking every 5 seconds.
        let runnable = model.automations.filter { !$0.runPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let next = runnable.compactMap({ $0.nextDue(now) }).min() else { return 30 }
        if next <= now { return 5 }
        return min(30, max(1, next.timeIntervalSince(now) + 0.5))
    }

    /// Runs the automation that has been due longest, if Hermit is free. Called by the loop, on return to the app and
    /// when a reminder arrives while the app is open.
    func tick() {
        guard running == nil, let model = self.model, model.canRunInBackground else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }
        #endif
        let now = Date()
        let due = model.automations.filter {
            $0.isDue(now) && !$0.runPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let a = due.min(by: { ($0.nextDue(now) ?? now) < ($1.nextDue(now) ?? now) }) else { return }
        run(a)
    }

    private func run(_ a: Automation) {
        guard let model = self.model else { return }
        let name = a.name, prompt = a.runPrompt
        running = name
        Task {
            let result = await model.runInBackground(prompt, title: name)
            running = nil
            // Stopped (the user sent a message, opened a chat, or left the app): it is still due and runs on a later check.
            guard let result else { return }
            let now = Date()
            model.recordRun(name, chat: result.chatID, reply: result.reply, needsApproval: result.needsApproval, at: now)
            model.toast(result.needsApproval ? "\(name) needs your approval" : "\(name) ran", kind: result.needsApproval ? .info : .success)
            AutomationNotes.postRan(name: name, chat: result.chatID, needsApproval: result.needsApproval, time: Automation.timeText(now))
            if openWhenDone == name {
                openWhenDone = nil
                model.openConversation(result.chatID)
            }
            // Another one may be due right behind it.
            tick()
        }
    }

    // MARK: Notifications

    /// Asks for notification permission (the system asks only the first time): when a scheduled automation is saved or
    /// switched on.
    func askPermission() {
        guard model != nil else { return }
        AutomationNotes.requestPermission()
    }

    /// Automations changed: reminders follow (soon, once, for a burst of changes).
    func changed(_ m: AppModel) {
        guard m === model else { return }
        reschedule()
    }

    /// One pending reminder per automation that is on, at its next slot. On a Mac, where Hermit usually stays open and
    /// runs it itself, the reminder comes three minutes late, so it only shows when the app really wasn't there to run it.
    func reschedule() {
        guard model != nil else { return }
        rescheduleTask?.cancel()
        rescheduleTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let model = self.model else { return }
            let now = Date()
            #if os(macOS)
            let late: TimeInterval = 180
            #else
            let late: TimeInterval = 0
            #endif
            let list = model.automations.compactMap { (a: Automation) -> AutomationNotes.Reminder? in
                guard let next = a.upcoming(now) else { return nil }
                return AutomationNotes.Reminder(name: a.name, fire: next.addingTimeInterval(late), time: Automation.timeText(next))
            }
            AutomationNotes.schedule(list)
        }
    }

    /// A notification was tapped: open the run's chat, or run it now and open its chat when done, or show its thread.
    func tapped(_ name: String, chat: String?) {
        guard let model = self.model else { pendingTap = (name, chat); return }
        if let chat, model.conversations.contains(where: { $0.id == chat }) {
            model.openConversation(chat)
            return
        }
        guard let a = model.automations.first(where: { $0.name == name }) else {
            model.toast("That automation was deleted", kind: .info)
            return
        }
        if running == name || a.isDue() {
            openWhenDone = name
            model.toast(model.canRunInBackground || running == name ? "Running \(name)…" : "\(name) runs as soon as Hermit is free", kind: .progress)
            tick()
            return
        }
        if let id = a.thread.reversed().compactMap({ AutomationThread.chatID($0) }).first(where: { id in model.conversations.contains { $0.id == id } }) {
            model.openConversation(id)
        } else {
            model.open(.automations)
            model.automationOpen = .existing(name)
        }
    }

    private func handlePendingTap() {
        guard let t = pendingTap else { return }
        pendingTap = nil
        tapped(t.name, chat: t.chat)
    }
}

/// The local notifications automations use. Not on the main actor: UserNotifications calls back on its own queue.
enum AutomationNotes {
    static let dueKind = "due"
    static let ranKind = "ran"
    static let duePrefix = "hermit.automation.due."
    static let ranPrefix = "hermit.automation.ran."

    struct Reminder: Sendable {
        let name: String
        let fire: Date
        let time: String
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in AutomationScheduler.shared.reschedule() }
        }
    }

    /// Replaces the pending reminders with `list`: the same id per automation, so each has at most one.
    static func schedule(_ list: [Reminder]) {
        let keep = Set(list.map { duePrefix + $0.name })
        UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
            let center = UNUserNotificationCenter.current()
            let stale = pending.map(\.identifier).filter { $0.hasPrefix(duePrefix) && !keep.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for r in list {
                let content = UNMutableNotificationContent()
                content.title = r.name
                content.body = "Due at \(r.time). Open Hermit to run it."
                content.sound = .default
                content.threadIdentifier = "automations"
                content.userInfo = ["automation": r.name, "kind": dueKind]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: duePrefix + r.name, content: content, trigger: trigger), withCompletionHandler: nil)
            }
        }
    }

    /// "Ran at 09:00". The reply itself stays in the app: a lock screen never shows what Hermit said.
    static func postRan(name: String, chat: String, needsApproval: Bool, time: String) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = needsApproval ? "Ran at \(time). It prepared something that needs your approval. Nothing has moved."
            : "Ran at \(time). Open it to read the reply."
        content.sound = .default
        content.threadIdentifier = "automations"
        content.userInfo = ["automation": name, "chat": chat, "kind": ranKind]
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [duePrefix + name])
        center.add(UNNotificationRequest(identifier: ranPrefix + name, content: content, trigger: nil), withCompletionHandler: nil)
    }
}

/// Receives automation notifications. Installed at launch (HermitApp) so a tap that launches the app is not missed.
public final class AutomationNotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = AutomationNotificationHandler()

    /// Makes this the notification center's delegate. Safe to call more than once.
    public static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// While Hermit is in front: a reminder is not shown (the app runs the automation itself, now); a run's notice goes
    /// to Notification Center only, since a toast already said it.
    /// The async forms of the delegate methods: they match the SDK's requirement whatever its closures are annotated with.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let kind = notification.request.content.userInfo["kind"] as? String
        if kind == AutomationNotes.dueKind {
            Task { @MainActor in AutomationScheduler.shared.tick() }
            return []
        } else if kind == AutomationNotes.ranKind {
            return [.list]
        } else {
            return [.banner, .list, .sound]
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let name = info["automation"] as? String else { return }
        let chat = info["chat"] as? String
        Task { @MainActor in AutomationScheduler.shared.tapped(name, chat: chat) }
    }
}
