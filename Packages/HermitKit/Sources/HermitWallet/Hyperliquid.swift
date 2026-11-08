import Foundation
import HermitCore

// Hyperliquid, signed on this device. Orders, cancels and leverage changes are "L1 actions": the action is
// msgpack-encoded, hashed with the nonce, and that hash is signed as an EIP-712 "Agent" message with the wallet's
// own EVM key (unlocked with Face ID / Touch ID). Hermit never holds a key on a server and never sees funds.
// Deposits are a plain USDC transfer on Arbitrum to Hyperliquid's bridge, which the normal Send flow handles.
// Spec: hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api (exchange endpoint, signing).

public enum Hyperliquid {
    public static let api = URL(string: "https://api.hyperliquid.xyz")!
    /// Hyperliquid's bridge on Arbitrum. USDC sent here (5 or more) lands in the sender's Hyperliquid account in about a minute.
    public static let bridge = "0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7"
    public static let minDeposit: Decimal = 5

    // MARK: Market metadata

    /// One perp: its asset id for orders and how many decimals sizes take.
    public struct Asset: Sendable, Hashable {
        public let coin: String       // "BTC", "xyz:TSLA"
        public let id: Int            // order asset id; builder dexes are 100000 + dex * 10000 + index
        public let szDecimals: Int
        public let maxLeverage: Int
        public let onlyIsolated: Bool
    }

    /// Every tradable perp on the main dex and trade.xyz, keyed by coin.
    public static func assets() async throws -> [String: Asset] {
        async let main = universe(dex: nil, dexIndex: 0)
        async let dexes = info(["type": "perpDexs"])
        var out = try await main
        if let list = try? await dexes as? [Any], let i = list.firstIndex(where: { ($0 as? [String: Any])?["name"] as? String == "xyz" }),
           let xyz = try? await universe(dex: "xyz", dexIndex: i) {
            out.merge(xyz) { a, _ in a }
        }
        return out
    }

    private static func universe(dex: String?, dexIndex: Int) async throws -> [String: Asset] {
        var body: [String: Any] = ["type": "meta"]
        if let dex { body["dex"] = dex }
        guard let meta = try await info(body) as? [String: Any], let u = meta["universe"] as? [[String: Any]] else {
            throw WalletError.badResponse("Hyperliquid meta")
        }
        var out: [String: Asset] = [:]
        for (i, m) in u.enumerated() {
            guard let name = m["name"] as? String, (m["isDelisted"] as? Bool) != true else { continue }
            let id = dex == nil ? i : 100_000 + dexIndex * 10_000 + i
            out[name] = Asset(coin: name, id: id, szDecimals: m["szDecimals"] as? Int ?? 0,
                              maxLeverage: m["maxLeverage"] as? Int ?? 1, onlyIsolated: m["onlyIsolated"] as? Bool ?? false)
        }
        return out
    }

    // MARK: Account

    public struct Position: Sendable, Hashable, Identifiable {
        public var id: String { coin }
        public let coin: String
        public let size: Double           // negative = short
        public let entry: Double
        public let value: Double
        public let pnl: Double
        public let roe: Double
        public let leverage: Int
        public let liquidation: Double?
        public let margin: Double
    }

    public struct OpenOrder: Sendable, Hashable, Identifiable {
        public var id: Int { oid }
        public let coin: String, oid: Int, isBuy: Bool, price: Double, size: Double, reduceOnly: Bool, time: Date
    }

    public struct Account: Sendable, Hashable {
        public var accountValue: Double = 0
        public var withdrawable: Double = 0
        public var marginUsed: Double = 0
        public var positions: [Position] = []
        public var orders: [OpenOrder] = []
        public var spotUSDC: Double = 0
    }

    /// Margin, positions and open orders for an address, across the main dex and trade.xyz.
    public static func account(_ user: String) async throws -> Account {
        async let main = info(["type": "clearinghouseState", "user": user])
        async let xyz = try? info(["type": "clearinghouseState", "user": user, "dex": "xyz"])
        async let orders = info(["type": "frontendOpenOrders", "user": user])
        async let xyzOrders = try? info(["type": "frontendOpenOrders", "user": user, "dex": "xyz"])
        async let spot = try? info(["type": "spotClearinghouseState", "user": user])
        var a = Account()
        for state in [try await main, await xyz].compactMap({ $0 as? [String: Any] }) {
            let ms = state["marginSummary"] as? [String: Any]
            a.accountValue += num(ms?["accountValue"]); a.marginUsed += num(ms?["totalMarginUsed"])
            a.withdrawable += num(state["withdrawable"])
            for p in (state["assetPositions"] as? [[String: Any]]) ?? [] {
                guard let pos = p["position"] as? [String: Any], let coin = pos["coin"] as? String else { continue }
                let lev = (pos["leverage"] as? [String: Any])?["value"] as? Int ?? 1
                a.positions.append(Position(coin: coin, size: num(pos["szi"]), entry: num(pos["entryPx"]), value: num(pos["positionValue"]),
                                            pnl: num(pos["unrealizedPnl"]), roe: num(pos["returnOnEquity"]), leverage: lev,
                                            liquidation: (pos["liquidationPx"] as? String).flatMap(Double.init), margin: num(pos["marginUsed"])))
            }
        }
        for list in [try await orders, await xyzOrders].compactMap({ $0 as? [[String: Any]] }) {
            for o in list {
                guard let coin = o["coin"] as? String, let oid = o["oid"] as? Int else { continue }
                a.orders.append(OpenOrder(coin: coin, oid: oid, isBuy: (o["side"] as? String) == "B", price: num(o["limitPx"]), size: num(o["sz"]),
                                          reduceOnly: o["reduceOnly"] as? Bool ?? false,
                                          time: Date(timeIntervalSince1970: num(o["timestamp"]) / 1000)))
            }
        }
        if let s = await spot as? [String: Any], let b = s["balances"] as? [[String: Any]] {
            a.spotUSDC = b.first { $0["coin"] as? String == "USDC" }.map { num($0["total"]) } ?? 0
        }
        return a
    }

    // MARK: Orders

    public enum TimeInForce: String, Sendable { case gtc = "Gtc", ioc = "Ioc", alo = "Alo" }

    public struct Order: Sendable {
        public let asset: Asset
        public let isBuy: Bool
        public let price: Double
        public let size: Double
        public var reduceOnly = false
        public var tif: TimeInForce = .gtc
        /// Take-profit / stop-loss trigger orders ride along with the entry (grouping "normalTpsl").
        public var takeProfit: Double? = nil
        public var stopLoss: Double? = nil
        public init(asset: Asset, isBuy: Bool, price: Double, size: Double, reduceOnly: Bool = false, tif: TimeInForce = .gtc,
                    takeProfit: Double? = nil, stopLoss: Double? = nil) {
            self.asset = asset; self.isBuy = isBuy; self.price = price; self.size = size; self.reduceOnly = reduceOnly; self.tif = tif
            self.takeProfit = takeProfit; self.stopLoss = stopLoss
        }
    }

    public enum OrderResult: Sendable, Hashable {
        case resting(oid: Int)
        case filled(oid: Int, size: Double, avgPrice: Double)
        public var summary: String {
            switch self {
            case .resting: "Order placed"
            case .filled(_, let s, let p): "Filled \(trimNumber(s)) at $\(trimNumber(p))"
            }
        }
    }

    /// A market order is an immediate-or-cancel limit order a little past the current price.
    public static func marketPrice(mid: Double, isBuy: Bool, asset: Asset, slippage: Double = 0.05) -> Double {
        roundPrice(mid * (isBuy ? 1 + slippage : 1 - slippage), szDecimals: asset.szDecimals)
    }

    /// Prices: at most 5 significant figures and at most 6 − szDecimals decimals (integers are always fine).
    public static func roundPrice(_ px: Double, szDecimals: Int) -> Double {
        guard px > 0 else { return 0 }
        if px >= 100_000 { return px.rounded() }
        let sig = Double(String(format: "%.5g", px)) ?? px
        let maxDec = max(0, 6 - szDecimals)
        let f = pow(10, Double(maxDec))
        return (sig * f).rounded() / f
    }

    public static func roundSize(_ sz: Double, szDecimals: Int) -> Double {
        let f = pow(10, Double(szDecimals)); return (sz * f).rounded(.down) / f
    }

    /// Wire form of a number: no exponent, no trailing zeros ("62000", "0.0015").
    public static func wire(_ x: Double) -> String {
        var s = String(format: "%.8f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func orderWire(_ o: Order) -> MsgPack {
        .map([("a", .int(o.asset.id)), ("b", .bool(o.isBuy)), ("p", .string(wire(o.price))), ("s", .string(wire(o.size))),
              ("r", .bool(o.reduceOnly)), ("t", .map([("limit", .map([("tif", .string(o.tif.rawValue))]))]))])
    }

    static func triggerWire(asset: Asset, isBuy: Bool, size: Double, trigger: Double, kind: String) -> MsgPack {
        // Trigger orders fire as market orders; the limit price is a 10% slippage cap past the trigger.
        let px = roundPrice(trigger * (isBuy ? 1.1 : 0.9), szDecimals: asset.szDecimals)
        return .map([("a", .int(asset.id)), ("b", .bool(isBuy)), ("p", .string(wire(px))), ("s", .string(wire(size))), ("r", .bool(true)),
                     ("t", .map([("trigger", .map([("isMarket", .bool(true)), ("triggerPx", .string(wire(roundPrice(trigger, szDecimals: asset.szDecimals)))),
                                                   ("tpsl", .string(kind))]))]))])
    }

    static func orderAction(_ o: Order) -> MsgPack {
        var orders = [orderWire(o)]
        if let tp = o.takeProfit { orders.append(triggerWire(asset: o.asset, isBuy: !o.isBuy, size: o.size, trigger: tp, kind: "tp")) }
        if let sl = o.stopLoss { orders.append(triggerWire(asset: o.asset, isBuy: !o.isBuy, size: o.size, trigger: sl, kind: "sl")) }
        let grouping = orders.count > 1 ? "normalTpsl" : "na"
        return .map([("type", .string("order")), ("orders", .array(orders)), ("grouping", .string(grouping))])
    }

    static func leverageAction(asset: Asset, leverage: Int, cross: Bool) -> MsgPack {
        .map([("type", .string("updateLeverage")), ("asset", .int(asset.id)), ("isCross", .bool(cross)), ("leverage", .int(leverage))])
    }

    static func cancelAction(assetID: Int, oid: Int) -> MsgPack {
        .map([("type", .string("cancel")), ("cancels", .array([.map([("a", .int(assetID)), ("o", .int(oid))])]))])
    }

    // MARK: Signing

    /// keccak(msgpack(action) ‖ nonce (8 bytes, big-endian) ‖ 0x00 for "no vault").
    static func actionHash(_ action: MsgPack, nonce: UInt64) -> [UInt8] {
        Hash.keccak256(action.encoded + nonce.bigEndianBytes(width: 8) + [0])
    }

    /// The EIP-712 digest of the "phantom agent" Hyperliquid verifies L1 actions against.
    static func agentDigest(connectionID: [UInt8], mainnet: Bool = true) -> [UInt8] {
        let domainType = Hash.keccak256(Array("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".utf8))
        let domain = Hash.keccak256(domainType + Hash.keccak256(Array("Exchange".utf8)) + Hash.keccak256(Array("1".utf8))
                                    + UInt64(1337).bigEndianBytes(width: 32) + [UInt8](repeating: 0, count: 32))
        let agentType = Hash.keccak256(Array("Agent(string source,bytes32 connectionId)".utf8))
        let structHash = Hash.keccak256(agentType + Hash.keccak256(Array((mainnet ? "a" : "b").utf8)) + connectionID)
        return Hash.keccak256([0x19, 0x01] + domain + structHash)
    }

    static func signature(digest: [UInt8], key: [UInt8]) throws -> [String: Any] {
        let (rs, recid) = try Secp256k1.sign(digest: digest, key: key)
        return ["r": Array(rs[0..<32]).hex0x, "s": Array(rs[32..<64]).hex0x, "v": 27 + Int(recid)]
    }

    // MARK: Network

    static func info(_ body: [String: Any]) async throws -> Any {
        try await post("info", body)
    }

    static func post(_ path: String, _ body: [String: Any]) async throws -> Any {
        var req = URLRequest(url: api.appending(path: path), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.safeData(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw WalletError.badResponse(String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? "Hyperliquid \(path)")
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func num(_ v: Any?) -> Double {
        if let s = v as? String { return Double(s) ?? 0 }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }
}

/// Signs and sends Hyperliquid actions with a wallet from the vault. Each call asks for Face ID / Touch ID once.
public struct HyperliquidTrader: Sendable {
    let vault: KeyVault
    let wallet: WalletRecord

    public init(vault: KeyVault, wallet: WalletRecord) { self.vault = vault; self.wallet = wallet }

    public func place(_ o: Hyperliquid.Order, leverage: Int?, cross: Bool = true) async throws -> Hyperliquid.OrderResult {
        if let leverage {
            _ = try await send(Hyperliquid.leverageAction(asset: o.asset, leverage: leverage, cross: cross && !o.asset.onlyIsolated),
                               reason: "Set \(o.asset.coin) leverage to \(leverage)x")
        }
        let side = o.isBuy ? "Long" : "Short"
        let r = try await send(Hyperliquid.orderAction(o), reason: "\(o.reduceOnly ? "Close" : side) \(Hyperliquid.wire(o.size)) \(o.asset.coin) on Hyperliquid")
        guard let statuses = ((r["data"] as? [String: Any])?["statuses"]) as? [Any], let first = statuses.first else {
            throw WalletError.badResponse("Hyperliquid order")
        }
        if let s = first as? [String: Any] {
            if let e = s["error"] as? String { throw WalletError.blocked(Self.plain(e)) }
            if let f = s["filled"] as? [String: Any] {
                return .filled(oid: f["oid"] as? Int ?? 0, size: Hyperliquid.num(f["totalSz"]), avgPrice: Hyperliquid.num(f["avgPx"]))
            }
            if let rest = s["resting"] as? [String: Any] { return .resting(oid: rest["oid"] as? Int ?? 0) }
        }
        throw WalletError.badResponse("Hyperliquid order")
    }

    public func cancel(assetID: Int, coin: String, oid: Int) async throws {
        let r = try await send(Hyperliquid.cancelAction(assetID: assetID, oid: oid), reason: "Cancel \(coin) order")
        if let st = ((r["data"] as? [String: Any])?["statuses"] as? [Any])?.first as? [String: Any], let e = st["error"] as? String {
            throw WalletError.blocked(Self.plain(e))
        }
    }

    /// Signs an L1 action with the wallet's EVM key and posts it to /exchange. Returns `response`.
    private func send(_ action: MsgPack, reason: String) async throws -> [String: Any] {
        let nonce = UInt64(Date().timeIntervalSince1970 * 1000)
        let digest = Hyperliquid.agentDigest(connectionID: Hyperliquid.actionHash(action, nonce: nonce))
        let sig = try await vault.withKey(wallet.id, kind: .evm, reason: reason) { key in try Hyperliquid.signature(digest: digest, key: key) }
        let body: [String: Any] = ["action": action.json, "nonce": nonce, "signature": sig, "vaultAddress": NSNull()]
        let out = try await Hyperliquid.post("exchange", body)
        guard let o = out as? [String: Any] else { throw WalletError.badResponse("Hyperliquid") }
        if o["status"] as? String != "ok" { throw WalletError.blocked(Self.plain(o["response"] as? String ?? "Hyperliquid refused the order.")) }
        return o["response"] as? [String: Any] ?? [:]
    }

    /// Hyperliquid's errors, said plainly.
    static func plain(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("does not exist") { return "This wallet has no Hyperliquid account yet. Deposit USDC first." }
        if l.contains("insufficient margin") { return "Not enough USDC on Hyperliquid for this order. Deposit more or lower the size." }
        if l.contains("minimum value") { return "Orders must be worth at least $10." }
        if l.contains("restricted") || l.contains("jurisdiction") { return "Hyperliquid isn't available in your region." }
        return e
    }
}

func trimNumber(_ x: Double) -> String { Hyperliquid.wire((x * 1e6).rounded() / 1e6) }

// MARK: MessagePack (just what Hyperliquid's action hash needs; maps keep their order)

indirect enum MsgPack: Sendable {
    case string(String), int(Int), bool(Bool), array([MsgPack]), map([(String, MsgPack)]), null

    var encoded: [UInt8] {
        switch self {
        case .null: return [0xc0]
        case .bool(let b): return [b ? 0xc3 : 0xc2]
        case .int(let i):
            precondition(i >= 0, "negative ints aren't used in Hyperliquid actions")
            let u = UInt64(i)
            if u < 0x80 { return [UInt8(u)] }
            if u <= 0xff { return [0xcc, UInt8(u)] }
            if u <= 0xffff { return [0xcd] + UInt16(u).bigEndianBytes(width: 2) }
            if u <= 0xffff_ffff { return [0xce] + UInt32(u).bigEndianBytes(width: 4) }
            return [0xcf] + u.bigEndianBytes(width: 8)
        case .string(let s):
            let b = Array(s.utf8)
            if b.count < 32 { return [0xa0 | UInt8(b.count)] + b }
            if b.count <= 0xff { return [0xd9, UInt8(b.count)] + b }
            return [0xda] + UInt16(b.count).bigEndianBytes(width: 2) + b
        case .array(let a):
            let head: [UInt8] = a.count < 16 ? [0x90 | UInt8(a.count)] : [0xdc] + UInt16(a.count).bigEndianBytes(width: 2)
            return head + a.flatMap(\.encoded)
        case .map(let m):
            let head: [UInt8] = m.count < 16 ? [0x80 | UInt8(m.count)] : [0xde] + UInt16(m.count).bigEndianBytes(width: 2)
            return head + m.flatMap { MsgPack.string($0.0).encoded + $0.1.encoded }
        }
    }

    /// The same value for the JSON body. Key order doesn't matter there; the server re-encodes in its own order,
    /// which is the order we hashed (it matches the documented field order).
    var json: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .int(let i): i
        case .string(let s): s
        case .array(let a): a.map(\.json)
        case .map(let m): Dictionary(m.map { ($0.0, $0.1.json) }, uniquingKeysWith: { a, _ in a })
        }
    }
}
