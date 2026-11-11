import XCTest
@testable import HermitWallet

/// Readable quote amounts, Aave's live supply rate, and batch-send validation that needs no network.
final class BatchAaveTests: XCTestCase {
    func testApprox() {
        XCTAssertEqual(Units.approx("5.518223344556677889900112"), "5.518")
        XCTAssertEqual(Units.approx("2.690444351237006824200359"), "2.69")
        XCTAssertEqual(Units.approx("55.1849"), "55.18")
        XCTAssertEqual(Units.approx("12345.678"), "12345.68")
        XCTAssertEqual(Units.approx("0.000551849"), "0.0005518")
        XCTAssertEqual(Units.approx("20"), "20")
        XCTAssertEqual(Units.approx("0"), "0")
        XCTAssertEqual(Units.approx("abc"), "abc")
    }

    func testAaveAPY() {
        // 5% APR in ray, compounded per second: about 5.127% APY.
        let oneRay = UInt128(1_000_000_000) * 1_000_000_000 * 1_000_000_000
        XCTAssertEqual(AaveV3.apy(liquidityRateRay: oneRay * 5 / 100), 0.05127, accuracy: 0.00002)
        XCTAssertEqual(AaveV3.apy(liquidityRateRay: 0), 0)
    }

    func testReserveDataParse() {
        var words = [[UInt8]](repeating: [UInt8](repeating: 0, count: 32), count: 15)
        // currentLiquidityRate (word 2) = 4% APR in ray; aTokenAddress (word 8).
        let rate = UInt128(1_000_000_000) * 1_000_000_000 * 1_000_000_000 * 4 / 100
        var r = rate
        for i in (16..<32).reversed() { words[2][i] = UInt8(r & 0xff); r >>= 8 }
        let aToken = [UInt8](repeating: 0xab, count: 20)
        words[8].replaceSubrange(12..<32, with: aToken)
        let res = AaveV3.reserve(fromReserveData: words.flatMap { $0 })
        XCTAssertEqual(res?.aToken, EVMAddress(bytes: aToken))
        XCTAssertEqual(res?.supplyAPY ?? 0, 0.04081, accuracy: 0.00002)
        // An asset the pool doesn't list comes back all zeros.
        XCTAssertNil(AaveV3.reserve(fromReserveData: [UInt8](repeating: 0, count: 32 * 15)))
        XCTAssertEqual(AaveV3.tokens(on: .base).map(\.symbol), ["USDC"])
        XCTAssertTrue(AaveV3.tokens(on: .polygon).isEmpty, "no Aave pool configured there")
    }

    func testAavePoolAddresses() {
        // Checked against PoolAddressesProvider.getPool() on each network; a wrong one is an empty account where deposits "succeed".
        XCTAssertEqual(AaveV3.pools, [
            "ethereum": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
            "base": "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
            "arbitrum": "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
        ])
        for c in [Chain.ethereum, Chain.base, Chain.arbitrum] { XCTAssertNotNil(AaveV3.pool(on: c), "\(c.id) pool must pass its checksum") }
    }

    /// Native coins count toward the daily limit at their price, stablecoins at face value, and an unpriced send says so.
    @MainActor func testDailyLimitCountsPricedCoins() {
        let d = UserDefaults(suiteName: "hermit.wallet.tests.\(UUID())")!
        let svc = WalletService(vault: KeyVault(store: HermitWallet.MemoryStore()), addressBook: AddressBook(defaults: d),
                                spendLimit: SpendLimit(defaults: d), sendLog: SendLog(defaults: d))
        let to = "0x1111111111111111111111111111111111111111"
        func limitCheck(_ chain: Chain, _ token: Token?, _ value: UInt128, usd: Decimal?) -> HazardCheck? {
            svc.hazardChecks(chain: chain, token: token, value: value, recipient: to, simOK: true, simDetail: "", usd: usd)
                .first { $0.title.lowercased().contains("daily limit") }
        }
        // 0.25 ETH priced at $600: over the default $500 limit, so the send is blocked.
        XCTAssertEqual(limitCheck(.ethereum, nil, 250_000_000_000_000_000, usd: 600)?.status, .fail)
        let ok = limitCheck(.ethereum, nil, 1_000_000_000_000_000, usd: Decimal(string: "2.4")!)
        XCTAssertEqual(ok?.status, .pass)
        XCTAssertEqual(ok?.detail, "$497.60 of $500 left today after this.")
        // Stablecoins still count at face value without a price.
        XCTAssertEqual(limitCheck(.base, Chain.base.token("USDC"), 1_250_000, usd: nil)?.detail, "$498.75 of $500 left today after this.")
        // No price: a warning, never a silent pass.
        XCTAssertEqual(limitCheck(.ethereum, nil, 1, usd: nil)?.status, .warn)
    }

    func testPendingSendSaysNotToResend() {
        let e = WalletError.pending(hash: "0xabc", explorer: "https://basescan.org/tx/0xabc")
        XCTAssertTrue(e.errorDescription?.contains("don't send it again") == true)
        XCTAssertTrue(e.errorDescription?.contains("0xabc") == true)
    }

    func testRateLimitBackoff() {
        XCTAssertEqual(JSONRPCClient.retrySeconds(retryAfter: "2", reset: nil, attempt: 1), 2)
        XCTAssertEqual(JSONRPCClient.retrySeconds(retryAfter: nil, reset: "8", attempt: 1), 5, "capped at 5 s")
        // An HTTP-date Retry-After isn't read: the growing pause applies.
        XCTAssertEqual(JSONRPCClient.retrySeconds(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", reset: nil, attempt: 3), 1.5)
        XCTAssertEqual(JSONRPCClient.maxRetries, 4)
    }

    /// When CoinGecko fails, prices come from 1Click's token list, matched by chain (a look-alike elsewhere is ignored).
    func testIntentsPriceFallback() throws {
        let json = """
        [{"assetId":"nep141:eth.omft.near","decimals":18,"blockchain":"eth","symbol":"ETH","price":2400.5,"contractAddress":null},
         {"assetId":"nep141:wrap.near","decimals":24,"blockchain":"near","symbol":"wNEAR","price":2.1,"contractAddress":"wrap.near"},
         {"assetId":"nep141:pol.omft.near","decimals":18,"blockchain":"pol","symbol":"POL","price":0.0877,"contractAddress":null},
         {"assetId":"nep141:fake.omft.near","decimals":18,"blockchain":"base","symbol":"SOL","price":99999,"contractAddress":"0x1234"}]
        """
        let list = try JSONDecoder().decode([IntentsToken].self, from: Data(json.utf8))
        let q = PriceFeed.quotes(fromIntents: list)
        XCTAssertEqual(q["ETH"]?.usd, 2400.5)
        XCTAssertEqual(q["POL"]?.usd, 0.0877)
        XCTAssertEqual(q["NEAR"]?.usd, 2.1)
        XCTAssertEqual(q["wNEAR"]?.usd, 2.1)
        XCTAssertNil(q["SOL"])
        XCTAssertNil(q["ETH"]?.change24h)
    }

    /// Batches run on EVM networks and Solana (SolanaBatchTests); NEAR has none.
    @MainActor func testBatchRejectsNonEVM() async {
        let svc = WalletService(vault: KeyVault(store: HermitWallet.MemoryStore()))
        _ = try? svc.importWallet(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", name: "T")
        do {
            _ = try await svc.planBatch(walletID: nil, chain: .near, symbol: "USDC", recipients: [("x", "1")], origin: .agent)
            XCTFail("NEAR batches aren't supported")
        } catch { XCTAssertTrue("\(error)".contains("EVM networks")) }
        do {
            _ = try await svc.planBatch(walletID: nil, chain: .base, symbol: "USDC",
                                        recipients: Array(repeating: ("0x1111111111111111111111111111111111111111", "1"), count: 201), origin: .agent)
            XCTFail("over the batch limit")
        } catch { XCTAssertTrue("\(error)".contains("up to 200")) }
    }

    /// Live, read-only: validation of a mixed list on Base against the empty test wallet. ONECLICK_LIVE-style opt in.
    @MainActor func testLiveBatchPlan() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMIT_LIVE"] != nil, "set HERMIT_LIVE=1 to read Base over RPC")
        let svc = WalletService(vault: KeyVault(store: HermitWallet.MemoryStore()))
        _ = try svc.importWallet(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", name: "T")
        let me = svc.selected!.evmAddress
        let plan = try await svc.planBatch(walletID: nil, chain: .base, symbol: "USDC", recipients: [
            ("0x1111111111111111111111111111111111111111", "1.5"), ("0x1111111111111111111111111111111111111111", "2"),
            (me, "1"), ("0x52908400098527886E0F7030069857D2E4169EE7", "1"), ("0x52908400098527886e0f7030069857d2e4169ee8", "x"), ("bob.eth", "1"),
        ], origin: .agent)
        XCTAssertEqual(plan.valid.count, 2)
        XCTAssertEqual(plan.invalid.map(\.problem), ["Same address as row 1", "That's this wallet", "Amount x isn't valid for USDC", "Names aren't looked up in a batch; use the 0x address"])
        XCTAssertEqual(plan.total, "2.5")
        XCTAssertFalse(plan.blocks.isEmpty, "the test wallet holds no USDC")
        XCTAssertFalse(plan.canSend)
    }
}
