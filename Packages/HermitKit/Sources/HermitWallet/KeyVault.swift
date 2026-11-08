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
    /// m/44'/397'/0' (SLIP-10 ed25519, as near-seed-phrase / MyNearWallet derive it): the NEAR implicit account, 64 hex.
    /// nil for wallets made before NEAR support until the user unlocks once to add it (the public key needs the seed).
    public var nearAccount: String?

    public init(id: UUID, name: String, created: Date, protection: KeyVault.Protection, wordCount: Int, evmAddress: String,
                solanaAddress: String, backedUp: Bool, nearAccount: String? = nil) {
        self.id = id; self.name = name; self.created = created; self.protection = protection; self.wordCount = wordCount
        self.evmAddress = evmAddress; self.solanaAddress = solanaAddress; self.backedUp = backedUp; self.nearAccount = nearAccount
    }

    /// "" for NEAR until the account is set up.
    public func address(on chain: Chain) -> String {
        switch chain.kind { case .evm: evmAddress; case .solana: solanaAddress; case .near: nearAccount ?? "" }
    }
}

/// Where the seed lives. Nothing here ever syncs to iCloud.
///
/// - `.secureEnclave` (`SecureEnclaveFileStore`): the BIP-39 entropy is sealed with AES-GCM under a key agreed (ECDH,
///   then HKDF-SHA256) between a one-off ephemeral P-256 key and a P-256 key that lives in the Secure Enclave. The
///   enclave key is created with `.privateKeyUsage + .userPresence`, so every unlock needs Touch ID / Face ID or the
///   device password, and it only works on this device. Its opaque handle and the sealed seed sit in one file in the
///   app's Application Support folder (the sandbox container on the Mac). No Keychain is involved, so this works in a
///   Developer ID build without a provisioning profile. The enclave can't do secp256k1 or ed25519, hence the wrap.
/// - `.keychain`: no Secure Enclave. On iOS (the simulator) the entropy is a data-protection Keychain item guarded by
///   `.userPresence`. On a Mac without an enclave it is a login-keychain item limited to this app, and the Touch ID /
///   password check before reading it is enforced by the app, not by hardware. Weaker; the label says so.
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
            case .keychain: "Keychain (no Secure Enclave here, weaker)"
            case .memoryOnly: "Memory only (test)"
            }
        }
    }

    public static let evmPath = "m/44'/60'/0'/0/0"
    public static let solanaPath = "m/44'/501'/0'/0'"
    public static let nearPath = "m/44'/397'/0'"

    let store: SealedStore
    private let lock = NSLock()
    private var records: [WalletRecord] = []

    public var protection: Protection { store.protection }

    public init(store: SealedStore) {
        self.store = store
        if let d = store.loadIndex(), let r = try? JSONDecoder().decode([WalletRecord].self, from: d) { records = r }
    }

    /// The vault for this device: the Secure Enclave file store when there is an enclave, otherwise the Keychain.
    public static func makeDefault(service: String = "my.hermit.wallet") -> KeyVault {
        if SecureEnclave.isAvailable, let dir = try? SecureEnclaveFileStore.defaultDirectory() {
            return KeyVault(store: SecureEnclaveFileStore(directory: dir))
        }
        return KeyVault(store: KeychainStore(service: service))
    }

    public var wallets: [WalletRecord] { lock.withLock { records } }

    /// New wallet from fresh system randomness. Returns the record; show the phrase with `exportPhrase`.
    @discardableResult
    public func create(name: String, words: Int = 12) throws -> WalletRecord {
        var e = try Mnemonic.randomEntropy(words: words)
        defer { e.wipe() }
        return try add(entropy: e, name: name, backedUp: false)
    }

    /// New wallet, plus its recovery phrase so it can be shown once for backup without a second unlock.
    /// The caller should drop the words as soon as the backup screen closes.
    public func createWithPhrase(name: String, words: Int = 12) throws -> (record: WalletRecord, phrase: String) {
        var e = try Mnemonic.randomEntropy(words: words)
        defer { e.wipe() }
        let r = try add(entropy: e, name: name, backedUp: false)
        return (r, try Mnemonic.phrase(fromEntropy: e))
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
            var key: [UInt8]
            switch kind {
            case .evm: key = try HD.secp256k1Key(seed: seed, path: Self.evmPath)
            case .solana: key = try HD.ed25519Seed(seed: seed, path: Self.solanaPath)
            case .near: key = try HD.ed25519Seed(seed: seed, path: Self.nearPath)
            }
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
                             wordCount: entropy.count * 3 / 4, evmAddress: evm, solanaAddress: sol, backedUp: backedUp,
                             nearAccount: try Self.nearAccount(seed: seed))
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

    /// The NEAR implicit account for a phrase.
    public static func nearAccount(phrase: String) throws -> String {
        var seed = Mnemonic.seed(phrase: phrase)
        defer { seed.wipe() }
        return try nearAccount(seed: seed)
    }

    static func nearAccount(seed: [UInt8]) throws -> String {
        var s = try HD.ed25519Seed(seed: seed, path: nearPath)
        defer { s.wipe() }
        return NearAccount.implicit(publicKey: [UInt8](try Curve25519.Signing.PrivateKey(rawRepresentation: s).publicKey.rawRepresentation))
    }

    /// Adds the NEAR account to a wallet made before NEAR support: one Face ID unlock to read the public key.
    @discardableResult
    public func addNearAccount(_ id: UUID) async throws -> String {
        let account = try await withKey(id, kind: .near, reason: "Add a NEAR account to this wallet") { key in
            NearAccount.implicit(publicKey: [UInt8](try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation))
        }
        try lock.withLock {
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].nearAccount = account; try saveIndex() }
        }
        return account
    }

    private func saveIndex() throws { try store.saveIndex(try JSONEncoder().encode(records)) }
}

// MARK: - Stores

private func keychainError(_ status: OSStatus, _ what: String) -> WalletError {
    if status == errSecUserCanceled || status == errSecAuthFailed { return .cancelled }
    let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    return .vault("Keychain \(what) failed: \(msg)")
}

/// The seed sealed to a Secure Enclave key and kept as a file. See `KeyVault.Protection.secureEnclave`.
///
/// File `seed-<id>.sealed` (JSON): the enclave key's opaque handle (`dataRepresentation`, useless off this device),
/// the ephemeral public key, and the AES-GCM box (nonce + ciphertext + tag) with the wallet id as associated data.
/// `wallets.json` next to it is the public index (names and addresses only).
public final class SecureEnclaveFileStore: SealedStore, @unchecked Sendable {
    public var protection: KeyVault.Protection { .secureEnclave }
    public let directory: URL
    /// Off only in tests: the enclave key then needs no Touch ID, so sealing and opening can run unattended.
    let requireUserPresence: Bool

    public init(directory: URL, requireUserPresence: Bool = true) {
        self.directory = directory; self.requireUserPresence = requireUserPresence
    }

    /// Application Support/Hermit/Wallet: inside the sandbox container on the Mac, the app's own folder on iOS.
    /// Left out of backups: the sealed seed only opens on this device anyway, and the recovery phrase is the backup.
    public static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = base.appendingPathComponent("Hermit/Wallet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
        return dir
    }

    struct Sealed: Codable {
        var version: Int
        var enclaveKey: Data
        var ephemeralPublicKey: Data
        var box: Data
    }

    func file(_ id: UUID) -> URL { directory.appendingPathComponent("seed-\(id.uuidString).sealed") }
    var indexFile: URL { directory.appendingPathComponent("wallets.json") }

    static func symmetricKey(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey, enclave: P256.KeyAgreement.PublicKey,
                             id: UUID) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral.x963Representation + enclave.x963Representation,
                                       sharedInfo: Data("hermit.wallet.seed.v1:\(id.uuidString)".utf8), outputByteCount: 32)
    }

    public func seal(_ secret: [UInt8], id: UUID) throws {
        let flags: SecAccessControlCreateFlags = requireUserPresence ? [.privateKeyUsage, .userPresence] : [.privateKeyUsage]
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &err) else {
            throw WalletError.vault("Couldn't set up key protection.")
        }
        let enclave: SecureEnclave.P256.KeyAgreement.PrivateKey
        do { enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access) } catch {
            throw WalletError.vault("Secure Enclave key creation failed: \(error.localizedDescription)")
        }
        // Sealing only needs the enclave's public key, so there is no prompt here.
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
        let key = Self.symmetricKey(shared, ephemeral: ephemeral.publicKey, enclave: enclave.publicKey, id: id)
        let box = try AES.GCM.seal(secret, using: key, authenticating: Data(id.uuidString.utf8))
        guard let combined = box.combined else { throw WalletError.vault("Couldn't seal the seed.") }
        let sealed = Sealed(version: 1, enclaveKey: enclave.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                            box: combined)
        try write(try JSONEncoder().encode(sealed), to: file(id))
    }

    public func open(id: UUID, reason: String) async throws -> SecretBytes {
        guard let data = try? Data(contentsOf: file(id)), let s = try? JSONDecoder().decode(Sealed.self, from: data) else {
            throw WalletError.vault("This wallet's key is missing. Restore it from the recovery phrase.")
        }
        let ctx = LAContext()
        if requireUserPresence {
            // Ask once here, then hand the evaluated context to the enclave key so it doesn't ask again.
            do { _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch let e as LAError {
                if [.userCancel, .appCancel, .systemCancel].contains(e.code) { throw WalletError.cancelled }
                throw WalletError.vault("Unlock failed: \(e.localizedDescription)")
            }
        }
        let box = UncheckedBox(ctx)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: s.enclaveKey, authenticationContext: box.value)
                    let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: s.ephemeralPublicKey)
                    let shared = try enclave.sharedSecretFromKeyAgreement(with: ephemeral)
                    let key = Self.symmetricKey(shared, ephemeral: ephemeral, enclave: enclave.publicKey, id: id)
                    let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: s.box), using: key, authenticating: Data(id.uuidString.utf8))
                    var bytes = [UInt8](plain)
                    let secret = SecretBytes(bytes)
                    bytes.wipe()
                    cont.resume(returning: secret)
                } catch {
                    cont.resume(throwing: WalletError.vault("Couldn't unlock this wallet's key. If this device's Secure Enclave was reset, restore the wallet from its recovery phrase."))
                }
            }
        }
    }

    public func remove(id: UUID) throws {
        let f = file(id)
        if FileManager.default.fileExists(atPath: f.path) { try FileManager.default.removeItem(at: f) }
    }

    public func loadIndex() -> Data? { try? Data(contentsOf: indexFile) }
    public func saveIndex(_ data: Data) throws { try write(data, to: indexFile) }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Keychain plumbing for the no-enclave fallback. iOS uses the data-protection keychain. A Mac uses the login keychain,
/// because the data-protection keychain needs a provisioning profile there (errSecMissingEntitlement, -34018).
class KeychainBase: @unchecked Sendable {
    let service: String
    #if os(iOS)
    static let dataProtection = true
    #else
    static let dataProtection = false
    #endif
    init(service: String) { self.service = service }

    func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        if Self.dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    func put(_ data: Data, account: String, access: SecAccessControl? = nil) throws {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var q = baseQuery(account)
        q[kSecValueData as String] = data
        if Self.dataProtection {
            if let access { q[kSecAttrAccessControl as String] = access } else {
                q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw keychainError(st, "save") }
    }

    func get(_ account: String, context: LAContext? = nil) throws -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context, Self.dataProtection { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw keychainError(st, "read") }
        return out as? Data
    }

    func del(_ account: String) { SecItemDelete(baseQuery(account) as CFDictionary) }

    func loadIndex() -> Data? { try? get("index") }
    func saveIndex(_ data: Data) throws { try put(data, account: "index") }
}

/// Fallback with no Secure Enclave: the entropy is a Keychain item, read only after Touch ID / Face ID or the password.
final class KeychainStore: KeychainBase, SealedStore, @unchecked Sendable {
    var protection: KeyVault.Protection { .keychain }

    func seal(_ secret: [UInt8], id: UUID) throws {
        var access: SecAccessControl?
        if Self.dataProtection {
            var err: Unmanaged<CFError>?
            access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &err)
            guard access != nil else { throw WalletError.vault("Couldn't set up key protection.") }
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
