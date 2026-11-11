import Foundation
import HermitCore

// Take profit and stop loss on a position that is already open, and cancelling several orders at once.
// Hyperliquid.swift only sends triggers along with a new order (grouping "normalTpsl"). A trigger for an existing
// position goes out on its own with grouping "positionTpsl": reduce only, fires as a market order, and covers the whole
// position whatever its size is by then (Hyperliquid lists such an order with size 0).
// Spec: hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint (place an order, cancel).

extension Hyperliquid {
    /// The order action for a take profit and/or a stop loss on the whole open position.
    /// `isLong` is the position's side: the triggers trade the other way (they sell a long, buy back a short).
    static func protectionAction(asset: Asset, isLong: Bool, takeProfit: Double?, stopLoss: Double?) -> MsgPack {
        var orders: [MsgPack] = []
        // Size 0 with "positionTpsl" means the whole position, and follows it when it grows or shrinks.
        if let tp = takeProfit { orders.append(triggerWire(asset: asset, isBuy: !isLong, size: 0, trigger: tp, kind: "tp")) }
        if let sl = stopLoss { orders.append(triggerWire(asset: asset, isBuy: !isLong, size: 0, trigger: sl, kind: "sl")) }
        return .map([("type", .string("order")), ("orders", .array(orders)), ("grouping", .string("positionTpsl"))])
    }

    /// One cancel action for several orders.
    static func cancelAction(_ items: [(assetID: Int, oid: Int)]) -> MsgPack {
        .map([("type", .string("cancel")),
              ("cancels", .array(items.map { MsgPack.map([("a", .int($0.assetID)), ("o", .int($0.oid))]) }))])
    }
}

extension HyperliquidTrader {
    /// Sets a take profit and/or a stop loss on the open position in `asset`, replacing the triggers in `replacing`
    /// (the same kind, set earlier). Everything is signed after one Face ID / Touch ID. The new triggers go first, so
    /// the position is never left without the protection it had: if the old ones then can't be cancelled, the answer
    /// says so and both stay.
    /// Returns a line for the user: "Stop loss set at $128".
    public func protect(asset: Hyperliquid.Asset, isLong: Bool, takeProfit: Double?, stopLoss: Double?, replacing: [Int] = []) async throws -> String {
        guard takeProfit != nil || stopLoss != nil else { throw WalletError.blocked("Give a take profit or a stop loss price.") }
        var actions: [MsgPack] = [Hyperliquid.protectionAction(asset: asset, isLong: isLong, takeProfit: takeProfit, stopLoss: stopLoss)]
        if !replacing.isEmpty { actions.append(Hyperliquid.cancelAction(replacing.map { (assetID: asset.id, oid: $0) })) }
        let kinds: [String] = (takeProfit == nil ? [] : ["Take profit"]) + (stopLoss == nil ? [] : ["Stop loss"])
        let signed = try await sign(actions, reason: "Set \(kinds.joined(separator: " and ").lowercased()) on \(asset.coin) on Hyperliquid")

        // The new triggers. Any refusal here stops everything: nothing was cancelled yet.
        let placed = try await post(signed[0])
        let statuses = ((placed["data"] as? [String: Any])?["statuses"] as? [Any]) ?? []
        // Every status is read before anything is reported: if one of two went in and the other didn't, the error names
        // both, so a trigger that is live is never passed over as "not set".
        var refused: [String] = [], live: [String] = []
        for (i, kind) in kinds.enumerated() {
            if i >= statuses.count { refused.append("Hyperliquid didn't confirm the \(kind.lowercased())") }
            else if let d = statuses[i] as? [String: Any], let e = d["error"] as? String { refused.append("\(kind) not set: \(Self.plain(e))") }
            else { live.append(kind) }
        }
        if !refused.isEmpty {
            let also = live.isEmpty ? "" : ". \(live.joined(separator: " and ")) was set: check it in Trade, Positions"
            throw WalletError.blocked(refused.joined(separator: ". ") + also)
        }
        var parts: [String] = []
        if let tp = takeProfit { parts.append("Take profit set at $\(trimNumber(tp))") }
        if let sl = stopLoss { parts.append("Stop loss set at $\(trimNumber(sl))") }

        // Then the ones they replace. A failure here is reported, not thrown: the new triggers are already live.
        if signed.count > 1 {
            do {
                let reply = try await post(signed[1])
                let failed = (((reply["data"] as? [String: Any])?["statuses"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["error"] as? String }
                if let e = failed.first { parts.append("The earlier one is still there (\(Self.plain(e))). Cancel it in Trade, Positions") }
            } catch {
                parts.append("The earlier one is still there. Cancel it in Trade, Positions")
            }
        }
        return parts.joined(separator: ". ")
    }

    /// Cancels several resting or trigger orders with one signature (one Face ID / Touch ID).
    public func cancelMany(_ orders: [(assetID: Int, oid: Int)], reason: String) async throws {
        guard !orders.isEmpty else { return }
        let signed = try await sign([Hyperliquid.cancelAction(orders)], reason: reason)
        let reply = try await post(signed[0])
        let failed = (((reply["data"] as? [String: Any])?["statuses"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["error"] as? String }
        if let e = failed.first {
            throw WalletError.blocked(failed.count == orders.count ? Self.plain(e) : "\(failed.count) of \(orders.count) orders weren't cancelled: \(Self.plain(e))")
        }
    }

    /// One action, signed and ready to post: its JSON body.
    private struct SignedAction: @unchecked Sendable { let body: [String: Any] }

    /// Signs L1 actions with the wallet's EVM key after one Face ID / Touch ID (the same scheme as placing an order).
    /// Nonces are one millisecond apart, in order.
    private func sign(_ actions: [MsgPack], reason: String) async throws -> [SignedAction] {
        let start = UInt64(Date().timeIntervalSince1970 * 1000)
        let nonces = actions.indices.map { start + UInt64($0) }
        let digests = zip(actions, nonces).map { Hyperliquid.agentDigest(connectionID: Hyperliquid.actionHash($0.0, nonce: $0.1)) }
        let sigs = try await vault.withKey(wallet.id, kind: .evm, reason: reason) { key in
            try digests.map { try Hyperliquid.signature(digest: $0, key: key) }
        }
        return actions.indices.map { i in
            SignedAction(body: ["action": actions[i].json, "nonce": nonces[i], "signature": sigs[i], "vaultAddress": NSNull()])
        }
    }

    /// Posts one signed action to /exchange and returns its `response`. A status other than "ok" is an error.
    private func post(_ a: SignedAction) async throws -> [String: Any] {
        let out = try await Hyperliquid.post("exchange", a.body)
        guard let o = out as? [String: Any] else { throw WalletError.badResponse("Hyperliquid") }
        if o["status"] as? String != "ok" { throw WalletError.blocked(Self.plain(o["response"] as? String ?? "Hyperliquid refused it.")) }
        return o["response"] as? [String: Any] ?? [:]
    }
}

// MARK: Values for tests and previews

// Hyperliquid's account types are filled from its API inside this module. These build one by hand, for the toolbox's
// tests in HermitUI (the memberwise initialisers are not public).
extension Hyperliquid.Position {
    public static func make(coin: String, size: Double, entry: Double, value: Double? = nil, pnl: Double = 0, roe: Double = 0, leverage: Int = 1,
                            liquidation: Double? = nil, margin: Double = 0, cross: Bool = true) -> Hyperliquid.Position {
        Hyperliquid.Position(coin: coin, size: size, entry: entry, value: value ?? abs(size) * entry, pnl: pnl, roe: roe, leverage: leverage,
                             liquidation: liquidation, margin: margin, cross: cross)
    }
}

extension Hyperliquid.OpenOrder {
    public static func make(coin: String, oid: Int, isBuy: Bool, price: Double, size: Double, reduceOnly: Bool = false, time: Date = Date(),
                            orderType: String = "Limit", isTrigger: Bool = false, triggerPx: Double = 0, triggerCondition: String = "",
                            isPositionTpsl: Bool = false) -> Hyperliquid.OpenOrder {
        Hyperliquid.OpenOrder(coin: coin, oid: oid, isBuy: isBuy, price: price, size: size, reduceOnly: reduceOnly, time: time,
                              orderType: orderType, isTrigger: isTrigger, triggerPx: triggerPx, triggerCondition: triggerCondition,
                              isPositionTpsl: isPositionTpsl)
    }
}

extension Hyperliquid.Account {
    public static func make(accountValue: Double = 0, withdrawable: Double = 0, marginUsed: Double = 0, positions: [Hyperliquid.Position] = [],
                            orders: [Hyperliquid.OpenOrder] = [], mode: String = "default") -> Hyperliquid.Account {
        var a = Hyperliquid.Account()
        a.accountValue = accountValue; a.withdrawable = withdrawable; a.marginUsed = marginUsed
        a.positions = positions; a.orders = orders; a.mode = mode
        return a
    }
}

extension Hyperliquid.Asset {
    public static func make(coin: String, id: Int, szDecimals: Int = 2, maxLeverage: Int = 20, onlyIsolated: Bool = false) -> Hyperliquid.Asset {
        Hyperliquid.Asset(coin: coin, id: id, szDecimals: szDecimals, maxLeverage: maxLeverage, onlyIsolated: onlyIsolated)
    }
}
