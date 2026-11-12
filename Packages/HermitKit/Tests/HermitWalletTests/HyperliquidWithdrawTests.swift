import XCTest
@testable import HermitWallet

/// Vectors from hyperliquid-python-sdk 0.24.0 (utils/signing.py: user_signed_payload, WITHDRAW_SIGN_TYPES,
/// sign_withdraw_from_bridge_action) with the public throwaway key 0x46…46 (address 0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F).
/// The 0x66eee case is the SDK's own signing call; the 0xa4b1 ones are the same payload with Hermit's chain id.
final class HyperliquidWithdrawTests: XCTestCase {
    let key = [UInt8](repeating: 0x46, count: 32)
    let own = "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f"

    func sign(_ typed: EIP712) throws -> (digest: String, r: String, s: String, v: Int) {
        let d = try typed.digest()
        let sig = try Hyperliquid.signature(digest: d, key: key)
        return (d.hex, sig["r"] as? String ?? "", sig["s"] as? String ?? "", sig["v"] as? Int ?? 0)
    }

    func testDigestAndSignatureMatchTheSDKOnItsOwnChainID() throws {
        let t = Hyperliquid.withdrawTypedData(destination: own, amount: "12.5", time: 1_700_000_000_000, chain: "0x66eee")
        let s = try sign(t)
        XCTAssertEqual(s.digest, "a938bac4cfbb3c804a13364fd22b4401236fa3b4c5ff1f06fec39838dfe0523f")
        XCTAssertEqual(s.r, "0x99b0a0a051940628465244c5dabdb4b7d59a7ae4b2444bd4c88d12ee13a6c03e")
        XCTAssertEqual(s.s, "0x2235a18b7dacc1cd583fa7c023aae5c7d6eb4aff6bcfbba4dc2b5db8a1893687")
        XCTAssertEqual(s.v, 28)
    }

    func testDigestAndSignatureOnArbitrum() throws {
        let a = try sign(Hyperliquid.withdrawTypedData(destination: own, amount: "12.5", time: 1_700_000_000_000))
        XCTAssertEqual(a.digest, "717592e7e7c3a25bdf817bafa23e9a35967669957ebac894acfa79f6b744fab2")
        XCTAssertEqual(a.r, "0xc4914f83f9b0acd6f6e18248141cbba8ca668d9a953a47dcf7e4db7e0b73373c")
        XCTAssertEqual(a.s, "0x761a5d5295fe0325c0cbae56a0ee19b1173b9de0b6c49cb3bd4f33596a9e5e03")
        XCTAssertEqual(a.v, 27)
        let b = try sign(Hyperliquid.withdrawTypedData(destination: own, amount: "100", time: 1_762_900_000_123))
        XCTAssertEqual(b.digest, "2bf3b9774926813bd493353fe130ddd768c3c5eeeee277cf856d85af78d0843a")
        XCTAssertEqual(b.r, "0xce4889955a3c7c56edf17d85b5e8cb9c33381aea3cc05e45eb761ed562a13955")
        XCTAssertEqual(b.s, "0x77328945b799d59255bbb3d194f9dbcb14989f3058ed669407e4a49a89d5568c")
        XCTAssertEqual(b.v, 27)
    }

    func testRequestBody() throws {
        let time: UInt64 = 1_700_000_000_000
        let action = Hyperliquid.withdrawAction(destination: own, amount: "12.5", time: time)
        let sig: [String: Any] = ["r": "0xaa", "s": "0xbb", "v": 27]
        let body = Hyperliquid.withdrawBody(action: action, time: time, signature: sig)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text, #"{"action":{"amount":"12.5","destination":"\#(own)","hyperliquidChain":"Mainnet","signatureChainId":"0xa4b1","time":1700000000000,"type":"withdraw3"},"nonce":1700000000000,"signature":{"r":"0xaa","s":"0xbb","v":27}}"#)
    }

    func testAmountText() {
        XCTAssertEqual(Hyperliquid.usdcText(12.5), "12.5")
        XCTAssertEqual(Hyperliquid.usdcText(100), "100")
        XCTAssertEqual(Hyperliquid.usdcText(Decimal(string: "0.1234567")!), "0.123456")
        XCTAssertEqual(Hyperliquid.parseUSDC("12.50"), Decimal(string: "12.5"))
        for bad in ["", "0", "-1", "1e3", "1,5", ".5", "5.", "1.1234567", "inf", "0x10", "1 2"] { XCTAssertNil(Hyperliquid.parseUSDC(bad), bad) }
    }

    // MARK: Review

    let id = UUID()
    func review(_ amount: String, _ account: Hyperliquid.Account, to: String? = nil) throws -> Hyperliquid.WithdrawReview {
        try Hyperliquid.withdrawReview(walletID: id, ownAddress: "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F", destination: to, amount: amount, account: account)
    }

    func testPlainWithdrawalPasses() throws {
        let r = try review("50", .make(accountValue: 100, withdrawable: 100))
        XCTAssertTrue(r.canSend)
        XCTAssertEqual(r.receive, 49)
        XCTAssertEqual(r.destination, own)
        XCTAssertFalse(r.positionsOpen)
        XCTAssertTrue(r.checks.allSatisfy { $0.status == .pass })
    }

    func testOverWithdrawableIsBlocked() throws {
        let r = try review("60", .make(accountValue: 100, withdrawable: 40))
        XCTAssertFalse(r.canSend)
        XCTAssertTrue(r.blockingReason?.contains("40") == true)
    }

    func testAtOrBelowTheFeeIsBlocked() throws {
        XCTAssertFalse(try review("1", .make(accountValue: 100, withdrawable: 100)).canSend)
        XCTAssertFalse(try review("0.5", .make(accountValue: 100, withdrawable: 100)).canSend)
        XCTAssertTrue(try review("1.5", .make(accountValue: 100, withdrawable: 100)).canSend)
    }

    func testOpenPositionsWarnWhenLittleMarginStaysFree() throws {
        let p = Hyperliquid.Position.make(coin: "BTC", size: 0.01, entry: 62000, margin: 60)
        let tight = try review("30", .make(accountValue: 100, withdrawable: 40, marginUsed: 60, positions: [p]))
        XCTAssertTrue(tight.canSend)
        XCTAssertTrue(tight.positionsOpen)
        XCTAssertTrue(tight.checks.contains { $0.status == .warn })
        let roomy = try review("5", .make(accountValue: 100, withdrawable: 40, marginUsed: 60, positions: [p]))
        XCTAssertFalse(roomy.checks.contains { $0.status == .warn })
    }

    func testOnlyYourOwnAddressAndUnifiedAccountsToo() throws {
        XCTAssertFalse(try review("50", .make(accountValue: 100, withdrawable: 100), to: "0x1111111111111111111111111111111111111111").canSend)
        // Unified and portfolio margin withdraw from their one USDC balance, still within what's free.
        XCTAssertTrue(try review("50", .make(accountValue: 100, withdrawable: 100, mode: "unifiedAccount")).canSend)
        XCTAssertTrue(try review("50", .make(accountValue: 100, withdrawable: 100, mode: "portfolioMargin")).canSend)
        XCTAssertFalse(try review("150", .make(accountValue: 100, withdrawable: 100, mode: "unifiedAccount")).canSend)
        XCTAssertThrowsError(try review("abc", .make(accountValue: 100, withdrawable: 100)))
    }
}
