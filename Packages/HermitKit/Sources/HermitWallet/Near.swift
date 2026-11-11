import Foundation
import CryptoKit

// NEAR Protocol: accounts, Borsh transactions signed with ed25519 (CryptoKit), and a small JSON-RPC client.
// Docs: docs.near.org/protocol/transactions, nomicon.io/RuntimeSpec/Transactions, docs.near.org/api/rpc.

/// A NEAR account id: a named account ("alice.near") or an implicit one (64 lowercase hex = the ed25519 public key).
public enum NearAccount {
    /// docs.near.org/protocol/account-id: 2-64 chars, lowercase letters, digits and `-_` separators, dot-separated parts.
    public static func isValid(_ s: String) -> Bool {
        guard (2...64).contains(s.count), s == s.lowercased() else { return false }
        return s.range(of: #"^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$"#, options: .regularExpression) != nil
    }
    public static func isImplicit(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
    /// The implicit account for an ed25519 public key.
    public static func implicit(publicKey: [UInt8]) -> String { publicKey.hex }
    /// "ed25519:<base58>", the form RPC and wallets show.
    public static func publicKeyString(_ pub: [UInt8]) -> String { "ed25519:" + Base58.encode(pub) }
}

/// Borsh, the binary format NEAR transactions are serialized in (borsh.io). Little-endian integers,
/// u32-length-prefixed strings and vectors.
public struct Borsh {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    public mutating func u128(_ v: UInt128) { u64(UInt64(truncatingIfNeeded: v)); u64(UInt64(truncatingIfNeeded: v >> 64)) }
    public mutating func string(_ s: String) { let b = Array(s.utf8); u32(UInt32(b.count)); bytes += b }
    public mutating func vec(_ b: [UInt8]) { u32(UInt32(b.count)); bytes += b }
    public mutating func fixed(_ b: [UInt8]) { bytes += b }
}

/// The actions Hermit uses. Borsh enum tags follow nearcore's `Action` (Transfer = 3, FunctionCall = 2).
public enum NearAction: Equatable, Sendable {
    case transfer(deposit: UInt128)
    case functionCall(method: String, args: [UInt8], gas: UInt64, deposit: UInt128)

    public static let tgas: UInt64 = 1_000_000_000_000
    /// One yoctoNEAR: NEP-141 `ft_transfer` requires exactly this attached (it proves a full-access key signed).
    public static let oneYocto: UInt128 = 1
    /// Storage for one NEP-141 registration (0.00125 NEAR), the usual `storage_balance_bounds().min`.
    public static let storageDeposit: UInt128 = 1_250_000_000_000_000_000_000

    public static func ftTransfer(receiver: String, amount: UInt128, memo: String? = nil) -> NearAction {
        // Same key order as near-api-js callers write it (receiver_id, amount, memo), so test vectors match byte for byte.
        var json = #"{"receiver_id":"\#(receiver)","amount":"\#(amount)""#
        if let memo { json += #","memo":"\#(memo)""# }
        return .functionCall(method: "ft_transfer", args: Array((json + "}").utf8), gas: 30 * tgas, deposit: oneYocto)
    }
    public static func storageDeposit(for account: String) -> NearAction {
        .functionCall(method: "storage_deposit", args: Array(#"{"account_id":"\#(account)","registration_only":true}"#.utf8),
                      gas: 30 * tgas, deposit: storageDeposit)
    }

    func encode(_ w: inout Borsh) {
        switch self {
        case .transfer(let d): w.u8(3); w.u128(d)
        case .functionCall(let m, let a, let g, let d): w.u8(2); w.string(m); w.vec(a); w.u64(g); w.u128(d)
        }
    }
    public var attached: UInt128 {
        switch self { case .transfer(let d): d; case .functionCall(_, _, _, let d): d }
    }
    public var gas: UInt64 {
        switch self { case .transfer: 0; case .functionCall(_, _, let g, _): g }
    }
}

public struct NearTransaction: Equatable, Sendable {
    public let signer: String
    public let publicKey: [UInt8]
    public let nonce: UInt64
    public let receiver: String
    public let blockHash: [UInt8]
    public let actions: [NearAction]

    public init(signer: String, publicKey: [UInt8], nonce: UInt64, receiver: String, blockHash: [UInt8], actions: [NearAction]) {
        self.signer = signer; self.publicKey = publicKey; self.nonce = nonce; self.receiver = receiver
        self.blockHash = blockHash; self.actions = actions
    }

    public var serialized: [UInt8] {
        var w = Borsh()
        w.string(signer)
        w.u8(0); w.fixed(publicKey)          // KeyType::ED25519
        w.u64(nonce)
        w.string(receiver)
        w.fixed(blockHash)
        w.u32(UInt32(actions.count))
        for a in actions { a.encode(&w) }
        return w.bytes
    }
    /// What gets signed, and the transaction's id (base58 of it).
    public var hash: [UInt8] { Hash.sha256(serialized) }
    public var hashString: String { Base58.encode(hash) }

    /// Signs with the raw 32-byte ed25519 seed. CryptoKit's ed25519 adds randomness, so signatures differ run to run
    /// but always verify.
    public func sign(ed25519Seed seed: [UInt8]) throws -> SignedNearTransaction {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        guard [UInt8](key.publicKey.rawRepresentation) == publicKey else { throw WalletError.invalidKey }
        let sig = try key.signature(for: Data(hash))
        return SignedNearTransaction(transaction: self, signature: [UInt8](sig))
    }
}

public struct SignedNearTransaction: Equatable, Sendable {
    public let transaction: NearTransaction
    public let signature: [UInt8]
    public var serialized: [UInt8] { transaction.serialized + [0] + signature }
    public var base64: String { Data(serialized).base64EncodedString() }
    public func verify() -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: transaction.publicKey) else { return false }
        return pub.isValidSignature(Data(signature), for: Data(transaction.hash))
    }
}

/// NEAR JSON-RPC (object params). Reads accounts, access keys and NEP-141 balances; sends signed transactions.
public final class NearClient: Sendable {
    public let url: URL
    let session: URLSession
    public init(url: URL = Chain.near.rpc, session: URLSession = .shared) { self.url = url; self.session = session }

    public struct RPCError: Error, LocalizedError, Equatable {
        public let cause: String
        public let message: String
        public var errorDescription: String? { message }
    }

    func call(_ method: String, _ params: JSON) async throws -> JSON {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["jsonrpc": "2.0", "id": "hermit", "method": .string(method), "params": params] as JSON)
        var attempt = 0
        while true {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                guard attempt < JSONRPCClient.maxRetries else { throw JSONRPCClient.busy }
                attempt += 1; try await Task.sleep(for: .seconds(JSONRPCClient.retrySeconds(resp, attempt: attempt))); continue
            }
            guard (200..<300).contains(status) else { throw WalletError.rpc(code: status, message: "HTTP \(status) from \(url.host() ?? "NEAR RPC")") }
            let j = try JSONDecoder().decode(JSON.self, from: data)
            if let e = j["error"], !e.isNull {
                throw RPCError(cause: e["cause"]?["name"]?.string ?? e["name"]?.string ?? "ERROR",
                               message: e["data"]?.string ?? e["message"]?.string ?? "NEAR RPC error")
            }
            guard let r = j["result"] else { throw WalletError.badResponse(method) }
            return r
        }
    }

    public struct AccountState: Equatable, Sendable {
        public let amount: UInt128
        public let locked: UInt128
        public let storageUsage: UInt64
        /// What can be spent: the balance less what storage staking holds (1e19 yocto per byte, NEP-448 "storage staking").
        public var available: UInt128 {
            let reserved = UInt128(storageUsage) * 10_000_000_000_000_000_000
            let free = amount > reserved ? amount - reserved : 0
            return free > locked ? free - locked : 0
        }
    }

    /// nil when the account doesn't exist yet (an implicit account exists only once someone has sent it NEAR).
    public func account(_ id: String) async throws -> AccountState? {
        do {
            let r = try await call("query", ["request_type": "view_account", "finality": "final", "account_id": .string(id)])
            guard let a = r["amount"]?.string.flatMap({ UInt128($0) }) else { throw WalletError.badResponse("view_account") }
            return AccountState(amount: a, locked: r["locked"]?.string.flatMap { UInt128($0) } ?? 0,
                                storageUsage: UInt64(r["storage_usage"]?.double ?? 0))
        } catch let e as RPCError where e.cause == "UNKNOWN_ACCOUNT" { return nil }
    }

    /// A read-only contract call; returns the JSON the method returned.
    public func view(_ contract: String, _ method: String, args: [UInt8] = Array("{}".utf8)) async throws -> JSON {
        let r = try await call("query", ["request_type": "call_function", "finality": "final", "account_id": .string(contract),
                                         "method_name": .string(method), "args_base64": .string(Data(args).base64EncodedString())])
        let bytes = (r["result"]?.array ?? []).compactMap { $0.double.map { UInt8($0) } }
        return (try? JSONDecoder().decode(JSON.self, from: Data(bytes))) ?? .null
    }

    public func ftBalance(token: String, owner: String) async throws -> UInt128 {
        let r = try await view(token, "ft_balance_of", args: Array(#"{"account_id":"\#(owner)"}"#.utf8))
        return r.string.flatMap { UInt128($0) } ?? 0
    }

    /// Whether `account` is registered with the token (has paid storage); `ft_transfer` to an unregistered one fails.
    public func isRegistered(token: String, account: String) async throws -> Bool {
        !(try await view(token, "storage_balance_of", args: Array(#"{"account_id":"\#(account)"}"#.utf8))).isNull
    }

    /// The access key's current nonce (the next transaction uses nonce + 1).
    public func accessKeyNonce(account: String, publicKey: String) async throws -> UInt64 {
        let r = try await call("query", ["request_type": "view_access_key", "finality": "final", "account_id": .string(account),
                                         "public_key": .string(publicKey)])
        guard let n = r["nonce"]?.double else { throw WalletError.badResponse("view_access_key") }
        return UInt64(n)
    }

    public func latestBlockHash() async throws -> [UInt8] {
        let r = try await call("block", ["finality": "final"])
        guard let h = r["header"]?["hash"]?.string, let b = Base58.decode(h), b.count == 32 else { throw WalletError.badResponse("block") }
        return b
    }

    public func gasPrice() async throws -> UInt128 {
        let r = try await call("gas_price", [.null])
        return r["gas_price"]?.string.flatMap { UInt128($0) } ?? 100_000_000
    }

    /// Sends and waits until the transaction and its receipts have executed. Returns (hash, success, failure text).
    public func send(_ tx: SignedNearTransaction) async throws -> (hash: String, success: Bool, failure: String?) {
        let r = try await call("send_tx", ["signed_tx_base64": .string(tx.base64), "wait_until": "EXECUTED_OPTIMISTIC"])
        let hash = r["transaction"]?["hash"]?.string ?? tx.transaction.hashString
        if let f = r["status"]?["Failure"], !f.isNull {
            let text = (try? String(data: JSONEncoder().encode(f), encoding: .utf8)) ?? "failed"
            return (hash, false, text)
        }
        // A function call can fail in a later receipt while the transaction itself succeeds.
        for o in r["receipts_outcome"]?.array ?? [] {
            if let f = o["outcome"]?["status"]?["Failure"], !f.isNull {
                return (hash, false, (try? String(data: JSONEncoder().encode(f), encoding: .utf8)) ?? "a receipt failed")
            }
        }
        return (hash, true, nil)
    }
}
