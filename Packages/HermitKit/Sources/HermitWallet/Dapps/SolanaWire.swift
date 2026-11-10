import Foundation

// Solana transactions as web apps send them: legacy, v0 (address lookup tables) and v1 (SIMD-0385: signatures at the
// end, compute budget in a message config). Parsed byte for byte; anything else is refused. The bytes Hermit signs
// are always the message bytes exactly as received, never a re-encoding.

public enum SolanaWireError: Error, LocalizedError, Equatable {
    case truncated(String)
    case unsupportedVersion(Int)
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .truncated(let w): "The transaction is cut short (\(w))."
        case .unsupportedVersion(let v): "Hermit can't read Solana transaction version \(v)."
        case .invalid(let w): "The transaction isn't valid: \(w)."
        }
    }
}

/// Reads bytes front to back.
struct SolanaReader {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { self.b = b }
    var atEnd: Bool { i == b.count }
    mutating func u8(_ what: String) throws -> UInt8 {
        guard i < b.count else { throw SolanaWireError.truncated(what) }
        defer { i += 1 }; return b[i]
    }
    mutating func bytes(_ n: Int, _ what: String) throws -> [UInt8] {
        guard n >= 0, i + n <= b.count else { throw SolanaWireError.truncated(what) }
        defer { i += n }; return Array(b[i..<i + n])
    }
    mutating func u16(_ what: String) throws -> Int { let x = try bytes(2, what); return Int(x[0]) | Int(x[1]) << 8 }
    mutating func u32(_ what: String) throws -> UInt32 {
        try bytes(4, what).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
    /// Solana's compact-u16 ("shortvec"): 1 to 3 bytes, 7 bits each, no redundant encodings.
    mutating func compactU16(_ what: String) throws -> Int {
        var v = 0
        for k in 0..<3 {
            let x = try u8(what)
            v |= Int(x & 0x7f) << (7 * k)
            if x & 0x80 == 0 {
                if k > 0 && x == 0 { throw SolanaWireError.invalid("non-canonical length in \(what)") }
                guard v <= 0xffff else { throw SolanaWireError.invalid("length too large in \(what)") }
                return v
            }
        }
        throw SolanaWireError.invalid("length too long in \(what)")
    }
    mutating func key(_ what: String) throws -> SolanaPublicKey { SolanaPublicKey(bytes: try bytes(32, what)) }
}

public struct SolanaCompiledInstruction: Equatable, Sendable {
    public let programIndex: Int
    public let accounts: [Int]
    public let data: [UInt8]
}

public struct SolanaLookup: Equatable, Sendable {
    public let table: SolanaPublicKey
    public let writable: [UInt8]
    public let readonly: [UInt8]
}

/// v1's message-level compute budget (SIMD-0385 TransactionConfigMask). nil fields weren't set (which in v1 means 0).
public struct SolanaV1Config: Equatable, Sendable {
    public var priorityFeeLamports: UInt64?
    public var computeUnitLimit: UInt32?
    public var loadedAccountsDataSizeLimit: UInt32?
    public var heapSize: UInt32?
}

public struct SolanaWireMessage: Equatable, Sendable {
    public enum Version: Equatable, Sendable { case legacy, v0, v1 }
    public let version: Version
    public let numRequiredSignatures: Int
    public let numReadonlySigned: Int
    public let numReadonlyUnsigned: Int
    public let staticKeys: [SolanaPublicKey]
    public let recentBlockhash: [UInt8]
    public let instructions: [SolanaCompiledInstruction]
    public let lookups: [SolanaLookup]
    public let config: SolanaV1Config?
    /// Exactly the bytes the signatures cover.
    public let bytes: [UInt8]

    public var feePayer: SolanaPublicKey { staticKeys[0] }
    public var signers: ArraySlice<SolanaPublicKey> { staticKeys.prefix(numRequiredSignatures) }
    public var loadedCount: Int { lookups.reduce(0) { $0 + $1.writable.count + $1.readonly.count } }
    public var loadedWritableCount: Int { lookups.reduce(0) { $0 + $1.writable.count } }

    /// Whether account `i` of the full list (static, then loaded writable, then loaded read-only) is writable.
    public func isWritable(_ i: Int) -> Bool {
        let n = staticKeys.count
        if i < numRequiredSignatures { return i < numRequiredSignatures - numReadonlySigned }
        if i < n { return i < n - numReadonlyUnsigned }
        return i < n + loadedWritableCount
    }
    public func isSigner(_ i: Int) -> Bool { i < numRequiredSignatures }

    /// Parses a legacy or v0 message (what follows the signatures). The whole input must be one message.
    public static func parse(_ bytes: [UInt8]) throws -> SolanaWireMessage {
        var r = SolanaReader(bytes)
        guard let first = bytes.first else { throw SolanaWireError.truncated("message") }
        var version = Version.legacy
        if first & 0x80 != 0 {
            let v = Int(first & 0x7f)
            guard v == 0 else { throw SolanaWireError.unsupportedVersion(v) }
            version = .v0; r.i = 1
        }
        let h0 = Int(try r.u8("header")), h1 = Int(try r.u8("header")), h2 = Int(try r.u8("header"))
        let nKeys = try r.compactU16("account keys")
        var keys: [SolanaPublicKey] = []
        for _ in 0..<nKeys { keys.append(try r.key("account key")) }
        let blockhash = try r.bytes(32, "recent blockhash")
        let nIx = try r.compactU16("instructions")
        var ixs: [SolanaCompiledInstruction] = []
        for _ in 0..<nIx {
            let p = Int(try r.u8("program index"))
            let na = try r.compactU16("instruction accounts")
            let accts = try r.bytes(na, "instruction accounts").map(Int.init)
            let nd = try r.compactU16("instruction data")
            ixs.append(SolanaCompiledInstruction(programIndex: p, accounts: accts, data: try r.bytes(nd, "instruction data")))
        }
        var lookups: [SolanaLookup] = []
        if version == .v0 {
            let nL = try r.compactU16("lookups")
            for _ in 0..<nL {
                let t = try r.key("lookup table")
                let w = try r.bytes(try r.compactU16("lookup writable"), "lookup writable")
                let ro = try r.bytes(try r.compactU16("lookup readonly"), "lookup readonly")
                lookups.append(SolanaLookup(table: t, writable: w, readonly: ro))
            }
        }
        guard r.atEnd else { throw SolanaWireError.invalid("extra bytes after the message") }
        let m = SolanaWireMessage(version: version, numRequiredSignatures: h0, numReadonlySigned: h1, numReadonlyUnsigned: h2,
                                  staticKeys: keys, recentBlockhash: blockhash, instructions: ixs, lookups: lookups, config: nil, bytes: bytes)
        try m.validate()
        return m
    }

    /// The header and indexes are consistent: at least one signer, enough keys, every index in range.
    func validate() throws {
        guard numRequiredSignatures >= 1 else { throw SolanaWireError.invalid("no signer") }
        guard numReadonlySigned < numRequiredSignatures else { throw SolanaWireError.invalid("the fee payer must be writable") }
        guard staticKeys.count >= numRequiredSignatures + numReadonlyUnsigned else { throw SolanaWireError.invalid("header counts exceed the keys") }
        let total = staticKeys.count + loadedCount
        guard total <= 256 else { throw SolanaWireError.invalid("too many accounts") }
        for ix in instructions {
            // Programs come from the static keys (a lookup can't name a program to invoke).
            guard ix.programIndex < staticKeys.count, ix.programIndex != 0 else { throw SolanaWireError.invalid("bad program index") }
            guard ix.accounts.allSatisfy({ $0 < total }) else { throw SolanaWireError.invalid("account index out of range") }
        }
    }
}

public struct SolanaWireTransaction: Equatable, Sendable {
    public var signatures: [[UInt8]]
    public let message: SolanaWireMessage

    /// Legacy and v0: shortvec(count) ‖ signatures ‖ message. v1: message (starting 0x81) ‖ signatures.
    public static func parse(_ raw: [UInt8]) throws -> SolanaWireTransaction {
        guard let first = raw.first else { throw SolanaWireError.truncated("transaction") }
        if first & 0x80 != 0 {
            // A versioned envelope: only v1 puts the version byte at offset 0.
            let v = Int(first & 0x7f)
            guard v == 1 else { throw SolanaWireError.unsupportedVersion(v) }
            return try parseV1(raw)
        }
        var r = SolanaReader(raw)
        let n = try r.compactU16("signatures")
        var sigs: [[UInt8]] = []
        for _ in 0..<n { sigs.append(try r.bytes(64, "signature")) }
        let message = try SolanaWireMessage.parse(Array(raw[r.i...]))
        guard sigs.count == message.numRequiredSignatures else { throw SolanaWireError.invalid("signature count doesn't match the header") }
        return SolanaWireTransaction(signatures: sigs, message: message)
    }

    static func parseV1(_ raw: [UInt8]) throws -> SolanaWireTransaction {
        var r = SolanaReader(raw)
        _ = try r.u8("version")
        let h0 = Int(try r.u8("header")), h1 = Int(try r.u8("header")), h2 = Int(try r.u8("header"))
        let mask = try r.u32("config mask")
        guard mask & ~UInt32(0b11111) == 0 else { throw SolanaWireError.invalid("unknown config fields") }
        guard (mask & 1 == 0) == (mask & 2 == 0) else { throw SolanaWireError.invalid("priority fee needs both mask bits") }
        let blockhash = try r.bytes(32, "lifetime")
        let nIx = Int(try r.u8("instructions"))
        let nKeys = Int(try r.u8("addresses"))
        guard nKeys <= 64, nIx <= 64 else { throw SolanaWireError.invalid("v1 allows at most 64 addresses and 64 instructions") }
        var keys: [SolanaPublicKey] = []
        for _ in 0..<nKeys { keys.append(try r.key("address")) }
        guard Set(keys).count == keys.count else { throw SolanaWireError.invalid("duplicate addresses") }
        var cfg = SolanaV1Config()
        if mask & 1 != 0 {
            let lo = UInt64(try r.u32("priority fee")), hi = UInt64(try r.u32("priority fee"))
            cfg.priorityFeeLamports = lo | hi << 32
        }
        if mask & 4 != 0 { cfg.computeUnitLimit = try r.u32("compute unit limit") }
        if mask & 8 != 0 { cfg.loadedAccountsDataSizeLimit = try r.u32("loaded data size") }
        if mask & 16 != 0 { cfg.heapSize = try r.u32("heap size") }
        var headers: [(Int, Int, Int)] = []
        for _ in 0..<nIx { headers.append((Int(try r.u8("program index")), Int(try r.u8("account count")), try r.u16("data length"))) }
        var ixs: [SolanaCompiledInstruction] = []
        for (p, na, nd) in headers {
            let a = try r.bytes(na, "instruction accounts").map(Int.init)
            ixs.append(SolanaCompiledInstruction(programIndex: p, accounts: a, data: try r.bytes(nd, "instruction data")))
        }
        let messageEnd = r.i
        var sigs: [[UInt8]] = []
        for _ in 0..<h0 { sigs.append(try r.bytes(64, "signature")) }
        guard r.atEnd else { throw SolanaWireError.invalid("extra bytes after the signatures") }
        let m = SolanaWireMessage(version: .v1, numRequiredSignatures: h0, numReadonlySigned: h1, numReadonlyUnsigned: h2,
                                  staticKeys: keys, recentBlockhash: blockhash, instructions: ixs, lookups: [], config: cfg,
                                  bytes: Array(raw[..<messageEnd]))
        try m.validate()
        return SolanaWireTransaction(signatures: sigs, message: m)
    }

    public var serialized: [UInt8] {
        message.version == .v1 ? message.bytes + signatures.flatMap { $0 }
            : shortvec(signatures.count) + signatures.flatMap { $0 } + message.bytes
    }
    /// The transaction id: the fee payer's signature.
    public var id: String { Base58.encode(signatures[0]) }
}

/// Address lookup table account data: a 56-byte header (type 1), then 32-byte addresses.
public enum SolanaLookupTable {
    public static func addresses(_ data: [UInt8]) throws -> [SolanaPublicKey] {
        guard data.count >= 56, data[0] == 1, data[1...3].allSatisfy({ $0 == 0 }), (data.count - 56) % 32 == 0 else {
            throw SolanaWireError.invalid("not an address lookup table")
        }
        return stride(from: 56, to: data.count, by: 32).map { SolanaPublicKey(bytes: Array(data[$0..<$0 + 32])) }
    }

    /// The message's full account list: static keys, then every table's writable picks, then every table's read-only picks.
    public static func resolve(_ m: SolanaWireMessage, tables: [SolanaPublicKey: [SolanaPublicKey]]) throws -> [SolanaPublicKey] {
        var w: [SolanaPublicKey] = [], ro: [SolanaPublicKey] = []
        for l in m.lookups {
            guard let t = tables[l.table] else { throw SolanaWireError.invalid("lookup table \(l.table) not found") }
            for i in l.writable { guard Int(i) < t.count else { throw SolanaWireError.invalid("lookup index out of range") }; w.append(t[Int(i)]) }
            for i in l.readonly { guard Int(i) < t.count else { throw SolanaWireError.invalid("lookup index out of range") }; ro.append(t[Int(i)]) }
        }
        return m.staticKeys + w + ro
    }
}

extension SolanaClient {
    /// Fetches the lookup tables a v0 message uses, in one call.
    public func lookupTables(for m: SolanaWireMessage) async throws -> [SolanaPublicKey: [SolanaPublicKey]] {
        let keys = Array(Set(m.lookups.map(\.table)))
        guard !keys.isEmpty else { return [:] }
        let r = try await rpc.call("getMultipleAccounts", [.array(keys.map { .string($0.description) }), ["encoding": "base64", "commitment": "confirmed"]])
        var out: [SolanaPublicKey: [SolanaPublicKey]] = [:]
        for (k, a) in zip(keys, r["value"]?.array ?? []) {
            guard a["owner"]?.string == "AddressLookupTab1e1111111111111111111111111",
                  let b64 = a["data"]?[0]?.string, let d = Data(base64Encoded: b64) else {
                throw SolanaWireError.invalid("lookup table \(k) not found")
            }
            out[k] = try SolanaLookupTable.addresses([UInt8](d))
        }
        return out
    }
}
