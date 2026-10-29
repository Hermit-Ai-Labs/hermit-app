import Foundation
@preconcurrency import Security
import LocalAuthentication
import CryptoKit

/// Public facts about a wallet. Safe to show, cache and log. Never holds secrets.
public struct WalletRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let created: Date
    public let protection: KeyVault.Protection
    public let wordCount: Int
    /// m/44'/60'/0'/0/0, EIP-55. The same address on every EVM chain.
    public let evmAddress: String
    /// m/44'/501'/0'/0', base58 (Phantom / Solflare compatible).
    public let solanaAddress: String
    /// Set once the user confirmed they wrote the phrase down.
    public var backedUp: Bool

    public func address(on chain: Chain) -> String { chain.kind == .evm ? evmAddress : solanaAddress }
}

/// Where the seed lives. Keychain items are device-only and never sync to iCloud.
///
/// - `.secureEnclave`: the BIP-39 entropy is encrypted (ECIES, X9.63-SHA256 + AES-GCM) to a P-256 key that lives in
///   the Secure Enclave. Decrypting needs Touch ID / Face ID (`.biometryCurrentSet`) or, on Macs without a sensor,
///   the device password (`.userPresence`). The enclave can't do secp256k1 or ed25519 itself, hence the wrap.
/// - `.keychain`: no Secure Enclave (the iOS simulator, some CI Macs): the entropy is a Keychain item guarded by
///   `.userPresence`. Weaker; shown to the user.
/// - `.memoryOnly`: tests only. Nothing touches disk.
public protocol SealedStore: Sendable {
    var protection: KeyVault.Protection { get }
    func seal(_ secret: [UInt8], id: UUID) throws
    func open(id: UUID, reason: String) async throws -> SecretBytes
    func remove(id: UUID) throws
    func loadIndex() -> Data?
    func saveIndex(_ data: Data) throws
}

public final class KeyVault: @unchecked Sendable {
    public enum Protection: String, Codable, Sendable {
        case secureEnclave, keychain, memoryOnly
        public var label: String {
            switch self {
            case .secureEnclave: "Secure Enclave"
            case .keychain: "Keychain (no Secure Enclave on this device)"
            case .memoryOnly: "Memory only (test)"
            }
        }
    }

    public static let evmPath = "m/44'/60'/0'/0/0"
    public static let solanaPath = "m/44'/501'/0'/0'"

    let store: SealedStore
    private let lock = NSLock()
    private var records: [WalletRecord] = []

    public var protection: Protection { store.protection }

    public init(store: SealedStore) {
        self.store = store
        if let d = store.loadIndex(), let r = try? JSONDecoder().decode([WalletRecord].self, from: d) { records = r }
    }

    /// The vault for this device: Secure Enclave when there is one, otherwise the Keychain.
    public static func makeDefault(service: String = "my.hermit.wallet") -> KeyVault {
        KeyVault(store: SecureEnclave.isAvailable ? SecureEnclaveStore(service: service) as SealedStore : KeychainStore(service: service))
    }

    public var wallets: [WalletRecord] { lock.withLock { records } }

    /// New wallet from fresh system randomness. Returns the record; show the phrase with `exportPhrase`.
    @discardableResult
    public func create(name: String, words: Int = 12) throws -> WalletRecord {
        var e = try Mnemonic.randomEntropy(words: words)
        defer { e.wipe() }
        return try add(entropy: e, name: name, backedUp: false)
    }

    @discardableResult
    public func importPhrase(_ phrase: String, name: String) throws -> WalletRecord {
        var e = try Mnemonic.entropy(fromPhrase: phrase)
        defer { e.wipe() }
        return try add(entropy: e, name: name, backedUp: true)
    }

    /// Shows the recovery phrase after Touch ID / Face ID. The caller should not keep the string around.
    public func exportPhrase(_ id: UUID, reason: String = "Show your recovery phrase") async throws -> String {
        let e = try await store.open(id: id, reason: reason)
        return try e.withBytes { try Mnemonic.phrase(fromEntropy: $0) }
    }

    public func delete(_ id: UUID) throws {
        try store.remove(id: id)
        try lock.withLock { records.removeAll { $0.id == id }; try saveIndex() }
    }

    public func rename(_ id: UUID, to name: String) throws {
        try lock.withLock {
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].name = name; try saveIndex() }
        }
    }

    public func markBackedUp(_ id: UUID) throws {
        try lock.withLock {
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].backedUp = true; try saveIndex() }
        }
    }

    /// Unlocks with biometrics, derives the key for `kind`, hands it to `body`, then wipes everything.
    /// The key never leaves this call.
    public func withKey<T>(_ id: UUID, kind: ChainKind, reason: String, _ body: ([UInt8]) throws -> T) async throws -> T {
        let e = try await store.open(id: id, reason: reason)
        return try e.withBytes { entropy in
            var phrase = try Mnemonic.phraseUTF8(fromEntropy: entropy)
            var seed = Mnemonic.seed(phraseUTF8: phrase)
            phrase.wipe()
            defer { seed.wipe() }
            var key = kind == .evm ? try HD.secp256k1Key(seed: seed, path: Self.evmPath) : try HD.ed25519Seed(seed: seed, path: Self.solanaPath)
            defer { key.wipe() }
            return try body(key)
        }
    }

    // MARK: -

    private func add(entropy: [UInt8], name: String, backedUp: Bool) throws -> WalletRecord {
        var phrase = try Mnemonic.phraseUTF8(fromEntropy: entropy)
        var seed = Mnemonic.seed(phraseUTF8: phrase)
        phrase.wipe()
        defer { seed.wipe() }
        let (evm, sol) = try Self.addresses(seed: seed)
        if let existing = wallets.first(where: { $0.evmAddress == evm }) {
            throw WalletError.vault("This wallet is already here as \u{201C}\(existing.name)\u{201D}.")
        }
        let r = WalletRecord(id: UUID(), name: name, created: Date(), protection: store.protection,
                             wordCount: entropy.count * 3 / 4, evmAddress: evm, solanaAddress: sol, backedUp: backedUp)
        try store.seal(entropy, id: r.id)
        try lock.withLock { records.append(r); try saveIndex() }
        return r
    }

    /// EVM and Solana addresses for a phrase (used at create/import time, and by tests).
    public static func addresses(phrase: String) throws -> (evm: String, solana: String) {
        var seed = Mnemonic.seed(phrase: phrase)
        defer { seed.wipe() }
        return try addresses(seed: seed)
    }

    static func addresses(seed: [UInt8]) throws -> (evm: String, solana: String) {
        var k = try HD.secp256k1Key(seed: seed, path: evmPath)
        let evm = EVMAddress(publicKey: try Secp256k1.publicKey(of: k, compressed: false)).checksummed
        k.wipe()
        var s = try HD.ed25519Seed(seed: seed, path: solanaPath)
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: s).publicKey.rawRepresentation
        s.wipe()
        return (evm, Base58.encode([UInt8](pub)))
    }

    private func saveIndex() throws { try store.saveIndex(try JSONEncoder().encode(records)) }
}

// MARK: - Stores

private func keychainError(_ status: OSStatus, _ what: String) -> WalletError {
    if status == errSecUserCanceled || status == errSecAuthFailed { return .cancelled }
    let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    return .vault("Keychain \(what) failed: \(msg)")
}

/// Shared Keychain plumbing: device-only generic passwords in the data-protection keychain.
class KeychainBase: @unchecked Sendable {
    let service: String
    init(service: String) { self.service = service }

    func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }

    func put(_ data: Data, account: String, access: SecAccessControl? = nil) throws {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        if let access { q[kSecAttrAccessControl as String] = access } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw keychainError(st, "save") }
    }

    func get(_ account: String, context: LAContext? = nil) throws -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw keychainError(st, "read") }
        return out as? Data
    }

    func del(_ account: String) { SecItemDelete(baseQuery(account) as CFDictionary) }

    func loadIndex() -> Data? { try? get("index") }
    func saveIndex(_ data: Data) throws { try put(data, account: "index") }

    /// Biometry if enrolled, otherwise the device password.
    static func accessFlags() -> SecAccessControlCreateFlags {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) ? .biometryCurrentSet : .userPresence
    }
}

/// Seed wrapped by a Secure Enclave P-256 key.
final class SecureEnclaveStore: KeychainBase, SealedStore, @unchecked Sendable {
    var protection: KeyVault.Protection { .secureEnclave }
    static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    func tag(_ id: UUID) -> Data { Data("\(service).se.\(id.uuidString)".utf8) }

    func seal(_ secret: [UInt8], id: UUID) throws {
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, Self.accessFlags()], &err) else {
            throw WalletError.vault("Couldn't set up key protection.")
        }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag(id),
                                            kSecAttrAccessControl as String: access],
        ]
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err), let pub = SecKeyCopyPublicKey(priv) else {
            throw WalletError.vault("Secure Enclave key creation failed: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        // Encrypting only needs the public key: no prompt.
        guard let box = SecKeyCreateEncryptedData(pub, Self.algorithm, Data(secret) as CFData, &err) as Data? else {
            removeKey(id); throw WalletError.vault("Couldn't encrypt the seed.")
        }
        do { try put(box, account: "seed.\(id.uuidString)") } catch { removeKey(id); throw error }
    }

    func open(id: UUID, reason: String) async throws -> SecretBytes {
        guard let box = try get("seed.\(id.uuidString)") else { throw WalletError.vault("This wallet's key is missing.") }
        let ctx = LAContext()
        ctx.localizedReason = reason
        ctx.touchIDAuthenticationAllowableReuseDuration = 0
        let q: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag(id),
                                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true,
                                kSecUseAuthenticationContext as String: ctx]
        var ref: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &ref)
        guard st == errSecSuccess, let r = ref else {
            if st == errSecItemNotFound { throw WalletError.vault("This wallet's Secure Enclave key is gone (biometrics changed?). Restore it from the recovery phrase.") }
            throw keychainError(st, "key lookup")
        }
        let priv = UncheckedBox(r as! SecKey) // swiftlint:disable:this force_cast
        // Decrypting is where Touch ID / Face ID is asked. It blocks, so run it off the main thread.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: Unmanaged<CFError>?
                guard let plain = SecKeyCreateDecryptedData(priv.value, Self.algorithm, box as CFData, &err) as Data? else {
                    let e = err?.takeRetainedValue()
                    let code = e.map { CFErrorGetCode($0) } ?? 0
                    cont.resume(throwing: code == LAError.userCancel.rawValue || code == LAError.appCancel.rawValue || code == LAError.systemCancel.rawValue
                                ? WalletError.cancelled : WalletError.vault("Unlock failed."))
                    return
                }
                var bytes = [UInt8](plain)
                let secret = SecretBytes(bytes)
                bytes.wipe()
                // `plain` is an immutable Data we can't wipe in place; it's released here.
                cont.resume(returning: secret)
            }
        }
    }

    func removeKey(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag(id)] as CFDictionary)
    }

    func remove(id: UUID) throws { del("seed.\(id.uuidString)"); removeKey(id) }
}

/// Fallback with no Secure Enclave: the entropy is a Keychain item that needs user presence to read.
final class KeychainStore: KeychainBase, SealedStore, @unchecked Sendable {
    var protection: KeyVault.Protection { .keychain }

    func seal(_ secret: [UInt8], id: UUID) throws {
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, Self.accessFlags(), &err) else {
            throw WalletError.vault("Couldn't set up key protection.")
        }
        try put(Data(secret), account: "seed.\(id.uuidString)", access: access)
    }

    func open(id: UUID, reason: String) async throws -> SecretBytes {
        let ctx = LAContext()
        do { try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch {
            throw WalletError.cancelled
        }
        let ctxBox = UncheckedBox(ctx)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let d = try self.get("seed.\(id.uuidString)", context: ctxBox.value) else {
                        throw WalletError.vault("This wallet's key is missing.")
                    }
                    var b = [UInt8](d); let s = SecretBytes(b); b.wipe()
                    cont.resume(returning: s)
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    func remove(id: UUID) throws { del("seed.\(id.uuidString)") }
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

/// Tests only. Holds secrets in memory, no biometrics.
public final class MemoryStore: SealedStore, @unchecked Sendable {
    public var protection: KeyVault.Protection { .memoryOnly }
    private var secrets: [UUID: SecretBytes] = [:]
    private var index: Data?
    private let lock = NSLock()
    public init() {}
    public func seal(_ secret: [UInt8], id: UUID) throws { lock.withLock { secrets[id] = SecretBytes(secret) } }
    public func open(id: UUID, reason: String) async throws -> SecretBytes {
        guard let s = lock.withLock({ secrets[id] }) else { throw WalletError.vault("missing") }
        return s
    }
    public func remove(id: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: id) } }
    public func loadIndex() -> Data? { lock.withLock { index } }
    public func saveIndex(_ data: Data) throws { lock.withLock { index = data } }
}
