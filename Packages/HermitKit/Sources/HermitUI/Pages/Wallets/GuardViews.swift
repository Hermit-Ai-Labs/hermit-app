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

    /// The vault's figure: the first token it holds (in the contract's order), or its first token at zero when it holds
    /// nothing. Tokens can't be added up without prices, so the others are only counted.
    struct Figure: Equatable {
        let number: String
        let symbol: String
        let more: Int
    }

    static func figure(_ s: NearGuard.Snapshot, _ v: NearGuard.GuardVault) -> Figure? {
        let held = s.tokens.filter { v.balance($0.id) > 0 }
        guard let t = held.first ?? s.tokens.first else { return nil }
        return Figure(number: t.number(v.balance(t.id)), symbol: t.symbol, more: max(0, held.count - 1))
    }

    /// `part` as a share of `whole` for the spent-today line: 0 to 2 (over the limit shows as full and red).
    static func share(_ part: UInt128, of whole: UInt128) -> Double {
        // Both scaled down together until they fit a UInt64 (the ratio is all that's drawn), so nothing can overflow.
        var p = part, w = whole
        while w > (UInt128(1) << 62) { p >>= 10; w >>= 10 }
        guard w > 0 else { return 0 }
        return Double(UInt64(min(p, w * 2))) / Double(UInt64(w))
    }
}

// MARK: The card in Security

/// Wallets > Security, under the spending policy. Only there when Budgets exists in this build and the wallet has a NEAR account.
struct GuardBudgetsCard: View {
    let vm: WalletsViewModel
    let wallet: WalletAccount
    let open: (WalletSheet) -> Void
    @State private var state: Loaded = .loading
    private var reveal: GuardKeyReveal { .shared }

    enum Loaded: Equatable { case loading, failed, notSetUp, vault(frozen: Bool, pockets: Int, orders: Int, requests: Int, figure: GuardText.Figure?) }

    var body: some View {
        if GuardConfig.isEnabled, wallet.record.nearAccount != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    SectionLabel("Budgets")
                    Spacer(minLength: 6)
                    Button { open(.budgets(wallet: wallet.id)) } label: {
                        HStack(spacing: 4) {
                            Text(state == .notSetUp ? "Set up" : "Open")
                            Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(HoloPillButton())
                    .accessibilityLabel(state == .notSetUp ? "Set up Budgets" : "Open Budgets")
                }
                panel
                if let k = reveal.pending {
                    NoteBox(symbol: "key", text: "The key for the pocket \(k.pocket) hasn't been saved yet. Open Budgets to see it.", tint: Theme.amber)
                }
                Text(blurb).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .task(id: wallet.id) { await load() }
        }
    }

    private var blurb: String {
        "Give an app or agent a small budget with rules, held in a vault on NEAR."
    }

    /// The state in a line, the vault's figure on the right, then the counts in three columns. Same panel as the
    /// spending policy above it (subtle fill, hairline, 12 pt corners).
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(status).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) { GuardDot(color: dot) }
                Spacer(minLength: 8)
                if let f = figure { GuardFigure(number: f.number, symbol: f.symbol, size: 22, more: f.more) }
            }
            if let c = counts {
                Hairline()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        fact(c[0].0, c[0].1)
                        column
                        fact(c[1].0, c[1].1)
                        column
                        fact(c[2].0, c[2].1, tint: waiting ? Theme.accent : Theme.text)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline) {
                                Text(c[i].0).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                                Spacer(minLength: 8)
                                Text(c[i].1).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(i == 2 && waiting ? Theme.accent : Theme.text)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private var column: some View { Rectangle().fill(Theme.border).frame(width: 1).padding(.horizontal, 12) }

    private func fact(_ label: String, _ value: String, tint: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize()
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(tint).monospacedDigit().fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        switch state {
        case .loading: return "Checking"
        case .failed: return "Couldn't reach NEAR right now"
        case .notSetUp: return "Not set up"
        case .vault(let frozen, _, _, _, _): return frozen ? "Frozen" : "Running"
        }
    }

    private var dot: Color {
        switch state {
        case .loading, .notSetUp: return Theme.faint
        case .failed: return Theme.amber
        case .vault(let frozen, _, _, _, _): return frozen ? Theme.red : Theme.green
        }
    }

    private var figure: GuardText.Figure? {
        if case .vault(_, _, _, _, let f) = state { return f }
        return nil
    }

    private var waiting: Bool {
        if case .vault(_, _, _, let requests, _) = state { return requests > 0 }
        return false
    }

    private var counts: [(String, String)]? {
        guard case .vault(_, let pockets, let orders, let requests, _) = state else { return nil }
        return [("Pockets", "\(pockets)"), ("Standing orders", "\(orders)"),
                ("Waiting for you", requests == 0 ? "Nothing" : "\(requests) request\(requests == 1 ? "" : "s")")]
    }

    private func load() async {
        guard let id = vm.wallet(wallet.id)?.record.id else { return }
        do {
            let s = try await vm.service.nearGuardSnapshot(walletID: id)
            if let v = s.vault {
                state = .vault(frozen: v.frozen, pockets: v.pockets, orders: v.orders, requests: s.requests.count, figure: GuardText.figure(s, v))
            } else { state = .notSetUp }
        } catch { state = .failed }
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
            Button("Try again") { Task { await load() } }.buttonStyle(OutlineButton())
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading Budgets").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 14)
        }
    }

    private func emptyContent(_ s: NearGuard.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Put money in a vault on NEAR and give an app or an agent a pocket: a small budget with its own limits. It can pay only what the pocket allows, and you can freeze everything or take your money back at any time.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            NoteBox(symbol: "checkmark.shield", text: "Setting up costs a deposit of \(NearGuard.TokenInfo.near.number(s.storageCost)) NEAR for the vault's storage. You get it back when you close the vault.")
            NoteBox(symbol: "exclamationmark.triangle", text: "Budgets is new software on NEAR and hasn't been audited. Only keep in it what you're comfortable risking.", tint: Theme.amber)
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            Button { act(.openVault(storage: s.storageCost, initial: 0), id: "open") } label: {
                HStack(spacing: 6) {
                    if busy == "open" { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy == "open" ? "Checking" : "Set up Budgets")
                }
            }
            .buttonStyle(WideButton()).disabled(busy != nil)
        }
    }

    private func vaultContent(_ s: NearGuard.Snapshot, _ v: NearGuard.GuardVault) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            balancesSection(s, v)
            VStack(alignment: .leading, spacing: 10) {
                freezeRow(v)
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            }
            if !s.requests.isEmpty { requestsSection(s) }
            pocketsSection(s)
            ordersSection(s)
            receiptsSection(s)
            VStack(alignment: .leading, spacing: 12) {
                Hairline()
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 1)
                    Text("A pocket's key can only pay inside its limits. It can't withdraw, freeze or change a rule: only you can, with \(Device.bio).")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Button("Close Budgets and get the deposit back") { act(.closeVault, id: "close") }
                    .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.muted).underline().disabled(busy != nil)
            }
        }
        .padding(.top, 6)
    }

    /// Running or Frozen, what that means, and the one control that changes it. Red only once it's frozen.
    private func freezeRow(_ v: NearGuard.GuardVault) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(v.frozen ? "Frozen" : "Running").font(.system(size: 14, weight: .medium)).foregroundStyle(v.frozen ? Theme.red : Theme.text)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) { GuardDot(color: v.frozen ? Theme.red : Theme.green) }
                Spacer(minLength: 8)
                if v.frozen {
                    Button(busy == "freeze" ? "Checking" : "Unfreeze") { act(.setFrozen(false), id: "freeze") }.buttonStyle(GuardSolidButton()).disabled(busy != nil)
                } else {
                    Button(busy == "freeze" ? "Checking" : "Freeze everything") { act(.setFrozen(true), id: "freeze") }.buttonStyle(OutlineButton()).disabled(busy != nil)
                }
            }
            Text(v.frozen ? "Nothing can be paid: no pocket, no standing order, no approval. You can still withdraw."
                          : "Pockets can pay inside their limits and standing orders run.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(v.frozen ? Theme.red.opacity(0.05) : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(v.frozen ? Theme.red.opacity(0.3) : Theme.border))
    }

    /// The sheet's header: the vault's figure in the serif, then one row per token with Add and Withdraw.
    private func balancesSection(_ s: NearGuard.Snapshot, _ v: NearGuard.GuardVault) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GuardEyebrow(text: "In the vault")
            if let f = GuardText.figure(s, v) {
                GuardFigure(number: f.number, symbol: f.symbol, size: 30).padding(.top, 4).padding(.bottom, 12)
            }
            VStack(spacing: 0) {
                ForEach(s.tokens) { t in
                    let held = v.balance(t.id)
                    Hairline()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            tokenLabel(t)
                            Spacer(minLength: 8)
                            tokenAmount(t, held)
                            balanceButtons(t, held)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) { tokenLabel(t); Spacer(minLength: 8); tokenAmount(t, held) }
                            balanceButtons(t, held)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            if !s.unknownTokens.isEmpty {
                Text("\(s.unknownTokens.count) other token\(s.unknownTokens.count == 1 ? "" : "s") on the contract's list couldn't be read, so Hermit leaves them out.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            if v.pendingOut > 0 {
                Text("A payment is still on its way, so the balance may change in a moment.").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }

    private func tokenLabel(_ t: NearGuard.TokenInfo) -> some View {
        HStack(spacing: 10) {
            LogoMark(t.symbol.lowercased(), size: 22)
            Text(t.symbol).font(.system(size: 14, weight: .medium))
        }
    }

    private func tokenAmount(_ t: NearGuard.TokenInfo, _ held: UInt128) -> some View {
        Text(t.number(held)).font(.system(size: 14)).monospacedDigit().foregroundStyle(held == 0 ? Theme.hint : Theme.text)
            .accessibilityLabel(t.text(held))
    }

    private func balanceButtons(_ t: NearGuard.TokenInfo, _ held: UInt128) -> some View {
        HStack(spacing: 8) {
            Button("Add") { route = .fund(token: t.id, withdraw: false) }.buttonStyle(OutlineButton())
            Button("Withdraw") { route = .fund(token: t.id, withdraw: true) }.buttonStyle(OutlineButton()).disabled(held == 0)
        }
    }

    private func requestsSection(_ s: NearGuard.Snapshot) -> some View {
        GuardSection(title: "Waiting for you") {
            GuardChip(text: "\(s.requests.count)", color: Theme.accent)
        } content: {
            RowList(items: s.requests) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(GuardText.amount(s, r.token, r.amount)) to \(shortAddr(r.recipient, keep: 10))").font(.system(size: 14, weight: .medium)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Asked by the key of \(r.pocket). Expires \(GuardText.time(r.expiresNs)).").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !r.reason.isEmpty {
                        Text("\u{201C}\(r.reason)\u{201D}").font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(busy == "a\(r.id)" ? "Checking" : "Approve") { act(.approve(r.id), id: "a\(r.id)") }.buttonStyle(AccentButton()).disabled(busy != nil)
                        Button("Reject") { act(.reject(r.id), id: "r\(r.id)") }.buttonStyle(OutlineButton()).disabled(busy != nil)
                    }
                    .padding(.top, 6)
                }
                .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pocketsSection(_ s: NearGuard.Snapshot) -> some View {
        GuardSection(title: "Pockets") {
            Button("New pocket") { route = .pocket(.new) }.buttonStyle(OutlineButton()).disabled(s.pockets.count >= NearGuard.maxPockets)
        } content: {
            if s.pockets.isEmpty {
                EmptyNote(text: "No pockets yet. A pocket is a small budget with its own limits, for one app or agent.")
            } else {
                RowList(items: s.pockets) { p in pocketRow(p, s) }
            }
        }
    }

    private func pocketRow(_ p: NearGuard.GuardPocket, _ s: NearGuard.Snapshot) -> some View {
        let now = NearGuard.ns(Date())
        let t = s.token(p.token)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LogoMark((t?.symbol ?? p.token).lowercased(), size: 18)
                Text(p.name).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                switch p.state(nowNs: now) {
                case .paused: GuardChip(text: "Paused", color: Theme.amber)
                case .expired: GuardChip(text: "Expired", color: Theme.red)
                case .active: EmptyView()
                }
                if p.publicKey == nil { GuardChip(text: "No key", color: Theme.muted) }
                Spacer(minLength: 6)
                Menu {
                    Button("Edit", systemImage: "pencil") { route = .pocket(.edit(p.name)) }
                    Button(p.paused ? "Resume" : "Pause", systemImage: p.paused ? "play" : "pause") { act(.setPaused(name: p.name, paused: !p.paused), id: "p\(p.name)") }
                    Button("Remove", systemImage: "trash", role: .destructive) { act(.removePocket(name: p.name), id: "p\(p.name)") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(busy != nil)
                .accessibilityLabel("Actions for \(p.name)")
            }
            if let t {
                pocketSpend(p, t, now: now)
                Text("Up to \(t.text(p.perPaymentCap)) per payment, \(t.text(p.dailyCap)) a day").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Token \(shortAddr(p.token)), which Hermit can't read").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Text("Can pay: \(GuardText.recipients(p.allowedRecipients))" + (p.expiresAt.map { ". Expires \(GuardText.time($0))" } ?? ""))
                .font(.system(size: 12.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Spent today 1.2 of 5 NEAR" over a thin line that fills toward the daily limit.
    private func pocketSpend(_ p: NearGuard.GuardPocket, _ t: NearGuard.TokenInfo, now: UInt64) -> some View {
        let spent = p.spentToday(nowNs: now)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Spent today \(t.number(spent)) of \(t.text(p.dailyCap))").font(.system(size: 12.5)).foregroundStyle(Theme.text).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            GuardMeter(fraction: GuardText.share(spent, of: p.dailyCap))
        }
        .padding(.top, 2).padding(.bottom, 2)
    }

    private func ordersSection(_ s: NearGuard.Snapshot) -> some View {
        GuardSection(title: "Standing orders") {
            if s.pockets.isEmpty {
                // Nothing to press yet: an order pays from a pocket, so say what comes first instead of a dead button.
                Label("Needs a pocket", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.hint)
                    .labelStyle(.titleAndIcon)
            } else {
                let full = s.orders.count >= NearGuard.maxOrders
                Button(full ? "Limit reached" : "New order") { route = .order }
                    .buttonStyle(OutlineButton()).disabled(full || busy != nil)
            }
        } content: {
            if s.orders.isEmpty {
                EmptyNote(text: s.pockets.isEmpty ? "Make a pocket first. A standing order pays from a pocket on a schedule."
                                                  : "No standing orders. An order pays the same amount to the same address on a schedule, even when your phone is off.")
            } else {
                RowList(items: s.orders) { o in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(GuardText.amount(s, o.token, o.amount)) to \(shortAddr(o.recipient, keep: 10))").font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(GuardText.sentence(NearGuard.everyText(o.intervalSeconds))), from \(o.pocket). Next \(GuardText.time(o.nextDueNs))"
                                 + (o.remaining.map { ", \($0) left" } ?? ""))
                                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            if !o.memo.isEmpty { Text(o.memo).font(.system(size: 12.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 8)
                        Button(busy == "o\(o.id)" ? "Checking" : "Cancel") { act(.cancelOrder(o.id), id: "o\(o.id)") }.buttonStyle(OutlineButton()).disabled(busy != nil)
                    }
                    .padding(.vertical, 12)
                }
                Text("Orders run on NEAR even when your phone is off. A due order is paid when someone triggers it, and only inside the pocket's limits.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }

    /// A ledger: who and how on the left, the amount on the right in even-width digits. Red only for a failed payment.
    private func receiptsSection(_ s: NearGuard.Snapshot) -> some View {
        let shown = allReceipts ? s.receipts : Array(s.receipts.prefix(8))
        return GuardSection("Payments") {
            if s.receipts.isEmpty {
                EmptyNote(text: "Nothing has been paid from the vault yet.")
            } else {
                RowList(items: shown) { r in receiptRow(r, s) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("The contract keeps the last \(NearGuard.maxReceipts) payments.").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if s.receipts.count > 8 {
                        Button(allReceipts ? "Show fewer" : "Show all \(s.receipts.count)") { withAnimation(.smooth) { allReceipts.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func receiptRow(_ r: NearGuard.GuardReceipt, _ s: NearGuard.Snapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("To \(shortAddr(r.recipient, keep: 10))").font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                Text(receiptLine(r)).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if !r.reason.isEmpty {
                    Text("\u{201C}\(r.reason)\u{201D}").font(.system(size: 12.5)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
                }
                if !r.ok { GuardChip(text: "Failed, refunded", color: Theme.red).padding(.top, 2) }
            }
            Spacer(minLength: 8)
            Text(GuardText.amount(s, r.token, r.amount)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                .foregroundStyle(r.ok ? Theme.text : Theme.red).strikethrough(!r.ok, color: Theme.red)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
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
            FormField(label: "Amount", trailing: trailing) { AmountTextField(text: $amount) }
            WrapRow {
                ForEach([("25%", UInt128(1)), ("50%", UInt128(2))], id: \.0) { q in
                    let t = GuardText.part(limit, q.1, of: 4, token)
                    SelectChip(title: q.0, on: amount == t && limit > 0) { amount = t }
                }
                let all = GuardText.part(limit, 1, of: 1, token)
                SelectChip(title: withdraw ? "All" : "Max", on: amount == all && limit > 0) { amount = all }
            }
            if let v = value, v > limit, withdraw || most != nil {
                Text(withdraw ? "The vault holds \(token.text(vaultHeld))." : "You can add up to \(token.text(limit)).").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            if withdraw {
                NoteBox(symbol: "arrow.down.to.line", text: "Withdrawing always works, also while Budgets is frozen. It only ever goes to your own account.")
            } else if token.isNative {
                NoteBox(symbol: "info.circle", text: "Hermit keeps \(NearGuard.TokenInfo.near.number(NearGuard.reserve)) NEAR in your account for fees.")
            } else {
                NoteBox(symbol: "info.circle", text: "\(token.symbol) goes in through the token's own transfer. If the contract can't take it, the token sends it back and Hermit tells you.")
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(WideButton()).disabled(!canReview)
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
                FormField(label: "Name") { BoxedTextField(placeholder: "Coffee", text: $name) }
                if snap.tokens.count > 1 {
                    FormField(label: "Token") { MenuField(selection: $tokenID, options: snap.tokens.map(\.id), title: { snap.token($0)?.symbol ?? $0 }) }
                }
            } else {
                FormField(label: "Token") { Text(token.symbol).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading) }
            }
            FormField(label: "Most per payment", trailing: token.symbol) { AmountTextField(text: $perPayment) }
            FormField(label: "Most per day", trailing: token.symbol) { AmountTextField(text: $daily) }
            FormField(label: "Can pay (optional)") { BoxedTextField(placeholder: "Anyone, or shop.near, bob.near", text: $recipients, mono: true) }
            FormField(label: "Expires") { MenuField(selection: $expiry, options: expiryOptions, title: { $0 }) }
            if !editing {
                FormField(label: "Key") {
                    WrapRow {
                        SelectChip(title: "Make a key", on: withKey) { withKey = true }
                        SelectChip(title: "No key", on: !withKey) { withKey = false }
                    }
                }
                NoteBox(symbol: "key", text: withKey
                        ? "Hermit makes a key for an app or an agent and shows it once. It can only pay inside this pocket's limits."
                        : "Without a key, only standing orders can pay from this pocket.")
            }
            NoteBox(symbol: "info.circle", text: "A day is a fixed 24 hours from the first payment. Around the edge of two days, up to twice the daily limit can go out.")
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(WideButton()).disabled(busy || (!editing && name.trimmingCharacters(in: .whitespaces).isEmpty))
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
            FormField(label: "From pocket") { MenuField(selection: $pocket, options: snap.pockets.map(\.name), title: { $0 }) }
            FormField(label: "Amount each time", trailing: chosen.map { "Up to \(token.text($0.perPaymentCap))" }) { AmountTextField(text: $amount) }
            FormField(label: "Pay to") { BoxedTextField(placeholder: "shop.near", text: $recipient, mono: true) }
            FormField(label: "Every") {
                HStack(spacing: 8) {
                    BoxedTextField(placeholder: "1", text: $every)
                    SelectChip(title: "Days", on: !weeks) { weeks = false }
                    SelectChip(title: "Weeks", on: weeks) { weeks = true }
                }
            }
            FormField(label: "How many times (optional)") { BoxedTextField(placeholder: "Until you cancel it", text: $times) }
            FormField(label: "Note (optional)") { BoxedTextField(placeholder: "Rent", text: $memo) }
            NoteBox(symbol: "info.circle", text: "The first payment is one interval from now. A missed payment is made once, never twice to catch up. If the pocket is paused, expired or over its daily limit, or the vault is short, that run waits.")
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(WideButton()).disabled(busy || chosen == nil)
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
                Text("Private key").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Text(key.privateKey).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            }
            ButtonPair {
                Button("Copy key") { Clip.copy(key.privateKey); model.toast("Key copied") }.buttonStyle(OutlineButton())
            } second: {
                Button("Copy as key file") { Clip.copy(key.keyFile); model.toast("Key file copied") }.buttonStyle(OutlineButton())
            }
            NoteBox(symbol: "key", text: "On your account the key can only call spend and request on \(contract). It can't withdraw, freeze or change a rule. It pays its own network fees from a small budget and stops when that's used up. Paste it where it's going, then clear your clipboard.")
        } foot: {
            Button("I've saved it", action: done).buttonStyle(WideButton())
        }
    }
}
