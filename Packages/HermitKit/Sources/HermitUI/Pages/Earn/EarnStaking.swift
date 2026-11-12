import SwiftUI
import Observation
import HermitCore
import HermitWallet

// Stake NEAR in Earn: the validator list in Savings, what's staked in Your deposits, and the Stake and Unstake sheets.
// Every number on these screens is read from NEAR when the screen opens: the validator set, each pool's fee, the
// wallet's balance in the pool and how long an epoch takes. The checks live in HermitWallet/NearStaking.swift.

/// The Stake NEAR sheet that's open. EarnPage presents it, so the approval sheet can follow it.
@MainActor @Observable
final class NearStakeFlow {
    static let shared = NearStakeFlow()
    var request: Request?

    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// nil stakes; a position unstakes from it.
        var unstake: NearStaking.Position?
        var walletID: String?
        var pool: String?
        var amount: String?
    }

    /// Opens Earn on the Stake sheet (from the NEAR account card in Wallets).
    static func stake(wallet: String?, model: AppModel) {
        shared.request = Request(walletID: wallet)
        model.open(.earn, tab: "save")
    }
}

enum NearStakeText {
    /// "33.4M NEAR staked".
    static func staked(_ yocto: UInt128) -> String {
        (Double(NearStaking.near(yocto)) ?? 0).tradeCompactUSD.replacingOccurrences(of: "$", with: "") + " NEAR staked"
    }
    /// The amount a chip writes: a share of `most`, cut to five decimals so it never tops it.
    static func part(_ most: UInt128, _ share: UInt128, of whole: UInt128) -> String { NearStaking.near(most / whole * share) }
    static func message(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? e.localizedDescription }

    /// The approval sheet for a checked move. Approve signs it on this device and waits for NEAR to run it; a failed
    /// transaction or receipt shows as a failure, like any NEAR send.
    @MainActor static func approval(_ r: NearStaking.Review, label: String? = nil) -> Approval {
        let vm = WalletsViewModel.shared, svc = vm.service
        var lines = r.lines
        if vm.wallets.count > 1, let name = vm.wallet(r.walletID.uuidString)?.name { lines.insert(["Wallet", name], at: 0) }
        if let label { lines.append(["Asked for by", "\(label), from your message"]) }
        return Approval(kind: r.kind, title: r.title, lines: lines,
                        checks: r.checks + ["Signed on \(Device.here) with your wallet's key"],
                        success: r.success, warnings: r.warnings) {
            let hash = try await svc.executeNearStaking(r)
            Task { @MainActor in await WalletsViewModel.shared.refresh() }
            return hash
        }
    }
}

// MARK: Savings: the validator list

/// Stake NEAR, under the lending pools in Savings: a short list of big, active validators with the fee each pool
/// charges, read from the pool itself. The rate is an estimate from last epoch's rewards and is labelled as one.
struct EarnStakeNear: View {
    @Environment(AppModel.self) private var model
    @State private var network: NearStaking.Network?
    @State private var failed = false
    private var vm: WalletsViewModel { .shared }

    private var hasAccount: Bool { vm.wallets.contains { $0.record.nearAccount != nil } }
    private var heldNear: Double { vm.holdings(wallet: nil, chain: .near).filter { $0.symbol == Chain.near.nativeSymbol }.reduce(0) { $0 + $1.amount } }

    var body: some View {
        TradeSection(title: "Stake NEAR") {
            VStack(alignment: .leading, spacing: 0) {
                Text("Stake NEAR with a validator and earn the network's rewards, less the validator's fee. To get it back you unstake, wait \(network?.unlockText ?? "\(NearStaking.unlockEpochs) epochs"), then withdraw.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
                if !vm.hasWallet {
                    TradeEmpty(icon: "leaf", title: "No wallet yet", note: "Create a wallet, then stake NEAR from here.")
                } else if !hasAccount {
                    TradeEmpty(icon: "leaf", title: "No NEAR account yet", note: "Add a NEAR account to your wallet in Wallets, then stake from here.",
                               action: ("Open Wallets", { model.open(.wallets) }))
                } else if vm.loaded && heldNear == 0 {
                    TradeEmpty(icon: "leaf", title: "No NEAR to stake yet", note: "Add NEAR to your wallet, or swap into it from another chain. Then pick a validator here.",
                               action: ("Add NEAR", { model.fundGoal = .token(.near, Chain.near.nativeSymbol) }))
                } else if let network {
                    if network.pools.isEmpty {
                        MarketStatus(kind: .failed("Couldn't read the validators' fees")) { Task { await load(force: true) } }
                    }
                    TradeRows(data: network.pools) { p in row(p) }
                    if !network.pools.isEmpty {
                        MarketSource(text: "The biggest active validators with a fee of \(NearStaking.percent(NearStaking.maxListedFee)) or less, read from NEAR just now. "
                                     + (network.networkAPR == nil ? "" : "Rates are an estimate from last epoch's rewards, after the fee; they change. ")
                                     + "A validator can change its fee.")
                            .padding(.top, 10)
                    }
                } else if failed {
                    MarketStatus(kind: .failed("Couldn't reach NEAR")) { Task { await load(force: true) } }
                } else {
                    MarketStatus(kind: .loading("Reading NEAR's validators"))
                }
            }
        }
        .task { await load(force: false) }
    }

    private func row(_ p: NearStaking.Pool) -> some View {
        HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo("NEAR"), name: "NEAR")
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(["\(p.fee.text) fee", NearStakeText.staked(p.stake)].joined(separator: ", "))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let apr = p.estimatedAPR {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(NearStaking.percent(apr)).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.green)
                    Text("a year, est.").font(.system(size: 12)).foregroundStyle(Theme.hint)
                }
                .monospacedDigit()
            }
            Button("Stake") { NearStakeFlow.shared.request = .init(pool: p.id) }.buttonStyle(TradeSmallButton(kind: .primary))
        }
        .padding(.vertical, 12)
    }

    private func load(force: Bool) async {
        guard vm.hasWallet, hasAccount else { return }
        failed = false
        do { network = try await vm.service.nearStakingNetwork(force: force) } catch { failed = network == nil }
    }
}

// MARK: Your deposits: what's staked

/// Every wallet's NEAR stakes, read from the pool contracts: staked, unstaking and ready to withdraw, with Unstake and
/// Withdraw. Nothing here is sample data.
struct EarnStakedNear: View {
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @State private var rows: [NearStaking.Position] = []
    @State private var failed = false
    @State private var loaded = false
    @State private var busy: String?
    @State private var error: String?
    private var vm: WalletsViewModel { .shared }

    private var hasAccount: Bool { vm.wallets.contains { $0.record.nearAccount != nil } }

    var body: some View {
        TradeSection(title: "NEAR staking") {
            if !hasAccount {
                MarketStatus(kind: .empty("No NEAR account yet"))
            } else if !loaded {
                MarketStatus(kind: .loading("Reading your NEAR stakes"))
            } else if rows.isEmpty && !failed {
                TradeEmpty(icon: "leaf", title: "No NEAR staked yet", note: "Pick a validator under Stake NEAR in Savings, or ask Hermit to stake. It shows here, earning.")
            }
            ForEach(rows) { r in row(r) }
            if loaded && failed {
                MarketStatus(kind: .failed("Couldn't read every staking pool, so some stakes may be missing")) { Task { await load() } }
            }
            if loaded && !rows.isEmpty {
                MarketSource(text: "Balances come from each pool's contract and include rewards so far. Unstaked NEAR can be withdrawn after \(NearStaking.unlockEpochs) epochs.")
                    .padding(.top, 6)
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
        }
        .task(id: vm.wallets.map(\.id)) { await load() }
        .onChange(of: model.approvalCount) { _, _ in Task { await load() } }
    }

    private func row(_ r: NearStaking.Position) -> some View {
        let b = r.balance
        var parts: [String] = []
        if b.unstaking > 0 { parts.append("\(NearStaking.near(b.unstaking)) unstaking") }
        if b.ready > 0 { parts.append("\(NearStaking.near(b.ready)) ready to withdraw") }
        if vm.wallets.count > 1, let name = vm.wallet(r.walletID.uuidString)?.name { parts.append(name) }
        return HStack(spacing: 12) {
            MarketLogo(key: TradeData.logo("NEAR"), name: "NEAR", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(NearStaking.poolName(r.pool)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(parts.isEmpty ? "Staked" : parts.joined(separator: ", "))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("\(NearStaking.near(b.staked)) NEAR").font(.system(size: 14, weight: .medium)).monospacedDigit()
            if b.ready > 0 {
                Button(busy == r.id ? "Checking" : "Withdraw") { withdraw(r) }.buttonStyle(TradeSmallButton(kind: .primary)).disabled(busy != nil)
            }
            if b.staked > NearStaking.dust {
                Button("Unstake") { NearStakeFlow.shared.request = .init(unstake: r) }.buttonStyle(TradeSmallButton()).disabled(busy != nil)
            }
        }
        .padding(.vertical, 11)
    }

    private func load() async {
        guard hasAccount else { rows = []; loaded = true; return }
        let r = await vm.service.nearStakingPositions(wallets: vm.wallets.map(\.record))
        withAnimation(.smooth) { rows = r.positions; failed = r.failed; loaded = true }
    }

    private func withdraw(_ r: NearStaking.Position) {
        busy = r.id; error = nil
        Task {
            defer { busy = nil }
            do {
                let review = try await vm.service.prepareNearStaking(walletID: r.walletID, pool: r.pool, move: .withdraw, origin: .user)
                ask(NearStakeText.approval(review)) { Task { await load(); await vm.refresh() } }
            } catch { self.error = NearStakeText.message(error) }
        }
    }
}

// MARK: The Stake and Unstake sheet

/// Stake: pick a validator and an amount, then the review. Unstake: an amount of what's staked in one pool. The review
/// is checked against the chain (HermitWallet's `prepareNearStaking`) and signed with Face ID on the approval sheet.
struct NearStakeSheet: View {
    let request: NearStakeFlow.Request
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @State private var amount: String
    @State private var walletID: String
    @State private var pool: String
    @State private var network: NearStaking.Network?
    /// The account's available balance: what NEAR reports, less what storage holds. nil until it's read.
    @State private var state: NearClient.AccountState?
    @State private var stateLoaded = false
    @State private var busy = false
    @State private var error: String?
    private var vm: WalletsViewModel { .shared }

    init(request: NearStakeFlow.Request) {
        self.request = request
        let vm = WalletsViewModel.shared
        let nearWallets = vm.wallets.filter { $0.record.nearAccount != nil }
        let selected = vm.service.selected?.id.uuidString
        let fallback = nearWallets.contains(where: { $0.id == selected }) ? selected : nearWallets.first?.id
        let first = request.unstake?.walletID.uuidString ?? request.walletID ?? fallback ?? vm.firstWalletID ?? ""
        _walletID = State(initialValue: first)
        _amount = State(initialValue: request.amount ?? "")
        _pool = State(initialValue: request.unstake?.pool ?? request.pool ?? "")
    }

    private var unstaking: NearStaking.Position? { request.unstake }
    private var wallets: [WalletAccount] { vm.wallets.filter { $0.record.nearAccount != nil } }
    private var account: String? { vm.wallet(walletID)?.record.nearAccount }
    /// The most this sheet will take: the stake limit (fee and reserve kept back), or what's staked in the pool.
    private var most: UInt128 { unstaking?.balance.staked ?? NearStaking.maxStake(available: state?.available ?? 0) }
    private var value: UInt128? { try? Units.parse(AmountText.clean(amount), decimals: 24) }
    private var chosen: NearStaking.Pool? { network?.pools.first { $0.id == pool } }
    private var wait: String { network?.unlockText ?? "\(NearStaking.unlockEpochs) epochs" }
    private var canReview: Bool {
        guard let v = value, v > 0, v <= most, !busy, !pool.isEmpty else { return false }
        return unstaking != nil || v >= NearStaking.minimumStake
    }

    var body: some View {
        SheetChrome(title: unstaking == nil ? "Stake NEAR" : "Unstake NEAR",
                    subtitle: unstaking.map { "From \(NearStaking.poolName($0.pool))" } ?? "Earn NEAR's staking rewards with a validator") {
            if unstaking == nil, wallets.count > 1 {
                FormField(label: "From") {
                    MenuField(selection: $walletID, options: wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 },
                              symbol: { vm.wallet($0)?.symbol })
                }
            }
            if unstaking == nil {
                if let network, !network.pools.isEmpty {
                    FormField(label: "Validator", trailing: chosen?.estimatedAPR.map { "About \(NearStaking.percent($0)) a year, est." }) {
                        MenuField(selection: $pool, options: network.pools.map(\.id),
                                  title: { id in network.pools.first(where: { $0.id == id }).map { "\($0.name), \($0.fee.text) fee" } ?? NearStaking.poolName(id) })
                    }
                } else if !pool.isEmpty {
                    FormField(label: "Validator") { Text(NearStaking.poolName(pool)).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            FormField(label: "Amount", trailing: trailing) { AmountTextField(text: $amount) }
            WrapRow {
                ForEach([("25%", UInt128(1)), ("50%", UInt128(2))], id: \.0) { q in
                    let t = NearStakeText.part(most, q.1, of: 4)
                    SelectChip(title: q.0, on: amount == t && most > 0) { amount = t }
                }
                let all = NearStakeText.part(most, 1, of: 1)
                SelectChip(title: unstaking == nil ? "Max" : "All", on: amount == all && most > 0) { amount = all }
            }
            if unstaking == nil {
                if account == nil {
                    NoteBox(symbol: "info.circle", text: "This wallet has no NEAR account yet. Add one in Wallets first.")
                } else if stateLoaded && most < NearStaking.minimumStake {
                    NoteBox(symbol: "arrow.down.to.line", text: "You have no NEAR to stake yet. Add some first: Hermit keeps \(NearStaking.near(NearStaking.reserve)) NEAR in the account for fees.")
                } else if let v = value, v > most, stateLoaded {
                    Text("You can stake up to \(NearStaking.near(most)) NEAR.").font(.system(size: 12.5)).foregroundStyle(Theme.red)
                }
                NoteBox(symbol: "info.circle", text: "Staked NEAR earns the network's rewards, less the validator's fee"
                        + (chosen.map { " (\($0.fee.text) now, and the validator can change it)" } ?? "")
                        + ". To get it back you unstake, wait \(wait), then withdraw. It earns nothing while it waits.")
                NoteBox(symbol: "checkmark.shield", text: "Hermit keeps \(NearStaking.near(NearStaking.reserve)) NEAR in your account, so you can always pay to unstake and withdraw.")
            } else {
                if let v = value, v > most {
                    Text("Only \(NearStaking.near(most)) NEAR is staked here.").font(.system(size: 12.5)).foregroundStyle(Theme.red)
                }
                NoteBox(symbol: "clock", text: "Unstaked NEAR is ready to withdraw after \(wait), and earns nothing while it waits. Unstaking again before then starts the wait over for all of it.")
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            if unstaking == nil, account != nil, stateLoaded, most < NearStaking.minimumStake {
                Button("Add NEAR") {
                    NearStakeFlow.shared.request = nil
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); model.fundGoal = .token(.near, Chain.near.nativeSymbol) }
                }
                .buttonStyle(WideButton())
            } else {
                Button { Task { await review() } } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(busy ? "Checking" : "Review")
                    }
                }
                .buttonStyle(WideButton()).disabled(!canReview)
            }
        }
        .task(id: walletID) { await load() }
    }

    private var trailing: String {
        if let u = unstaking { return "\(NearStaking.near(u.balance.staked)) NEAR staked" }
        guard stateLoaded else { return "Reading your balance" }
        return "\(NearStaking.near(state?.available ?? 0)) NEAR available"
    }

    private func load() async {
        stateLoaded = false; error = nil
        let service = vm.service
        async let networkA = try? service.nearStakingNetwork()
        do {
            if let a = account { state = try await service.nearAccountState(a) } else { state = nil }
            stateLoaded = true
        } catch {
            // The balance is unknown, not zero: the sheet keeps "Reading your balance" and Review stays off.
            state = nil
            self.error = "Couldn't reach NEAR right now. Close this and try again."
        }
        network = await networkA
        // The first validator on the list, unless the sheet was opened for one.
        if unstaking == nil, pool.isEmpty, let first = network?.pools.first { pool = first.id }
    }

    private func review() async {
        guard let w = vm.wallet(walletID), let v = value else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let move: NearStaking.Move
            if let u = unstaking {
                // "All" unstakes with unstake_all, so nothing is left behind by rounding.
                move = .unstake(amount == NearStakeText.part(u.balance.staked, 1, of: 1) ? nil : v)
            } else {
                move = .stake(v)
            }
            let r = try await vm.service.prepareNearStaking(walletID: w.record.id, pool: pool, move: move, origin: .user)
            ask(NearStakeText.approval(r)) { Task { await vm.refresh() } }
        } catch {
            self.error = NearStakeText.message(error)
        }
    }
}
