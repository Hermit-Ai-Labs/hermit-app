#if os(iOS)
import ActivityKit
import BackgroundTasks
import Foundation
import HermitActivity
import UIKit

/// Keeps a model download running after the user leaves the app, and shows it as a Live Activity.
///
/// - Background time comes from a `BGContinuedProcessingTask` (iOS 26): the user tapped Download, so the system lets
///   the app keep running and shows its own progress. If the system ends the task early (low battery, heavy load, or
///   the user stops it), the download pauses; the `.part` file stays and the download resumes the next time Hermit
///   is opened.
/// - The Live Activity (drawn by the HermitWidgets extension) is the flight: the plane crosses from the cloud to the
///   phone as the bytes land.
@MainActor
final class DownloadKeepAlive {
    /// Info.plist lists "my.hermit.ios.model-download.*"; each request adds a unique suffix.
    static let taskPrefix = "my.hermit.ios.model-download"

    /// Called when the system ends the background task early: the store pauses the download.
    var onExpire: ((String) -> Void)?
    /// Called when the app is opened again after such a pause: the store resumes it.
    var onResume: ((String) -> Void)?

    private var modelID: String?
    private var modelName = ""
    private var task: BGContinuedProcessingTask?
    private var activity: Activity<ModelDownloadAttributes>?
    private var registered = false
    private var expired = false
    private var resumeID: String?
    private var lastState: ModelDownloadAttributes.ContentState?
    private var lastPush = Date.distantPast
    private var activeObserver: NSObjectProtocol?

    init() {
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    /// A download started (or resumed) on the user's tap, while the app is in front.
    func begin(id: String, name: String, received: Int64, total: Int64) {
        guard modelID == nil else { return }
        modelID = id; modelName = name; expired = false; resumeID = nil; lastState = nil
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
        var state = last; state.phase = expired && phase == .paused ? .paused : phase
        if phase == .landed { state.received = max(state.total, state.received) }
        endActivity(state)
        if let task { task.setTaskCompleted(success: phase == .landed); self.task = nil }
        if expired && phase == .paused { resumeID = id }
        modelID = nil
    }

    // MARK: Background task

    private func submitTask(_ name: String) {
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskPrefix + ".*", using: nil) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                Task { @MainActor in self?.started(task) }
            }
            guard registered else { return }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: "\(Self.taskPrefix).\(UUID().uuidString.prefix(8))",
                                                       title: "Downloading \(name)",
                                                       subtitle: "Keeps going if you leave Hermit")
        // Start now or not at all: the download itself runs either way while the app is open.
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    private func started(_ task: BGContinuedProcessingTask) {
        guard let id = modelID else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = max(lastState?.total ?? 1, 1)
        task.progress.completedUnitCount = lastState?.received ?? 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.modelID == id else { return }
                self.expired = true
                self.onExpire?(id)
            }
        }
    }

    private func appBecameActive() {
        guard let id = resumeID, modelID == nil else { return }
        resumeID = nil
        onResume?(id)
    }

    // MARK: Live Activity

    private func startActivity(_ state: ModelDownloadAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A download from an earlier launch may have left one behind.
        for old in Activity<ModelDownloadAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
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
