import Foundation
import CryptoKit
import CommonCrypto
import CryptoSwift
import libsecp256k1

// MARK: - Hashes

public enum Hash {
    /// Ethereum's Keccak-256 (the original Keccak padding, not NIST SHA3-256). Uses CryptoSwift.
    public static func keccak256(_ data: [UInt8]) -> [UInt8] {
        SHA3(variant: .keccak256).calculate(for: data)
    }
    public static func sha256(_ data: [UInt8]) -> [UInt8] { [UInt8](CryptoKit.SHA256.hash(data: data)) }
    static func hmacSHA512(key: [UInt8], data: [UInt8]) -> [UInt8] {
        [UInt8](HMAC<CryptoKit.SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    static func pbkdf2SHA512(password: [UInt8], salt: [UInt8], rounds: UInt32, length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let rc = password.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: Int8.self) { pwc in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwc.baseAddress, password.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, &out, length)
            }
        }
        precondition(rc == kCCSuccess, "PBKDF2 failed")
        return out
    }
}

// MARK: - secp256k1 (bitcoin-core/libsecp256k1 through 21-DOT-DEV/swift-secp256k1)

public enum Secp256k1 {
    /// One signing context, randomised once against side channels. libsecp256k1 contexts are safe to share
    /// for signing once created and randomised.
    nonisolated(unsafe) private static let ctx: OpaquePointer = {
        let c = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE))!
        var seed = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &seed)
        _ = secp256k1_context_randomize(c, seed)
        seed.wipe()
        return c
    }()

    static func isValidPrivateKey(_ key: [UInt8]) -> Bool {
        key.count == 32 && secp256k1_ec_seckey_verify(ctx, key) == 1
    }

    /// Public key, 33 bytes compressed or 65 bytes uncompressed (0x04 prefix).
    static func publicKey(of key: [UInt8], compressed: Bool) throws -> [UInt8] {
        var pub = secp256k1_pubkey()
        guard key.count == 32, secp256k1_ec_pubkey_create(ctx, &pub, key) == 1 else { throw WalletError.invalidKey }
        var len = compressed ? 33 : 65
        var out = [UInt8](repeating: 0, count: len)
        let flags = UInt32(compressed ? SECP256K1_EC_COMPRESSED : SECP256K1_EC_UNCOMPRESSED)
        guard secp256k1_ec_pubkey_serialize(ctx, &out, &len, &pub, flags) == 1 else { throw WalletError.invalidKey }
        return out
    }

    /// (key + tweak) mod n, as BIP-32 child derivation needs.
    static func tweakAdd(_ key: [UInt8], _ tweak: [UInt8]) throws -> [UInt8] {
        var k = key
        guard secp256k1_ec_seckey_tweak_add(ctx, &k, tweak) == 1 else { k.wipe(); throw WalletError.invalidKey }
        return k
    }

    /// Recoverable ECDSA over a 32-byte digest with RFC 6979 nonces and low-S. Returns (r||s, recovery id).
    static func sign(digest: [UInt8], key: [UInt8]) throws -> (rs: [UInt8], recid: Int32) {
        precondition(digest.count == 32)
        var sig = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_sign_recoverable(ctx, &sig, digest, key, nil, nil) == 1 else { throw WalletError.invalidKey }
        var out = [UInt8](repeating: 0, count: 64); var recid: Int32 = 0
        _ = secp256k1_ecdsa_recoverable_signature_serialize_compact(ctx, &out, &recid, &sig)
        return (out, recid)
    }

    /// Recovers the uncompressed public key (65 bytes) that produced a signature. Used to verify what we built.
    public static func recover(digest: [UInt8], rs: [UInt8], recid: Int32) -> [UInt8]? {
        guard digest.count == 32, rs.count == 64, (0...3).contains(recid) else { return nil }
        var sig = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &sig, rs, recid) == 1 else { return nil }
        var pub = secp256k1_pubkey()
        guard secp256k1_ecdsa_recover(ctx, &pub, &sig, digest) == 1 else { return nil }
        var len = 65; var out = [UInt8](repeating: 0, count: 65)
        _ = secp256k1_ec_pubkey_serialize(ctx, &out, &len, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED))
        return out
    }
}

// MARK: - BIP-39

public enum Mnemonic {
    public static let wordlist: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { fatalError("BIP-39 wordlist missing") }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        precondition(words.count == 2048)
        return words
    }()
    private static let index: [String: Int] = Dictionary(uniqueKeysWithValues: wordlist.enumerated().map { ($1, $0) })

    /// Fresh entropy from the system CSPRNG. 16 bytes = 12 words, 32 bytes = 24 words.
    static func randomEntropy(words: Int) throws -> [UInt8] {
        guard [12, 15, 18, 21, 24].contains(words) else { throw WalletError.invalidMnemonic }
        var e = [UInt8](repeating: 0, count: words / 3 * 4)
        guard SecRandomCopyBytes(kSecRandomDefault, e.count, &e) == errSecSuccess else { throw WalletError.vault("No randomness available.") }
        return e
    }

    public static func phrase(fromEntropy e: [UInt8]) throws -> String {
        var b = try phraseUTF8(fromEntropy: e)
        defer { b.wipe() }
        return String(decoding: b, as: UTF8.self)
    }

    /// The phrase as UTF-8 bytes, so signing can derive the seed without making an unwipeable String.
    static func phraseUTF8(fromEntropy e: [UInt8]) throws -> [UInt8] {
        guard [16, 20, 24, 28, 32].contains(e.count) else { throw WalletError.invalidMnemonic }
        let csBits = e.count / 4
        var bits = [Bool](); bits.reserveCapacity(e.count * 8 + csBits)
        for b in e { for i in (0..<8).reversed() { bits.append((b >> i) & 1 == 1) } }
        let h = Hash.sha256(e)
        for i in 0..<csBits { bits.append((h[i / 8] >> (7 - i % 8)) & 1 == 1) }
        var out = [UInt8](); out.reserveCapacity(bits.count)
        for c in stride(from: 0, to: bits.count, by: 11) {
            var v = 0
            for i in 0..<11 { v = v << 1 | (bits[c + i] ? 1 : 0) }
            if !out.isEmpty { out.append(0x20) }
            out += wordlist[v].utf8
        }
        for i in bits.indices { bits[i] = false }
        return out
    }

    /// BIP-39 seed from phrase bytes (the English wordlist is ASCII, so no normalisation is needed).
    static func seed(phraseUTF8: [UInt8], passphrase: String = "") -> [UInt8] {
        let salt = Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        return Hash.pbkdf2SHA512(password: phraseUTF8, salt: salt, rounds: 2048, length: 64)
    }

    /// Validates the words and checksum and returns the entropy.
    public static func entropy(fromPhrase phrase: String) throws -> [UInt8] {
        let words = normalize(phrase).split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(words.count) else { throw WalletError.invalidMnemonic }
        var bits = [Bool]()
        for w in words {
            guard let v = index[w] else { throw WalletError.invalidMnemonic }
            for i in (0..<11).reversed() { bits.append((v >> i) & 1 == 1) }
        }
        let csBits = words.count / 3
        let entBits = bits.count - csBits
        var e = [UInt8](repeating: 0, count: entBits / 8)
        for i in 0..<entBits where bits[i] { e[i / 8] |= 1 << (7 - i % 8) }
        let h = Hash.sha256(e)
        for i in 0..<csBits where bits[entBits + i] != ((h[i / 8] >> (7 - i % 8)) & 1 == 1) {
            e.wipe(); throw WalletError.invalidMnemonic
        }
        return e
    }

    public static func isValid(_ phrase: String) -> Bool {
        guard var e = try? entropy(fromPhrase: phrase) else { return false }
        e.wipe(); return true
    }

    /// The 64-byte BIP-39 seed: PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic" + passphrase (NFKD).
    public static func seed(phrase: String, passphrase: String = "") -> [UInt8] {
        var pw = Array(normalize(phrase).utf8)
        defer { pw.wipe() }
        let salt = Array(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)
        return Hash.pbkdf2SHA512(password: pw, salt: salt, rounds: 2048, length: 64)
    }

    static func normalize(_ s: String) -> String {
        s.decomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - HD derivation

public enum HD {
    public static let hardened: UInt32 = 0x8000_0000

    /// BIP-32 secp256k1 private key derivation. Path like "m/44'/60'/0'/0/0".
    public static func secp256k1Key(seed: [UInt8], path: String) throws -> [UInt8] {
        var I = Hash.hmacSHA512(key: Array("Bitcoin seed".utf8), data: seed)
        var key = Array(I[0..<32]), chain = Array(I[32..<64])
        I.wipe()
        guard Secp256k1.isValidPrivateKey(key) else { throw WalletError.invalidKey }
        for index in try parse(path) {
            var data: [UInt8]
            if index >= hardened { data = [0] + key } else { data = try Secp256k1.publicKey(of: key, compressed: true) }
            data += index.bigEndianBytes(width: 4)
            var J = Hash.hmacSHA512(key: chain, data: data)
            data.wipe()
            let il = Array(J[0..<32])
            // tweakAdd fails when IL >= n or the result is zero; BIP-32 says skip to the next index (probability ~2^-127).
            let child = try Secp256k1.tweakAdd(key, il)
            key.wipe(); key = child
            chain.wipe(); chain = Array(J[32..<64]); J.wipe()
        }
        chain.wipe()
        return key
    }

    /// SLIP-10 ed25519 derivation (hardened only), as Phantom and Solflare use for m/44'/501'/0'/0'.
    public static func ed25519Seed(seed: [UInt8], path: String) throws -> [UInt8] {
        var I = Hash.hmacSHA512(key: Array("ed25519 seed".utf8), data: seed)
        var key = Array(I[0..<32]), chain = Array(I[32..<64])
        I.wipe()
        for index in try parse(path) {
            guard index >= hardened else { throw WalletError.invalidKey }
            var data = [0] + key + index.bigEndianBytes(width: 4)
            var J = Hash.hmacSHA512(key: chain, data: data)
            data.wipe(); key.wipe(); chain.wipe()
            key = Array(J[0..<32]); chain = Array(J[32..<64]); J.wipe()
        }
        chain.wipe()
        return key
    }

    static func parse(_ path: String) throws -> [UInt32] {
        var parts = path.split(separator: "/")
        guard parts.first == "m" else { throw WalletError.invalidKey }
        parts.removeFirst()
        return try parts.map { p in
            let h = p.hasSuffix("'") || p.hasSuffix("h")
            guard let n = UInt32(h ? p.dropLast() : p), n < hardened else { throw WalletError.invalidKey }
            return h ? n | hardened : n
        }
    }
}
