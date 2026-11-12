import SwiftUI
import Observation
import HermitCore
import HermitWallet

// Budgets: the app side of Hermit Guard (contracts/guard). A vault on NEAR holds money; pockets are small budgets with
// rules; a pocket's key (for an app, a script or an agent) can pay only what its pocket allows. Everything on these screens
// is read from the contract when the screen opens, and every change is checked and approved like any other NEAR move
// (HermitWallet/NearGuard.swift). Nothing here is shown unless GuardConfig.contractID is set.

/// A pocket key that was just made and hasn't been saved by the user. Held in memory only, until "I've saved it".
@MainActor @Observable
final class GuardKeyReveal {
    static let shared = GuardKeyReveal()
    var pending: IssuedKey?
}

enum GuardText {
    static func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }

    /// The approval sheet for a checked move. Approve signs it on this device and waits for NEAR to run it. A new pocket
    /// key is handed to GuardKeyReveal when the move went through.
    @MainActor static func approval(_ r: NearGuard.Review) -> Approval {
        let vm = WalletsViewModel.shared, svc = vm.service
        var lines = r.lines
        if vm.wallets.count > 1, let name = vm.wallet(r.walletID.uuidString)?.name { lines.insert(["Wallet", name], at: 0) }
        return Approval(kind: r.kind, title: r.title, lines: lines,
                        checks: r.checks + ["Signed on \(Device.here) with your wallet's key"],
                        success: r.success, warnings: r.warnings) {
            let out = try await svc.executeNearGuard(r)
            await MainActor.run {
                if let k = out.issuedKey { GuardKeyReveal.shared.pending = k }
                Task { await WalletsViewModel.shared.refresh() }
            }
            return out.hash
        }
    }

    static func amount(_ s: NearGuard.Snapshot, _ token: String, _ v: UInt128) -> String { s.token(token)?.text(v) ?? "\(v) of \(shortAddr(token))" }

    /// A share of `most` as exact text for the token, cut down (never up).
    static func part(_ most: UInt128, _ share: UInt128, of whole: UInt128, _ t: NearGuard.TokenInfo) -> String {
        Units.format(most / whole * share, decimals: t.decimals)
    }

    static func recipients(_ list: [String]) -> String {
        list.isEmpty ? "Anyone" : list.count <= 2 ? list.joined(separator: ", ") : "\(list[0]), \(list[1]) and \(list.count - 2) more"
    }

    /// First letter up: "every 2 weeks" becomes "Every 2 weeks".
    static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func time(_ ns: UInt64) -> String { NearGuard.date(ns: ns).formatted(date: .abbreviated, time: .shortened) }
}

// MARK: The card in Security

/// Wallets > Security, under the spending policy. Only there when Budgets exists in this build and the wallet has a NEAR account.
/// Dressed like Home's "Crypto today" card: the holo wash, a small eyebrow, a bold title, a serif figure and frosted tiles.
struct GuardBudgetsCard: View {
    let vm: WalletsViewModel
    let wallet: WalletAccount
    let open: (WalletSheet) -> Void
    @State private var state: Loaded = .loading
    private var reveal: GuardKeyReveal { .shared }

    /// What the vault shows on the card. `total` and `unit` are only set when the vault holds exactly one token.
    struct Facts: Equatable {
        var frozen: Bool
        var pockets: Int
        var orders: Int
        var requests: Int
        var total: String?
        var unit: String?
        var spent: String?
    }

    enum Loaded: Equatable { case loading, failed, notSetUp, vault(Facts) }

    var body: some View {
        if GuardConfig.isEnabled, wallet.record.nearAccount != nil {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let k = reveal.pending {
                    NoteBox(symbol: "key", text: "The key for the pocket \(k.pocket) hasn't been saved yet. Open Budgets to see it.", tint: Theme.amber)
                }
                if case .vault(let f) = state { tiles(f) }
                Text(blurb).font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Button(state == .notSetUp ? "Set up Budgets" : "Open Budgets") { openSheet() }.buttonStyle(BudgetButton(kind: .primary))
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .holoCard()
            .task(id: wallet.id) { await load() }
        }
    }

    private func openSheet() { open(.budgets(wallet: wallet.id)) }

    private var blurb: String {
        "Give an app or agent a small budget with rules, held in a vault on NEAR."
    }

    private var title: String {
        switch state {
        case .loading: return "Checking"
        case .failed: return "Couldn't reach NEAR right now"
        case .notSetUp: return "Not set up yet"
        case .vault(let f): return f.frozen ? "Frozen" : "Running"
        }
    }

    private var titleColor: Color {
        if case .vault(let f) = state, f.frozen { return Theme.red }
        return Theme.text
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Budgets").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(titleColor).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if case .vault(let f) = state, let total = f.total { figure(total, f.unit) }
        }
    }

    private func figure(_ total: String, _ unit: String?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(total).font(.serif(46)).tracking(-1).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.4)
            if let unit { Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted) }
        }
        .layoutPriority(1)
    }

    private func tiles(_ f: Facts) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
            tile("square.stack", "\(f.pockets)", "Pockets", Theme.text)
            tile("repeat", "\(f.orders)", "Standing orders", Theme.text)
            tile("hourglass", "\(f.requests)", "Waiting for you", f.requests > 0 ? Theme.amber : Theme.text)
            if let spent = f.spent { tile("arrow.up.right", spent, "Spent today", Theme.text) }
        }
    }

    private func tile(_ symbol: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        Button { openSheet() } label: { BudgetFactTile(symbol: symbol, value: value, label: label, tint: tint) }
            .buttonStyle(PressStyle())
    }

    private func load() async {
        guard let id = vm.wallet(wallet.id)?.record.id else { return }
        do {
            let s = try await vm.service.nearGuardSnapshot(walletID: id)
            if let v = s.vault { state = .vault(Self.facts(s, v)) } else { state = .notSetUp }
        } catch { state = .failed }
    }

    /// Real numbers only: a figure for the total and for today's spending when they are in one token, otherwise nothing.
    private static func facts(_ s: NearGuard.Snapshot, _ v: NearGuard.GuardVault) -> Facts {
        var f = Facts(frozen: v.frozen, pockets: v.pockets, orders: v.orders, requests: s.requests.count)
        let held = s.tokens.filter { v.balance($0.id) > 0 }
        if held.count == 1, let t = held.first { f.total = t.number(v.balance(t.id)); f.unit = t.symbol }
        let now = NearGuard.ns(Date())
        let used = Set(s.pockets.map(\.token))
        if used.count == 1, let id = used.first, let t = s.token(id) {
            f.spent = t.text(s.pockets.reduce(UInt128(0)) { $0 + $1.spentToday(nowNs: now) })
        }
        return f
    }
}

// MARK: The Budgets sheet

struct GuardBudgetsSheet: View {
    let vm: WalletsViewModel
    let walletID: String
    /// Opens this sheet again once an approval is through (the approval sheet replaces it).
    let reopen: () -> Void
    @Environment(\.askApproval) private var ask
    @State private var snap: NearGuard.Snapshot?
    @State private var loadFailed = false
    @State private var route: Route = .home
    @State private var busy: String?
    @State private var error: String?
    @State private var allReceipts = false

    enum Route: Equatable { case home, fund(token: String, withdraw: Bool), pocket(GuardPocketForm.Mode), order, key }

    var body: some View {
        Group {
            switch route {
            case .home:
                SheetChrome(title: "Budgets", subtitle: subtitle) { home }
            case .fund(let id, let withdraw):
                if let snap, let t = snap.token(id) {
                    GuardFundForm(snap: snap, token: t, withdraw: withdraw, walletID: walletID, back: { route = .home }, submit: prepare)
                }
            case .pocket(let mode):
                if let snap { GuardPocketForm(snap: snap, mode: mode, back: { route = .home }, submit: prepare) }
            case .order:
                if let snap { GuardOrderForm(snap: snap, back: { route = .home }, submit: prepare) }
            case .key:
                if let k = GuardKeyReveal.shared.pending { GuardKeyBody(key: k, contract: snap?.contract ?? GuardConfig.contractID ?? "", done: {
                    GuardKeyReveal.shared.pending = nil; route = .home
                }) } else { SheetChrome(title: "Budgets") { EmptyNote(text: "Nothing to show.") } }
            }
        }
        .task {
            if GuardKeyReveal.shared.pending != nil { route = .key }
            await load()
        }
    }

    private var subtitle: String? {
        guard let s = snap, let v = s.vault else { return "Spending rules for apps and agents" }
        return v.frozen ? "Frozen" : "Running"
    }

    private func load() async {
        guard let id = vm.wallet(walletID)?.record.id else { return }
        do { snap = try await vm.service.nearGuardSnapshot(walletID: id); loadFailed = false } catch { loadFailed = snap == nil }
    }

    /// Checks a move against the chain and opens the approval sheet. Returns the reason in words when it can't go ahead.
    private func prepare(_ move: NearGuard.Move) async -> String? {
        guard let id = vm.wallet(walletID)?.record.id else { return "That wallet is gone." }
        do {
            let r = try await vm.service.prepareNearGuard(walletID: id, move: move, origin: .user)
            ask(GuardText.approval(r)) { reopen() }
            return nil
        } catch { return GuardText.message(error) }
    }

    private func act(_ move: NearGuard.Move, id: String) {
        busy = id; error = nil
        Task {
            error = await prepare(move)
            busy = nil
        }
    }

    // MARK: Home

    @ViewBuilder private var home: some View {
        if let s = snap {
            if let v = s.vault { vaultContent(s, v) } else { emptyContent(s) }
        } else if loadFailed {
            NoteBox(symbol: "wifi.exclamationmark", text: "Couldn't reach NEAR right now.")
            Button("Try again") { Task { await load() } }.buttonStyle(BudgetButton(kind: .soft))
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading Budgets").font(.system(size: 15)).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 14)
        }
    }

    private func errorText(_ e: String) -> some View {
        Text(e).font(.system(size: 14)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
    }

    private func emptyContent(_ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Budgets").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
                Text("Not set up yet").font(.system(size: 22, weight: .bold))
                Text("Put money in a vault on NEAR and give an app or an agent a pocket: a small budget with its own limits. It can pay only what the pocket allows, and you can freeze everything or take your money back at any time.")
                    .font(.system(size: 15.5)).foregroundStyle(Theme.text.opacity(0.8)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).holoCard()
            NoteBox(symbol: "checkmark.shield", text: "Setting up costs a deposit of \(NearGuard.TokenInfo.near.number(s.storageCost)) NEAR for the vault's storage. You get it back when you close the vault.")
            NoteBox(symbol: "exclamationmark.triangle", text: "Budgets is new software on NEAR and hasn't been audited. Only keep in it what you're comfortable risking.", tint: Theme.amber)
            if let error { errorText(error) }
            Button { act(.openVault(storage: s.storageCost, initial: 0), id: "open") } label: {
                HStack(spacing: 8) {
                    if busy == "open" { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy == "open" ? "Checking" : "Set up Budgets")
                }
            }
            .buttonStyle(BudgetButton(kind: .primary, height: 56)).disabled(busy != nil)
        }
    }

    private func vaultContent(_ s: NearGuard.Snapshot, _ v: NearGuard.GuardVault) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            hero(s, v)
            freezeCard(v)
            if let error { errorText(error) }
            if !s.requests.isEmpty { requestsSection(s) }
            pocketsSection(s)
            ordersSection(s)
            receiptsSection(s)
            VStack(alignment: .leading, spacing: 10) {
                NoteBox(symbol: "lock.shield", text: "A pocket's key can only pay inside its limits. It can't withdraw, freeze or change a rule: only you can, with \(Device.bio).")
                Button("Close Budgets and get the deposit back") { act(.closeVault, id: "close") }
                    .buttonStyle(.plain).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.muted)
                    .frame(minHeight: 44).disabled(busy != nil)
            }
        }
    }

    private func freezeCard(_ v: NearGuard.GuardVault) -> some View {
        let tint = v.frozen ? Theme.red : Theme.green
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: v.frozen ? "snowflake" : "checkmark.circle.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.frozen ? "Frozen" : "Running").font(.system(size: 20, weight: .bold)).foregroundStyle(v.frozen ? Theme.red : Theme.text)
                    Text(v.frozen ? "Nothing can be paid: no pocket, no standing order, no approval. You can still withdraw."
                                  : "Pockets can pay inside their limits and standing orders run.")
                        .font(.system(size: 15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if v.frozen {
                Button(busy == "freeze" ? "Checking" : "Unfreeze") { act(.setFrozen(false), id: "freeze") }
                    .buttonStyle(BudgetButton(kind: .green, height: 56)).disabled(busy != nil)
            } else {
                Button(busy == "freeze" ? "Checking" : "Freeze everything") { act(.setFrozen(true), id: "freeze") }
                    .buttonStyle(BudgetButton(kind: .danger, height: 56)).disabled(busy != nil)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(v.frozen ? Theme.red.opacity(0.10) : Theme.subtle, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(v.frozen ? Theme.red.opacity(0.55) : Theme.border, lineWidth: v.frozen ? 1.5 : 1))
    }

    /// The balance per token in large type on the holo wash, with big Add and Withdraw buttons.
    private func hero(_ s: NearGuard.Snapshot, _ v: NearGuard.GuardVault) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("In the vault").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.muted)
                Text(v.frozen ? "Frozen" : "Running").font(.system(size: 22, weight: .bold)).foregroundStyle(v.frozen ? Theme.red : Theme.text)
            }
            ForEach(s.tokens) { t in balanceTile(t, v.balance(t.id)) }
            if !s.unknownTokens.isEmpty {
                Text("\(s.unknownTokens.count) other token\(s.unknownTokens.count == 1 ? "" : "s") on the contract's list couldn't be read, so Hermit leaves them out.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if v.pendingOut > 0 {
                Text("A payment is still on its way, so the balance may change in a moment.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).holoCard()
    }

    private func balanceTile(_ t: NearGuard.TokenInfo, _ held: UInt128) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                LogoMark(t.symbol.lowercased(), size: 36)
                Text(t.symbol).font(.system(size: 17, weight: .bold))
                Spacer(minLength: 8)
                Text(t.number(held)).font(.serif(36)).tracking(-0.5).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                    .accessibilityLabel(t.text(held))
            }
            HStack(spacing: 10) {
                Button("Add") { route = .fund(token: t.id, withdraw: false) }.buttonStyle(BudgetButton(kind: .accent))
                Button("Withdraw") { route = .fund(token: t.id, withdraw: true) }.buttonStyle(BudgetButton(kind: .soft)).disabled(held == 0)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).holoTile(radius: 20)
    }

    private func requestsSection(_ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BudgetHeading("Waiting for you")
            ForEach(s.requests) { r in requestCard(r, s) }
        }
    }

    private func requestCard(_ r: NearGuard.GuardRequest, _ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(GuardText.amount(s, r.token, r.amount)) to \(shortAddr(r.recipient, keep: 10))").font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Asked by the key of \(r.pocket). Expires \(GuardText.time(r.expiresNs)).").font(.system(size: 14.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !r.reason.isEmpty {
                Text("\u{201C}\(r.reason)\u{201D}").font(.system(size: 14.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(busy == "a\(r.id)" ? "Checking" : "Approve") { act(.approve(r.id), id: "a\(r.id)") }
                    .buttonStyle(BudgetButton(kind: .green, height: 48)).disabled(busy != nil)
                Button("Reject") { act(.reject(r.id), id: "r\(r.id)") }
                    .buttonStyle(BudgetButton(kind: .danger, height: 48)).disabled(busy != nil)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).paperTile(tint: Theme.amber)
    }

    private func pocketsSection(_ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BudgetHeading(text: "Pockets") {
                Button("New pocket") { route = .pocket(.new) }
                    .buttonStyle(BudgetButton(kind: .soft, height: 44, fullWidth: false)).disabled(s.pockets.count >= NearGuard.maxPockets)
            }
            if s.pockets.isEmpty {
                EmptyNote(text: "No pockets yet. A pocket is a small budget with its own limits, for one app or agent.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(s.pockets) { p in pocketTile(p, s) }
                }
            }
        }
    }

    private func pocketTile(_ p: NearGuard.GuardPocket, _ s: NearGuard.Snapshot) -> some View {
        let now = NearGuard.ns(Date())
        let t = s.token(p.token)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                if let t { LogoMark(t.symbol.lowercased(), size: 34) } else { Image(systemName: "questionmark.circle").font(.system(size: 30)).foregroundStyle(Theme.faint) }
                Spacer(minLength: 4)
                pocketMenu(p)
            }
            Text(p.name).font(.system(size: 16, weight: .bold)).textCase(.uppercase).fixedSize(horizontal: false, vertical: true)
            pocketChips(p, now)
            pocketLimits(p, t, now)
            Text("Can pay: \(GuardText.recipients(p.allowedRecipients))" + (p.expiresAt.map { ". Expires \(GuardText.time($0))" } ?? ""))
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).paperTile()
    }

    private func pocketMenu(_ p: NearGuard.GuardPocket) -> some View {
        Menu {
            Button("Edit", systemImage: "pencil") { route = .pocket(.edit(p.name)) }
            Button(p.paused ? "Resume" : "Pause", systemImage: p.paused ? "play" : "pause") { act(.setPaused(name: p.name, paused: !p.paused), id: "p\(p.name)") }
            Button("Remove", systemImage: "trash", role: .destructive) { act(.removePocket(name: p.name), id: "p\(p.name)") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(busy != nil)
        .accessibilityLabel("Actions for \(p.name)")
    }

    @ViewBuilder private func pocketChips(_ p: NearGuard.GuardPocket, _ now: UInt64) -> some View {
        let state = p.state(nowNs: now)
        if state != .active || p.publicKey == nil {
            WrapRow(spacing: 6) {
                switch state {
                case .paused: StateChip(text: "Paused", color: Theme.amber, symbol: "pause.circle")
                case .expired: StateChip(text: "Expired", color: Theme.red, symbol: "clock.badge.exclamationmark")
                case .active: EmptyView()
                }
                if p.publicKey == nil { StateChip(text: "No key", color: Theme.muted, symbol: "key") }
            }
        }
    }

    @ViewBuilder private func pocketLimits(_ p: NearGuard.GuardPocket, _ t: NearGuard.TokenInfo?, _ now: UInt64) -> some View {
        if let t {
            let spent = p.spentToday(nowNs: now)
            let share = p.dailyCap > 0 ? Double(spent) / Double(p.dailyCap) : 0
            BudgetBar(fraction: share, tint: share >= 1 ? Theme.red : share >= 0.8 ? Theme.amber : Theme.green)
            Text("Spent today \(t.number(spent)) of \(t.text(p.dailyCap))").font(.system(size: 14.5, weight: .semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text("Up to \(t.text(p.perPaymentCap)) per payment, \(t.text(p.dailyCap)) a day").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Token \(shortAddr(p.token)), which Hermit can't read").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ordersSection(_ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BudgetHeading(text: "Standing orders") {
                Button("New order") { route = .order }
                    .buttonStyle(BudgetButton(kind: .soft, height: 44, fullWidth: false)).disabled(s.pockets.isEmpty || s.orders.count >= NearGuard.maxOrders)
            }
            if s.orders.isEmpty {
                EmptyNote(text: s.pockets.isEmpty ? "Make a pocket first. A standing order pays from a pocket on a schedule."
                                                  : "No standing orders. An order pays the same amount to the same address on a schedule, even when your phone is off.")
            } else {
                ForEach(s.orders) { o in orderCard(o, s) }
                Text("Orders run on NEAR even when your phone is off. A due order is paid when someone triggers it, and only inside the pocket's limits.")
                    .font(.system(size: 13)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func orderCard(_ o: NearGuard.GuardOrder, _ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(GuardText.amount(s, o.token, o.amount)) to \(shortAddr(o.recipient, keep: 10))").font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(GuardText.sentence(NearGuard.everyText(o.intervalSeconds))), from \(o.pocket). Next \(GuardText.time(o.nextDueNs))"
                     + (o.remaining.map { ", \($0) left" } ?? ""))
                    .font(.system(size: 14.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if !o.memo.isEmpty { Text(o.memo).font(.system(size: 14.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true) }
            }
            Button(busy == "o\(o.id)" ? "Checking" : "Cancel") { act(.cancelOrder(o.id), id: "o\(o.id)") }
                .buttonStyle(BudgetButton(kind: .danger, height: 46)).disabled(busy != nil)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).paperTile()
    }

    private func receiptsSection(_ s: NearGuard.Snapshot) -> some View {
        let shown = allReceipts ? s.receipts : Array(s.receipts.prefix(8))
        return VStack(alignment: .leading, spacing: 12) {
            BudgetHeading("Payments")
            if s.receipts.isEmpty {
                EmptyNote(text: "Nothing has been paid from the vault yet.")
            } else {
                RowList(items: shown) { r in receiptRow(r, s) }
                    .padding(.horizontal, 18).padding(.vertical, 4).paperTile()
                if s.receipts.count > 8 {
                    Button(allReceipts ? "Show fewer" : "Show all \(s.receipts.count)") { withAnimation(.smooth) { allReceipts.toggle() } }
                        .buttonStyle(BudgetButton(kind: .soft, height: 46))
                }
                Text("The contract keeps the last \(NearGuard.maxReceipts) payments.").font(.system(size: 13)).foregroundStyle(Theme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func receiptRow(_ r: NearGuard.GuardReceipt, _ s: NearGuard.Snapshot) -> some View {
        let tint = r.ok ? Theme.green : Theme.red
        return VStack(alignment: .leading, spacing: 5) {
            (Text(GuardText.amount(s, r.token, r.amount)).foregroundStyle(tint) + Text(" to \(shortAddr(r.recipient, keep: 10))"))
                .font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !r.ok { StateChip(text: "Failed, refunded", color: Theme.red, symbol: "xmark.octagon") }
            Text(receiptLine(r)).font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !r.reason.isEmpty { Text("\u{201C}\(r.reason)\u{201D}").font(.system(size: 14)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func receiptLine(_ r: NearGuard.GuardReceipt) -> String {
        let how: String
        switch r.kind {
        case .spend: how = "Paid by the key of \(r.pocket)"
        case .order: how = "Standing order from \(r.pocket)"
        case .approved: how = "Approved by you, from \(r.pocket)"
        case .withdraw: how = "Withdrawn to your account"
        case .other(let k): how = k.isEmpty ? r.pocket : "\(k), \(r.pocket)"
        }
        return "\(how). \(GuardText.time(r.timeNs))"
    }
}

// MARK: Add and withdraw

struct GuardFundForm: View {
    let snap: NearGuard.Snapshot
    let token: NearGuard.TokenInfo
    let withdraw: Bool
    let walletID: String
    let back: () -> Void
    let submit: @MainActor (NearGuard.Move) async -> String?
    @State private var amount = ""
    /// Add: what the wallet can put in. Withdraw: what the vault holds.
    @State private var most: UInt128?
    @State private var busy = false
    @State private var error: String?

    private var vaultHeld: UInt128 { snap.vault?.balance(token.id) ?? 0 }
    private var value: UInt128? { try? token.parse(AmountText.clean(amount)) }
    private var limit: UInt128 { withdraw ? vaultHeld : (most ?? 0) }
    private var canReview: Bool { if let v = value, v > 0, v <= limit, !busy { return true } else { return false } }

    var body: some View {
        SheetChrome(title: withdraw ? "Withdraw \(token.symbol)" : "Add \(token.symbol)", subtitle: withdraw ? "To your own NEAR account" : "Into your Budgets vault", onBack: back) {
            BudgetFormField(label: "Amount", trailing: trailing) { BudgetAmountField(text: $amount) }
            WrapRow {
                ForEach([("25%", UInt128(1)), ("50%", UInt128(2))], id: \.0) { q in
                    let t = GuardText.part(limit, q.1, of: 4, token)
                    BudgetChip(title: q.0, on: amount == t && limit > 0) { amount = t }
                }
                let all = GuardText.part(limit, 1, of: 1, token)
                BudgetChip(title: withdraw ? "All" : "Max", on: amount == all && limit > 0) { amount = all }
            }
            if let v = value, v > limit, withdraw || most != nil {
                Text(withdraw ? "The vault holds \(token.text(vaultHeld))." : "You can add up to \(token.text(limit)).").font(.system(size: 14)).foregroundStyle(Theme.red)
            }
            if withdraw {
                NoteBox(symbol: "arrow.down.to.line", text: "Withdrawing always works, also while Budgets is frozen. It only ever goes to your own account.")
            } else if token.isNative {
                NoteBox(symbol: "info.circle", text: "Hermit keeps \(NearGuard.TokenInfo.near.number(NearGuard.reserve)) NEAR in your account for fees.")
            } else {
                NoteBox(symbol: "info.circle", text: "\(token.symbol) goes in through the token's own transfer. If the contract can't take it, the token sends it back and Hermit tells you.")
            }
            if let error { Text(error).font(.system(size: 14)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(BudgetButton(kind: .primary, height: 56)).disabled(!canReview)
        }
        .task { await load() }
    }

    private var trailing: String {
        if withdraw { return "\(token.text(vaultHeld)) in the vault" }
        guard let m = most else { return "Reading your balance" }
        return "\(token.text(m)) available"
    }

    private func load() async {
        guard !withdraw, let id = WalletsViewModel.shared.wallet(walletID)?.record.id else { return }
        most = await WalletsViewModel.shared.service.nearGuardMaxDeposit(walletID: id, token: token)
        if most == nil { error = "Couldn't read your balance. Close this and try again." }
    }

    private func review() async {
        guard let v = value else { return }
        busy = true; error = nil
        defer { busy = false }
        let move: NearGuard.Move
        if withdraw {
            // "All" withdraws whatever the vault holds when the call runs, so nothing is left behind.
            move = .withdraw(token: token.id, amount: amount == GuardText.part(vaultHeld, 1, of: 1, token) ? nil : v)
        } else {
            move = token.isNative ? .depositNear(v) : .depositToken(token: token.id, amount: v)
        }
        error = await submit(move)
    }
}

// MARK: New and edited pockets

struct GuardPocketForm: View {
    enum Mode: Equatable { case new, edit(String) }
    let snap: NearGuard.Snapshot
    let mode: Mode
    let back: () -> Void
    let submit: @MainActor (NearGuard.Move) async -> String?
    @State private var name: String
    @State private var tokenID: String
    @State private var perPayment: String
    @State private var daily: String
    @State private var recipients: String
    @State private var expiry: String
    @State private var withKey = true
    @State private var busy = false
    @State private var error: String?

    static let expiries: [(String, Double)] = [("In 1 day", 1), ("In 7 days", 7), ("In 30 days", 30), ("In 90 days", 90)]
    private let never = "Never"
    private var keep: String? { existing?.expiresAt.map { "Keep \(GuardText.time($0))" } }

    init(snap: NearGuard.Snapshot, mode: Mode, back: @escaping () -> Void, submit: @escaping @MainActor (NearGuard.Move) async -> String?) {
        self.snap = snap; self.mode = mode; self.back = back; self.submit = submit
        var old: NearGuard.GuardPocket?
        if case .edit(let n) = mode { old = snap.pocket(n) }
        let t = old.flatMap { snap.token($0.token) } ?? snap.tokens.first ?? .near
        _name = State(initialValue: old?.name ?? "")
        _tokenID = State(initialValue: t.id)
        _perPayment = State(initialValue: old.map { Units.format($0.perPaymentCap, decimals: t.decimals) } ?? "")
        _daily = State(initialValue: old.map { Units.format($0.dailyCap, decimals: t.decimals) } ?? "")
        _recipients = State(initialValue: old?.allowedRecipients.joined(separator: ", ") ?? "")
        _expiry = State(initialValue: old?.expiresAt.map { "Keep \(GuardText.time($0))" } ?? "Never")
    }

    private var existing: NearGuard.GuardPocket? { if case .edit(let n) = mode { snap.pocket(n) } else { nil } }
    private var editing: Bool { existing != nil }
    private var token: NearGuard.TokenInfo { snap.token(tokenID) ?? .near }
    private var expiryOptions: [String] { (keep.map { [$0] } ?? []) + [never] + Self.expiries.map(\.0) }

    var body: some View {
        SheetChrome(title: editing ? "Change pocket" : "New pocket", subtitle: editing ? existing?.name : "A small budget with its own limits", onBack: back) {
            if !editing {
                BudgetFormField(label: "Name") { BudgetTextField(placeholder: "Coffee", text: $name) }
                if snap.tokens.count > 1 {
                    BudgetFormField(label: "Token") { BudgetMenuField(selection: $tokenID, options: snap.tokens.map(\.id), title: { snap.token($0)?.symbol ?? $0 }) }
                }
            } else {
                BudgetFormField(label: "Token") { Text(token.symbol).font(.system(size: 17)).frame(maxWidth: .infinity, alignment: .leading).modifier(BudgetFieldBox()) }
            }
            BudgetFormField(label: "Most per payment", trailing: token.symbol) { BudgetAmountField(text: $perPayment) }
            BudgetFormField(label: "Most per day", trailing: token.symbol) { BudgetAmountField(text: $daily) }
            BudgetFormField(label: "Can pay (optional)") { BudgetTextField(placeholder: "Anyone, or shop.near, bob.near", text: $recipients, mono: true) }
            BudgetFormField(label: "Expires") { BudgetMenuField(selection: $expiry, options: expiryOptions, title: { $0 }) }
            if !editing {
                BudgetFormField(label: "Key") {
                    WrapRow {
                        BudgetChip(title: "Make a key", on: withKey) { withKey = true }
                        BudgetChip(title: "No key", on: !withKey) { withKey = false }
                    }
                }
                NoteBox(symbol: "key", text: withKey
                        ? "Hermit makes a key for an app or an agent and shows it once. It can only pay inside this pocket's limits."
                        : "Without a key, only standing orders can pay from this pocket.")
            }
            NoteBox(symbol: "info.circle", text: "A day is a fixed 24 hours from the first payment. Around the edge of two days, up to twice the daily limit can go out.")
            if let error { Text(error).font(.system(size: 14)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(BudgetButton(kind: .primary, height: 56)).disabled(busy || (!editing && name.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }

    private func review() async {
        error = nil
        guard let per = try? token.parse(AmountText.clean(perPayment)), per > 0 else { error = "Enter the most this pocket can pay in one payment."; return }
        guard let day = try? token.parse(AmountText.clean(daily)), day > 0 else { error = "Enter the most this pocket can pay in a day."; return }
        let expiresAt: UInt64?
        if let k = keep, expiry == k { expiresAt = existing?.expiresAt }
        else if let days = Self.expiries.first(where: { $0.0 == expiry })?.1 { expiresAt = NearGuard.ns(Date().addingTimeInterval(days * 86_400)) }
        else { expiresAt = nil }
        let list = NearGuard.parseRecipients(recipients)
        busy = true
        defer { busy = false }
        if let old = existing {
            let d = NearGuard.PocketDraft(name: old.name, token: old.token, perPayment: per, daily: day, recipients: list, expiresAtNs: expiresAt, publicKey: old.publicKey)
            error = await submit(.updatePocket(d))
        } else {
            let d = NearGuard.PocketDraft(name: name.trimmingCharacters(in: .whitespaces), token: tokenID, perPayment: per, daily: day, recipients: list,
                                          expiresAtNs: expiresAt, withKey: withKey)
            error = await submit(.createPocket(d))
        }
    }
}

// MARK: Standing orders

struct GuardOrderForm: View {
    let snap: NearGuard.Snapshot
    let back: () -> Void
    let submit: @MainActor (NearGuard.Move) async -> String?
    @State private var pocket: String
    @State private var amount = ""
    @State private var recipient = ""
    @State private var every = "1"
    @State private var weeks = false
    @State private var times = ""
    @State private var memo = ""
    @State private var busy = false
    @State private var error: String?

    init(snap: NearGuard.Snapshot, back: @escaping () -> Void, submit: @escaping @MainActor (NearGuard.Move) async -> String?) {
        self.snap = snap; self.back = back; self.submit = submit
        _pocket = State(initialValue: snap.pockets.first?.name ?? "")
    }

    private var chosen: NearGuard.GuardPocket? { snap.pocket(pocket) }
    private var token: NearGuard.TokenInfo { chosen.flatMap { snap.token($0.token) } ?? .near }

    var body: some View {
        SheetChrome(title: "New standing order", subtitle: "Pays on a schedule, even when your phone is off", onBack: back) {
            BudgetFormField(label: "From pocket") { BudgetMenuField(selection: $pocket, options: snap.pockets.map(\.name), title: { $0 }) }
            BudgetFormField(label: "Amount each time", trailing: chosen.map { "Up to \(token.text($0.perPaymentCap))" }) { BudgetAmountField(text: $amount) }
            BudgetFormField(label: "Pay to") { BudgetTextField(placeholder: "shop.near", text: $recipient, mono: true) }
            BudgetFormField(label: "Every") {
                HStack(spacing: 8) {
                    BudgetTextField(placeholder: "1", text: $every)
                    BudgetChip(title: "Days", on: !weeks) { weeks = false }
                    BudgetChip(title: "Weeks", on: weeks) { weeks = true }
                }
            }
            BudgetFormField(label: "How many times (optional)") { BudgetTextField(placeholder: "Until you cancel it", text: $times) }
            BudgetFormField(label: "Note (optional)") { BudgetTextField(placeholder: "Rent", text: $memo) }
            NoteBox(symbol: "info.circle", text: "The first payment is one interval from now. A missed payment is made once, never twice to catch up. If the pocket is paused, expired or over its daily limit, or the vault is short, that run waits.")
            if let error { Text(error).font(.system(size: 14)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(BudgetButton(kind: .primary, height: 56)).disabled(busy || chosen == nil)
        }
    }

    private func review() async {
        error = nil
        guard let p = chosen else { return }
        guard let a = try? token.parse(AmountText.clean(amount)), a > 0 else { error = "Enter the amount to pay each time."; return }
        guard let n = UInt64(every.trimmingCharacters(in: .whitespaces)), n > 0, n <= 3_650 else { error = "Enter how many days or weeks apart the payments are."; return }
        var count: UInt32?
        let t = times.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            guard let c = UInt32(t), c > 0 else { error = "Enter how many times it should run, or leave it empty."; return }
            count = c
        }
        let d = NearGuard.OrderDraft(pocket: p.name, amount: a, recipient: recipient.trimmingCharacters(in: .whitespaces).lowercased(),
                                     intervalSeconds: n * (weeks ? 604_800 : 86_400), remaining: count,
                                     memo: memo.trimmingCharacters(in: .whitespaces))
        busy = true
        defer { busy = false }
        error = await submit(.createOrder(d))
    }
}

// MARK: The key, shown once

struct GuardKeyBody: View {
    let key: IssuedKey
    let contract: String
    let done: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        SheetChrome(title: "Pocket key", subtitle: key.pocket) {
            NoteBox(symbol: "exclamationmark.triangle", text: "This is the only time you'll see this key. Hermit doesn't keep it. Anyone who has it can pay whatever the pocket allows, so hand it only to the app or agent it's for.", tint: Theme.red)
            VStack(alignment: .leading, spacing: 6) {
                Text("Private key").font(.system(size: 15, weight: .medium))
                Text(key.privateKey).font(.system(size: 13.5, design: .monospaced)).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
            }
            ButtonPair {
                Button("Copy key") { Clip.copy(key.privateKey); model.toast("Key copied") }.buttonStyle(BudgetButton(kind: .soft, height: 48))
            } second: {
                Button("Copy as key file") { Clip.copy(key.keyFile); model.toast("Key file copied") }.buttonStyle(BudgetButton(kind: .soft, height: 48))
            }
            NoteBox(symbol: "key", text: "On your account the key can only call spend and request on \(contract). It can't withdraw, freeze or change a rule. It pays its own network fees from a small budget and stops when that's used up. Paste it where it's going, then clear your clipboard.")
        } foot: {
            Button("I've saved it", action: done).buttonStyle(BudgetButton(kind: .green, height: 56))
        }
    }
}
