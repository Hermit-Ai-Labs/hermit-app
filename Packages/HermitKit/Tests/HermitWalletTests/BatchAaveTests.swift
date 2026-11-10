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

    @MainActor func testBatchRejectsNonEVM() async {
        let svc = WalletService(vault: KeyVault(store: HermitWallet.MemoryStore()))
        _ = try? svc.importWallet(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", name: "T")
        do {
            _ = try await svc.planBatch(walletID: nil, chain: .solana, symbol: "USDC", recipients: [("x", "1")], origin: .agent)
            XCTFail("Solana batches aren't supported")
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
