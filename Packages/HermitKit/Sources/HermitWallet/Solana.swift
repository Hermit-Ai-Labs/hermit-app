import Foundation
import CryptoKit

// MARK: - Instructions and legacy messages

public struct SolanaAccountMeta: Equatable, Sendable {
    public var key: SolanaPublicKey
    public var isSigner: Bool
    public var isWritable: Bool
    public init(_ key: SolanaPublicKey, signer: Bool, writable: Bool) { self.key = key; isSigner = signer; isWritable = writable }
}

public struct SolanaInstruction: Equatable, Sendable {
    public var program: SolanaPublicKey
    public var accounts: [SolanaAccountMeta]
    public var data: [UInt8]
    public init(program: SolanaPublicKey, accounts: [SolanaAccountMeta], data: [UInt8]) {
        self.program = program; self.accounts = accounts; self.data = data
    }

    public static func setComputeUnitLimit(_ units: UInt32) -> Self {
        .init(program: .computeBudgetProgram, accounts: [], data: [2] + units.littleEndianBytes(width: 4))
    }
    /// Priority fee in micro-lamports per compute unit.
    public static func setComputeUnitPrice(_ microLamports: UInt64) -> Self {
        .init(program: .computeBudgetProgram, accounts: [], data: [3] + microLamports.littleEndianBytes(width: 8))
    }
    public static func transfer(from: SolanaPublicKey, to: SolanaPublicKey, lamports: UInt64) -> Self {
        .init(program: .systemProgram, accounts: [.init(from, signer: true, writable: true), .init(to, signer: false, writable: true)],
              data: [2, 0, 0, 0] + lamports.littleEndianBytes(width: 8))
    }
    /// Creates the recipient's associated token account if it doesn't exist (no-op if it does).
    public static func createAssociatedTokenAccountIdempotent(payer: SolanaPublicKey, owner: SolanaPublicKey, mint: SolanaPublicKey) -> Self {
        let ata = SolanaPublicKey.associatedTokenAccount(owner: owner, mint: mint)
        return .init(program: .associatedTokenProgram, accounts: [
            .init(payer, signer: true, writable: true), .init(ata, signer: false, writable: true),
            .init(owner, signer: false, writable: false), .init(mint, signer: false, writable: false),
            .init(.systemProgram, signer: false, writable: false), .init(.tokenProgram, signer: false, writable: false),
        ], data: [1])
    }
    public static func transferChecked(source: SolanaPublicKey, mint: SolanaPublicKey, destination: SolanaPublicKey,
                                       owner: SolanaPublicKey, amount: UInt64, decimals: UInt8) -> Self {
        .init(program: .tokenProgram, accounts: [
            .init(source, signer: false, writable: true), .init(mint, signer: false, writable: false),
            .init(destination, signer: false, writable: true), .init(owner, signer: true, writable: false),
        ], data: [12] + amount.littleEndianBytes(width: 8) + [decimals])
    }
}

func shortvec(_ n: Int) -> [UInt8] {
    var v = n; var out = [UInt8]()
    repeat {
        var b = UInt8(v & 0x7F); v >>= 7
        if v != 0 { b |= 0x80 }
        out.append(b)
    } while v != 0
    return out
}

/// A compiled legacy message. Account order follows the Solana SDK: fee payer first, then writable signers,
/// read-only signers, writable and read-only non-signers, each group sorted by key bytes.
public struct SolanaMessage: Equatable, Sendable {
    public var accountKeys: [SolanaPublicKey]
    public var numSigners: Int
    public var numReadonlySigned: Int
    public var numReadonlyUnsigned: Int
    public var recentBlockhash: [UInt8]
    public var instructions: [SolanaInstruction]

    public init(payer: SolanaPublicKey, instructions: [SolanaInstruction], recentBlockhash: [UInt8]) {
        var meta: [SolanaPublicKey: (signer: Bool, writable: Bool)] = [payer: (true, true)]
        for ix in instructions {
            meta[ix.program] = meta[ix.program] ?? (false, false)
            for a in ix.accounts {
                let m = meta[a.key] ?? (false, false)
                meta[a.key] = (m.signer || a.isSigner, m.writable || a.isWritable)
            }
        }
        let rest = meta.filter { $0.key != payer }
        func group(_ s: Bool, _ w: Bool) -> [SolanaPublicKey] { rest.filter { $0.value.signer == s && $0.value.writable == w }.map(\.key).sorted() }
        let ws = [payer] + group(true, true), rs = group(true, false), wu = group(false, true), ru = group(false, false)
        accountKeys = ws + rs + wu + ru
        numSigners = ws.count + rs.count
        numReadonlySigned = rs.count
        numReadonlyUnsigned = ru.count
        self.recentBlockhash = recentBlockhash
        self.instructions = instructions
    }

    public var serialized: [UInt8] {
        var out: [UInt8] = [UInt8(numSigners), UInt8(numReadonlySigned), UInt8(numReadonlyUnsigned)]
        out += shortvec(accountKeys.count) + accountKeys.flatMap(\.bytes)
        out += recentBlockhash
        out += shortvec(instructions.count)
        let index = Dictionary(uniqueKeysWithValues: accountKeys.enumerated().map { ($1, UInt8($0)) })
        for ix in instructions {
            out.append(index[ix.program]!)
            out += shortvec(ix.accounts.count) + ix.accounts.map { index[$0.key]! }
            out += shortvec(ix.data.count) + ix.data
        }
        return out
    }
}

public struct SolanaTransaction: Sendable {
    public var message: SolanaMessage
    public var signatures: [[UInt8]]

    public init(message: SolanaMessage) {
        self.message = message
        signatures = Array(repeating: [UInt8](repeating: 0, count: 64), count: message.numSigners)
    }

    /// Signs as the fee payer with an ed25519 key from SLIP-10 (32-byte seed). The caller wipes the seed.
    public mutating func sign(ed25519Seed seed: [UInt8]) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        guard key.publicKey.rawRepresentation.bytes == message.accountKeys[0].bytes else { throw WalletError.invalidKey }
        signatures[0] = try key.signature(for: message.serialized).bytes
    }

    public var serialized: [UInt8] { shortvec(signatures.count) + signatures.flatMap { $0 } + message.serialized }
    public var base64: String { Data(serialized).base64EncodedString() }
    /// The transaction id is the fee payer's signature in base58.
    public var signature: String { Base58.encode(signatures[0]) }

    public func verifySignature() -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: message.accountKeys[0].bytes) else { return false }
        return pub.isValidSignature(signatures[0], for: message.serialized)
    }
}

// MARK: - RPC

public struct SolanaSimulation: Sendable {
    public var error: String?
    public var unitsConsumed: UInt64
    public var logs: [String]
    /// Post-simulation state of the accounts we asked about (lamports, and token amount if it's a token account).
    public var accounts: [(lamports: UInt64, tokenAmount: UInt128?)?]
}

public final class SolanaClient: Sendable {
    public let rpc: JSONRPCClient
    public init(url: URL, session: URLSession = .shared) { rpc = JSONRPCClient(url: url, session: session) }

    func u64(_ j: JSON?, _ what: String) throws -> UInt64 {
        guard let d = j?.double, d >= 0, let v = UInt64(exactly: d) else { throw WalletError.badResponse(what) }
        return v
    }

    public func balance(_ a: SolanaPublicKey) async throws -> UInt64 {
        try u64(try await rpc.call("getBalance", [.string(a.description), ["commitment": "confirmed"]])["value"], "getBalance")
    }

    /// Sum of the owner's token accounts for a mint, in base units.
    public func tokenBalance(owner: SolanaPublicKey, mint: SolanaPublicKey) async throws -> UInt128 {
        let r = try await rpc.call("getTokenAccountsByOwner", [.string(owner.description), ["mint": .string(mint.description)],
                                                             ["encoding": "jsonParsed", "commitment": "confirmed"]])
        var total: UInt128 = 0
        for acc in r["value"]?.array ?? [] {
            if let s = acc["account"]?["data"]?["parsed"]?["info"]?["tokenAmount"]?["amount"]?.string, let v = UInt128(s) { total += v }
        }
        return total
    }

    /// The owner's balance of each mint in base units (0 when it holds none), from two calls in all: one per token
    /// program (SPL Token and Token-2022). One call per mint ran into the public node's 10 per 10 s limit per method.
    public func tokenBalances(owner: SolanaPublicKey, mints: [SolanaPublicKey]) async throws -> [SolanaPublicKey: UInt128] {
        func accounts(_ program: String) async throws -> JSON {
            try await rpc.call("getTokenAccountsByOwner", [.string(owner.description), ["programId": .string(program)],
                                                           ["encoding": "jsonParsed", "commitment": "confirmed"]])
        }
        async let classic = accounts("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
        async let token2022 = accounts("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
        let replies = try await [classic, token2022]
        let wanted = Set(mints.map(\.description))
        var byMint: [String: UInt128] = [:]
        for r in replies {
            for acc in r["value"]?.array ?? [] {
                let info = acc["account"]?["data"]?["parsed"]?["info"]
                guard let mint = info?["mint"]?.string, wanted.contains(mint),
                      let s = info?["tokenAmount"]?["amount"]?.string, let v = UInt128(s) else { continue }
                byMint[mint, default: 0] += v
            }
        }
        var out: [SolanaPublicKey: UInt128] = [:]
        for m in mints { out[m] = byMint[m.description] ?? 0 }
        return out
    }

    public func accountExists(_ a: SolanaPublicKey) async throws -> Bool {
        let r = try await rpc.call("getAccountInfo", [.string(a.description), ["encoding": "base64", "commitment": "confirmed"]])
        return !(r["value"]?.isNull ?? true)
    }

    public func latestBlockhash() async throws -> (hash: [UInt8], lastValidBlockHeight: UInt64) {
        let r = try await rpc.call("getLatestBlockhash", [["commitment": "confirmed"]])
        guard let s = r["value"]?["blockhash"]?.string, let h = Base58.decode(s), h.count == 32 else { throw WalletError.badResponse("blockhash") }
        return (h, try u64(r["value"]?["lastValidBlockHeight"], "lastValidBlockHeight"))
    }

    /// Priority fee (micro-lamports per CU): the median of recent non-zero fees paid on these accounts, at least 1000.
    public func priorityFee(accounts: [SolanaPublicKey]) async throws -> UInt64 {
        let r = try await rpc.call("getRecentPrioritizationFees", [.array(accounts.map { .string($0.description) })])
        let fees = (r.array ?? []).compactMap { $0["prioritizationFee"]?.double }.filter { $0 > 0 }.sorted()
        let median = fees.isEmpty ? 0 : fees[fees.count / 2]
        return Swift.min(Swift.max(UInt64(median), 1_000), 5_000_000) // cap: 5 lamports per CU
    }

    public func simulate(_ tx: SolanaTransaction, accounts: [SolanaPublicKey] = []) async throws -> SolanaSimulation {
        var cfg: [String: JSON] = ["encoding": "base64", "sigVerify": false, "replaceRecentBlockhash": true, "commitment": "confirmed"]
        if !accounts.isEmpty { cfg["accounts"] = ["encoding": "jsonParsed", "addresses": .array(accounts.map { .string($0.description) })] }
        let r = try await rpc.call("simulateTransaction", [.string(tx.base64), .object(cfg)])
        guard let v = r["value"] else { throw WalletError.badResponse("simulate") }
        let err: String? = (v["err"].map { $0.isNull ? nil : String(data: (try? JSONEncoder().encode($0)) ?? Data(), encoding: .utf8) } ?? nil)
        let posts: [(lamports: UInt64, tokenAmount: UInt128?)?] = (v["accounts"]?.array ?? []).map { a in
            guard !a.isNull, let l = a["lamports"]?.double else { return nil }
            let amt = a["data"]?["parsed"]?["info"]?["tokenAmount"]?["amount"]?.string.flatMap { UInt128($0) }
            return (UInt64(l), amt)
        }
        return SolanaSimulation(error: err, unitsConsumed: UInt64(v["unitsConsumed"]?.double ?? 0),
                                logs: (v["logs"]?.array ?? []).compactMap(\.string), accounts: posts)
    }

    public func send(_ tx: SolanaTransaction) async throws -> String {
        let r = try await rpc.call("sendTransaction", [.string(tx.base64), ["encoding": "base64", "preflightCommitment": "confirmed", "maxRetries": 5]])
        guard let sig = r.string else { throw WalletError.badResponse("sendTransaction") }
        return sig
    }

    /// Lamports the network charges for this message (base fee + priority fee).
    public func fee(for message: SolanaMessage) async throws -> UInt64 {
        let r = try await rpc.call("getFeeForMessage", [.string(Data(message.serialized).base64EncodedString()), ["commitment": "confirmed"]])
        return try u64(r["value"], "fee")
    }

    /// Waits until the signature is confirmed. Returns (success, slot, error).
    public func waitForConfirmation(_ signature: String, timeout: Duration = .seconds(90)) async throws -> (Bool, UInt64, String?) {
        let clock = ContinuousClock(); let deadline = clock.now + timeout
        while clock.now < deadline {
            try Task.checkCancellation()
            if let r = try? await rpc.call("getSignatureStatuses", [[.string(signature)], ["searchTransactionHistory": false]]),
               let st = r["value"]?[0], !st.isNull,
               let level = st["confirmationStatus"]?.string, level == "confirmed" || level == "finalized" {
                let err = st["err"].flatMap { $0.isNull ? nil : "failed on chain" }
                return (err == nil, UInt64(st["slot"]?.double ?? 0), err)
            }
            try await Task.sleep(for: .seconds(1.5))
        }
        throw WalletError.timeout
    }
}
