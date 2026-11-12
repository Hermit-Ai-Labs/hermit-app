import Foundation

// Native NEAR staking: delegating to a validator through its staking pool contract (near/core-contracts, staking-pool).
// Every method name, argument and number below was checked against mainnet on 2026-11-12 with read-only RPC calls and
// against the contract source:
//   deposit_and_stake {}            payable, stakes the attached NEAR
//   unstake {"amount": "<yocto>"}   unstake_all {}   withdraw_all {}
//   get_account {"account_id"} -> {account_id, unstaked_balance, staked_balance, can_withdraw}
//   get_reward_fee_fraction {} -> {numerator, denominator}      is_staking_paused {} -> bool
// Unstaked NEAR can be withdrawn NUM_EPOCHS_TO_UNLOCK = 4 epochs after the last unstake. An epoch is 43,200 blocks,
// which took 6.9 hours when measured, so the wait is read from the chain each time and never written down here.

public enum NearStaking {
    /// Gas attached to each call. Real mainnet calls attach 28 to 300 Tgas and burn 3 to 28 (deposit_and_stake burns
    /// the most: it pings the pool, restakes and reserves 20 Tgas for its callback). What isn't used is refunded.
    public static let gas: UInt64 = 100 * NearAction.tgas
    /// The most a call can cost: its gas at twice mainnet's gas price, the same ceiling NEAR sends show.
    public static let feeCeiling: UInt128 = UInt128(gas) * 200_000_000
    /// NEAR that always stays in the account after a stake (0.05), so there's gas left to unstake and withdraw later.
    public static let reserve: UInt128 = 50_000_000_000_000_000_000_000
    /// The smallest stake Hermit prepares (0.01 NEAR): below it the pool's share rounding can refuse the deposit.
    public static let minimumStake: UInt128 = 10_000_000_000_000_000_000_000
    /// Balances under 0.000001 NEAR are rounding leftovers (pools leave 1 or 2 yocto behind), not money to show.
    public static let dust: UInt128 = 1_000_000_000_000_000_000
    /// The contract's NUM_EPOCHS_TO_UNLOCK.
    public static let unlockEpochs = 4
    /// The code every pool made by the `poolv1.near` factory runs. The factory has no access keys and neither do its
    /// pools, so this code can't be swapped. Hermit only stakes into a pool whose code hash is this one.
    public static let poolCodeHash = "J1arLz48fgXcGyCPVckFwLnewNH6j1uw79thsvwqGYTY"
    /// How many pools Stake NEAR offers, the highest fee it lists, and the least uptime this epoch.
    public static let listSize = 6
    public static let maxListedFee = 0.10
    public static let minUptime = 0.95
    /// Pools whose fee is read for the list (the biggest by stake that pass the validator checks).
    static let readLimit = 12

    // MARK: Actions

    // Arguments are written the way near-api-js writes them (JSON.stringify of {} and {amount}), so the bytes match.
    public static func depositAndStake(_ amount: UInt128) -> NearAction {
        .functionCall(method: "deposit_and_stake", args: Array("{}".utf8), gas: gas, deposit: amount)
    }
    public static func unstake(_ amount: UInt128) -> NearAction {
        .functionCall(method: "unstake", args: Array(#"{"amount":"\#(amount)"}"#.utf8), gas: gas, deposit: 0)
    }
    public static var unstakeAll: NearAction { .functionCall(method: "unstake_all", args: Array("{}".utf8), gas: gas, deposit: 0) }
    public static var withdrawAll: NearAction { .functionCall(method: "withdraw_all", args: Array("{}".utf8), gas: gas, deposit: 0) }

    // MARK: Pools

    /// A staking pool made by one of NEAR's two pool factories: "name.poolv1.near" or "name.pool.near".
    public static func isFactoryPool(_ id: String) -> Bool {
        guard NearAccount.isValid(id) else { return false }
        for suffix in [".poolv1.near", ".pool.near"] where id.hasSuffix(suffix) {
            let name = id.dropLast(suffix.count)
            return !name.isEmpty && !name.contains(".")
        }
        return false
    }
    /// "astro-stakers" for "astro-stakers.poolv1.near".
    public static func poolName(_ id: String) -> String {
        for suffix in [".poolv1.near", ".pool.near"] where id.hasSuffix(suffix) { return String(id.dropLast(suffix.count)) }
        return id
    }

    /// What `get_account` says about one delegator.
    public struct PoolAccount: Equatable, Hashable, Sendable {
        public let staked: UInt128
        public let unstaked: UInt128
        /// True once the unstaked balance has waited its four epochs (also true when there is nothing unstaked).
        public let canWithdraw: Bool
        public init(staked: UInt128, unstaked: UInt128, canWithdraw: Bool) {
            self.staked = staked; self.unstaked = unstaked; self.canWithdraw = canWithdraw
        }
        public init?(_ j: JSON) {
            guard let s = j["staked_balance"]?.string.flatMap({ UInt128($0) }),
                  let u = j["unstaked_balance"]?.string.flatMap({ UInt128($0) }), let c = j["can_withdraw"]?.bool else { return nil }
            self.init(staked: s, unstaked: u, canWithdraw: c)
        }
        /// Unstaked and still waiting.
        public var unstaking: UInt128 { !canWithdraw && unstaked > NearStaking.dust ? unstaked : 0 }
        /// Unstaked and ready to withdraw.
        public var ready: UInt128 { canWithdraw && unstaked > NearStaking.dust ? unstaked : 0 }
        public var isEmpty: Bool { staked <= NearStaking.dust && unstaked <= NearStaking.dust }
    }

    /// The share of rewards the pool's owner keeps, from `get_reward_fee_fraction`. The owner can change it.
    public struct Fee: Equatable, Hashable, Sendable {
        public let numerator: UInt32
        public let denominator: UInt32
        public init(numerator: UInt32, denominator: UInt32) { self.numerator = numerator; self.denominator = denominator }
        public init?(_ j: JSON) {
            guard let n = j["numerator"]?.double.flatMap({ UInt32(exactly: $0) }),
                  let d = j["denominator"]?.double.flatMap({ UInt32(exactly: $0) }), d > 0, n <= d else { return nil }
            self.init(numerator: n, denominator: d)
        }
        public var fraction: Double { Double(numerator) / Double(denominator) }
        /// "1%", "2.5%".
        public var text: String { NearStaking.percent(fraction) }
    }

    /// One row of the RPC `validators` answer.
    public struct Validator: Equatable, Sendable {
        public let account: String
        public let stake: UInt128
        public let slashed: Bool
        /// Blocks, chunks and endorsements this epoch so far: what was asked of it and what it did.
        public let expected: Double
        public let produced: Double
        public init?(_ j: JSON) {
            guard let a = j["account_id"]?.string, let s = j["stake"]?.string.flatMap({ UInt128($0) }) else { return nil }
            account = a; stake = s; slashed = j["is_slashed"]?.bool ?? false
            func n(_ k: String) -> Double { j[k]?.double ?? 0 }
            expected = n("num_expected_blocks") + n("num_expected_chunks") + n("num_expected_endorsements")
            produced = n("num_produced_blocks") + n("num_produced_chunks") + n("num_produced_endorsements")
        }
        /// nil right after an epoch starts, before anything was asked of it.
        public var uptime: Double? { expected > 0 ? min(1, produced / expected) : nil }
    }

    /// The RPC `validators` answer for the current epoch.
    public struct ValidatorSet: Equatable, Sendable {
        public let current: [Validator]
        public let next: Set<String>
        public let kicked: Set<String>
        public let epochHeight: UInt64
        public let epochStartHeight: UInt64
        /// What each validator was paid for the previous epoch, in yocto.
        public let rewards: [String: UInt128]

        public init?(_ r: JSON) {
            guard let cur = r["current_validators"]?.array, !cur.isEmpty, let h = r["epoch_height"]?.double.flatMap({ UInt64(exactly: $0) }),
                  let start = r["epoch_start_height"]?.double.flatMap({ UInt64(exactly: $0) }) else { return nil }
            current = cur.compactMap { Validator($0) }
            next = Set((r["next_validators"]?.array ?? []).compactMap { $0["account_id"]?.string })
            kicked = Set((r["prev_epoch_kickout"]?.array ?? []).compactMap { $0["account_id"]?.string })
            epochHeight = h; epochStartHeight = start
            if case .object(let o)? = r["validator_reward_paid_prev_epoch"] {
                rewards = o.compactMapValues { $0.string.flatMap { UInt128($0) } }
            } else { rewards = [:] }
        }

        /// Validating this epoch, kept for the next one, and not slashed or kicked out.
        public func isActive(_ pool: String) -> Bool {
            guard let v = current.first(where: { $0.account == pool }) else { return false }
            return !v.slashed && v.stake > 0 && next.contains(pool) && !kicked.contains(pool)
        }

        /// Pools Hermit could offer, biggest stake first: active, made by the keyless poolv1 factory, and online.
        /// Fees are read from each pool afterwards (`NearStaking.shortlist`).
        public func candidates() -> [Validator] {
            current.filter { v in
                v.account.hasSuffix(".poolv1.near") && NearStaking.isFactoryPool(v.account) && isActive(v.account)
                    && (v.uptime ?? 1) >= NearStaking.minUptime
            }
            .sorted { ($0.stake, $1.account) > ($1.stake, $0.account) }
        }

        /// What validators earned last epoch on their stake, as a yearly rate before any pool fee (0.0497 = 4.97%).
        /// An estimate: last epoch's rewards over this epoch's stake, times the epochs in a year. nil when the numbers
        /// don't make a believable rate, so nothing is shown instead of a wrong figure.
        public func networkAPR(epochSeconds: Double) -> Double? {
            guard epochSeconds >= 3_600, epochSeconds <= 172_800 else { return nil }
            var paid = 0.0, staked = 0.0
            for v in current { if let r = rewards[v.account], r > 0 { paid += Double(r); staked += Double(v.stake) } }
            guard staked > 0, paid > 0 else { return nil }
            let apr = paid / staked * (31_536_000 / epochSeconds)
            return apr > 0 && apr < 0.25 ? apr : nil
        }
    }

    /// A pool on the Stake NEAR list, with its fee read from the contract.
    public struct Pool: Identifiable, Equatable, Hashable, Sendable {
        public let id: String
        public let stake: UInt128
        public let fee: Fee
        public let uptime: Double?
        /// The network's rate last epoch less this pool's fee. nil when it couldn't be worked out.
        public let estimatedAPR: Double?
        public var name: String { NearStaking.poolName(id) }
        public init(id: String, stake: UInt128, fee: Fee, uptime: Double?, estimatedAPR: Double?) {
            self.id = id; self.stake = stake; self.fee = fee; self.uptime = uptime; self.estimatedAPR = estimatedAPR
        }
    }

    /// The list Stake NEAR shows: the biggest candidates whose fee could be read and is at most `maxListedFee`.
    public static func shortlist(_ set: ValidatorSet, fees: [String: Fee], networkAPR: Double?) -> [Pool] {
        set.candidates().compactMap { v -> Pool? in
            guard let fee = fees[v.account], fee.fraction <= maxListedFee else { return nil }
            return Pool(id: v.account, stake: v.stake, fee: fee, uptime: v.uptime, estimatedAPR: networkAPR.map { $0 * (1 - fee.fraction) })
        }
        .prefix(listSize).map { $0 }
    }

    /// The validator set, the list and how long an epoch takes right now.
    public struct Network: Equatable, Sendable {
        public let set: ValidatorSet
        public let pools: [Pool]
        /// How long the previous epoch took. nil when the blocks couldn't be read.
        public let epochSeconds: Double?
        public let networkAPR: Double?
        public var unlockText: String { NearStaking.unlockText(epochSeconds: epochSeconds) }
    }

    /// One wallet's stake in one pool.
    public struct Position: Identifiable, Equatable, Hashable, Sendable {
        public var id: String { "\(walletID.uuidString):\(pool)" }
        public let walletID: UUID
        public let account: String
        public let pool: String
        public let balance: PoolAccount
        public init(walletID: UUID, account: String, pool: String, balance: PoolAccount) {
            self.walletID = walletID; self.account = account; self.pool = pool; self.balance = balance
        }
        /// Everything of this wallet's in the pool: staked, unstaking and ready.
        public var total: UInt128 { balance.staked + (balance.unstaked > NearStaking.dust ? balance.unstaked : 0) }
    }

    // MARK: Words and numbers

    /// "12.5" for 12.5 NEAR in yocto, cut (never rounded up) to five decimals.
    public static func near(_ yocto: UInt128) -> String { Units.format(yocto, decimals: 24, maxFraction: 5) }

    /// 0.01 -> "1%", 0.025 -> "2.5%".
    public static func percent(_ fraction: Double) -> String {
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), fraction * 100)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "%"
    }

    /// "4 epochs, about 28 hours": the wait between Unstake and Withdraw, from how long an epoch takes now.
    public static func unlockText(epochSeconds: Double?) -> String {
        guard let s = epochSeconds, s > 0 else { return "\(unlockEpochs) epochs" }
        let hours = Double(unlockEpochs) * s / 3_600
        let about = hours < 48 ? "\(max(1, Int(hours.rounded()))) hours" : "\(Int((hours / 24).rounded())) days"
        return "\(unlockEpochs) epochs, about \(about)"
    }

    /// The most that can be staked from an available balance (the one that already leaves out storage): everything
    /// but this call's fee and the reserve.
    public static func maxStake(available: UInt128) -> UInt128 {
        let keep = reserve + feeCeiling
        return available > keep ? available - keep : 0
    }

    // MARK: Review

    public enum Move: Equatable, Sendable {
        case stake(UInt128)
        /// nil unstakes everything.
        case unstake(UInt128?)
        case withdraw
    }

    /// What was read from the chain for a review.
    public struct Context: Sendable {
        /// The account's available balance, nil when the account doesn't exist on chain yet.
        public var available: UInt128?
        public var position: PoolAccount
        public var fee: Fee?
        public var paused = false
        /// In the validator set this epoch and next.
        public var active = false
        /// The pool's code hash is `poolCodeHash` and the pool has no access keys.
        public var standardCode = false
        public var epochSeconds: Double?
        public var networkAPR: Double?
        public var usdPerNear: Decimal?
        public init(available: UInt128?, position: PoolAccount) { self.available = available; self.position = position }
    }

    /// A checked stake, unstake or withdrawal, ready for the approval sheet. Nothing has been signed.
    public struct Review: Equatable, Sendable {
        public let move: Move
        public let walletID: UUID
        public let account: String
        public let pool: String
        /// The NEAR this moves: the stake, what's being unstaked (the staked balance for "all"), or what's ready.
        public let amount: UInt128
        public let actions: [NearAction]
        public let kind: String
        public let title: String
        public let success: String
        /// The Face ID prompt.
        public let reason: String
        public let lines: [[String]]
        public let checks: [String]
        public let warnings: [String]
        /// Dollars counted toward the daily limit once a stake is sent. nil for unstakes, withdrawals and no price.
        public let usd: Decimal?
    }

    /// Checks a move against what the chain says and the spending policy, and writes the review. Throws
    /// `WalletError.blocked` with the reason when it shouldn't go ahead; nothing reaches the approval sheet then.
    public static func review(_ move: Move, walletID: UUID, account: String, pool: String, context c: Context,
                              policy: SpendPolicy, origin: ActionOrigin, now: Date = Date()) throws -> Review {
        guard isFactoryPool(pool) else { throw WalletError.blocked("\(pool) isn't a NEAR staking pool Hermit can use.") }
        let wait = unlockText(epochSeconds: c.epochSeconds)
        let name = poolName(pool)
        let feeLine = ["Network fee", "Up to \(near(feeCeiling)) NEAR"]
        func needGas() throws -> UInt128 {
            guard let a = c.available else {
                throw WalletError.blocked("This NEAR account isn't active yet. It starts once it receives NEAR.")
            }
            guard a >= feeCeiling else {
                throw WalletError.blocked("You need about \(near(feeCeiling)) NEAR in the account to pay for this. Add a little NEAR first.")
            }
            return a
        }

        switch move {
        case .stake(let amount):
            guard c.standardCode else {
                throw WalletError.blocked("\(pool) doesn't run the standard staking pool contract, so Hermit won't stake there.")
            }
            guard c.active else {
                throw WalletError.blocked("\(pool) isn't an active validator right now, so NEAR staked there would earn nothing.")
            }
            guard !c.paused else { throw WalletError.blocked("\(pool) has paused staking.") }
            guard let fee = c.fee else { throw WalletError.blocked("Couldn't read the pool's fee, so nothing was prepared.") }
            guard fee.fraction < 1 else { throw WalletError.blocked("\(pool) keeps all the rewards (a 100% fee).") }
            guard let available = c.available else {
                throw WalletError.blocked("This NEAR account isn't active yet. It starts once it receives NEAR.")
            }
            guard amount >= minimumStake else {
                throw WalletError.blocked("The smallest stake Hermit prepares is \(near(minimumStake)) NEAR.")
            }
            let most = maxStake(available: available)
            guard amount <= most else {
                throw WalletError.blocked(most >= minimumStake
                    ? "You can stake up to \(near(most)) NEAR. Hermit keeps \(near(reserve)) NEAR in the account so you can always pay to unstake."
                    : "Not enough NEAR to stake. Hermit keeps \(near(reserve)) NEAR in the account for fees, and \(near(available)) is available.")
            }
            let usd: Decimal? = c.usdPerNear.flatMap { p in Decimal(string: Units.format(amount, decimals: 24)).map { $0 * p } }
            let verdict = policy.evaluate(usd: usd.map { NSDecimalNumber(decimal: $0).doubleValue }, payee: nil, origin: origin, now: now)
            if verdict.decision == .block {
                // The policy's own words, pointed at Earn instead of Swap.
                throw WalletError.blocked(verdict.blocks.joined(separator: " ").replacingOccurrences(of: "Open Swap yourself", with: "Stake from Earn yourself"))
            }
            let text = near(amount)
            var lines: [[String]] = [["Pool", pool], ["Amount", "\(text) NEAR"], ["Pool fee", "\(fee.text) of rewards"]]
            if let apr = c.networkAPR {
                lines.append(["Estimated rate", "About \(percent(apr * (1 - fee.fraction))) a year after the fee, from last epoch"])
            }
            lines.append(["To get it back", "Unstake, wait \(wait), withdraw"])
            lines.append(["Stays in your account", "About \(near(available - amount - feeCeiling)) NEAR, for fees"])
            lines.append(feeLine)
            var warnings = verdict.warnings
            if fee.fraction > maxListedFee { warnings.append("This pool keeps \(fee.text) of your rewards.") }
            let checks = ["Pool is a NEAR validator this epoch and next", "Standard pool contract that can't be replaced",
                          "Fee read from the pool just now: \(fee.text)", "\(near(reserve)) NEAR kept back for fees"]
                + verdict.passed.filter { !$0.hasPrefix("Pays out") }
            return Review(move: move, walletID: walletID, account: account, pool: pool, amount: amount, actions: [depositAndStake(amount)],
                          kind: "Stake on NEAR", title: "Stake \(text) NEAR with \(name)", success: "Staked \(text) NEAR",
                          reason: "Stake \(text) NEAR with \(pool)", lines: lines, checks: checks, warnings: warnings, usd: usd)

        case .unstake(let asked):
            let staked = c.position.staked
            guard staked > dust else { throw WalletError.blocked("Nothing is staked with \(pool).") }
            _ = try needGas()
            var all = asked == nil
            if let a = asked {
                guard a > 0 else { throw WalletError.blocked("Not a valid amount.") }
                guard a <= staked else { throw WalletError.blocked("Only \(near(staked)) NEAR is staked with \(pool).") }
                if staked - a <= dust { all = true }
            }
            let amount = all ? staked : (asked ?? staked)
            let text = near(amount)
            var warnings: [String] = []
            if c.position.ready > 0 {
                warnings.append("\(near(c.position.ready)) NEAR is ready to withdraw from this pool. Withdraw it first: unstaking now locks it again for the whole wait.")
            } else if c.position.unstaking > 0 {
                warnings.append("\(near(c.position.unstaking)) NEAR is already unstaking here. Unstaking more starts the wait again for all of it.")
            }
            let lines: [[String]] = [["Pool", pool], ["Amount", all ? "All, about \(text) NEAR" : "\(text) NEAR"],
                                     ["Ready to withdraw in", wait], ["While it waits", "It earns nothing"], feeLine]
            return Review(move: move, walletID: walletID, account: account, pool: pool, amount: amount,
                          actions: [all ? unstakeAll : unstake(amount)],
                          kind: "Unstake on NEAR", title: "Unstake \(all ? "all" : text) NEAR from \(name)", success: "Unstaking \(text) NEAR",
                          reason: "Unstake \(text) NEAR from \(pool)", lines: lines,
                          checks: ["Staked balance read from the pool just now", "Stays yours: it can only be withdrawn to your own account"],
                          warnings: warnings, usd: nil)

        case .withdraw:
            guard c.position.unstaked > dust else { throw WalletError.blocked("Nothing is waiting to be withdrawn from \(pool).") }
            guard c.position.canWithdraw else {
                throw WalletError.blocked("That NEAR is still unstaking. It takes \(wait) from the last unstake.")
            }
            _ = try needGas()
            let amount = c.position.unstaked
            let text = near(amount)
            return Review(move: move, walletID: walletID, account: account, pool: pool, amount: amount, actions: [withdrawAll],
                          kind: "Withdraw on NEAR", title: "Withdraw \(text) NEAR from \(name)", success: "Withdrew \(text) NEAR",
                          reason: "Withdraw \(text) NEAR from \(pool)",
                          lines: [["Pool", pool], ["Amount", "\(text) NEAR"], ["To", "Your NEAR account"], feeLine],
                          checks: ["The pool says this NEAR is ready", "Goes back to your own account"], warnings: [], usd: nil)
        }
    }

    // MARK: The assistant's tools

    /// Whether a prepare_deposit, prepare_withdraw or position call is about staking NEAR: the asset is NEAR, or the
    /// chain is NEAR and no other asset was named. The tool list has no staking tool, so these calls are routed here.
    public static func handles(symbol: String?, chain: String?) -> Bool {
        let s = (symbol ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s == "NEAR" { return true }
        let c = (chain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.isEmpty && (c == "near" || c == "near protocol")
    }

    /// What "withdraw my NEAR" should prepare.
    public enum Exit: Equatable, Sendable {
        /// NEAR is ready in this pool: withdraw it.
        case withdraw(Position)
        /// Unstake from this pool (nil: all of it).
        case unstake(Position, UInt128?)
        /// More than one pool fits: ask which.
        case choose([Position])
        /// The amount is more than what's staked there.
        case tooMuch(Position)
        /// Everything is already unstaking: nothing to do but wait.
        case waiting([Position])
        case nothing
    }

    /// Ready NEAR is withdrawn first when no amount was asked for; otherwise the stake is unstaked (all, or `amount`).
    public static func exit(_ positions: [Position], amount: UInt128?) -> Exit {
        let live = positions.filter { !$0.balance.isEmpty }
        guard !live.isEmpty else { return .nothing }
        let ready = live.filter { $0.balance.ready > 0 }
        let staked = live.filter { $0.balance.staked > dust }
        if amount == nil, !ready.isEmpty { return ready.count == 1 ? .withdraw(ready[0]) : .choose(ready) }
        if staked.isEmpty {
            if !ready.isEmpty { return ready.count == 1 ? .withdraw(ready[0]) : .choose(ready) }
            return .waiting(live)
        }
        guard staked.count == 1 else { return .choose(staked) }
        if let amount, amount > staked[0].balance.staked { return .tooMuch(staked[0]) }
        return .unstake(staked[0], amount)
    }

    // MARK: Which pools a wallet has used

    static let rememberKey = "hermit.near.stakingPools"

    /// Pools this device has staked into for an account, so a position shows even when the index below is down.
    public static func remembered(account: String, defaults: UserDefaults = .standard) -> [String] {
        (defaults.dictionary(forKey: rememberKey)?[account] as? [String]) ?? []
    }
    public static func remember(pool: String, account: String, defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: rememberKey) as? [String: [String]]) ?? [:]
        var mine = all[account] ?? []
        guard !mine.contains(pool) else { return }
        mine.append(pool); all[account] = mine
        defaults.set(all, forKey: rememberKey)
    }

    /// The pools an account has ever delegated to, from FastNEAR's index (the same provider as Hermit's NEAR RPC).
    /// It only says where to look: every balance is then read from the pool contract itself. nil when it didn't answer.
    public static func indexedPools(account: String, session: URLSession = .shared) async -> [String]? {
        guard NearAccount.isValid(account), let url = URL(string: "https://api.fastnear.com/v1/account/\(account)/staking") else { return nil }
        let req = URLRequest(url: url, timeoutInterval: 15)
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONDecoder().decode(JSON.self, from: data) else { return nil }
        return pools(fromIndex: j)
    }
    static func pools(fromIndex j: JSON) -> [String]? {
        guard let rows = j["pools"]?.array else { return nil }
        return rows.compactMap { $0["pool_id"]?.string }.filter(isFactoryPool)
    }
}

/// The validator list for ten minutes, so opening Stake NEAR twice doesn't read every pool's fee twice.
actor NearStakingCache {
    static let shared = NearStakingCache()
    private var saved: (at: Date, network: NearStaking.Network)?
    func get(maxAge: TimeInterval) -> NearStaking.Network? {
        guard let s = saved, Date().timeIntervalSince(s.at) < maxAge else { return nil }
        return s.network
    }
    func put(_ n: NearStaking.Network) { saved = (Date(), n) }
}

extension NearClient {
    /// The current epoch's validators (RPC `validators` with a null block).
    public func validatorSet() async throws -> NearStaking.ValidatorSet {
        let r = try await call("validators", [.null])
        guard let s = NearStaking.ValidatorSet(r) else { throw WalletError.badResponse("validators") }
        return s
    }

    public func poolAccount(pool: String, account: String) async throws -> NearStaking.PoolAccount {
        let r = try await view(pool, "get_account", args: Array(#"{"account_id":"\#(account)"}"#.utf8))
        guard let a = NearStaking.PoolAccount(r) else { throw WalletError.badResponse("get_account") }
        return a
    }

    public func poolFee(_ pool: String) async throws -> NearStaking.Fee {
        guard let f = NearStaking.Fee(try await view(pool, "get_reward_fee_fraction")) else {
            throw WalletError.badResponse("get_reward_fee_fraction")
        }
        return f
    }

    public func poolPaused(_ pool: String) async throws -> Bool {
        guard let b = try await view(pool, "is_staking_paused").bool else { throw WalletError.badResponse("is_staking_paused") }
        return b
    }

    /// A contract's code hash and how many access keys its account has (none means nobody can replace the code).
    public func contractInfo(_ id: String) async throws -> (codeHash: String, accessKeys: Int) {
        async let accountA = call("query", ["request_type": "view_account", "finality": "final", "account_id": .string(id)])
        async let keysA = call("query", ["request_type": "view_access_key_list", "finality": "final", "account_id": .string(id)])
        let (account, keys) = try await (accountA, keysA)
        guard let hash = account["code_hash"]?.string, let list = keys["keys"]?.array else { throw WalletError.badResponse("view_account") }
        return (hash, list.count)
    }

    /// How long the previous epoch took, in seconds: the time between its first block and the first block of the
    /// current one (`startHeight`, from `validators`). The epoch length in blocks comes from the protocol config.
    public func epochSeconds(startHeight: UInt64) async throws -> Double {
        let config = try await call("EXPERIMENTAL_protocol_config", ["finality": "final"])
        guard let length = config["epoch_length"]?.double.flatMap({ UInt64(exactly: $0) }), length > 0, startHeight > length else {
            throw WalletError.badResponse("protocol_config")
        }
        async let endA = blockTime(height: startHeight)
        async let startA = blockTime(height: startHeight - length)
        let (end, start) = try await (endA, startA)
        guard end > start else { throw WalletError.badResponse("block") }
        return end - start
    }

    /// A block's timestamp in seconds.
    func blockTime(height: UInt64) async throws -> Double {
        let r = try await call("block", ["block_id": .number(Double(height))])
        if let ns = r["header"]?["timestamp_nanosec"]?.string.flatMap({ Double($0) }) { return ns / 1e9 }
        guard let ns = r["header"]?["timestamp"]?.double else { throw WalletError.badResponse("block") }
        return ns / 1e9
    }
}

extension WalletService {
    /// The validator set, the Stake NEAR list with live fees, and the epoch time. Kept for ten minutes.
    public func nearStakingNetwork(force: Bool = false) async throws -> NearStaking.Network {
        if !force, let hit = await NearStakingCache.shared.get(maxAge: 600) { return hit }
        let client = nearClient
        let set = try await client.validatorSet()
        let seconds = try? await client.epochSeconds(startHeight: set.epochStartHeight)
        let apr = seconds.flatMap { set.networkAPR(epochSeconds: $0) }
        var fees: [String: NearStaking.Fee] = [:]
        await withTaskGroup(of: (String, NearStaking.Fee)?.self) { g in
            for v in set.candidates().prefix(NearStaking.readLimit) {
                let id = v.account
                g.addTask {
                    guard let fee = try? await client.poolFee(id) else { return nil }
                    return (id, fee)
                }
            }
            for await r in g { if let r { fees[r.0] = r.1 } }
        }
        let network = NearStaking.Network(set: set, pools: NearStaking.shortlist(set, fees: fees, networkAPR: apr),
                                          epochSeconds: seconds, networkAPR: apr)
        // An empty list (every fee read failed) isn't kept, so the next open tries again.
        if !network.pools.isEmpty { await NearStakingCache.shared.put(network) }
        return network
    }

    /// Every wallet's NEAR stakes, read from the pool contracts. Where to look comes from FastNEAR's index plus the
    /// pools this device staked into. `failed` means something didn't answer, so a missing row is unknown, not zero.
    public func nearStakingPositions(wallets list: [WalletRecord]? = nil) async -> (positions: [NearStaking.Position], failed: Bool) {
        let all = list ?? wallets
        let ws = all.compactMap { w in w.nearAccount.map { (w.id, $0) } }
        guard !ws.isEmpty else { return ([], false) }
        let client = nearClient
        var out: [NearStaking.Position] = [], failed = false
        await withTaskGroup(of: ([NearStaking.Position], Bool).self) { g in
            for (id, account) in ws {
                g.addTask {
                    let indexed = await NearStaking.indexedPools(account: account)
                    var ok = indexed != nil
                    let pools = Set((indexed ?? []) + NearStaking.remembered(account: account)).filter { NearStaking.isFactoryPool($0) }.sorted()
                    var rows: [NearStaking.Position] = []
                    for pool in pools {
                        guard let b = try? await client.poolAccount(pool: pool, account: account) else { ok = false; continue }
                        if !b.isEmpty { rows.append(NearStaking.Position(walletID: id, account: account, pool: pool, balance: b)) }
                    }
                    return (rows, ok)
                }
            }
            for await (rows, ok) in g { out += rows; if !ok { failed = true } }
        }
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        out.sort { (order[$0.walletID] ?? 0, $1.total, $0.pool) < (order[$1.walletID] ?? 0, $0.total, $1.pool) }
        return (out, failed)
    }

    /// Reads everything a review needs (the account, the wallet's balance in the pool and, for a stake, the pool's
    /// fee, code and place in the validator set) and checks it. Nothing is signed here.
    public func prepareNearStaking(walletID: UUID, pool: String, move: NearStaking.Move, origin: ActionOrigin) async throws -> NearStaking.Review {
        guard let w = wallets.first(where: { $0.id == walletID }) else { throw WalletError.vault("That wallet is gone.") }
        guard let account = w.nearAccount else { throw WalletError.blocked("Add a NEAR account to this wallet first.") }
        guard NearStaking.isFactoryPool(pool) else { throw WalletError.blocked("\(pool) isn't a NEAR staking pool Hermit can use.") }
        let client = nearClient
        async let stateA = client.account(account)
        async let positionA = client.poolAccount(pool: pool, account: account)
        let (state, position) = try await (stateA, positionA)
        var c = NearStaking.Context(available: state?.available, position: position)
        if case .stake = move {
            let network = try await nearStakingNetwork()
            async let feeA = client.poolFee(pool)
            async let pausedA = client.poolPaused(pool)
            async let codeA = client.contractInfo(pool)
            let (fee, paused, code) = try await (feeA, pausedA, codeA)
            c.fee = fee; c.paused = paused
            c.active = network.set.isActive(pool)
            c.standardCode = code.codeHash == NearStaking.poolCodeHash && code.accessKeys == 0
            c.epochSeconds = network.epochSeconds; c.networkAPR = network.networkAPR
            c.usdPerNear = await usdPerUnit(chain: .near, token: nil)
        } else {
            c.epochSeconds = (try? await nearStakingNetwork())?.epochSeconds
        }
        return try NearStaking.review(move, walletID: walletID, account: account, pool: pool, context: c, policy: policy, origin: origin)
    }

    /// Signs and sends a reviewed move (Face ID inside `executeNear`), waits for it to execute and returns the hash.
    /// A failed transaction or receipt throws. A stake counts toward the daily limit once it's through.
    public func executeNearStaking(_ r: NearStaking.Review) async throws -> String {
        // Remembered before sending, so a stake that lands after a dropped connection still shows up.
        NearStaking.remember(pool: r.pool, account: r.account)
        let hash = try await executeNear(walletID: r.walletID, receiver: r.pool, actions: r.actions, reason: r.reason)
        if case .stake = r.move, let usd = r.usd { spendLimit.record(usd: usd) }
        return hash
    }
}
