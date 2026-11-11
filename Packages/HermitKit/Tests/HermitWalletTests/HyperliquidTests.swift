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

    func object(_ s: String) throws -> [String: Any] { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }

    /// Shapes from the live info API (2026-11-11). A unified account keeps its USDC in the spot state; the perp dex states
    /// show almost nothing.
    func testUnifiedAccountReadsSpotUSDC() throws {
        let main = try object(#"""
        {"marginSummary":{"accountValue":"0.0","totalMarginUsed":"0.0"},"withdrawable":"0.0009","assetPositions":[
          {"position":{"coin":"BTC","szi":"0.01","entryPx":"62000","positionValue":"625","unrealizedPnl":"12.5","returnOnEquity":"0.1",
           "leverage":{"type":"isolated","value":5},"liquidationPx":"50000","marginUsed":"125"}}]}
        """#)
        let xyz = try object(#"{"marginSummary":{"accountValue":"1.43","totalMarginUsed":"0.0"},"withdrawable":"1.43","assetPositions":[]}"#)
        let spot = try object(#"""
        {"balances":[{"coin":"USDC","token":0,"total":"21374.99","hold":"3000.0","entryNtl":"0.0"}],"tokenToAvailableAfterMaintenance":[[0,"16982.98"]]}
        """#)
        let a = Hyperliquid.account(states: [main, xyz], orders: [], spot: spot, mode: "unifiedAccount")
        XCTAssertTrue(a.isUnified)
        XCTAssertEqual(a.withdrawable, 16982.98, accuracy: 0.001)
        XCTAssertEqual(a.accountValue, 21374.99 + 12.5, accuracy: 0.001)
        XCTAssertEqual(a.spotUSDC, 21374.99, accuracy: 0.001)
        XCTAssertEqual(a.positions.first?.cross, false)
        // Without the available-after-maintenance entry: total minus hold.
        let bare = try object(#"{"balances":[{"coin":"USDC","token":0,"total":"79.38","hold":"0.0"}]}"#)
        XCTAssertEqual(Hyperliquid.account(states: [main], orders: [], spot: bare, mode: "portfolioMargin").withdrawable, 79.38, accuracy: 0.001)
        // A standard account adds each dex's own numbers and leaves spot USDC aside.
        let std = Hyperliquid.account(states: [main, xyz], orders: [], spot: spot, mode: "default")
        XCTAssertFalse(std.isUnified)
        XCTAssertEqual(std.withdrawable, 0.0009 + 1.43, accuracy: 0.0001)
        XCTAssertEqual(std.accountValue, 1.43, accuracy: 0.0001)
        XCTAssertEqual(Hyperliquid.account(states: [main], orders: [], spot: nil, mode: nil).mode, "default")
    }

    func testTriggerOrdersKeepTheirTrigger() throws {
        let stop = try object(#"""
        {"coin":"BTC","oid":42,"side":"A","limitPx":"81510.0","sz":"0.0","reduceOnly":true,"timestamp":1762500000000,"orderType":"Stop Market",
         "isTrigger":true,"triggerPx":"74100.0","triggerCondition":"Price above 74100","isPositionTpsl":true}
        """#)
        let limit = try object(#"{"coin":"ETH","oid":43,"side":"B","limitPx":"3000","sz":"0.5","timestamp":1762500000000}"#)
        let a = Hyperliquid.account(states: [], orders: [[stop, limit]], spot: nil, mode: nil)
        XCTAssertEqual(a.orders.count, 2)
        let s = a.orders[0]
        XCTAssertTrue(s.isTrigger); XCTAssertTrue(s.isPositionTpsl)
        XCTAssertEqual(s.orderType, "Stop Market"); XCTAssertEqual(s.triggerPx, 74100); XCTAssertEqual(s.triggerCondition, "Price above 74100")
        XCTAssertFalse(a.orders[1].isTrigger); XCTAssertEqual(a.orders[1].orderType, "Limit")
    }

    func testTakeProfitAndStopLossAnswersAreRead() {
        let o = Hyperliquid.Order(asset: btc, isBuy: true, price: 62000, size: 0.001, takeProfit: 65000, stopLoss: 60000)
        let p = HyperliquidTrader.protection(o, statuses: ["waitingForTrigger", ["error": "Invalid TP/SL price. asset=0"]])
        XCTAssertEqual(p, [Hyperliquid.Protection(kind: "Take profit", error: nil),
                           Hyperliquid.Protection(kind: "Stop loss", error: "Invalid TP/SL price. asset=0")])
        let r = Hyperliquid.OrderResult.filled(oid: 1, size: 0.001, avgPrice: 62000, protection: p)
        XCTAssertTrue(r.protectionFailed)
        XCTAssertEqual(r.summary, "Filled 0.001 at $62000. Take profit set. Stop loss not set: Invalid TP/SL price. asset=0")
        // An answer that's missing never counts as set.
        let missing = HyperliquidTrader.protection(o, statuses: [["resting": ["oid": 7]]])
        XCTAssertNil(missing[0].error)
        XCTAssertEqual(missing[1].error, "Hyperliquid didn't confirm it")
        XCTAssertEqual(Hyperliquid.OrderResult.resting(oid: 2).summary, "Order placed")
        XCTAssertTrue(HyperliquidTrader.protection(.init(asset: btc, isBuy: true, price: 62000, size: 0.001), statuses: []).isEmpty)
    }
}
