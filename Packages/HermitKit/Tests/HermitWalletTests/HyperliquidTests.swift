import XCTest
@testable import HermitWallet

/// Vectors from hyperliquid-python-sdk (signing.py: action_hash, sign_l1_action) with key 0x11…11 and nonce 1762500000000.
final class HyperliquidTests: XCTestCase {
    let key = [UInt8](repeating: 0x11, count: 32)
    let nonce: UInt64 = 1_762_500_000_000
    let btc = Hyperliquid.Asset(coin: "BTC", id: 0, szDecimals: 5, maxLeverage: 40, onlyIsolated: false)

    func testOrderMsgpackHashAndSignature() throws {
        let action = Hyperliquid.orderAction(.init(asset: btc, isBuy: true, price: 62000, size: 0.0015))
        XCTAssertEqual(action.encoded.hex, "83a474797065a56f72646572a66f72646572739186a16100a162c3a170a53632303030a173a6302e30303135a172c2a17481a56c696d697481a3746966a3477463a867726f7570696e67a26e61")
        let h = Hyperliquid.actionHash(action, nonce: nonce)
        XCTAssertEqual(h.hex, "fcf8ea5a41d871390f60d900cd5f71f84c318898344cda4fe5ecf281f67b419d")
        let sig = try Hyperliquid.signature(digest: Hyperliquid.agentDigest(connectionID: h), key: key)
        XCTAssertEqual(sig["r"] as? String, "0xbe8e9cdf6cf9359af1ecea480685c8d7a582a2bbf9b5f7d5a918ffa9e7943b1a")
        XCTAssertEqual(sig["s"] as? String, "0x7f355e32279fa2307785004b74d4a819d17d80989e0a3d18b154e572c0b745aa")
        XCTAssertEqual(sig["v"] as? Int, 27)
    }

    func testLeverageOnBuilderDex() throws {
        let tsla = Hyperliquid.Asset(coin: "xyz:TSLA", id: 110_005, szDecimals: 3, maxLeverage: 10, onlyIsolated: true)
        let a = Hyperliquid.leverageAction(asset: tsla, leverage: 5, cross: true)
        let h = Hyperliquid.actionHash(a, nonce: nonce)
        XCTAssertEqual(h.hex, "ea303fabf6c924e21da191b78b4e40b8d8b4dc0262b1d73a288bfa70977a0512")
        let sig = try Hyperliquid.signature(digest: Hyperliquid.agentDigest(connectionID: h), key: key)
        XCTAssertEqual(sig["r"] as? String, "0x6f51ddc1663bbee860bb5b379b26ff50006fc17aabd7d26315032618e18f3ac7")
    }

    func testRounding() {
        XCTAssertEqual(Hyperliquid.roundPrice(62123.456, szDecimals: 5), 62123)
        XCTAssertEqual(Hyperliquid.roundPrice(0.0123456, szDecimals: 0), 0.012346)
        XCTAssertEqual(Hyperliquid.roundPrice(3.456789, szDecimals: 2), 3.4568)
        XCTAssertEqual(Hyperliquid.roundSize(0.0012999, szDecimals: 5), 0.00129)
        XCTAssertEqual(Hyperliquid.wire(62000), "62000")
        XCTAssertEqual(Hyperliquid.wire(0.0015), "0.0015")
    }
}
