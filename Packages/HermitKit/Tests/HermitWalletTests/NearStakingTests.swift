import XCTest
@testable import HermitWallet

/// NEAR staking. Fixtures were recorded from mainnet (free.rpc.fastnear.com) on 2026-11-12:
/// `near-staking-get-account.json` is a real `get_account` answer from zavodil.poolv1.near for an account that had
/// just unstaked; `near-staking-validators.json` is the real `validators` answer cut down to ten validators (and the
/// first three kickouts), with nothing else changed. Expected transaction bytes come from near-api-js 4.0.4
/// (`transactions.functionCall`), with the same signer, nonce and block hash as `NearTests`.
final class NearStakingTests: XCTestCase {
    let implicit = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
    let blockHash = "4reLvkAWfqk5fsqio1KLudk46cqRz9erQdaHkWZKMJDZ"
    let pool = "zavodil.poolv1.near"
    let near: UInt128 = 1_000_000_000_000_000_000_000_000
    let wallet = UUID()

    func json(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(JSON.self, from: try Data(contentsOf: url))
    }

    func tx(_ actions: [NearAction]) -> NearTransaction {
        NearTransaction(signer: implicit, publicKey: [UInt8](hex: implicit)!, nonce: 123_456_789, receiver: pool,
                        blockHash: Base58.decode(blockHash)!, actions: actions)
    }

    func policy() -> SpendPolicy {
        let d = UserDefaults(suiteName: "stake-\(UUID())")!
        return SpendPolicy(limit: SpendLimit(defaults: d), book: AddressBook(defaults: d), defaults: d)
    }

    /// A healthy pool and an account with `available` NEAR in it, priced at $2 a NEAR.
    func context(available: UInt128?, staked: UInt128 = 0, unstaked: UInt128 = 0, canWithdraw: Bool = true) -> NearStaking.Context {
        var c = NearStaking.Context(available: available, position: .init(staked: staked, unstaked: unstaked, canWithdraw: canWithdraw))
        c.fee = NearStaking.Fee(numerator: 1, denominator: 100)
        c.active = true; c.standardCode = true
        c.epochSeconds = 24_921.9; c.networkAPR = 0.0497; c.usdPerNear = 2
        return c
    }

    func review(_ move: NearStaking.Move, _ c: NearStaking.Context, origin: ActionOrigin = .user, pool: String? = nil,
                policy p: SpendPolicy? = nil) throws -> NearStaking.Review {
        try NearStaking.review(move, walletID: wallet, account: implicit, pool: pool ?? self.pool, context: c, policy: p ?? policy(), origin: origin)
    }

    func blocked(_ move: NearStaking.Move, _ c: NearStaking.Context, origin: ActionOrigin = .user, pool: String? = nil,
                 policy p: SpendPolicy? = nil, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try review(move, c, origin: origin, pool: pool, policy: p)
            XCTFail("expected a block", file: file, line: line)
            return ""
        } catch WalletError.blocked(let why) { return why } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: Bytes

    func testStakingCallsMatchNearApiJs() {
        let head = "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b0700000000130000007a61766f64696c2e706f6f6c76312e6e656172394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c01000000"
        // deposit_and_stake {} with 2.5 NEAR attached, 100 Tgas.
        let stake = tx([NearStaking.depositAndStake(UInt128("2500000000000000000000000")!)])
        XCTAssertEqual(stake.serialized.hex, head + "02110000006465706f7369745f616e645f7374616b65020000007b7d00407a10f35a000000008012520085456511020000000000")
        XCTAssertEqual(stake.hashString, "GZiBfc9xUJweBMcathce9XBwNeboZkEnYB4iL99Xefj3")
        // unstake {"amount":"1250000000000000000000000"}, nothing attached.
        let unstake = tx([NearStaking.unstake(UInt128("1250000000000000000000000")!)])
        XCTAssertEqual(unstake.serialized.hex, head + "0207000000756e7374616b65260000007b22616d6f756e74223a2231323530303030303030303030303030303030303030303030227d00407a10f35a000000000000000000000000000000000000")
        XCTAssertEqual(unstake.hashString, "5P6oNJehCk6vmS1NkqJTCeFPdKFaMM5sHvbK1zxN27eA")
        let unstakeAll = tx([NearStaking.unstakeAll])
        XCTAssertEqual(unstakeAll.serialized.hex, head + "020b000000756e7374616b655f616c6c020000007b7d00407a10f35a000000000000000000000000000000000000")
        XCTAssertEqual(unstakeAll.hashString, "786dBqhsezTh2U2wn3DvhxB2889msgHMkeXJSi77eFnw")
        let withdrawAll = tx([NearStaking.withdrawAll])
        XCTAssertEqual(withdrawAll.serialized.hex, head + "020c00000077697468647261775f616c6c020000007b7d00407a10f35a000000000000000000000000000000000000")
        XCTAssertEqual(withdrawAll.hashString, "BWv8oZF7zGdmcKtH7fzzj18A1dQ1wSUxEWi4JzGiutK5")
        XCTAssertEqual(NearStaking.gas, 100_000_000_000_000)
        XCTAssertEqual(NearStaking.depositAndStake(7).attached, 7)
        XCTAssertEqual(NearStaking.unstakeAll.attached, 0)
    }

    // MARK: Reading the pool and the validators

    func testGetAccountFromRecordedResponse() throws {
        let rpc = try json("near-staking-get-account")
        let a = try XCTUnwrap(NearStaking.PoolAccount(NearClient.viewValue(try XCTUnwrap(rpc["result"]))))
        XCTAssertEqual(a.staked, UInt128("345530508480305501941100967")!)
        XCTAssertEqual(a.unstaked, UInt128("21150000000000000000000004")!)
        XCTAssertFalse(a.canWithdraw)
        // Unstaked and still waiting: all of it is "unstaking", none is ready.
        XCTAssertEqual(a.unstaking, a.unstaked); XCTAssertEqual(a.ready, 0); XCTAssertFalse(a.isEmpty)
        // The same shape for an account the pool has never seen, and the 1 or 2 yocto pools leave behind.
        let none = try XCTUnwrap(NearStaking.PoolAccount(["account_id": "x.near", "unstaked_balance": "0", "staked_balance": "0", "can_withdraw": true]))
        XCTAssertTrue(none.isEmpty)
        let leftover = NearStaking.PoolAccount(staked: 3 * near, unstaked: 2, canWithdraw: true)
        XCTAssertEqual(leftover.ready, 0); XCTAssertEqual(leftover.unstaking, 0)
        // Anything else isn't an account.
        XCTAssertNil(NearStaking.PoolAccount(["staked_balance": "1"]))
        XCTAssertNil(NearStaking.PoolAccount(.null))
        // The fee, as the pools answer it.
        XCTAssertEqual(NearStaking.Fee(["numerator": 1, "denominator": 100])?.text, "1%")
        XCTAssertEqual(NearStaking.Fee(["numerator": 25, "denominator": 1000])?.text, "2.5%")
        XCTAssertEqual(NearStaking.Fee(["numerator": 10000, "denominator": 10000])?.fraction, 1)
        XCTAssertNil(NearStaking.Fee(["numerator": 1, "denominator": 0]))
        XCTAssertNil(NearStaking.Fee(["numerator": 3, "denominator": 2]))
    }

    func testValidatorSetAndShortlist() throws {
        let set = try XCTUnwrap(NearStaking.ValidatorSet(try XCTUnwrap(try json("near-staking-validators")["result"])))
        XCTAssertEqual(set.epochHeight, 4963); XCTAssertEqual(set.epochStartHeight, 224_221_937)
        XCTAssertEqual(set.current.count, 10)
        XCTAssertTrue(set.isActive("astro-stakers.poolv1.near"))
        XCTAssertFalse(set.isActive("anyroute.pool.near"))        // kicked out last epoch
        XCTAssertFalse(set.isActive("nobody.poolv1.near"))
        // Biggest first; figment was online 74% of the epoch and liver comes from the other factory, so neither is offered.
        XCTAssertEqual(set.candidates().map(\.account), ["astro-stakers.poolv1.near", "ledgerbyfigment.poolv1.near", "staked.poolv1.near",
                                                         "binancenode1.poolv1.near", "sumerian.poolv1.near", "zavodil.poolv1.near",
                                                         "cnear-1.poolv1.near", "kiln-1.poolv1.near"])
        // Last epoch's rewards over the stake, for an epoch that took 24,921.9 s (measured from block timestamps).
        let apr = try XCTUnwrap(set.networkAPR(epochSeconds: 24_921.911703443))
        XCTAssertEqual(apr, 0.0498, accuracy: 0.0002)
        XCTAssertNil(set.networkAPR(epochSeconds: 60))             // not a believable epoch: no rate, not a wrong one
        XCTAssertNil(set.networkAPR(epochSeconds: 3_600))          // a rate over 25% a year isn't believable either
        // The fees the pools answered on 2026-11-12. Over 10% (sumerian) and private pools (cnear-1, 100%) aren't listed.
        func fee(_ n: UInt32, _ d: UInt32 = 100) -> NearStaking.Fee { .init(numerator: n, denominator: d) }
        let fees = ["astro-stakers.poolv1.near": fee(1), "ledgerbyfigment.poolv1.near": fee(5), "staked.poolv1.near": fee(10),
                    "binancenode1.poolv1.near": fee(5), "sumerian.poolv1.near": fee(15), "zavodil.poolv1.near": fee(1),
                    "cnear-1.poolv1.near": fee(10000, 10000), "kiln-1.poolv1.near": fee(5)]
        let list = NearStaking.shortlist(set, fees: fees, networkAPR: apr)
        XCTAssertEqual(list.map(\.name), ["astro-stakers", "ledgerbyfigment", "staked", "binancenode1", "zavodil", "kiln-1"])
        XCTAssertEqual(try XCTUnwrap(list[0].estimatedAPR), apr * 0.99, accuracy: 1e-9)
        // A pool whose fee couldn't be read isn't listed, and without a rate none is shown.
        let partial = NearStaking.shortlist(set, fees: ["zavodil.poolv1.near": fee(1)], networkAPR: nil)
        XCTAssertEqual(partial.map(\.id), ["zavodil.poolv1.near"]); XCTAssertNil(partial[0].estimatedAPR)
        XCTAssertNil(NearStaking.ValidatorSet(["current_validators": []]))
    }

    func testPoolNamesAndWords() {
        for ok in ["zavodil.poolv1.near", "liver.pool.near", "bitwise_1.poolv1.near"] { XCTAssertTrue(NearStaking.isFactoryPool(ok), ok) }
        for bad in ["poolv1.near", "evil.near", "a.b.poolv1.near", "zavodil.poolv1.near.evil.near", "Zavodil.poolv1.near", ".pool.near", implicit] {
            XCTAssertFalse(NearStaking.isFactoryPool(bad), bad)
        }
        XCTAssertEqual(NearStaking.poolName("astro-stakers.poolv1.near"), "astro-stakers")
        // Four epochs of 6.9 hours.
        XCTAssertEqual(NearStaking.unlockText(epochSeconds: 24_921.9), "4 epochs, about 28 hours")
        XCTAssertEqual(NearStaking.unlockText(epochSeconds: 43_200), "4 epochs, about 2 days")
        XCTAssertEqual(NearStaking.unlockText(epochSeconds: nil), "4 epochs")
        XCTAssertEqual(NearStaking.percent(0.049203), "4.92%"); XCTAssertEqual(NearStaking.percent(0.1), "10%")
    }

    // MARK: Reserve

    func testReserveIsAlwaysKept() throws {
        // 0.05 NEAR stays, plus this call's fee ceiling (100 Tgas at 2e8 yocto = 0.02 NEAR).
        XCTAssertEqual(NearStaking.feeCeiling, near / 50)
        XCTAssertEqual(NearStaking.maxStake(available: 10 * near), 10 * near - near / 20 - near / 50)
        XCTAssertEqual(NearStaking.maxStake(available: near / 20), 0)
        XCTAssertEqual(NearStaking.maxStake(available: 0), 0)
        let most = NearStaking.maxStake(available: 10 * near)
        let r = try review(.stake(most), context(available: 10 * near))
        XCTAssertEqual(r.actions, [NearStaking.depositAndStake(most)])
        XCTAssertTrue(r.lines.contains(["Stays in your account", "About 0.05 NEAR, for fees"]))
        // One yocto more than the limit is refused, with the limit in the reason.
        XCTAssertTrue(blocked(.stake(most + 1), context(available: 10 * near)).contains("up to 9.93 NEAR"))
        XCTAssertTrue(blocked(.stake(10 * near), context(available: 10 * near)).contains("up to 9.93 NEAR"))
        // An account with only the reserve can't stake at all; one that doesn't exist yet neither.
        XCTAssertTrue(blocked(.stake(near / 100), context(available: near / 16)).contains("Not enough NEAR"))
        XCTAssertTrue(blocked(.stake(near), context(available: nil)).contains("isn't active yet"))
        XCTAssertTrue(blocked(.stake(near / 1000), context(available: 10 * near)).contains("smallest stake"))
    }

    // MARK: Reviews

    func testStakeReview() throws {
        let r = try review(.stake(5 * near / 2), context(available: 10 * near))
        XCTAssertEqual(r.title, "Stake 2.5 NEAR with zavodil"); XCTAssertEqual(r.kind, "Stake on NEAR")
        XCTAssertEqual(r.pool, pool); XCTAssertEqual(r.amount, 5 * near / 2); XCTAssertEqual(r.usd, 5)
        XCTAssertEqual(r.actions, [.functionCall(method: "deposit_and_stake", args: Array("{}".utf8), gas: 100 * NearAction.tgas, deposit: 5 * near / 2)])
        XCTAssertTrue(r.lines.contains(["Pool", pool]))
        XCTAssertTrue(r.lines.contains(["Pool fee", "1% of rewards"]))
        XCTAssertTrue(r.lines.contains(["Estimated rate", "About 4.92% a year after the fee, from last epoch"]))
        XCTAssertTrue(r.lines.contains(["To get it back", "Unstake, wait 4 epochs, about 28 hours, withdraw"]))
        XCTAssertTrue(r.checks.contains("Pool is a NEAR validator this epoch and next"))
        XCTAssertTrue(r.checks.contains { $0.contains("daily limit") })
        XCTAssertTrue(r.warnings.isEmpty)
        // No rate is shown when there isn't one, and a high fee is called out.
        var c = context(available: 10 * near)
        c.networkAPR = nil; c.fee = .init(numerator: 15, denominator: 100)
        let high = try review(.stake(near), c)
        XCTAssertFalse(high.lines.contains { $0[0] == "Estimated rate" })
        XCTAssertTrue(high.warnings.contains("This pool keeps 15% of your rewards."))
    }

    func testStakeIsRefusedWhenThePoolIsntRight() {
        func c(_ change: (inout NearStaking.Context) -> Void) -> NearStaking.Context { var c = context(available: 10 * near); change(&c); return c }
        XCTAssertTrue(blocked(.stake(near), c { $0.active = false }).contains("isn't an active validator"))
        XCTAssertTrue(blocked(.stake(near), c { $0.standardCode = false }).contains("standard staking pool contract"))
        XCTAssertTrue(blocked(.stake(near), c { $0.paused = true }).contains("paused"))
        XCTAssertTrue(blocked(.stake(near), c { $0.fee = nil }).contains("fee"))
        XCTAssertTrue(blocked(.stake(near), c { $0.fee = .init(numerator: 100, denominator: 100) }).contains("100% fee"))
        XCTAssertTrue(blocked(.stake(near), context(available: 10 * near), pool: "evil.near").contains("isn't a NEAR staking pool"))
    }

    func testPolicyCapAppliesToAnAgentStake() throws {
        // $2 a NEAR. 60 NEAR is $120: over the assistant's $100 per-move cap, fine for the user.
        let rich = context(available: 1_000 * near)
        XCTAssertTrue(blocked(.stake(60 * near), rich, origin: .agent).contains("up to $100 per move"))
        XCTAssertNoThrow(try review(.stake(60 * near), rich, origin: .user))
        let ok = try review(.stake(40 * near), rich, origin: .agent)
        XCTAssertTrue(ok.checks.contains { $0.contains("per-move cap") })
        XCTAssertEqual(ok.usd, 80)
        // The assistant can't stake NEAR it can't price; the user can, with a warning.
        var unpriced = rich; unpriced.usdPerNear = nil
        XCTAssertTrue(blocked(.stake(near), unpriced, origin: .agent).contains("without a price"))
        XCTAssertTrue(try review(.stake(near), unpriced, origin: .user).warnings.contains { $0.contains("No price") })
        // The daily limit ($500) holds for everyone, and what's already spent today counts.
        XCTAssertTrue(blocked(.stake(300 * near), rich, origin: .user).contains("daily limit"))
        let p = policy()
        p.limit.record(usd: 450)
        XCTAssertTrue(blocked(.stake(40 * near), rich, origin: .agent, policy: p).contains("daily limit"))
        // A lower cap set in Security applies too.
        let strict = policy()
        strict.agentCapUSD = 25
        XCTAssertTrue(blocked(.stake(20 * near), rich, origin: .agent, policy: strict).contains("up to $25 per move"))
    }

    func testUnstakeAndWithdrawReviews() throws {
        let staked = context(available: near, staked: 5 * near)
        let all = try review(.unstake(nil), staked)
        XCTAssertEqual(all.actions, [NearStaking.unstakeAll]); XCTAssertEqual(all.amount, 5 * near)
        XCTAssertEqual(all.title, "Unstake all NEAR from zavodil")
        XCTAssertTrue(all.lines.contains(["Ready to withdraw in", "4 epochs, about 28 hours"]))
        XCTAssertNil(all.usd)
        let part = try review(.unstake(2 * near), staked)
        XCTAssertEqual(part.actions, [NearStaking.unstake(2 * near)])
        // The whole balance by amount is unstake_all, so rounding leaves nothing behind.
        XCTAssertEqual(try review(.unstake(5 * near), staked).actions, [NearStaking.unstakeAll])
        XCTAssertTrue(blocked(.unstake(6 * near), staked).contains("Only 5 NEAR"))
        XCTAssertTrue(blocked(.unstake(nil), context(available: near)).contains("Nothing is staked"))
        // Leaving never needs the pool to be healthy, and isn't a spend: no cap, no price needed.
        var dead = staked
        dead.active = false; dead.standardCode = false; dead.fee = nil; dead.usdPerNear = nil
        XCTAssertNoThrow(try review(.unstake(nil), dead, origin: .agent, pool: "liver.pool.near"))
        // It does need gas.
        XCTAssertTrue(blocked(.unstake(nil), context(available: near / 1000, staked: 5 * near)).contains("to pay for this"))
        // Unstaking again restarts the wait for what's already unstaked: the review says so.
        XCTAssertTrue(try review(.unstake(near), context(available: near, staked: 5 * near, unstaked: near, canWithdraw: false)).warnings[0].contains("already unstaking"))
        XCTAssertTrue(try review(.unstake(near), context(available: near, staked: 5 * near, unstaked: near, canWithdraw: true)).warnings[0].contains("ready to withdraw"))

        let ready = context(available: near, staked: 5 * near, unstaked: 3 * near, canWithdraw: true)
        let w = try review(.withdraw, ready)
        XCTAssertEqual(w.actions, [NearStaking.withdrawAll]); XCTAssertEqual(w.amount, 3 * near)
        XCTAssertEqual(w.title, "Withdraw 3 NEAR from zavodil")
        XCTAssertTrue(blocked(.withdraw, context(available: near, unstaked: 3 * near, canWithdraw: false)).contains("still unstaking"))
        XCTAssertTrue(blocked(.withdraw, context(available: near, staked: near, unstaked: 2, canWithdraw: true)).contains("Nothing is waiting"))
    }

    // MARK: The assistant's tools

    func testToolRoutingForNear() {
        // prepare_deposit / prepare_withdraw with NEAR as the asset, or with NEAR as the chain and no other asset.
        XCTAssertTrue(NearStaking.handles(symbol: "NEAR", chain: nil))
        XCTAssertTrue(NearStaking.handles(symbol: " near ", chain: "near"))
        XCTAssertTrue(NearStaking.handles(symbol: "NEAR", chain: "ethereum"))   // the model's guessed chain doesn't matter
        XCTAssertTrue(NearStaking.handles(symbol: nil, chain: "NEAR"))
        XCTAssertTrue(NearStaking.handles(symbol: "", chain: "near protocol"))
        // Everything else stays with Aave.
        XCTAssertFalse(NearStaking.handles(symbol: "USDC", chain: "base"))
        XCTAssertFalse(NearStaking.handles(symbol: "USDC", chain: "near"))
        XCTAssertFalse(NearStaking.handles(symbol: "wNEAR", chain: nil))
        XCTAssertFalse(NearStaking.handles(symbol: nil, chain: nil))

        func position(_ pool: String, staked: UInt128 = 0, unstaked: UInt128 = 0, canWithdraw: Bool = true) -> NearStaking.Position {
            .init(walletID: wallet, account: implicit, pool: pool, balance: .init(staked: staked, unstaked: unstaked, canWithdraw: canWithdraw))
        }
        let a = position("astro-stakers.poolv1.near", staked: 5 * near)
        XCTAssertEqual(NearStaking.exit([], amount: nil), .nothing)
        XCTAssertEqual(NearStaking.exit([position(pool, unstaked: 2)], amount: nil), .nothing)          // leftovers aren't a position
        // "Withdraw my NEAR": everything staked is unstaked; an amount unstakes that much.
        XCTAssertEqual(NearStaking.exit([a], amount: nil), .unstake(a, nil))
        XCTAssertEqual(NearStaking.exit([a], amount: 2 * near), .unstake(a, 2 * near))
        XCTAssertEqual(NearStaking.exit([a], amount: 6 * near), .tooMuch(a))
        // NEAR that finished unstaking is withdrawn first.
        let ready = position(pool, staked: near, unstaked: 3 * near, canWithdraw: true)
        XCTAssertEqual(NearStaking.exit([ready], amount: nil), .withdraw(ready))
        XCTAssertEqual(NearStaking.exit([a, ready], amount: nil), .withdraw(ready))
        XCTAssertEqual(NearStaking.exit([ready], amount: near / 2), .unstake(ready, near / 2))
        // Still waiting: nothing to prepare.
        let waiting = position(pool, unstaked: 3 * near, canWithdraw: false)
        XCTAssertEqual(NearStaking.exit([waiting], amount: nil), .waiting([waiting]))
        XCTAssertEqual(NearStaking.exit([waiting, a], amount: nil), .unstake(a, nil))
        // Two pools to choose from: ask.
        let b = position(pool, staked: near)
        XCTAssertEqual(NearStaking.exit([a, b], amount: nil), .choose([a, b]))
        XCTAssertEqual(NearStaking.exit([a, b], amount: near), .choose([a, b]))
    }

    func testWhichPoolsAWalletUsed() throws {
        // FastNEAR's answer for an account (2026-11-12), with one row that isn't a staking pool added.
        let index = try JSONDecoder().decode(JSON.self, from: Data(#"{"account_id":"a.near","pools":[{"pool_id":"npro.poolv1.near","last_update_block_height":208631923},{"pool_id":"liver.pool.near","last_update_block_height":219106258},{"pool_id":"evil.near","last_update_block_height":1}]}"#.utf8))
        XCTAssertEqual(NearStaking.pools(fromIndex: index), ["npro.poolv1.near", "liver.pool.near"])
        XCTAssertNil(NearStaking.pools(fromIndex: ["error": "x"]))
        let d = UserDefaults(suiteName: "stake-\(UUID())")!
        XCTAssertEqual(NearStaking.remembered(account: implicit, defaults: d), [])
        NearStaking.remember(pool: pool, account: implicit, defaults: d)
        NearStaking.remember(pool: pool, account: implicit, defaults: d)
        NearStaking.remember(pool: "astro-stakers.poolv1.near", account: implicit, defaults: d)
        XCTAssertEqual(NearStaking.remembered(account: implicit, defaults: d), [pool, "astro-stakers.poolv1.near"])
        XCTAssertEqual(NearStaking.remembered(account: "other.near", defaults: d), [])
    }
}
