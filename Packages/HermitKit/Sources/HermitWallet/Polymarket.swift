import Foundation
import CryptoKit

/// Polymarket on Polygon, trading from the wallet's own address (signature type 0, "EOA"). Orders are EIP-712 messages
/// signed on this phone and matched by Polymarket's order book (CLOB); settlement happens on chain in USDC.e.
/// The CLOB needs API credentials, which are derived by signing a ClobAuth message (no account, no email).
/// Contracts and message formats: github.com/Polymarket/py-clob-client (config.py, signing/), docs.polymarket.com.
public enum Polymarket {
    public static let clob = URL(string: "https://clob.polymarket.com")!
    public static let exchange = "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E"
    public static let negRiskExchange = "0xC5d563A36AE78145C45a50134d48A1215220f80a"
    public static let negRiskAdapter = "0xd91E80cF2E7be2e162c6513ceD06f1dD0dA35296"
    public static let usdcE = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
    public static let ctf = "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045"

    public struct Credentials: Codable, Sendable { public let apiKey, secret, passphrase: String }

    public struct Market: Sendable, Hashable, Identifiable {
        public var id: String { conditionID }
        public let conditionID, question: String
        public let outcomes: [String]
        public let tokenIDs: [String]
        public let prices: [Double]
        public let volume24h: Double
        public let ends: Date?
        public let negRisk: Bool
        public let image: URL?
    }

    public struct Position: Sendable, Hashable, Identifiable {
        public var id: String { asset }
        public let asset, title, outcome: String
        public let size, avgPrice, currentValue, pnl: Double
    }

    // MARK: Public data

    /// Whether Polymarket accepts orders from this connection's country.
    public static func blocked() async -> (blocked: Bool, country: String?) {
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: "https://polymarket.com/api/geoblock")!),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (false, nil) }
        return (o["blocked"] as? Bool ?? false, o["country"] as? String)
    }

    /// Busiest open markets (gamma API).
    public static func markets(limit: Int = 30) async throws -> [Market] {
        let u = URL(string: "https://gamma-api.polymarket.com/markets?active=true&closed=false&order=volume24hr&ascending=false&limit=\(limit)")!
        let (d, _) = try await URLSession.shared.data(from: u)
        let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        return list.compactMap { m in
            func arr(_ k: String) -> [String] {
                (m[k] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any] }?.map { "\($0)" } ?? []
            }
            let toks = arr("clobTokenIds"), outs = arr("outcomes"), px = arr("outcomePrices").compactMap(Double.init)
            guard let cid = m["conditionId"] as? String, let q = m["question"] as? String, toks.count == 2, outs.count == 2, m["enableOrderBook"] as? Bool != false
            else { return nil }
            return Market(conditionID: cid, question: q, outcomes: outs, tokenIDs: toks, prices: px.count == 2 ? px : [0.5, 0.5],
                          volume24h: (m["volume24hr"] as? Double) ?? 0, ends: (m["endDate"] as? String).flatMap { iso.date(from: $0) },
                          negRisk: m["negRisk"] as? Bool ?? false, image: (m["icon"] as? String).flatMap(URL.init))
        }
    }

    public static func positions(_ user: String) async throws -> [Position] {
        let (d, _) = try await URLSession.shared.data(from: URL(string: "https://data-api.polymarket.com/positions?user=\(user)&sizeThreshold=0.01")!)
        return (try JSONSerialization.jsonObject(with: d) as? [[String: Any]] ?? []).compactMap { p in
            guard let a = p["asset"] as? String else { return nil }
            return Position(asset: a, title: p["title"] as? String ?? "", outcome: p["outcome"] as? String ?? "",
                            size: p["size"] as? Double ?? 0, avgPrice: p["avgPrice"] as? Double ?? 0,
                            currentValue: p["currentValue"] as? Double ?? 0, pnl: p["cashPnl"] as? Double ?? 0)
        }
    }

    /// Best ask for buying a token (lowest sell order), and its tick size.
    public static func bestAsk(_ tokenID: String) async throws -> (price: Double, tick: Double) {
        let (d, _) = try await URLSession.shared.data(from: clob.appending(path: "book").appending(queryItems: [.init(name: "token_id", value: tokenID)]))
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        let asks = (o["asks"] as? [[String: Any]] ?? []).compactMap { Double($0["price"] as? String ?? "") }
        let tick = Double(o["tick_size"] as? String ?? "") ?? 0.01
        guard let best = asks.min() else { throw WalletError.blocked("Nobody is selling this outcome right now.") }
        return (best, tick)
    }

    // MARK: Signing

    static let authMessage = "This message attests that I control the given wallet"

    static func clobAuth(address: String, timestamp: Int, nonce: Int) -> EIP712 {
        EIP712(types: ["ClobAuth": [.init("address", "address"), .init("timestamp", "string"), .init("nonce", "uint256"), .init("message", "string")]],
               primaryType: "ClobAuth",
               domain: ["name": .string("ClobAuthDomain"), "version": .string("1"), "chainId": .number(137)],
               message: ["address": .string(address), "timestamp": .string(String(timestamp)), "nonce": .number(Double(nonce)),
                         "message": .string(authMessage)])
    }

    public struct Order: Sendable {
        public let salt: Int
        public let maker: String
        public let tokenID: String
        public let makerAmount: UInt128   // USDC.e paid (6 decimals) for a buy
        public let takerAmount: UInt128   // shares received (6 decimals)
        public let side: Int              // 0 buy, 1 sell
        public let negRisk: Bool
    }

    static func orderData(_ o: Order) -> EIP712 {
        let f: [EIP712.Field] = [.init("salt", "uint256"), .init("maker", "address"), .init("signer", "address"), .init("taker", "address"),
                                 .init("tokenId", "uint256"), .init("makerAmount", "uint256"), .init("takerAmount", "uint256"),
                                 .init("expiration", "uint256"), .init("nonce", "uint256"), .init("feeRateBps", "uint256"),
                                 .init("side", "uint8"), .init("signatureType", "uint8")]
        return EIP712(types: ["Order": f], primaryType: "Order",
                      domain: ["name": .string("Polymarket CTF Exchange"), "version": .string("1"), "chainId": .number(137),
                               "verifyingContract": .string(o.negRisk ? negRiskExchange : exchange)],
                      message: ["salt": .string(String(o.salt)), "maker": .string(o.maker), "signer": .string(o.maker),
                                "taker": .string("0x0000000000000000000000000000000000000000"), "tokenId": .string(o.tokenID),
                                "makerAmount": .string(String(o.makerAmount)), "takerAmount": .string(String(o.takerAmount)),
                                "expiration": .string("0"), "nonce": .string("0"), "feeRateBps": .string("0"),
                                "side": .number(Double(o.side)), "signatureType": .number(0)])
    }

    /// A market buy of `usdc` worth of one outcome, priced a few ticks past the best ask (fill-or-kill).
    public static func marketBuy(maker: String, tokenID: String, usdc: Double, bestAsk: Double, tick: Double, negRisk: Bool) -> (Order, Double) {
        let price = min(0.99, (((bestAsk + tick * 2) / tick).rounded(.up)) * tick)
        let spend = (usdc * 100).rounded(.down) / 100                    // USDC to 2 decimals
        let shares = ((spend / price) * 100).rounded(.down) / 100       // shares to 2 decimals
        let o = Order(salt: Int.random(in: 1..<1_000_000_000), maker: maker, tokenID: tokenID,
                      makerAmount: UInt128((spend * 1e6).rounded()), takerAmount: UInt128((shares * 1e6).rounded()), side: 0, negRisk: negRisk)
        return (o, price)
    }

    // MARK: Approvals

    /// The one-time approvals a wallet needs before its first trade: USDC.e for the exchanges, and the outcome tokens
    /// (to sell later). Only the missing ones are returned.
    public static func approvalCalls(owner: EVMAddress, client: EVMClient) async throws -> [ContractCall] {
        let spenders = [exchange, negRiskExchange, negRiskAdapter].compactMap(EVMAddress.init)
        var calls: [ContractCall] = []
        let usdc = EVMAddress(usdcE)!, ctfAddr = EVMAddress(ctf)!
        let max = [UInt8](repeating: 0xff, count: 32)
        for s in spenders {
            let a = try await client.call(to: usdc, data: ERC20.selector("allowance(address,address)") + ERC20.word(owner) + ERC20.word(s))
            if a.allSatisfy({ $0 == 0 }) {
                calls.append(ContractCall(to: usdc, data: ERC20.selector("approve(address,uint256)") + ERC20.word(s) + max,
                                          label: "Allow Polymarket to use your USDC.e"))
            }
            let ok = try await client.call(to: ctfAddr, data: ERC20.selector("isApprovedForAll(address,address)") + ERC20.word(owner) + ERC20.word(s))
            if ok.last != 1 {
                calls.append(ContractCall(to: ctfAddr, data: ERC20.selector("setApprovalForAll(address,bool)") + ERC20.word(s) + ERC20.word(UInt128(1)),
                                          label: "Allow Polymarket to move your outcome shares"))
            }
        }
        return calls
    }
}

/// Talks to the CLOB as one wallet: derives (and keeps) its API credentials, posts signed orders.
public struct PolymarketTrader: Sendable {
    let vault: KeyVault
    let wallet: WalletRecord
    public init(vault: KeyVault, wallet: WalletRecord) { self.vault = vault; self.wallet = wallet }

    var address: String { wallet.evmAddress }

    /// API credentials from a signed ClobAuth message, cached in UserDefaults per address (they only work with that signature).
    func credentials() async throws -> Polymarket.Credentials {
        let k = "pm.creds.\(address.lowercased())"
        if let d = UserDefaults.standard.data(forKey: k), let c = try? JSONDecoder().decode(Polymarket.Credentials.self, from: d) { return c }
        let ts = Int(Date().timeIntervalSince1970)
        let typed = Polymarket.clobAuth(address: address, timestamp: ts, nonce: 0)
        let sig = try await vault.withKey(wallet.id, kind: .evm, reason: "Sign in to Polymarket") { key in try typed.sign(key: key) }
        let headers = ["POLY_ADDRESS": address, "POLY_SIGNATURE": sig, "POLY_TIMESTAMP": String(ts), "POLY_NONCE": "0"]
        var c = try? await request("GET", "/auth/derive-api-key", headers: headers)
        if c?["apiKey"] == nil { c = try await request("POST", "/auth/api-key", headers: headers) }
        guard let key = c?["apiKey"] as? String, let secret = c?["secret"] as? String, let pass = c?["passphrase"] as? String else {
            throw WalletError.badResponse("Polymarket didn't return API credentials")
        }
        let creds = Polymarket.Credentials(apiKey: key, secret: secret, passphrase: pass)
        UserDefaults.standard.set(try JSONEncoder().encode(creds), forKey: k)
        return creds
    }

    /// Signs the order (Face ID) and posts it fill-or-kill. Returns Polymarket's order id.
    public func place(_ o: Polymarket.Order, reason: String) async throws -> String {
        let creds = try await credentials()
        let sig = try await vault.withKey(wallet.id, kind: .evm, reason: reason) { key in try Polymarket.orderData(o).sign(key: key) }
        let order: [String: Any] = ["salt": o.salt, "maker": o.maker, "signer": o.maker, "taker": "0x0000000000000000000000000000000000000000",
                                    "tokenId": o.tokenID, "makerAmount": String(o.makerAmount), "takerAmount": String(o.takerAmount),
                                    "expiration": "0", "nonce": "0", "feeRateBps": "0", "side": o.side == 0 ? "BUY" : "SELL",
                                    "signatureType": 0, "signature": sig]
        let body = try JSONSerialization.data(withJSONObject: ["order": order, "owner": creds.apiKey, "orderType": "FOK"])
        let r = try await request("POST", "/order", headers: l2(creds, "POST", "/order", body), body: body)
        if let e = r["errorMsg"] as? String, !e.isEmpty { throw WalletError.blocked(Self.plain(e)) }
        if r["success"] as? Bool == false { throw WalletError.blocked("Polymarket didn't fill the order. Try again.") }
        return r["orderID"] as? String ?? ""
    }

    func l2(_ c: Polymarket.Credentials, _ method: String, _ path: String, _ body: Data?) -> [String: String] {
        let ts = String(Int(Date().timeIntervalSince1970))
        let msg = ts + method + path + (body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        let key = Data(base64URL: c.secret) ?? Data()
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        let sig = mac.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return ["POLY_ADDRESS": address, "POLY_SIGNATURE": sig, "POLY_TIMESTAMP": ts, "POLY_API_KEY": c.apiKey, "POLY_PASSPHRASE": c.passphrase]
    }

    func request(_ method: String, _ path: String, headers: [String: String], body: Data? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: Polymarket.clob.appending(path: path), timeoutInterval: 20)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await URLSession.shared.data(for: req)
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw WalletError.blocked("Polymarket isn't available in your country.") }
        guard (200..<300).contains(code) else { throw WalletError.blocked(Self.plain(o["error"] as? String ?? "Polymarket error \(code)")) }
        return o
    }

    static func plain(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("not enough balance") || l.contains("allowance") { return "Not enough USDC.e on Polygon (or approvals missing)." }
        if l.contains("fok") || l.contains("fully filled") { return "Not enough sellers at this price. Try a smaller amount." }
        if l.contains("geoblock") || l.contains("restricted") { return "Polymarket isn't available in your country." }
        return e
    }
}

extension Data {
    /// base64url without padding, as Polymarket's API secret comes.
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
