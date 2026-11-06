#if os(iOS)
import ActivityKit
import BackgroundTasks
import Foundation
import HermitActivity
import UIKit

/// Keeps a model download running after the user leaves the app, and shows it as a Live Activity.
///
/// - The bytes move through a background URLSession (`BackgroundDownloads`), so the download itself never depends on
///   Hermit running. A `BGContinuedProcessingTask` (iOS 26) is a bonus: while the system grants it, Hermit keeps
///   running in the background and the Live Activity stays live. When it ends, or isn't granted, the activity says
///   "Downloading in the background" with the last numbers, and is updated again when iOS wakes Hermit for the
///   finished transfer or the user comes back.
/// - The Live Activity (drawn by the HermitWidgets extension) is the flight: the plane crosses from the cloud to the
///   phone as the bytes land.
@MainActor
final class DownloadKeepAlive {
    /// Info.plist lists "my.hermit.ios.model-download.*"; each request adds a unique suffix.
    static let taskPrefix = "my.hermit.ios.model-download"

    private var modelID: String?
    private var modelName = ""
    private var task: BGContinuedProcessingTask?
    private var activity: Activity<ModelDownloadAttributes>?
    private var lastState: ModelDownloadAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    /// The keep-alive that gets the system's background task when it starts.
    private static weak var current: DownloadKeepAlive?

    private static var registered = false

    /// Registers the background task's launch handler once. The app delegate calls it from didFinishLaunching, and
    /// submitting calls it too, because SwiftUI can build the first screen (and start a download) before that.
    /// Submitting without a registered handler crashes, so nothing is submitted unless this returns true.
    @discardableResult static func registerAtLaunch() -> Bool {
        if registered { return true }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskPrefix + ".*", using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                if let keeper = current { keeper.started(task) } else { task.setTaskCompleted(success: true) }
            }
        }
        return registered
    }

    init() {
        Self.current = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
    }

    /// A download started (or resumed) on the user's tap, while the app is in front.
    func begin(id: String, name: String, received: Int64, total: Int64) {
        guard modelID == nil else { return }
        modelID = id; modelName = name; lastState = nil
        let state = ModelDownloadAttributes.ContentState(phase: .downloading, received: received, total: total)
        startActivity(state)
        submitTask(name)
    }

    /// Progress. Pushed to the Live Activity at most about once a second, or when the phase changes.
    func update(id: String, phase: ModelDownloadAttributes.Phase, received: Int64, total: Int64) {
        guard id == modelID else { return }
        let state = ModelDownloadAttributes.ContentState(phase: phase, received: received, total: total)
        if let task {
            task.progress.totalUnitCount = max(total, 1)
            task.progress.completedUnitCount = min(received, max(total, 1))
            task.updateTitle("Downloading \(modelName)", subtitle: phase == .verifying ? "Checking the files" : state.sizeLine)
        }
        let now = Date()
        let changed = lastState?.phase != phase
        let moved = lastState.map { $0.percent != state.percent } ?? true
        guard changed || (moved && now.timeIntervalSince(lastPush) >= 1) else { return }
        lastState = state; lastPush = now
        push(state)
    }

    /// The download stopped: landed, paused by the user, paused because the system ended the task, or failed.
    func finish(id: String, phase: ModelDownloadAttributes.Phase) {
        guard id == modelID else { return }
        let last = lastState ?? ModelDownloadAttributes.ContentState(phase: phase, received: 0, total: 0)
        var state = last; state.phase = phase
        if phase == .landed { state.received = max(state.total, state.received) }
        endActivity(state)
        if let task { task.setTaskCompleted(success: phase == .landed); self.task = nil }
        modelID = nil
    }

    // MARK: Background task

    private func submitTask(_ name: String) {
        guard Self.registerAtLaunch() else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: "\(Self.taskPrefix).\(UUID().uuidString.prefix(8))",
                                                       title: "Downloading \(name)",
                                                       subtitle: "Keeps going if you leave Hermit")
        // Start now or not at all: the background session carries the download either way.
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { print("Hermit: background time not granted: \(error)") }
    }

    private func started(_ task: BGContinuedProcessingTask) {
        guard let id = modelID else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = max(lastState?.total ?? 1, 1)
        task.progress.completedUnitCount = lastState?.received ?? 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                // The system took the background time back. The transfer goes on in the background session; the
                // activity just stops being live until Hermit runs again.
                guard let self, self.modelID == id, let t = self.task else { return }
                self.task = nil
                t.setTaskCompleted(success: false)
                self.showBackground()
            }
        }
    }

    /// Without background time Hermit is about to be suspended: say so instead of leaving a number that looks stuck.
    private func wentToBackground() {
        guard modelID != nil, task == nil else { return }
        showBackground()
    }

    private func cameBack() {
        guard modelID != nil, var state = lastState, state.phase == .background else { return }
        state.phase = .downloading
        lastState = state; lastPush = Date()
        push(state)
    }

    private func showBackground() {
        guard var state = lastState, state.phase == .downloading else { return }
        state.phase = .background
        lastState = state; lastPush = Date()
        push(state)
    }

    // MARK: Live Activity

    private func startActivity(_ state: ModelDownloadAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // After a relaunch the activity from the earlier run is still up: keep using it (iOS doesn't allow starting a
        // new one while Hermit runs in the background). Anything else left over is ended.
        let existing = Activity<ModelDownloadAttributes>.activities
        if let keep = existing.first(where: { $0.attributes.modelName == modelName && $0.activityState == .active }) {
            activity = keep
            for old in existing where old.id != keep.id { Task { await old.end(nil, dismissalPolicy: .immediate) } }
            // Before the sizes are known again, keep the numbers the card already shows.
            let shown = keep.content.state
            if shown.total > 0 && state.total == 0 { lastState = shown; lastPush = Date(); return }
            lastState = state; lastPush = Date()
            push(state)
            return
        }
        for old in existing { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        activity = try? Activity.request(attributes: ModelDownloadAttributes(modelName: modelName),
                                         content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        lastState = state; lastPush = Date()
    }

    private func push(_ state: ModelDownloadAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity(_ state: ModelDownloadAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(10 * 60))) }
    }
}
#endif
