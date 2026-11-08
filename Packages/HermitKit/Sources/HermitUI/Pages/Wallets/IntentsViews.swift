import SwiftUI
import HermitCore
import HermitWallet

/// NEAR Intents swaps in flight: polls 1Click's status for each and opens the status sheet (RootView presents it, so it
/// works from Wallets, Trade or a chat card alike).
@MainActor @Observable
final class IntentsActivity {
    static let shared = IntentsActivity()

    struct Focus: Identifiable, Hashable { let id: String }
    /// The swap whose status sheet is open.
    var focus: Focus?
    private(set) var states: [String: IntentsSwapState] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var swaps: [TrackedSwap] = WalletService.intentsLedger.all
    @ObservationIgnored private var polling: Set<String> = []

    /// Swaps from the last two days that haven't settled.
    var active: [TrackedSwap] {
        swaps.filter { !$0.status.isFinal && Date().timeIntervalSince($0.created) < 172_800 }
    }

    func show(_ depositAddress: String) {
        reload()
        focus = Focus(id: depositAddress)
        track(depositAddress)
    }

    func reload() { swaps = WalletService.intentsLedger.all }

    /// Polls every 5 seconds (20 once settled-looking states repeat) until SUCCESS, REFUNDED or FAILED, or the deadline
    /// is an hour past.
    func track(_ depositAddress: String) {
        guard !polling.contains(depositAddress) else { return }
        polling.insert(depositAddress)
        let svc = WalletsViewModel.shared.service
        Task { [weak self] in
            defer { self?.polling.remove(depositAddress) }
            var same = 0
            while true {
                do {
                    let s = try await svc.refreshIntentsStatus(depositAddress)
                    guard let self else { return }
                    if self.states[depositAddress] == s { same += 1 } else { same = 0 }
                    withAnimation(.smooth) { self.states[depositAddress] = s; self.errors[depositAddress] = nil; self.reload() }
                    if s.status.isFinal {
                        if s.status == .success { Task { await WalletsViewModel.shared.refresh() } }
                        return
                    }
                } catch let e as OneClickError where e.status == 404 {
                    // 1Click learns about a deposit address a moment after the quote; keep asking.
                    self?.errors[depositAddress] = nil
                } catch {
                    self?.errors[depositAddress] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                if let dl = WalletService.intentsLedger.swap(depositAddress)?.deadline, Date() > dl.addingTimeInterval(3600),
                   self?.states[depositAddress]?.status == .pendingDeposit { return }
                try? await Task.sleep(for: .seconds(same > 6 ? 20 : 5))
            }
        }
    }

    func state(_ id: String) -> IntentsSwapState? { states[id] }
    func error(_ id: String) -> String? { errors[id] }
}

/// The four places a NEAR Intents swap's money can be, and what happens on each failure.
struct IntentsProgress: View {
    let swap: TrackedSwap?
    let state: IntentsSwapState?
    /// For Add funds: the user sends from somewhere else, so step 1 is theirs, not a Hermit transaction.
    var external = false

    private var status: IntentsStatus { state?.status ?? swap?.status ?? .pendingDeposit }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<4, id: \.self) { i in row(i) }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        problem
    }

    private var titles: [String] {
        [external ? "You send to the deposit address" : "Deposit sent from your wallet",
         "1Click sees the deposit", "Solvers swap it on NEAR Intents", "Delivered to \(swap?.toPlaceName ?? "you")"]
    }

    private func detail(_ i: Int) -> String? {
        switch i {
        case 0: if let h = swap?.txHash { return shortAddr(h, keep: 8) }; return external ? "Waiting for it to arrive" : nil
        case 1: return state?.originTxs.first.map { shortAddr($0.hash, keep: 8) }
        case 2: return state?.nearTxs.isEmpty == false ? "\(state!.nearTxs.count) NEAR transaction\(state!.nearTxs.count == 1 ? "" : "s")" : nil
        default:
            if status == .success, let out = state?.amountOutFormatted { return "\(IntentsFmt.amount(out)) arrived" }
            return nil
        }
    }

    @ViewBuilder private func row(_ i: Int) -> some View {
        let cur = status.step
        let done = i < cur || status == .success
        let failedHere = i == cur && status.isProblem
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green) }
                else if failedHere { Image(systemName: status == .incompleteDeposit ? "exclamationmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(status == .failed ? Theme.red : Theme.amber) }
                else if i == cur { ProgressView().controlSize(.mini) }
                else { Circle().strokeBorder(Theme.border, lineWidth: 1.5) }
            }
            .frame(width: 16, height: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(titles[i]).font(.system(size: 13.5, weight: i == cur ? .medium : .regular))
                    .foregroundStyle(done || i == cur ? Theme.text : Theme.faint)
                if let d = detail(i) { Text(d).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if i == 3, status == .success, let u = state?.destinationTxs.first?.url {
                Link(destination: u) { Image(systemName: "arrow.up.right.square").font(.system(size: 13)) }.foregroundStyle(Theme.muted)
            }
            if i == 0, let u = state?.originTxs.first?.url {
                Link(destination: u) { Image(systemName: "arrow.up.right.square").font(.system(size: 13)) }.foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 9)
        .animation(.smooth, value: status)
        if i < 3 { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 27) }
    }

    @ViewBuilder private var problem: some View {
        let refundTo = state?.refundTo.map { shortAddr($0) } ?? "your address"
        switch status {
        case .incompleteDeposit:
            NoteBox(symbol: "exclamationmark.circle", text: "Only \(state?.depositedFormatted.map(IntentsFmt.amount) ?? "part") arrived, less than the quote needs. "
                    + "Send the rest to the same address before the quote expires, or it all goes back to \(refundTo).", tint: Theme.amber)
        case .refunded:
            NoteBox(symbol: "arrow.uturn.backward.circle", text: "Refunded \(state?.refundedFormatted.map(IntentsFmt.amount) ?? "the deposit") to \(refundTo)"
                    + (state?.refundReason.map { " (\(IntentsFmt.reason($0)))" } ?? "") + ". Nothing was swapped.", tint: Theme.amber)
        case .failed:
            NoteBox(symbol: "xmark.octagon", text: "The swap failed and nothing was delivered. 1Click returns deposits to \(refundTo); "
                    + "the explorer shows where the funds are.", tint: Theme.red)
        default: EmptyView()
        }
    }
}

enum IntentsFmt {
    /// "2.704574174131954765039327" -> "2.7046"; keeps small amounts readable without cutting them off.
    static func amount(_ s: String) -> String { Double(s).map(MoneyFmt.amount) ?? s }
    static func reason(_ r: String) -> String {
        switch r {
        case "PARTIAL_DEPOSIT": "less than the quoted amount arrived"
        case "DEADLINE_EXCEEDED", "EXPIRED": "the quote expired"
        default: r.replacingOccurrences(of: "_", with: " ").lowercased()
        }
    }
    static func seconds(_ s: Int) -> String { s < 60 ? "Under a minute" : s < 3600 ? "About \(Int((Double(s) / 60).rounded(.up))) min" : "About \(s / 3600) h" }
}

/// Where a NEAR Intents swap is, live: deposit, seen, swapping, delivered, or refunded / failed.
struct IntentsStatusSheet: View {
    let depositAddress: String
    private var act: IntentsActivity { .shared }
    private var swap: TrackedSwap? { act.swaps.first { $0.depositAddress == depositAddress } }

    var body: some View {
        let state = act.state(depositAddress)
        let status = state?.status ?? swap?.status ?? .pendingDeposit
        SheetChrome(title: status.headline, subtitle: swap.map { "\($0.from) to \($0.toPlaceName)" }) {
            IntentsProgress(swap: swap, state: state, external: swap?.external ?? false)
            DetailLines(lines: lines(state), monoKeys: ["Deposit address"])
            if let e = act.error(depositAddress) { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            if let u = OneClick.explorer(depositAddress: depositAddress) {
                Link(destination: u) { Label("Open in NEAR Intents Explorer", systemImage: "safari") }
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
            }
        }
        .task { act.track(depositAddress) }
    }

    private func lines(_ s: IntentsSwapState?) -> [(String, String)] {
        var l: [(String, String)] = []
        if let w = swap { l.append(("You sent", w.from)); l.append(("You get", s?.amountOutFormatted.map { "\(IntentsFmt.amount($0)) on \(w.toPlaceName)" } ?? w.to)) }
        l.append(("Route", "NEAR Intents (1Click)"))
        l.append(("Deposit address", shortAddr(depositAddress, keep: 8)))
        if let d = s?.updatedAt { l.append(("Updated", d.formatted(date: .omitted, time: .shortened))) }
        return l
    }
}
