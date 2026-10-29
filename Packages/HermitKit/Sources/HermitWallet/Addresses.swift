import Foundation

// MARK: - EVM addresses

public struct EVMAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count == 42, t.hasPrefix("0x"), let b = [UInt8](hex: t), b.count == 20 else { return nil }
        let body = t.dropFirst(2)
        // Mixed case means the sender used an EIP-55 checksum: it has to be right.
        if body != body.lowercased() && body != body.uppercased() && EVMAddress.checksum(b) != t { return nil }
        bytes = b
    }
    public init(bytes: [UInt8]) { precondition(bytes.count == 20); self.bytes = bytes }

    /// From a 65-byte uncompressed public key.
    public init(publicKey: [UInt8]) {
        precondition(publicKey.count == 65)
        bytes = Array(Hash.keccak256(Array(publicKey[1...]))[12...])
    }

    /// EIP-55 mixed-case checksum.
    public var checksummed: String { EVMAddress.checksum(bytes) }
    public var description: String { checksummed }

    static func checksum(_ b: [UInt8]) -> String {
        let lower = b.hex
        let h = Hash.keccak256(Array(lower.utf8))
        var out = "0x"
        for (i, c) in lower.enumerated() {
            let nibble = (h[i / 2] >> (i % 2 == 0 ? 4 : 0)) & 0xF
            out.append(nibble >= 8 ? Character(c.uppercased()) : c)
        }
        return out
    }
}

// MARK: - Base58 (Bitcoin alphabet, used by Solana)

public enum Base58 {
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    static let map: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    public static func encode(_ bytes: [UInt8]) -> String {
        let zeros = bytes.prefix(while: { $0 == 0 }).count
        var digits = [UInt8]() // base-58 digits, little-endian
        for b in bytes {
            var carry = Int(b)
            for j in 0..<digits.count {
                carry += Int(digits[j]) << 8
                digits[j] = UInt8(carry % 58); carry /= 58
            }
            while carry > 0 { digits.append(UInt8(carry % 58)); carry /= 58 }
        }
        return String(repeating: "1", count: zeros) + String(decoding: digits.reversed().map { alphabet[Int($0)] }, as: UTF8.self)
    }

    public static func decode(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        let zeros = chars.prefix(while: { $0 == UInt8(ascii: "1") }).count
        var bytes = [UInt8]() // little-endian
        for c in chars {
            guard var carry = map[c] else { return nil }
            for j in 0..<bytes.count {
                carry += Int(bytes[j]) * 58
                bytes[j] = UInt8(carry & 0xFF); carry >>= 8
            }
            while carry > 0 { bytes.append(UInt8(carry & 0xFF)); carry >>= 8 }
        }
        return [UInt8](repeating: 0, count: zeros) + bytes.reversed()
    }
}

// MARK: - Solana public keys

public struct SolanaPublicKey: Hashable, Sendable, CustomStringConvertible, Comparable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) { precondition(bytes.count == 32); self.bytes = bytes }
    public init?(_ base58: String) {
        guard let b = Base58.decode(base58.trimmingCharacters(in: .whitespaces)), b.count == 32 else { return nil }
        bytes = b
    }
    public var description: String { Base58.encode(bytes) }
    public var isOnCurve: Bool { Ed25519Curve.isOnCurve(bytes) }
    public static func < (a: Self, b: Self) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }

    public static let systemProgram = SolanaPublicKey("11111111111111111111111111111111")!
    public static let tokenProgram = SolanaPublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")!
    public static let associatedTokenProgram = SolanaPublicKey("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")!
    public static let computeBudgetProgram = SolanaPublicKey("ComputeBudget111111111111111111111111111111")!

    /// Program-derived address: the first bump (255 down) whose hash is off the ed25519 curve.
    public static func findProgramAddress(seeds: [[UInt8]], program: SolanaPublicKey) -> (SolanaPublicKey, UInt8)? {
        for bump in stride(from: 255, through: 0, by: -1) {
            var data = seeds.flatMap { $0 }
            data.append(UInt8(bump))
            data += program.bytes + Array("ProgramDerivedAddress".utf8)
            let h = Hash.sha256(data)
            if !Ed25519Curve.isOnCurve(h) { return (SolanaPublicKey(bytes: h), UInt8(bump)) }
        }
        return nil
    }

    /// The owner's associated token account for a mint (classic SPL Token program).
    public static func associatedTokenAccount(owner: SolanaPublicKey, mint: SolanaPublicKey,
                                              tokenProgram: SolanaPublicKey = .tokenProgram) -> SolanaPublicKey {
        findProgramAddress(seeds: [owner.bytes, tokenProgram.bytes, mint.bytes], program: .associatedTokenProgram)!.0
    }
}
