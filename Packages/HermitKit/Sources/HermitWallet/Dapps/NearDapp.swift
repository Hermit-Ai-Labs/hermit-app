import Foundation

// NEAR web apps in Hermit's browser: what a page's request means, before anything is shown or signed. Pure functions,
// no network and no keys. The page talks the HOT near-connect "injected wallet" protocol (and NEP-408's window.near):
// actions arrive in near-connect's ConnectorAction shape, {type, params}. The page script turns bigints into strings and
// byte arrays into {"$hermitBytes": base64}, and sends JSON args as the exact text the page serialized ({"$hermitJSON"}).

public enum NearDapp {
    /// NEP-413's prefix tag, 2^31 + 413: a signed message can never be a valid transaction.
    public static let nep413Tag: UInt32 = 2_147_484_061
    /// The most gas one NEAR transaction can attach.
    public static let maxGas: UInt64 = 300 * NearAction.tgas
    /// near-connect's default sign-in key allowance (0.25 NEAR).
    public static let defaultAllowance: UInt128 = 250_000_000_000_000_000_000_000
    public static let oneNear: UInt128 = 1_000_000_000_000_000_000_000_000
    /// What the review prices gas at (yocto per gas; mainnet sits at 1e8 and refunds what isn't burnt), and a plain action's gas.
    static let gasPriceCeiling: UInt128 = 200_000_000
    static let plainActionGas: UInt64 = 450_000_000_000
    static let maxTransactions = 10
    static let maxActions = 50

    /// One transaction a site asked for, signed by the connected account.
    public struct Tx: Equatable, Sendable {
        public let receiver: String
        public let actions: [NearAction]
        public init(receiver: String, actions: [NearAction]) { self.receiver = receiver; self.actions = actions }
    }

    /// The function-call key a site asks to add when it signs in (near-connect's addFunctionCallKey, NEP-408's permission).
    public struct FunctionCallKey: Equatable, Sendable {
        public let publicKey: [UInt8]
        public let contract: String
        /// Empty: any method.
        public let methods: [String]
        /// nil: no allowance cap.
        public let allowance: UInt128?
        public var action: NearAction { .addFunctionCallKey(publicKey: publicKey, allowance: allowance, receiver: contract, methods: methods) }
    }

    static func bad(_ m: String) -> DappRPCError { .params(m) }
    static func refuse(_ m: String) -> DappRPCError { DappRPCError(4200, m) }

    // MARK: Parsing

    /// Mainnet only for now. A request that names no network means the connector's default, mainnet.
    public static func checkNetwork(_ j: JSON?) throws {
        guard let j, !j.isNull else { return }
        let id = j.string ?? j["networkId"]?.string
        guard let id else { throw bad("Expected network \"mainnet\".") }
        guard id == "mainnet" else { throw refuse("Hermit only supports NEAR mainnet here, not \(id).") }
    }

    /// "ed25519:<base58>" (or bare base58) to 32 bytes. Other key types are refused.
    public static func publicKey(_ j: JSON?) throws -> [UInt8] {
        guard let s = j?.string, !s.isEmpty else { throw bad("Expected a public key \"ed25519:…\".") }
        var body = Substring(s)
        if let colon = s.firstIndex(of: ":") {
            guard s[..<colon] == "ed25519" else { throw refuse("Hermit only handles ed25519 keys.") }
            body = s[s.index(after: colon)...]
        }
        guard let b = Base58.decode(String(body)), b.count == 32 else { throw bad("Not a valid ed25519 public key: \(s.prefix(60))") }
        return b
    }

    /// A yocto amount: a decimal string (what the connector sends) or a whole JSON number. Missing means 0.
    public static func amount(_ j: JSON?, _ what: String) throws -> UInt128 {
        guard let j, !j.isNull else { return 0 }
        if let s = j.string {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber), let v = UInt128(t) else { throw bad("Bad \(what): \(s.prefix(60))") }
            return v
        }
        if let d = j.double, d >= 0, d == d.rounded(), d < 9e15 { return UInt128(d) }
        throw bad("Bad \(what).")
    }

    public static func gas(_ j: JSON?) throws -> UInt64 {
        guard let j, !j.isNull else { return 30 * NearAction.tgas }
        let v = try amount(j, "gas")
        guard v > 0, v <= UInt128(maxGas) else { throw bad("Gas must be between 1 and 300 Tgas.") }
        return UInt64(v)
    }

    /// Bytes from a {"$hermitBytes": base64} or {"$hermitJSON": text} wrapper, a base64 string, or a byte-number array.
    static func bytes(_ j: JSON?) -> [UInt8]? {
        guard let j else { return nil }
        if case .object(let o) = j, o.count == 1 {
            if let b = o["$hermitBytes"]?.string { return Data(base64Encoded: b).map { [UInt8]($0) } }
            if let t = o["$hermitJSON"]?.string { return Array(t.utf8) }
        }
        if let s = j.string { return Data(base64Encoded: s).map { [UInt8]($0) } }
        if let a = j.array {
            var out: [UInt8] = []
            for v in a { guard let n = v.int, (0...255).contains(n) else { return nil }; out.append(UInt8(n)) }
            return out
        }
        return nil
    }

    /// Function-call args: a JSON object becomes its JSON text, bytes and base64 stay bytes.
    public static func args(_ j: JSON?) throws -> [UInt8] {
        guard let j, !j.isNull else { return [] }
        if let b = bytes(j) { return b }
        switch j {
        case .string: throw bad("Function call args: a string must be base64.")
        case .object, .array:
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return [UInt8]((try? e.encode(j)) ?? Data())
        default: throw bad("Function call args must be an object or bytes.")
        }
    }

    /// The NEP-413 nonce: exactly 32 bytes.
    public static func nonce(_ j: JSON?) throws -> [UInt8] {
        guard let b = bytes(j), b.count == 32 else { throw bad("The nonce must be 32 bytes.") }
        return b
    }

    /// One connector action, checked against what Hermit will sign for a site. `account` is the signer.
    public static func action(_ j: JSON, account: String, receiver: String) throws -> NearAction {
        guard let type = j["type"]?.string else { throw bad("Each action needs a type.") }
        let p = j["params"] ?? .object([:])
        switch type.lowercased() {
        case "functioncall":
            guard let m = p["methodName"]?.string, !m.isEmpty, m.utf8.count <= 256 else { throw bad("FunctionCall needs a methodName.") }
            return .functionCall(method: m, args: try args(p["args"]), gas: try gas(p["gas"]), deposit: try amount(p["deposit"], "deposit"))
        case "transfer":
            return .transfer(deposit: try amount(p["deposit"], "deposit"))
        case "addkey":
            let perm = p["accessKey"]?["permission"]
            if perm?.string?.lowercased() == "fullaccess" || perm?["fullAccess"] != nil || perm?["FullAccess"] != nil {
                throw refuse("Hermit won't add a full-access key for a site: that key could take everything in your account.")
            }
            if let g = p["gasKeyInfo"], !g.isNull { throw refuse("Hermit doesn't add gas keys for sites.") }
            guard receiver == account else { throw bad("AddKey only works on your own account.") }
            let key = try publicKey(p["publicKey"])
            guard key != ownKey(account) else { throw refuse("That is the key Hermit signs with.") }
            guard let perm, case .object = perm, let r = perm["receiverId"]?.string else {
                throw refuse("Hermit only adds function-call keys (receiverId and methodNames).")
            }
            guard NearAccount.isValid(r) else { throw bad("Bad receiverId in AddKey: \(r.prefix(64))") }
            let methods = try methodNames(perm["methodNames"])
            var allowance: UInt128? = nil
            if let a = perm["allowance"], !a.isNull { allowance = try amount(a, "allowance") }
            return .addFunctionCallKey(publicKey: key, allowance: allowance, receiver: r, methods: methods)
        case "deletekey":
            guard receiver == account else { throw bad("DeleteKey only works on your own account.") }
            let key = try publicKey(p["publicKey"])
            guard key != ownKey(account) else { throw refuse("Hermit won't remove the key it signs with: you would lose this account.") }
            return .deleteKey(publicKey: key)
        case "deleteaccount": throw refuse("Hermit won't delete your NEAR account for a site.")
        case "deploycontract", "deployglobalcontract", "useglobalcontract": throw refuse("Hermit won't deploy a contract to your account for a site.")
        case "stake": throw refuse("Hermit doesn't stake from a site's request. Use Earn in Hermit.")
        case "createaccount": throw refuse("Hermit doesn't create accounts for a site.")
        default: throw refuse("Hermit doesn't sign \(type.prefix(40)) actions.")
        }
    }

    static func methodNames(_ j: JSON?) throws -> [String] {
        guard let j, !j.isNull else { return [] }
        guard let a = j.array else { throw bad("methodNames must be a list.") }
        return try a.map { v in
            guard let s = v.string, !s.isEmpty, s.utf8.count <= 256 else { throw bad("Bad method name.") }
            return s
        }
    }

    /// The account's own full-access key (an implicit account's id is its public key in hex).
    static func ownKey(_ account: String) -> [UInt8]? { NearAccount.isImplicit(account) ? [UInt8](hex: account) : nil }

    /// {transactions: [{signerId?, receiverId, actions}]} for the connected `account`.
    public static func transactions(_ p: JSON, account: String) throws -> [Tx] {
        guard let list = p["transactions"]?.array, !list.isEmpty else { throw bad("Expected { transactions: [{ receiverId, actions }] }.") }
        guard list.count <= maxTransactions else { throw bad("Too many transactions in one request (\(list.count)).") }
        return try list.map { t in
            if let s = t["signerId"], !s.isNull, s.string != account {
                throw DappRPCError(4100, "The site asked to sign as \(s.string?.prefix(64) ?? "another account"), which isn't the connected account.")
            }
            guard let r = t["receiverId"]?.string, NearAccount.isValid(r) else { throw bad("Bad receiverId: \(t["receiverId"]?.string?.prefix(64) ?? "missing")") }
            guard let acts = t["actions"]?.array, !acts.isEmpty else { throw bad("A transaction needs at least one action.") }
            guard acts.count <= maxActions else { throw bad("Too many actions in one transaction.") }
            let actions = try acts.map { try action($0, account: account, receiver: r) }
            guard actions.reduce(UInt64(0), { $0 + $1.gas }) <= maxGas else { throw bad("A transaction can use at most 300 Tgas.") }
            return Tx(receiver: r, actions: actions)
        }
    }

    /// near-connect's addFunctionCallKey: {contractId, publicKey, allowMethods: {anyMethod, methodNames}, gasAllowance}.
    public static func functionCallKey(_ j: JSON, account: String) throws -> FunctionCallKey {
        let key = try publicKey(j["publicKey"])
        guard key != ownKey(account) else { throw refuse("That is the key Hermit signs with.") }
        guard let c = j["contractId"]?.string, NearAccount.isValid(c) else { throw bad("Bad contractId: \(j["contractId"]?.string?.prefix(64) ?? "missing")") }
        let any = j["allowMethods"]?["anyMethod"]?.bool ?? false
        let methods = any ? [] : try methodNames(j["allowMethods"]?["methodNames"])
        guard any || !methods.isEmpty else { throw bad("Name the methods the key may call, or set anyMethod.") }
        let allowance: UInt128?
        switch j["gasAllowance"]?["kind"]?.string {
        case nil: allowance = defaultAllowance
        case "unlimited": allowance = nil
        case "limited":
            let a = try amount(j["gasAllowance"]?["amount"], "gas allowance")
            guard a > 0 else { throw bad("The gas allowance must be more than 0.") }
            allowance = a
        case let k?: throw bad("Unknown gas allowance kind \(k.prefix(20)).")
        }
        return FunctionCallKey(publicKey: key, contract: c, methods: methods, allowance: allowance)
    }

    // MARK: NEP-413

    /// borsh(u32 tag) ‖ borsh(message) ‖ nonce[32] ‖ borsh(recipient) ‖ borsh(Option<callbackUrl>). Signed as its SHA-256.
    public static func nep413Payload(message: String, nonce: [UInt8], recipient: String, callbackUrl: String?) -> [UInt8] {
        var w = Borsh()
        w.u32(nep413Tag)
        w.string(message)
        w.fixed(nonce)
        w.string(recipient)
        if let callbackUrl { w.u8(1); w.string(callbackUrl) } else { w.u8(0) }
        return w.bytes
    }

    // MARK: Words

    public static func nearText(_ v: UInt128) -> String {
        let s = Units.format(v, decimals: 24, maxFraction: 6)
        return (s == "0" && v > 0 ? Units.format(v, decimals: 24) : s) + " NEAR"
    }
    public static func tgasText(_ g: UInt64) -> String {
        let t = Double(g) / Double(NearAction.tgas)
        return (t == t.rounded() ? String(Int(t)) : String(format: "%.2f", t)) + " Tgas"
    }
    public static func shortAccount(_ a: String) -> String { NearAccount.isImplicit(a) || a.count > 32 ? "\(a.prefix(6))…\(a.suffix(4))" : a }
    static func shortKey(_ k: [UInt8]) -> String { let s = Base58.encode(k); return "ed25519:\(s.prefix(6))…\(s.suffix(4))" }

    /// Args as text for the review: JSON text when it is UTF-8, else a byte count.
    public static func argsText(_ b: [UInt8]) -> String {
        if b.isEmpty { return "none" }
        guard let s = String(bytes: b, encoding: .utf8), !s.contains(where: { $0.isASCII && $0.asciiValue! < 0x20 && $0 != "\n" && $0 != "\t" }) else {
            return "\(b.count) bytes (not text)"
        }
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }

    static func methodsText(_ m: [String]) -> String { m.isEmpty ? "any method" : m.joined(separator: ", ") }

    /// What a key can do, in words.
    public static func keyText(receiver: String, methods: [String], allowance: UInt128?) -> String {
        "Can call \(methodsText(methods)) on \(receiver), " + (allowance.map { "up to \(nearText($0)) for gas" } ?? "with no limit on gas")
    }

    /// The review sheet's words for a list of transactions.
    public struct Review: Equatable, Sendable {
        public var title: String
        public var lines: [[String]]
        public var warnings: [String]
        /// NEAR leaving the wallet: transfers plus deposits attached to calls.
        public var deposit: UInt128
        public var gas: UInt64
        /// Who gets the NEAR, when every transfer goes to one account and no call attaches NEAR.
        public var payee: String?
        public var movesFunds: Bool { deposit > 0 }
    }

    public static func review(_ txs: [Tx], account: String) -> Review {
        var lines: [[String]] = [], warnings: [String] = []
        var deposit: UInt128 = 0, gas: UInt64 = 0
        var transferTo = Set<String>(), callDeposit = false
        for (i, t) in txs.enumerated() {
            lines.append([txs.count > 1 ? "Transaction \(i + 1)" : "To", t.receiver])
            for a in t.actions {
                deposit += a.attached
                gas += a.gas == 0 ? plainActionGas : a.gas
                switch a {
                case .functionCall(let m, let args, let g, let d):
                    lines.append(["Calls", "\(m) on \(shortAccount(t.receiver))"])
                    lines.append(["Arguments", argsText(args)])
                    lines.append(["Gas", tgasText(g)])
                    if d > 0 { lines.append(["Deposit", nearText(d)]); callDeposit = true }
                    if d == NearAction.oneYocto {
                        warnings.append("\(m) attaches 1 yoctoNEAR, the check NEAR contracts use before moving tokens. Tokens a call moves aren't counted toward your daily limit.")
                    } else if d > 0 {
                        warnings.append("This attaches \(nearText(d)) to \(t.receiver). The contract decides what happens to it.")
                    }
                    if ["ft_transfer", "ft_transfer_call", "nft_transfer", "nft_transfer_call", "mt_transfer", "mt_transfer_call", "mt_batch_transfer"].contains(m), d != NearAction.oneYocto {
                        warnings.append("\(m) moves tokens out of your wallet.")
                    }
                case .transfer(let d):
                    lines.append(["Sends", "\(nearText(d)) to \(shortAccount(t.receiver))"])
                    transferTo.insert(t.receiver)
                case .addFunctionCallKey(let k, let allowance, let r, let methods):
                    lines.append(["Adds a key", shortKey(k)])
                    lines.append(["Key can", keyText(receiver: r, methods: methods, allowance: allowance)])
                    if allowance == nil { warnings.append("The new key has no gas allowance limit: it can spend your NEAR on gas until you remove it.") }
                    if methods.isEmpty { warnings.append("The new key can call any method on \(r) without asking you.") }
                case .deleteKey(let k):
                    lines.append(["Removes a key", shortKey(k)])
                }
            }
        }
        let title: String
        if txs.count == 1, txs[0].actions.count == 1 {
            switch txs[0].actions[0] {
            case .functionCall(let m, _, _, _): title = "Call \(m)"
            case .transfer(let d): title = "Send \(nearText(d))"
            case .addFunctionCallKey: title = "Add an access key"
            case .deleteKey: title = "Remove an access key"
            }
        } else if txs.count == 1 {
            title = "\(txs[0].actions.count) actions on \(shortAccount(txs[0].receiver))"
        } else {
            title = "\(txs.count) transactions"
        }
        lines.append(["Network fee", "up to \(nearText(UInt128(gas) * gasPriceCeiling))"])
        let payee = !callDeposit && transferTo.count == 1 ? transferTo.first : nil
        return Review(title: title, lines: lines, warnings: warnings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                      deposit: deposit, gas: gas, payee: payee)
    }

    /// Dollars for `yocto` NEAR at `price`, nil without a price.
    public static func usd(_ yocto: UInt128, price: Double?) -> Decimal? {
        guard let price, price > 0 else { return nil }
        let near = (Decimal(string: String(yocto)) ?? 0) / (Decimal(string: String(oneNear)) ?? 1)
        return near * Decimal(price)
    }
}
