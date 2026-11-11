import XCTest
@testable import HermitWallet

/// The actions behind set_tp_sl and a cancel of several orders: what is signed, field by field. No network, no key.
final class HyperliquidProtectionTests: XCTestCase {
    let sol = Hyperliquid.Asset(coin: "SOL", id: 5, szDecimals: 2, maxLeverage: 20, onlyIsolated: false)

    func orders(_ action: MsgPack) -> [[String: Any]] { ((action.json as? [String: Any])?["orders"] as? [[String: Any]]) ?? [] }
    func trigger(_ order: [String: Any]) -> [String: Any] { ((order["t"] as? [String: Any])?["trigger"] as? [String: Any]) ?? [:] }

    /// A long's protection sells: reduce only, market on trigger, for the whole position (size 0, grouping positionTpsl).
    func testProtectionForALong() {
        let action = Hyperliquid.protectionAction(asset: sol, isLong: true, takeProfit: 170, stopLoss: 128)
        let json = action.json as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "order")
        XCTAssertEqual(json?["grouping"] as? String, "positionTpsl")
        let list = orders(action)
        XCTAssertEqual(list.count, 2)
        for o in list {
            XCTAssertEqual(o["a"] as? Int, 5)
            XCTAssertEqual(o["b"] as? Bool, false, "a long is closed by selling")
            XCTAssertEqual(o["r"] as? Bool, true, "reduce only")
            XCTAssertEqual(o["s"] as? String, "0", "the whole position")
            XCTAssertEqual(trigger(o)["isMarket"] as? Bool, true)
        }
        XCTAssertEqual(trigger(list[0])["tpsl"] as? String, "tp")
        XCTAssertEqual(trigger(list[0])["triggerPx"] as? String, "170")
        XCTAssertEqual(trigger(list[1])["tpsl"] as? String, "sl")
        XCTAssertEqual(trigger(list[1])["triggerPx"] as? String, "128")
        // The limit price is a slippage cap past the trigger: below it for a sell.
        XCTAssertEqual(list[1]["p"] as? String, "115.2")
    }

    /// A short's protection buys, and one price alone is one order.
    func testStopAloneForAShort() {
        let action = Hyperliquid.protectionAction(asset: sol, isLong: false, takeProfit: nil, stopLoss: 150)
        let list = orders(action)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["b"] as? Bool, true, "a short is closed by buying")
        XCTAssertEqual(list[0]["r"] as? Bool, true)
        XCTAssertEqual(trigger(list[0])["tpsl"] as? String, "sl")
        XCTAssertEqual(list[0]["p"] as? String, "165")
        XCTAssertEqual((action.json as? [String: Any])?["grouping"] as? String, "positionTpsl")
    }

    /// set_tp_sl's review prints wire(roundPrice(asked)) and hands roundPrice(asked) to this action. The trigger that is
    /// signed is that same text, from the rounded price and from the raw one alike: the price shown is the price signed.
    func testTriggerSignedIsTheTriggerShown() {
        let eth = Hyperliquid.Asset(coin: "ETH", id: 1, szDecimals: 4, maxLeverage: 25, onlyIsolated: false)
        let cases: [(Hyperliquid.Asset, Double)] = [(sol, 128.123456), (sol, 170.0), (sol, 99.99999), (sol, 0.0123456789), (eth, 3456.789), (eth, 123456.7)]
        for (asset, asked) in cases {
            let rounded = Hyperliquid.roundPrice(asked, szDecimals: asset.szDecimals)
            let shown = Hyperliquid.wire(rounded)
            let fromShown = orders(Hyperliquid.protectionAction(asset: asset, isLong: true, takeProfit: rounded, stopLoss: nil))
            XCTAssertEqual(trigger(fromShown[0])["triggerPx"] as? String, shown, "\(asked)")
            let fromRaw = orders(Hyperliquid.protectionAction(asset: asset, isLong: false, takeProfit: nil, stopLoss: asked))
            XCTAssertEqual(trigger(fromRaw[0])["triggerPx"] as? String, shown, "\(asked)")
        }
        let signed = orders(Hyperliquid.protectionAction(asset: sol, isLong: true, takeProfit: 128.123456, stopLoss: 3456.789))
        XCTAssertEqual(trigger(signed[0])["triggerPx"] as? String, "128.12")
        XCTAssertEqual(trigger(signed[1])["triggerPx"] as? String, "3456.8")
    }

    func testCancelSeveral() {
        let action = Hyperliquid.cancelAction([(assetID: 1, oid: 8123), (assetID: 0, oid: 8200)])
        let json = action.json as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "cancel")
        let cancels = json?["cancels"] as? [[String: Any]]
        XCTAssertEqual(cancels?.count, 2)
        XCTAssertEqual(cancels?.first?["a"] as? Int, 1)
        XCTAssertEqual(cancels?.first?["o"] as? Int, 8123)
        XCTAssertEqual(cancels?.last?["o"] as? Int, 8200)
        // One order through the same builder is the same bytes as the existing single cancel.
        XCTAssertEqual(Hyperliquid.cancelAction([(assetID: 1, oid: 8123)]).encoded, Hyperliquid.cancelAction(assetID: 1, oid: 8123).encoded)
    }

    func testMakersForTests() {
        let p = Hyperliquid.Position.make(coin: "SOL", size: 10, entry: 140.1, pnl: 22.6, leverage: 5, liquidation: 118.4)
        XCTAssertEqual(p.value, 1401, accuracy: 0.001)
        let o = Hyperliquid.OpenOrder.make(coin: "SOL", oid: 8140, isBuy: false, price: 115.2, size: 0, reduceOnly: true, orderType: "Stop Market",
                                           isTrigger: true, triggerPx: 128, isPositionTpsl: true)
        let a = Hyperliquid.Account.make(accountValue: 250.5, positions: [p], orders: [o])
        XCTAssertEqual(a.positions.count, 1)
        XCTAssertEqual(a.orders.first?.triggerPx, 128)
    }
}
