import SwiftUI
import Observation
import HermitCore
import HermitWallet

/// Batch sends prepared on this device, by id, with each row's live status. Kept in the app's defaults (addresses,
/// amounts and hashes are public) so a chat reopened later still shows what went out, and an interrupted batch can
/// be resumed.
@MainActor @Observable
final class BatchStore {
    static let shared = BatchStore()
    private(set) var plans: [String: BatchPlan] = [:]
    private(set) var running: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// The batch whose review sheet is open (RootView presents it).
    var reviewing: BatchRef?

    private let key = "hermit.batches"
    private init() {
        guard !WalletsViewModel.runningTests, let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([BatchPlan].self, from: d) else { return }
        plans = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    func add(_ p: BatchPlan) { plans[p.id] = p; save() }
    func plan(_ id: String) -> BatchPlan? { plans[id] }

    func review(_ id: String, model: AppModel) {
        guard plans[id] != nil else { model.toast("That batch isn't on this device anymore"); return }
        reviewing = BatchRef(id: id)
    }

    /// Signs (one Face ID / Touch ID) and sends what's left of the batch, updating each row as it goes.
    func run(_ id: String, service: WalletService) async {
        guard let p = plans[id], !running.contains(id) else { return }
        running.insert(id); errors[id] = nil
        defer { running.remove(id); save() }
        do {
            try await service.runBatch(p) { [weak self] row in
                guard let self, var plan = self.plans[id], let i = plan.rows.firstIndex(where: { $0.line == row.line }) else { return }
                withAnimation(.snappy) { plan.rows[i] = row; self.plans[id] = plan }
            }
        } catch WalletError.cancelled {
        } catch {
            errors[id] = (error as? WalletError)?.errorDescription ?? error.localizedDescription
        }
        await WalletsViewModel.shared.afterSend()
    }

    private func save() {
        guard !WalletsViewModel.runningTests else { return }
        let keep = plans.values.sorted { $0.created > $1.created }.prefix(30)
        if let d = try? JSONEncoder().encode(Array(keep)) { UserDefaults.standard.set(d, forKey: key) }
    }
}

#if DEBUG
extension BatchStore {
    /// Screenshots only (DebugFixtures): a batch in memory, never saved.
    func debugInsert(_ p: BatchPlan) { plans[p.id] = p }
}
#endif

struct BatchRef: Identifiable, Hashable { let id: String }

/// How a row's state reads.
extension BatchRow {
    var stateText: String {
        switch status {
        case .invalid: problem ?? "Left out"
        case .ready: "Ready"
        case .sent: error ?? "Sent, confirming"
        case .confirmed: "Sent"
        case .failed: error ?? "Failed"
        }
    }
    var tone: Color {
        switch status {
        case .invalid, .failed: Theme.red
        case .confirmed: Theme.green
        case .sent: Theme.amber
        case .ready: Theme.muted
        }
    }
    var shortAddress: String { address.isEmpty ? input : "\(address.prefix(6))…\(address.suffix(4))" }
}

/// The one review for a batch: every recipient, the total, fees, the checks and anything left out or blocking.
/// Approve asks for Face ID / Touch ID once, then the transfers go out one by one with their status here and in chat.
struct BatchSendSheet: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private var store: BatchStore { .shared }
    private var vm: WalletsViewModel { .shared }

    var body: some View {
        if let p = store.plan(id) {
            let running = store.running.contains(id)
            SheetChrome(title: "Send \(p.total) \(p.symbol) to \(p.valid.count) address\(p.valid.count == 1 ? "" : "es")",
                        subtitle: [p.chain?.name, p.source].compactMap { $0 }.joined(separator: ", ")) {
                DetailLines(lines: summary(p))
                if !p.blocks.isEmpty {
                    ForEach(p.blocks, id: \.self) { NoteBox(symbol: "xmark.octagon", text: $0, tint: Theme.red) }
                }
                if !p.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(p.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                BatchRowsList(plan: p, limit: nil)
                VStack(alignment: .leading, spacing: 7) {
                    Label("Checks", systemImage: "checkmark.shield").font(.system(size: 13, weight: .medium))
                    ForEach(p.checks, id: \.self) { c in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 12))
                            Text(c).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let e = store.errors[id] { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            } foot: {
                if p.done {
                    Button("Done") { dismiss() }.buttonStyle(WideButton())
                } else {
                    Button { start(p) } label: {
                        HStack(spacing: 7) {
                            if running { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "touchid") }
                            Text(running ? progress(p) : p.valid.contains { $0.status != .ready } ? "Resume, \(p.remaining.count) left" : "Approve and send")
                        }
                    }
                    .buttonStyle(WideButton(kind: .accent)).disabled(!p.canSend || running)
                }
            }
        } else {
            SheetChrome(title: "Batch send") { EmptyNote(text: "This batch isn't on this device anymore.") }
        }
    }

    private func summary(_ p: BatchPlan) -> [(String, String)] {
        var l: [(String, String)] = [("From", vm.wallet(p.walletID.uuidString)?.name ?? "Wallet"), ("Network", p.chain?.name ?? p.chainID),
                                     ("Recipients", "\(p.valid.count)" + (p.invalid.isEmpty ? "" : ", \(p.invalid.count) left out")),
                                     ("Total", "\(p.total) \(p.symbol)"), ("Network fees", "up to \(p.feeText)")]
        if p.origin == .agent { l.append(("Asked for by", "Hermit, from your message")) }
        return l
    }

    private func progress(_ p: BatchPlan) -> String {
        let n = p.valid.filter { $0.status == .confirmed || $0.status == .sent }.count
        return "Sending \(min(n + 1, p.valid.count)) of \(p.valid.count)"
    }

    private func start(_ p: BatchPlan) {
        // The chat follows the batch: one card with every row's status, posted once.
        if model.route == .home, model.inChat, !model.messages.contains(where: { $0.blocks.contains(.card(.batchSend(id))) }) {
            withAnimation(.smooth) { model.messages.append(Message(role: .assistant, blocks: [.card(.batchSend(id))])) }
            model.commit()
        }
        Task { await store.run(id, service: vm.service) }
    }
}

/// Rows with their state and, once sent, a link to the transaction.
struct BatchRowsList: View {
    let plan: BatchPlan
    /// Show only the first rows (chat card); nil shows all (review sheet).
    let limit: Int?

    var body: some View {
        let rows = limit.map { Array(plan.rows.prefix($0)) } ?? plan.rows
        VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 10) {
                        Text("\(r.line)").foregroundStyle(Theme.faint).frame(minWidth: 18, alignment: .leading).monospacedDigit()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.shortAddress).font(Theme.mono).lineLimit(1)
                            if r.status != .ready { Text(r.stateText).font(.system(size: 11.5)).foregroundStyle(r.tone).lineLimit(2) }
                        }
                        Spacer(minLength: 6)
                        Text(r.amount.isEmpty ? "–" : "\(r.amount) \(plan.symbol)").monospacedDigit().foregroundStyle(r.status == .invalid ? Theme.faint : Theme.text)
                            .lineLimit(1)
                        statusMark(r).frame(width: 18)
                    }
                    .font(.system(size: 12.5)).padding(.vertical, 7)
                    if i < rows.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            if let limit, plan.rows.count > limit {
                Text("+ \(plan.rows.count - limit) more").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
    }

    @ViewBuilder private func statusMark(_ r: BatchRow) -> some View {
        if let h = r.hash, let url = plan.chain?.explorerURL(tx: h) {
            Link(destination: url) {
                Image(systemName: r.status == .confirmed ? "checkmark.circle.fill" : r.status == .failed ? "xmark.circle.fill" : "clock")
                    .foregroundStyle(r.tone).font(.system(size: 13))
            }
            .help("Open the transaction")
            .accessibilityLabel("Transaction for row \(r.line)")
        } else if r.status == .invalid || r.status == .failed {
            Image(systemName: "minus.circle").foregroundStyle(Theme.red.opacity(0.7)).font(.system(size: 13))
        }
    }
}

/// The batch in chat: totals, progress, the first rows with links, and Review / Resume.
struct BatchSendCard: View {
    let id: String
    @Environment(AppModel.self) private var model
    private var store: BatchStore { .shared }

    var body: some View {
        if let p = store.plan(id) {
            let sent = p.valid.filter { $0.status == .confirmed }.count
            let failed = p.valid.filter { $0.status == .failed }.count
            let running = store.running.contains(id)
            ChatCard {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(Theme.text).font(.system(size: 14))
                CardTitle(p.source ?? "Batch send")
                Spacer()
                Text(p.chain?.name ?? "").font(.system(size: 12)).foregroundStyle(Theme.faint)
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    KVGrid(pairs: [["Recipients", "\(p.valid.count)"], ["Total", "\(p.total) \(p.symbol)"],
                                   [p.invalid.isEmpty ? "Sent" : "Left out", p.invalid.isEmpty ? "\(sent)" : "\(p.invalid.count)"]],
                           tones: p.invalid.isEmpty ? [:] : ["Left out": .red])
                    BatchRowsList(plan: p, limit: 8)
                    if sent > 0 || running || failed > 0 {
                        VStack(spacing: 6) {
                            HStack {
                                Text(p.done ? "All sent" : running ? "Sending…" : failed > 0 ? "\(failed) failed" : "Stopped")
                                Spacer()
                                Text("\(sent) / \(p.valid.count)").monospacedDigit().contentTransition(.numericText(value: Double(sent)))
                            }
                            .font(.system(size: 12.5))
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.hover)
                                    Capsule().fill(Theme.green).frame(width: g.size.width * CGFloat(sent) / CGFloat(max(p.valid.count, 1)))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                    if let e = store.errors[id] { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
                }
            } foot: {
                if p.done {
                    Label("All \(p.valid.count) sent", systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button { store.review(id, model: model) } label: {
                        Label(running ? "Open" : p.valid.contains { $0.status != .ready } ? "Resume" : "Review", systemImage: "list.bullet")
                    }
                    .buttonStyle(BrandButton())
                }
            }
            .animation(.smooth, value: sent)
        } else {
            ChatCard { Text("This batch isn't on this device anymore.").font(.system(size: 13)).foregroundStyle(Theme.muted) }
        }
    }
}
