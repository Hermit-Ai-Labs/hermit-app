import SwiftUI

/// Keeps the balances on screen fresh without the Add funds sheet: reads again when the page comes up and when the app
/// becomes active, then about every 25 seconds. Paused while the app is in the background or inactive, while a review
/// (approval) or the Add funds sheet is up (that one reads every second itself), and while `paused` (the page's own
/// sheet). It never overlaps a read: `refreshIfStale` skips while one is running, and a read younger than 20 s is
/// reused. Skipped in tests and snapshots, which have no network.
struct WalletAutoRefresh: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    let vm: WalletsViewModel
    let paused: Bool

    static let every: Double = 25

    private var active: Bool { phase == .active && !paused && model.approval == nil && model.fundGoal == nil }

    func body(content: Content) -> some View {
        content
            // Restarts whenever it may run again (app active, sheet closed), which reads at once if the numbers are old.
            .task(id: active) {
                guard active, !SnapshotMode.active, !WalletsViewModel.runningTests else { return }
                while !Task.isCancelled {
                    await vm.refreshIfStale(Self.every - 5)
                    try? await Task.sleep(for: .seconds(Self.every))
                }
            }
            // Money arrived (seen in Activity): read the balances now.
            .onChange(of: ActivityFeed.shared.items.first { $0.kind == .received }?.id) { old, new in
                guard old != nil, new != nil, !SnapshotMode.active else { return }
                Task { await vm.refresh() }
            }
    }
}

extension View {
    func walletAutoRefresh(_ vm: WalletsViewModel, paused: Bool = false) -> some View {
        modifier(WalletAutoRefresh(vm: vm, paused: paused))
    }
}
