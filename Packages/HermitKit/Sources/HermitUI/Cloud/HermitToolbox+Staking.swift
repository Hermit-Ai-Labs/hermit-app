import Foundation
import HermitCore
import HermitWallet

// NEAR staking for the assistant. The on-device models were trained on a fixed tool list, so there is no staking tool:
// prepare_deposit with NEAR as the asset prepares a stake, prepare_withdraw with NEAR prepares an unstake (or a
// withdrawal when NEAR is ready), and get_positions and get_portfolio list what's staked. `NearStaking.handles` in
// HermitWallet decides the routing. Like every money tool these only prepare a review: a stake runs the spending policy
// as the assistant (the per-move cap, the daily limit, no unpriced moves) before anything opens, and the user approves
// with Face ID or Touch ID.

extension HermitToolbox {
    /// A positive amount of NEAR from a tool call, in yocto. nil when the call gave none.
    static func nearAmount(_ a: [String: Any]) throws -> (value: UInt128, number: Double)? {
        guard let n = (a["amount"] as? NSNumber)?.doubleValue ?? (a["amount"] as? String).flatMap(Double.init) else { return nil }
        guard n.isFinite, n > 0, let v = try? Units.parse(String(format: "%.6f", n), decimals: 24), v > 0 else { throw ToolError("Not a valid amount") }
        return (v, n)
    }

    /// The reason a review was refused, as a tool result the model can repeat.
    static func stakingRefusal(_ e: Error) -> ToolOutcome? {
        guard let w = e as? WalletError, case .blocked(let why) = w else { return nil }
        return json(["status": "blocked", "prepared": false, "reasons": [why], "note": "Nothing was prepared. Tell the user why."])
    }

    /// prepare_deposit for NEAR: a stake with a validator. The pool is one the call names from Hermit's list, else the
    /// one this wallet already stakes with, else the first on the list; the assistant can't point a stake anywhere else.
    @MainActor static func prepareStake(_ a: [String: Any], label: String?) async throws -> ToolOutcome {
        let symbol = ToolsV3.text(a, "symbol").uppercased()
        guard symbol.isEmpty || symbol == "NEAR" else {
            return json(["status": "unsupported", "prepared": false, "note": "On NEAR, Hermit can only stake NEAR itself. Tell the user."])
        }
        guard let amount = try nearAmount(a) else { throw ToolError("Needs a positive amount of NEAR") }
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        guard w.record.nearAccount != nil else {
            return json(["status": "unsupported", "prepared": false, "note": "This wallet has no NEAR account yet. The user can add one in Wallets."])
        }
        let vm = WalletsViewModel.shared, svc = vm.service
        let network = try await svc.nearStakingNetwork()
        var named = ToolsV3.text(a, "project").lowercased()
        if named.isEmpty { named = ToolsV3.text(a, "pool").lowercased() }
        var picked = network.pools.first(where: { $0.id == named || $0.name == named })?.id
        if picked == nil {
            let mine = await svc.nearStakingPositions(wallets: [w.record]).positions
            picked = mine.first(where: { $0.balance.staked > NearStaking.dust && $0.pool.hasSuffix(".poolv1.near") })?.pool
        }
        guard let pool = picked ?? network.pools.first?.id else { throw ToolError("Couldn't read NEAR's validators right now") }
        let review: NearStaking.Review
        do {
            review = try await svc.prepareNearStaking(walletID: w.record.id, pool: pool, move: .stake(amount.value), origin: .agent)
        } catch {
            if let refused = stakingRefusal(error) { return refused }
            throw error
        }
        var out: [String: Any] = ["status": "review_opened", "kind": "deposit", "executed": false, "pool": "NEAR staking with \(pool)",
                                  "amount": "\(Units.approx(amount.number)) NEAR", "unstake_wait": network.unlockText,
                                  "note": "Waiting for the user to review the stake and approve it with \(Device.bio). Getting it back means unstaking, waiting \(network.unlockText), then withdrawing."]
        if let listed = network.pools.first(where: { $0.id == pool }) {
            out["fee_pct"] = ToolsV3.r2(listed.fee.fraction * 100)
            if let apr = listed.estimatedAPR {
                out["apy_pct"] = ToolsV3.r2(apr * 100)
                out["rate_note"] = "apy_pct is an estimate from the last epoch's rewards, after the validator's fee. Say it's an estimate."
            }
        }
        if !review.warnings.isEmpty { out["warnings"] = review.warnings }
        if vm.wallets.count > 1 { out["wallet"] = w.name }
        var o = json(out)
        o.action = Action("Review stake", approval: NearStakeText.approval(review, label: label))
        return o
    }

    /// prepare_withdraw for NEAR. With no amount, NEAR that's ready is withdrawn; otherwise the stake is unstaked (all
    /// of it, or `amount`), which starts the wait. Neither sends money anywhere but the user's own account.
    @MainActor static func prepareUnstake(_ a: [String: Any], label: String) async throws -> ToolOutcome {
        let symbol = ToolsV3.text(a, "symbol").uppercased()
        guard symbol.isEmpty || symbol == "NEAR" else {
            return json(["status": "nothing_to_withdraw", "prepared": false, "note": "On NEAR, Hermit only stakes NEAR itself. Tell the user."])
        }
        let amount = try nearAmount(a)
        let vm = WalletsViewModel.shared, svc = vm.service
        guard !vm.wallets.isEmpty else { throw ToolError("No wallet on \(Device.here) yet") }
        let (all, failed) = await svc.nearStakingPositions(wallets: vm.wallets.map(\.record))
        let wait = (try? await svc.nearStakingNetwork())?.unlockText ?? "\(NearStaking.unlockEpochs) epochs"
        func named(_ p: NearStaking.Position) -> String {
            NearStaking.poolName(p.pool) + (vm.wallets.count > 1 ? " (\(vm.wallet(p.walletID.uuidString)?.name ?? "wallet"))" : "")
        }
        let position: NearStaking.Position, move: NearStaking.Move
        switch NearStaking.exit(all, amount: amount?.value) {
        case .nothing:
            var o: [String: Any] = ["status": "nothing_to_withdraw", "prepared": false, "note": "The user has no NEAR staked. Tell them."]
            if failed { o["unreachable"] = ["near"]; o["note"] = "Couldn't read the user's NEAR stakes right now, so nothing was prepared. Tell them to try again." }
            return json(o)
        case .waiting(let ps):
            let total = ps.reduce(UInt128(0)) { $0 + $1.balance.unstaking }
            return json(["status": "nothing_to_withdraw", "prepared": false, "unstaking": "\(NearStaking.near(total)) NEAR",
                         "note": "The user's NEAR is still unstaking. It can be withdrawn \(wait) after the unstake. Nothing was prepared. Tell them."])
        case .choose(let ps):
            return json(["status": "needs_choice", "prepared": false,
                         "question": "Which validator? " + ps.map { p in
                             let b = p.balance
                             return "\(named(p)): " + (b.ready > 0 && amount == nil ? "\(NearStaking.near(b.ready)) NEAR ready" : "\(NearStaking.near(b.staked)) NEAR staked")
                         }.joined(separator: ", ") + ".",
                         "note": "Nothing was prepared. Ask the user which one."])
        case .tooMuch(let p):
            return json(["status": "insufficient", "prepared": false, "supplied": "\(NearStaking.near(p.balance.staked)) NEAR",
                         "note": "Only \(NearStaking.near(p.balance.staked)) NEAR is staked with \(named(p)). Tell the user."])
        case .withdraw(let p): position = p; move = .withdraw
        case .unstake(let p, let v): position = p; move = .unstake(v)
        }
        let review: NearStaking.Review
        do {
            review = try await svc.prepareNearStaking(walletID: position.walletID, pool: position.pool, move: move, origin: .agent)
        } catch {
            if let refused = stakingRefusal(error) { return refused }
            throw error
        }
        var out: [String: Any] = ["status": "review_opened", "kind": "withdraw", "executed": false, "pool": "NEAR staking with \(position.pool)",
                                  "amount": "\(NearStaking.near(review.amount)) NEAR"]
        if move == .withdraw {
            out["step"] = "withdraw"
            out["note"] = "This NEAR finished unstaking. Waiting for the user to approve the withdrawal to their own account with \(Device.bio)."
        } else {
            out["step"] = "unstake"
            out["unstake_wait"] = wait
            out["note"] = "This only starts unstaking: the NEAR can be withdrawn \(wait) after the user approves, and earns nothing meanwhile. Say so. Waiting for the user to approve with \(Device.bio)."
        }
        if !review.warnings.isEmpty { out["warnings"] = review.warnings }
        var o = json(out)
        o.action = Action(move == .withdraw ? "Review withdrawal" : "Review unstake", approval: NearStakeText.approval(review, label: label))
        return o
    }

    /// get_positions rows for staked NEAR, next to the Aave ones. `apy_pct` is the estimate for pools on Hermit's list
    /// and null for the rest.
    static func stakingRows(_ positions: [NearStaking.Position], pools: [NearStaking.Pool]) -> [[String: Any]] {
        positions.map { p in
            var row: [String: Any] = ["symbol": "NEAR", "chain": "near", "kind": "staking", "pool": p.pool,
                                      "amount": NearStaking.near(p.balance.staked), "apy_pct": NSNull()]
            if let apr = pools.first(where: { $0.id == p.pool })?.estimatedAPR { row["apy_pct"] = ToolsV3.r2(apr * 100); row["apy_is_estimate"] = true }
            if p.balance.unstaking > 0 { row["unstaking"] = NearStaking.near(p.balance.unstaking) }
            if p.balance.ready > 0 { row["ready_to_withdraw"] = NearStaking.near(p.balance.ready) }
            return row
        }
    }
}
