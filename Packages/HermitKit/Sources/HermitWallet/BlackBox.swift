import Foundation
import CryptoKit
import HermitCore

/// Hermit Black Box, our contract on NEAR mainnet: `hermit-blackbox.near` (contracts/blackbox).
///
/// - Model registry: each Hermit model's weights hash and pin digest, append-only. `checkModel` asks the chain whether
///   the model this app pins is the one we published.
/// - Flight recorder: after you approve a move the assistant prepared, a SHA-256 fingerprint of the decision (what the
///   review showed, what happened, a salt from this device) is written on chain by a function-call key that can only
///   call `record`. The chat, amounts and addresses never leave the device; the text behind each fingerprint is kept
///   here (`BlackBox.log`) so it can be checked against the chain later.
public enum BlackBox {
    public static let contract = "hermit-blackbox.near"
    public static let explorer = URL(string: "https://nearblocks.io/address/hermit-blackbox.near")!
    /// Gas allowance on the recorder key: about 200 records at 2 Tgas each.
    public static let allowance: UInt128 = 50_000_000_000_000_000_000_000   // 0.05 NEAR
    static let recordGas: UInt64 = 3_000_000_000_000   // a record burns about 2 Tgas; the allowance is charged for what is reserved
    static let keyName = "blackbox.recorder"

    // ---------- model registry ----------

    /// SHA-256 over one line per pinned file, sorted by path: "path\tsize\tsha256\n". Same as near/blackbox.py.
    public static func pinDigest(files: [(path: String, size: Int64, sha256: String)]) -> String {
        let text = files.sorted { $0.path < $1.path }.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// true: published and matching; false: missing, revoked or different; nil: couldn't reach NEAR.
    public static func checkModel(id: String, weightsSHA256: String, pinDigest: String, client: NearClient = NearClient()) async -> Bool? {
        let args = #"{"id":"\#(id)","weights_sha256":"\#(weightsSHA256)","pin_digest":"\#(pinDigest)"}"#
        guard let r = try? await client.view(contract, "check_model", args: Array(args.utf8)) else { return nil }
        return r.bool ?? false
    }

    // ---------- flight recorder ----------

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { fp }
        public let fp: String
        public let kind: String
        /// The exact bytes that were hashed (canonical JSON, salt included).
        public let preimage: String
        public var tx: String?
        public let date: Date
    }

    struct RecorderKey { let account: String; let seed: [UInt8]; let publicKey: [UInt8] }

    static var recorder: RecorderKey? {
        guard let s = Secrets.get(keyName) else { return nil }
        let p = s.split(separator: " ").map(String.init)
        guard p.count == 2, let seed = [UInt8](hex: p[1]), seed.count == 32,
              let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        return RecorderKey(account: p[0], seed: seed, publicKey: [UInt8](k.publicKey.rawRepresentation))
    }

    public static var isOn: Bool { recorder != nil }
    /// Posted when the recorder is turned on or off, so screens showing AI insurance (which needs it) refresh.
    public static let changed = Notification.Name("hermit.blackbox.changed")
    public static var account: String? { recorder?.account }

    /// The fingerprint and the canonical text behind it.
    public static func fingerprint(kind: String, title: String, lines: [[String]], checks: [String], warnings: [String],
                                   result: String, tx: String?, model: String?, at date: Date = Date(),
                                   salt: String = randomHex(16)) -> (fp: String, preimage: String) {
        let obj: [String: Any] = ["v": 1, "kind": kind, "title": title, "lines": lines, "checks": checks, "warnings": warnings,
                                  "result": result, "tx": tx ?? "", "model": model ?? "",
                                  "at": ISO8601DateFormatter().string(from: date), "salt": salt]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return (hex(SHA256.hash(data: data)), String(decoding: data, as: UTF8.self))
    }

    /// "Swap" -> "swap", "Perp order" -> "perp_order": what the contract accepts as `kind`.
    public static func kindSlug(_ s: String) -> String {
        let t = s.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" }
        let out = String(String(t).prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return out.isEmpty ? "move" : out
    }

    /// Writes the fingerprint on chain with the recorder key. Returns the transaction hash, nil when off or it failed.
    public static func record(fp: String, kind: String, model: String?, client: NearClient = NearClient()) async -> String? {
        guard let k = recorder else { return nil }
        var args = #"{"fp":"\#(fp)","kind":"\#(kindSlug(kind))""#
        if let model, model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./:".contains($0)) }), model.count <= 96 {
            args += #","model":"\#(model)""#
        }
        args += "}"
        do {
            async let n = client.accessKeyNonce(account: k.account, publicKey: NearAccount.publicKeyString(k.publicKey))
            async let b = client.latestBlockHash()
            let tx = NearTransaction(signer: k.account, publicKey: k.publicKey, nonce: try await n + 1, receiver: contract,
                                     blockHash: try await b, actions: [.functionCall(method: "record", args: Array(args.utf8), gas: recordGas, deposit: 0)])
            let r = try await client.send(try tx.sign(ed25519Seed: k.seed))
            return r.success ? r.hash : nil
        } catch { return nil }
    }

    // ---------- the log on this device ----------

    static let logKey = "hermit.blackbox.log"
    public static var log: [Entry] {
        (UserDefaults.standard.data(forKey: logKey).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
    }
    static let logLock = NSLock()
    public static func save(_ e: Entry) {
        logLock.withLock {
            var all = log.filter { $0.fp != e.fp }
            all.insert(e, at: 0)
            UserDefaults.standard.set(try? JSONEncoder().encode(Array(all.prefix(500))), forKey: logKey)
        }
    }

    /// Fingerprints an approved move, keeps it here, and writes it on chain when the recorder is on.
    public static func note(kind: String, title: String, lines: [[String]], checks: [String], warnings: [String],
                            result: String, tx: String?, model: String?) async {
        guard isOn else { return }
        let (fp, pre) = fingerprint(kind: kind, title: title, lines: lines, checks: checks, warnings: warnings, result: result, tx: tx, model: model)
        var e = Entry(fp: fp, kind: kindSlug(kind), preimage: pre, tx: nil, date: Date())
        save(e)
        e.tx = await record(fp: fp, kind: kind, model: model)
        save(e)
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    public static func randomHex(_ n: Int) -> String { hex((0..<n).map { _ in UInt8.random(in: 0...255) }) }
}

extension WalletService {
    /// Turns the recorder on: adds a function-call key to this wallet's NEAR account that can only call `record` on
    /// hermit-blackbox.near, with a 0.05 NEAR gas allowance. One approval; after that, records need none.
    public func enableBlackBox(walletID: UUID) async throws -> String {
        guard let w = wallets.first(where: { $0.id == walletID }), let from = w.nearAccount,
              let pub = [UInt8](hex: from), pub.count == 32 else { throw WalletError.invalidKey }
        let client = NearClient()
        guard let acct = try await client.account(from), acct.amount > BlackBox.allowance / 5 else {
            throw WalletError.blocked("Your NEAR account needs a little NEAR first, 0.02 is plenty. Each record costs about 0.0002 NEAR in gas.")
        }
        let key = Curve25519.Signing.PrivateKey()
        let newPub = [UInt8](key.publicKey.rawRepresentation)
        async let nonceA = client.accessKeyNonce(account: from, publicKey: NearAccount.publicKeyString(pub))
        async let blockA = client.latestBlockHash()
        let tx = NearTransaction(signer: from, publicKey: pub, nonce: try await nonceA + 1, receiver: from, blockHash: try await blockA,
                                 actions: [.addFunctionCallKey(publicKey: newPub, allowance: BlackBox.allowance, receiver: BlackBox.contract, methods: ["record"])])
        let signed = try await vault.withKey(w.id, kind: .near, reason: "Turn on the black box") { seed in try tx.sign(ed25519Seed: seed) }
        guard signed.verify() else { throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.") }
        let r = try await client.send(signed)
        guard r.success else { throw WalletError.blocked(r.failure ?? "NEAR refused the key.") }
        guard Secrets.set("\(from) \(BlackBox.hex(key.rawRepresentation))", for: BlackBox.keyName) else {
            throw WalletError.blocked("The key was added on NEAR but this device couldn't save it. Try again.")
        }
        NotificationCenter.default.post(name: BlackBox.changed, object: nil)
        return r.hash
    }

    /// Turns the recorder off: removes its key from the NEAR account (one approval) and from this device.
    public func disableBlackBox() async throws {
        guard let k = BlackBox.recorder else { return }
        defer { Secrets.set(nil, for: BlackBox.keyName); NotificationCenter.default.post(name: BlackBox.changed, object: nil) }
        guard let w = wallets.first(where: { $0.nearAccount == k.account }), let pub = [UInt8](hex: k.account) else { return }
        let client = NearClient()
        async let nonceA = client.accessKeyNonce(account: k.account, publicKey: NearAccount.publicKeyString(pub))
        async let blockA = client.latestBlockHash()
        let tx = NearTransaction(signer: k.account, publicKey: pub, nonce: try await nonceA + 1, receiver: k.account,
                                 blockHash: try await blockA, actions: [.deleteKey(publicKey: k.publicKey)])
        let signed = try await vault.withKey(w.id, kind: .near, reason: "Turn off the black box") { seed in try tx.sign(ed25519Seed: seed) }
        _ = try await client.send(signed)
    }
}
