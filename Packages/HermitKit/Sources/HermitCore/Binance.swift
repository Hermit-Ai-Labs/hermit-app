import Foundation
import CryptoKit

/// Binance spot through its REST API (developers.binance.com/docs/binance-spot-api-docs), signed on this phone with
/// the user's own API key (HMAC-SHA256). Keys live in the Keychain. Read-only keys work for balances; trading needs
/// a key with Spot trading enabled. Withdrawals are never used.
public struct Binance: Sendable {
    public static let host = URL(string: "https://api.binance.com")!
    let key: String
    let secret: String

    public init(key: String, secret: String) { self.key = key; self.secret = secret }

    /// The key saved on this phone, if any.
    public static var saved: Binance? {
        guard let k = Secrets.get("binance.key"), let s = Secrets.get("binance.secret") else { return nil }
        return Binance(key: k, secret: s)
    }
    /// Keeps this key on the phone (Keychain).
    public func save() { Self.save(key: key, secret: secret) }

    public static func save(key: String?, secret: String?) {
        Secrets.set(key, for: "binance.key"); Secrets.set(secret, for: "binance.secret")
    }

    public struct Balance: Sendable, Hashable, Identifiable {
        public var id: String { asset }
        public let asset: String
        public let free: Double
        public let locked: Double
        public var total: Double { free + locked }
    }

    public struct Account: Sendable {
        public let canTrade: Bool
        public let balances: [Balance]
    }

    public struct Order: Sendable, Hashable, Identifiable {
        public var id: Int { orderId }
        public let symbol: String, orderId: Int, side: String, type: String, price: Double, qty: Double, filled: Double
    }

    public struct Fill: Sendable { public let orderId: Int; public let status: String; public let filledQty: Double; public let quoteSpent: Double }

    // MARK: Reads

    public func account() async throws -> Account {
        let o = try await signed("GET", "/api/v3/account", ["omitZeroBalances": "true"])
        guard let d = o as? [String: Any] else { throw BinanceError.api("Unexpected reply") }
        let bal = (d["balances"] as? [[String: Any]] ?? []).compactMap { b -> Balance? in
            guard let a = b["asset"] as? String else { return nil }
            let f = Double(b["free"] as? String ?? "") ?? 0, l = Double(b["locked"] as? String ?? "") ?? 0
            return f + l > 0 ? Balance(asset: a, free: f, locked: l) : nil
        }
        return Account(canTrade: d["canTrade"] as? Bool ?? false, balances: bal)
    }

    public func openOrders() async throws -> [Order] {
        let o = try await signed("GET", "/api/v3/openOrders", [:])
        return (o as? [[String: Any]] ?? []).compactMap { d in
            guard let s = d["symbol"] as? String, let id = d["orderId"] as? Int else { return nil }
            return Order(symbol: s, orderId: id, side: d["side"] as? String ?? "", type: d["type"] as? String ?? "",
                         price: Double(d["price"] as? String ?? "") ?? 0, qty: Double(d["origQty"] as? String ?? "") ?? 0,
                         filled: Double(d["executedQty"] as? String ?? "") ?? 0)
        }
    }

    /// Public prices for many symbols at once, e.g. ["BTCUSDT": 102000].
    public static func prices() async throws -> [String: Double] {
        let (data, _) = try await URLSession.shared.data(from: host.appending(path: "/api/v3/ticker/price"))
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var out: [String: Double] = [:]
        for p in list { if let s = p["symbol"] as? String, let v = Double(p["price"] as? String ?? "") { out[s] = v } }
        return out
    }

    // MARK: Orders

    /// Market buy spending `quote` (e.g. 50 USDT), or market sell of `qty` base. Returns what filled.
    public func market(symbol: String, buy: Bool, quote: Double? = nil, qty: Double? = nil) async throws -> Fill {
        var p = ["symbol": symbol, "side": buy ? "BUY" : "SELL", "type": "MARKET", "newOrderRespType": "RESULT"]
        if let quote { p["quoteOrderQty"] = Self.num(quote) } else if let qty { p["quantity"] = Self.num(qty) }
        return try fill(try await signed("POST", "/api/v3/order", p))
    }

    public func limit(symbol: String, buy: Bool, qty: Double, price: Double) async throws -> Fill {
        let p = ["symbol": symbol, "side": buy ? "BUY" : "SELL", "type": "LIMIT", "timeInForce": "GTC",
                 "quantity": Self.num(qty), "price": Self.num(price), "newOrderRespType": "RESULT"]
        return try fill(try await signed("POST", "/api/v3/order", p))
    }

    public func cancel(symbol: String, orderId: Int) async throws {
        _ = try await signed("DELETE", "/api/v3/order", ["symbol": symbol, "orderId": String(orderId)])
    }

    private func fill(_ o: Any) throws -> Fill {
        guard let d = o as? [String: Any] else { throw BinanceError.api("Unexpected reply") }
        return Fill(orderId: d["orderId"] as? Int ?? 0, status: d["status"] as? String ?? "",
                    filledQty: Double(d["executedQty"] as? String ?? "") ?? 0, quoteSpent: Double(d["cummulativeQuoteQty"] as? String ?? "") ?? 0)
    }

    static func num(_ x: Double) -> String {
        var s = String(format: "%.8f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: Transport

    private func signed(_ method: String, _ path: String, _ params: [String: String]) async throws -> Any {
        var p = params
        p["timestamp"] = String(Int(Date().timeIntervalSince1970 * 1000))
        p["recvWindow"] = "10000"
        let query = p.keys.sorted().map { "\($0)=\(p[$0]!.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_.~"))) ?? "")" }
            .joined(separator: "&")
        let sig = HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        var comps = URLComponents(url: Self.host.appending(path: path), resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = query + "&signature=" + sig
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "X-MBX-APIKEY")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            if code == 451 || code == 403 { throw BinanceError.region }
            let msg = (json as? [String: Any])?["msg"] as? String ?? "HTTP \(code)"
            throw BinanceError.api(Self.plain(msg))
        }
        return json ?? [:]
    }

    static func plain(_ m: String) -> String {
        let l = m.lowercased()
        if l.contains("api-key") || l.contains("signature") { return "Binance didn't accept this API key. Check the key and secret." }
        if l.contains("permissions") { return "This API key can't trade. Turn on Spot trading for it on Binance, or keep it read-only." }
        if l.contains("insufficient balance") { return "Not enough balance on Binance for this order." }
        if l.contains("notional") { return "Order is below Binance's minimum for this pair (usually $5)." }
        return m
    }
}

public enum BinanceError: Error, LocalizedError, Sendable {
    case region, api(String)
    public var errorDescription: String? {
        switch self {
        case .region: "Binance isn't available from your location."
        case .api(let m): m
        }
    }
}
