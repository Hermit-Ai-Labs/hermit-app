import Foundation
import CryptoKit

/// NEAR Intents through the 1Click Swap API (docs.near-intents.org/integration/distribution-channels/1click-api).
///
/// Flow (ORIGIN_CHAIN): ask for a quote; a real (non-dry) quote comes with a one-time `depositAddress` on the origin chain;
/// the user sends `amountIn` there from their own wallet (a plain transfer, through the approval sheet); Hermit reports
/// the transaction hash (`/v0/deposit/submit`) and polls `/v0/status` until SUCCESS, REFUNDED or FAILED. Solvers on NEAR
/// Intents fill the swap and 1Click pays out on the destination chain. Dry quotes (`dry: true`) price a route without
/// creating anything, which is what "Try a quote" uses.
///
/// Without a JWT (partners.near-intents.org) quotes carry an extra fee (0.2% as of 2026-11, shown as `appFeeBps`) and
/// confidential swaps are refused (401), so the JWT is optional config.
public struct OneClick: Sendable {
    public static let defaultBase = URL(string: "https://1click.chaindefuser.com")!
    /// 1Click's quote-signing key (`ONE_CLICK_MANAGER_PUB_KEY` in @defuse-protocol/one-click-sdk-typescript 0.1.26).
    public static let managerPublicKey = "ed25519:reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc"
    public static let jwtDefaultsKey = "hermit.intents.jwt"

    public var base: URL
    public var jwt: String?
    /// Sends a request and returns (body, status). Swapped out in tests for recorded fixtures.
    public var transport: @Sendable (URLRequest) async throws -> (Data, Int)

    public init(base: URL = OneClick.defaultBase, jwt: String? = OneClick.configuredJWT,
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = OneClick.urlSession) {
        self.base = base; self.jwt = jwt?.isEmpty == true ? nil : jwt; self.transport = transport
    }

    /// The partner JWT, if set: the ONECLICK_JWT environment variable (CI, tests) or the app's settings. Never in the repo.
    public static var configuredJWT: String? {
        if let e = ProcessInfo.processInfo.environment["ONECLICK_JWT"], !e.isEmpty { return e }
        return UserDefaults.standard.string(forKey: jwtDefaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }
    public var authenticated: Bool { jwt != nil }

    public static let urlSession: @Sendable (URLRequest) async throws -> (Data, Int) = { req in
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Any? = nil) async throws -> JSON {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!, timeoutInterval: 25)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jwt { req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, status) = try await transport(req)
        let j = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (200..<300).contains(status) else { throw OneClickError(status: status, message: j["message"]?.string ?? "HTTP \(status)") }
        return j
    }
}

public struct OneClickError: Error, LocalizedError, Equatable {
    public let status: Int
    public let message: String
    /// Plain words for the common refusals; the API's own message otherwise.
    public var errorDescription: String? {
        let m = message.lowercased()
        if status == 401 && m.contains("confidential") { return "Confidential swaps need a 1Click partner key. Add one in Settings." }
        if m.contains("amount is too low") || m.contains("too small") || m.contains("minimum") { return "That amount is too small for this route. Try a little more." }
        if m.contains("no quotes") || m.contains("failed to get quote") || m.contains("no route") { return "No solver quoted this route right now. Try another amount or token." }
        if status == 404 { return "1Click doesn't know this deposit." }
        if status == 429 { return "1Click is busy. Try again in a moment." }
        return message
    }
}

// MARK: Tokens

/// One asset 1Click can swap: `assetId` is what quotes use ("nep141:base-0x8335….omft.near", "nep141:btc.omft.near", …).
public struct IntentsToken: Codable, Hashable, Sendable, Identifiable {
    public var id: String { assetId }
    public let assetId: String
    public let decimals: Int
    /// 1Click's chain code: "eth", "base", "arb", "sol", "near", "btc", "hypercore", …
    public let blockchain: String
    public let symbol: String
    public let price: Double?
    public let contractAddress: String?
}

extension OneClick {
    /// Every supported token (about 216 on 40 chains, 2026-11-08). Cached for 10 minutes in memory and on disk.
    public func tokens(force: Bool = false) async throws -> [IntentsToken] {
        if !force, let c = await IntentsTokenCache.shared.fresh() { return c }
        let j = try await request("v0/tokens")
        let data = try JSONEncoder().encode(j)
        let list = try JSONDecoder().decode([IntentsToken].self, from: data)
        guard !list.isEmpty else { throw OneClickError(status: 200, message: "1Click returned no tokens") }
        await IntentsTokenCache.shared.store(list)
        return list
    }
}

actor IntentsTokenCache {
    static let shared = IntentsTokenCache()
    private var list: [IntentsToken] = []
    private var at: Date = .distantPast
    private var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("hermit-1click-tokens.json")
    }
    func fresh() -> [IntentsToken]? {
        if !list.isEmpty, Date().timeIntervalSince(at) < 600 { return list }
        if let f = file, let attrs = try? FileManager.default.attributesOfItem(atPath: f.path), let m = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 600, let d = try? Data(contentsOf: f), let l = try? JSONDecoder().decode([IntentsToken].self, from: d) {
            list = l; at = m; return l
        }
        return nil
    }
    /// Last list seen, however old (for showing names and logos while offline).
    func any() -> [IntentsToken] {
        if !list.isEmpty { return list }
        if let f = file, let d = try? Data(contentsOf: f), let l = try? JSONDecoder().decode([IntentsToken].self, from: d) { list = l }
        return list
    }
    func store(_ l: [IntentsToken]) {
        list = l; at = Date()
        if let f = file, let d = try? JSONEncoder().encode(l) { try? d.write(to: f, options: .atomic) }
    }
}

// MARK: Places and asset ids

/// Where a swap can start or end. Hermit holds keys for EVM chains, Solana and NEAR; Bitcoin and Hyperliquid are
/// destinations (BTC to an address the user types, Hyperliquid USDC to the user's own perps account).
public enum IntentsPlace: Hashable, Sendable, Identifiable {
    case chain(Chain)
    case bitcoin
    case hyperliquid

    public var id: String { switch self { case .chain(let c): c.id; case .bitcoin: "btc"; case .hyperliquid: "hyperliquid" } }
    public var name: String { switch self { case .chain(let c): c.name; case .bitcoin: "Bitcoin"; case .hyperliquid: "Hyperliquid" } }
    public var logo: String { switch self { case .chain(let c): c.logo; case .bitcoin: "btc"; case .hyperliquid: "hyperliquid" } }
    public var chain: Chain? { if case .chain(let c) = self { return c }; return nil }

    /// 1Click's chain code for this place.
    public var blockchain: String? {
        switch self {
        case .bitcoin: return "btc"
        case .hyperliquid: return "hypercore"
        case .chain(let c):
            guard !c.isTestnet else { return nil }
            return ["ethereum": "eth", "base": "base", "arbitrum": "arb", "bnb": "bsc", "polygon": "pol", "monad": "monad",
                    "robinhood": "hood", "solana": "sol", "near": "near"][c.id]
        }
    }

    /// Every place Hermit can quote through Intents.
    public static var all: [IntentsPlace] { Chain.mainnets.compactMap { IntentsPlace.chain($0).blockchain != nil ? .chain($0) : nil } + [.bitcoin, .hyperliquid] }
}

public enum IntentsAssets {
    /// Hyperliquid perps USDC (8 decimals); see the Hyperliquid page of the 1Click docs. Credited to the perps balance.
    public static let hyperliquidUSDC = "1cs_v1:hypercore:hip1:0x6d1e7cde53ba9467b783cb7c530ce054"
    public static let bitcoin = "nep141:btc.omft.near"
    /// Native NEAR is quoted as wNEAR; 1Click wraps a plain NEAR transfer to the deposit account for you.
    public static let wrappedNear = "nep141:wrap.near"
    /// Dry quotes to Bitcoin need some recipient before the user has typed theirs: the Bitcoin wiki's BIP-173 example.
    /// Only ever used with `dry: true`; a real quote always uses the address the user entered.
    public static let dryQuoteBitcoinRecipient = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    /// The 1Click token for a Hermit token (nil = the chain's native coin) at a place, from the live token list.
    public static func token(_ symbol: String?, at place: IntentsPlace, in list: [IntentsToken], hermitToken: Token? = nil) -> IntentsToken? {
        guard let code = place.blockchain else { return nil }
        switch place {
        case .hyperliquid: return list.first { $0.assetId == hyperliquidUSDC }
        case .bitcoin: return list.first { $0.assetId == bitcoin }
        case .chain(let c):
            let here = list.filter { $0.blockchain == code }
            if let t = hermitToken {
                if let m = here.first(where: { $0.contractAddress?.caseInsensitiveCompare(t.address) == .orderedSame }) { return m }
                return nil
            }
            let sym = symbol ?? c.nativeSymbol
            if c.kind == .near, sym.caseInsensitiveCompare(c.nativeSymbol) == .orderedSame { return list.first { $0.assetId == wrappedNear } }
            if sym.caseInsensitiveCompare(c.nativeSymbol) == .orderedSame {
                return here.first { $0.contractAddress == nil && $0.symbol.caseInsensitiveCompare(sym) == .orderedSame }
                    ?? here.first { $0.contractAddress == nil && c.nativeSymbol == "ETH" && $0.symbol == "ETH" }
            }
            if let t = c.token(sym) { return here.first { $0.contractAddress?.caseInsensitiveCompare(t.address) == .orderedSame } }
            return here.first { $0.symbol.caseInsensitiveCompare(sym) == .orderedSame }
        }
    }

    /// Symbols you can receive at a place: Hermit's tokens first (balances are tracked), then the rest 1Click lists there.
    public static func symbols(at place: IntentsPlace, in list: [IntentsToken]) -> [String] {
        guard let code = place.blockchain else { return [] }
        if case .hyperliquid = place { return ["USDC"] }
        if case .bitcoin = place { return ["BTC"] }
        var out: [String] = []
        if let c = place.chain { out = [c.nativeSymbol] + c.tokens.map(\.symbol).filter { $0 != "wNEAR" } }
        for t in list where t.blockchain == code && !out.contains(where: { $0.caseInsensitiveCompare(t.symbol) == .orderedSame }) {
            if place.chain?.kind == .near && t.symbol == "wNEAR" { continue }
            out.append(t.symbol)
        }
        return out
    }
}

// MARK: Quotes

public struct IntentsQuoteRequest: Sendable, Equatable {
    public enum SwapType: String, Sendable { case exactInput = "EXACT_INPUT", exactOutput = "EXACT_OUTPUT", flexInput = "FLEX_INPUT" }
    public enum Confidentiality: String, Sendable { case `public`, basic, advanced }

    public var dry: Bool
    public var swapType: SwapType = .exactInput
    /// Basis points (100 = 1%).
    public var slippageBps: Int = 100
    public var originAsset: String
    public var destinationAsset: String
    public var amount: UInt128
    public var recipient: String
    public var refundTo: String
    /// ORIGIN_CHAIN, or INTENTS to refund into the user's NEAR Intents balance (their NEAR account).
    public var refundType: String = "ORIGIN_CHAIN"
    public var deadline: Date
    public var confidentiality: Confidentiality = .public

    public init(dry: Bool, swapType: SwapType = .exactInput, slippageBps: Int = 100, originAsset: String, destinationAsset: String,
                amount: UInt128, recipient: String, refundTo: String, refundType: String = "ORIGIN_CHAIN",
                deadline: Date = Date().addingTimeInterval(600), confidentiality: Confidentiality = .public) {
        self.dry = dry; self.swapType = swapType; self.slippageBps = slippageBps; self.originAsset = originAsset
        self.destinationAsset = destinationAsset; self.amount = amount; self.recipient = recipient; self.refundTo = refundTo
        self.refundType = refundType; self.deadline = deadline; self.confidentiality = confidentiality
    }

    public var body: [String: Any] {
        var b: [String: Any] = ["dry": dry, "swapType": swapType.rawValue, "slippageTolerance": slippageBps, "originAsset": originAsset,
                                "depositType": "ORIGIN_CHAIN", "destinationAsset": destinationAsset, "amount": String(amount),
                                "recipient": recipient, "recipientType": "DESTINATION_CHAIN", "refundTo": refundTo,
                                "refundType": refundType, "deadline": OneClick.iso(deadline)]
        if confidentiality != .public { b["confidentiality"] = confidentiality.rawValue }
        return b
    }
}

public struct IntentsQuote: Sendable {
    public let request: IntentsQuoteRequest
    public let amountIn: UInt128
    public let amountInFormatted: String
    public let amountInUSD: Double?
    public let minAmountIn: UInt128
    public let amountOut: UInt128
    public let amountOutFormatted: String
    public let amountOutUSD: Double?
    public let minAmountOut: UInt128
    /// Real quotes only: where the user sends `amountIn` on the origin chain, and a memo some chains need with it.
    public let depositAddress: String?
    public let depositMemo: String?
    public let deadline: Date?
    public let seconds: Int
    /// The extra fee 1Click charges this quote, in basis points (20 = 0.2% without a JWT).
    public let appFeeBps: Int
    /// Ed25519 signature by 1Click's manager key over the quote, checked as `verifyQuoteSignature` does.
    public let signatureValid: Bool
    public let correlationId: String?
    public let timestamp: String?
    public let raw: JSON

    /// What the user gives up in dollars between in and out (fees, spread, slippage), when both are priced.
    public var costUSD: Double? { amountInUSD.flatMap { i in amountOutUSD.map { max(0, i - $0) } } }

    init(request: IntentsQuoteRequest, raw j: JSON) throws {
        guard let q = j["quote"], let ai = q["amountIn"]?.string.flatMap({ UInt128($0) }),
              let ao = q["amountOut"]?.string.flatMap({ UInt128($0) }) else { throw OneClickError(status: 200, message: "1Click quote had no amounts") }
        self.request = request; raw = j
        amountIn = ai; amountOut = ao
        amountInFormatted = q["amountInFormatted"]?.string ?? ""
        amountOutFormatted = q["amountOutFormatted"]?.string ?? ""
        amountInUSD = q["amountInUsd"]?.string.flatMap(Double.init)
        amountOutUSD = q["amountOutUsd"]?.string.flatMap(Double.init)
        minAmountIn = q["minAmountIn"]?.string.flatMap { UInt128($0) } ?? ai
        minAmountOut = q["minAmountOut"]?.string.flatMap { UInt128($0) } ?? ao
        depositAddress = q["depositAddress"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        depositMemo = q["depositMemo"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        deadline = q["deadline"]?.string.flatMap(OneClick.date)
        seconds = q["timeEstimate"]?.int ?? 60
        appFeeBps = (j["quoteRequest"]?["appFees"]?.array ?? []).compactMap { $0["fee"]?.int }.reduce(0, +)
        correlationId = j["correlationId"]?.string
        timestamp = j["timestamp"]?.string
        signatureValid = QuoteSignature.verify(j)
    }
}

extension OneClick {
    public func quote(_ r: IntentsQuoteRequest) async throws -> IntentsQuote {
        try IntentsQuote(request: r, raw: try await request("v0/quote", method: "POST", body: r.body))
    }

    /// Tells 1Click about the deposit so it starts sooner (optional; it also watches the chain).
    public func submitDeposit(txHash: String, depositAddress: String, nearSender: String? = nil, memo: String? = nil) async throws {
        var b: [String: Any] = ["txHash": txHash, "depositAddress": depositAddress]
        if let nearSender { b["nearSenderAccount"] = nearSender }
        if let memo { b["memo"] = memo }
        _ = try await request("v0/deposit/submit", method: "POST", body: b)
    }

    public func status(depositAddress: String, memo: String? = nil) async throws -> IntentsSwapState {
        var q = [URLQueryItem(name: "depositAddress", value: depositAddress)]
        if let memo { q.append(URLQueryItem(name: "depositMemo", value: memo)) }
        return IntentsSwapState(try await request("v0/status", query: q))
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// NEAR Intents Explorer page for a swap.
    public static func explorer(depositAddress: String) -> URL? { URL(string: "https://explorer.near-intents.org/transactions/\(depositAddress)") }
}

// MARK: Status

public enum IntentsStatus: String, Sendable, Codable, CaseIterable {
    case pendingDeposit = "PENDING_DEPOSIT"
    case knownDepositTx = "KNOWN_DEPOSIT_TX"
    case processing = "PROCESSING"
    case success = "SUCCESS"
    case incompleteDeposit = "INCOMPLETE_DEPOSIT"
    case refunded = "REFUNDED"
    case failed = "FAILED"

    /// Nothing more will happen on its own.
    public var isFinal: Bool { self == .success || self == .refunded || self == .failed }
    public var isProblem: Bool { self == .incompleteDeposit || self == .refunded || self == .failed }

    /// Where the money is right now, in plain words.
    public var headline: String {
        switch self {
        case .pendingDeposit: "Waiting for your deposit"
        case .knownDepositTx: "Deposit seen, waiting for confirmations"
        case .processing: "Solvers are filling the swap on NEAR Intents"
        case .success: "Delivered"
        case .incompleteDeposit: "Deposit was less than the quote"
        case .refunded: "Refunded"
        case .failed: "Swap failed"
        }
    }
    /// Which of the four steps (deposit, seen, swap, delivered) is current: 0-based.
    public var step: Int {
        switch self {
        case .pendingDeposit, .incompleteDeposit: 0
        case .knownDepositTx: 1
        case .processing, .refunded, .failed: 2
        case .success: 3
        }
    }
}

public struct IntentsSwapState: Sendable, Equatable {
    public struct Tx: Sendable, Equatable, Hashable { public let hash: String; public let url: URL? }
    public let status: IntentsStatus
    public let updatedAt: Date?
    public let amountInFormatted: String?
    public let amountOutFormatted: String?
    public let amountOutUSD: Double?
    /// Of the origin asset, in its smallest unit, sent back to `refundTo`.
    public let refundedAmount: UInt128?
    public let refundedFormatted: String?
    /// e.g. PARTIAL_DEPOSIT.
    public let refundReason: String?
    /// What actually arrived at the deposit address (for INCOMPLETE_DEPOSIT).
    public let depositedFormatted: String?
    public let originTxs: [Tx]
    public let destinationTxs: [Tx]
    public let nearTxs: [String]
    public let refundTo: String?

    public init(_ j: JSON) {
        status = j["status"]?.string.flatMap(IntentsStatus.init(rawValue:)) ?? .pendingDeposit
        updatedAt = j["updatedAt"]?.string.flatMap(OneClick.date)
        let d = j["swapDetails"]
        amountInFormatted = d?["amountInFormatted"]?.string
        amountOutFormatted = d?["amountOutFormatted"]?.string
        amountOutUSD = d?["amountOutUsd"]?.string.flatMap(Double.init)
        refundedAmount = d?["refundedAmount"]?.string.flatMap { UInt128($0) }
        refundedFormatted = d?["refundedAmountFormatted"]?.string
        refundReason = d?["refundReason"]?.string
        depositedFormatted = d?["depositedAmountFormatted"]?.string
        func txs(_ k: String) -> [Tx] {
            (d?[k]?.array ?? []).compactMap { t in t["hash"]?.string.map { Tx(hash: $0, url: t["explorerUrl"]?.string.flatMap(URL.init(string:))) } }
        }
        originTxs = txs("originChainTxHashes")
        destinationTxs = txs("destinationChainTxHashes")
        nearTxs = (d?["nearTxHashes"]?.array ?? []).compactMap(\.string)
        refundTo = j["quoteResponse"]?["quoteRequest"]?["refundTo"]?.string
    }
}

// MARK: Signature

/// 1Click signs every quote: ed25519 over base58(sha256(stable-JSON of the request and quote fields + timestamp)).
/// This mirrors `verifyQuoteSignature` in @defuse-protocol/one-click-sdk-typescript 0.1.26 field for field, including
/// JavaScript's spread semantics (a later `undefined` removes an earlier key) and json-stable-stringify's output.
public enum QuoteSignature {
    static let requestKeys = ["dry", "swapType", "slippageTolerance", "originAsset", "depositType", "destinationAsset", "amount",
                              "refundTo", "refundType", "recipient", "recipientType", "deadline"]
    static let requestTruthyKeys = ["quoteWaitingTimeMs", "referral", "virtualChainRecipient", "virtualChainRefundRecipient", "customRecipientMsg"]
    static let quoteKeys = ["amountIn", "amountInFormatted", "amountInUsd", "minAmountIn", "amountOut", "amountOutFormatted", "amountOutUsd",
                            "minAmountOut"]
    static let quoteTruthyKeys = ["depositAddress", "depositMemo", "deadline", "timeWhenInactive", "timeEstimate", "refundFee", "withdrawFee"]

    static func truthy(_ v: JSON?) -> Bool {
        switch v {
        case nil, .null?: false
        case .bool(let b)?: b
        case .number(let n)?: n != 0 && !n.isNaN
        case .string(let s)?: !s.isEmpty
        default: true
        }
    }

    /// The exact string 1Click hashed.
    public static func message(_ response: JSON) -> String? {
        guard let req = response["quoteRequest"], let q = response["quote"], let ts = response["timestamp"] else { return nil }
        var o: [String: JSON] = [:]
        for k in requestKeys { if let v = req[k] { o[k] = v } }
        for k in requestTruthyKeys where truthy(req[k]) { o[k] = req[k] }
        for k in quoteKeys { if let v = q[k] { o[k] = v } }
        if req["dry"]?.bool != true {
            // `{ ...request, ...quote }` where quote.deadline may be `undefined`: that drops the request's deadline too.
            for k in quoteTruthyKeys { if truthy(q[k]) { o[k] = q[k] } else { o.removeValue(forKey: k) } }
        }
        o["timestamp"] = ts
        return stableStringify(.object(o))
    }

    public static func hash(_ response: JSON) -> String? {
        message(response).map { Base58.encode(Hash.sha256(Array($0.utf8))) }
    }

    public static func verify(_ response: JSON, publicKey: String = OneClick.managerPublicKey) -> Bool {
        guard let h = hash(response), let sigText = response["signature"]?.string,
              let sig = Base58.decode(sigText.hasPrefix("ed25519:") ? String(sigText.dropFirst(8)) : sigText),
              let pk = Base58.decode(publicKey.hasPrefix("ed25519:") ? String(publicKey.dropFirst(8)) : publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk) else { return false }
        return key.isValidSignature(Data(sig), for: Data(h.utf8))
    }

    /// json-stable-stringify: keys sorted by UTF-16 code units, no whitespace, JSON.stringify's escaping and numbers.
    public static func stableStringify(_ v: JSON) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return jsNumber(n)
        case .string(let s): return jsString(s)
        case .array(let a): return "[" + a.map(stableStringify).joined(separator: ",") + "]"
        case .object(let o):
            let keys = o.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            return "{" + keys.map { jsString($0) + ":" + stableStringify(o[$0]!) }.joined(separator: ",") + "}"
        }
    }

    static func jsNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
        return "\(n)"
    }

    static func jsString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
