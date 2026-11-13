import Foundation
import CryptoKit

// Signing for NEAR web apps. The key comes from `KeyVault.withKey(.near)` (Face ID / Touch ID), the same ed25519 key and
// CryptoKit signing Hermit's own NEAR sends use. Every signature is verified against the account's public key before
// anything leaves this file. Runs only after the user approved the request on the approval sheet.

extension WalletService {
    /// The wallet's NEAR account and its public key, if `walletID` still has `account`.
    func dappNearKey(_ walletID: UUID, account: String) throws -> (WalletRecord, [UInt8]) {
        guard let w = wallets.first(where: { $0.id == walletID }) else { throw WalletError.vault("That wallet is gone.") }
        guard w.nearAccount == account, let pub = [UInt8](hex: account), pub.count == 32 else {
            throw WalletError.blocked("This wallet's NEAR account changed. Nothing was signed.")
        }
        return (w, pub)
    }

    /// NEP-413 signMessage: an ed25519 signature over sha256(payload), self-checked.
    public func dappNearSignMessage(walletID: UUID, account: String, payload: [UInt8], reason: String) async throws -> [UInt8] {
        let (w, pub) = try dappNearKey(walletID, account: account)
        let digest = Hash.sha256(payload)
        let sig = try await vault.withKey(w.id, kind: .near, reason: reason) { seed -> [UInt8] in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard [UInt8](key.publicKey.rawRepresentation) == pub else { throw WalletError.invalidKey }
            return [UInt8](try key.signature(for: Data(digest)))
        }
        guard let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pub), pk.isValidSignature(Data(sig), for: Data(digest)) else {
            throw WalletError.blocked("The signature failed its self-check. Nothing was returned to the site.")
        }
        return sig
    }

    /// Signs a site's transactions with one Face ID check (consecutive nonces), then sends them one at a time, each only
    /// after the one before it executed. Returns each transaction's FinalExecutionOutcome. `sent` runs for every
    /// transaction that executed successfully (index, hash). Stops at the first failure.
    public func dappNearSend(walletID: UUID, account: String, transactions txs: [NearDapp.Tx], reason: String,
                             sent: @MainActor (Int, String) -> Void = { _, _ in }) async throws -> [JSON] {
        guard allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard !txs.isEmpty else { return [] }
        let (w, pub) = try dappNearKey(walletID, account: account)
        let client = nearClient
        async let nonceA = client.accessKeyNonce(account: account, publicKey: NearAccount.publicKeyString(pub))
        async let blockA = client.latestBlockHash()
        let (nonce, block) = try await (nonceA, blockA)
        let unsigned = txs.enumerated().map { i, t in
            NearTransaction(signer: account, publicKey: pub, nonce: nonce + UInt64(i) + 1, receiver: t.receiver, blockHash: block, actions: t.actions)
        }
        let signed = try await vault.withKey(w.id, kind: .near, reason: reason) { seed in try unsigned.map { try $0.sign(ed25519Seed: seed) } }
        for (u, s) in zip(unsigned, signed) {
            guard s.verify(), s.transaction == u else { throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.") }
        }
        defer { Task { await self.refreshBalances(chains: [.near]) } }
        var outcomes: [JSON] = []
        for (i, tx) in signed.enumerated() {
            let earlier = i == 0 ? "" : " The first \(i) of \(signed.count) transactions went through."
            let outcome: JSON
            do { outcome = try await client.sendOutcome(tx) }
            catch let e as NearClient.RPCError where e.cause != "TIMEOUT_ERROR" {
                throw WalletError.blocked("NEAR refused the transaction: \(e.message)." + earlier)
            } catch {
                // Sent, not confirmed: it may still land. Nothing more is sent.
                throw WalletError.pending(hash: tx.transaction.hashString, explorer: Chain.near.explorerURL(tx: tx.transaction.hashString)?.absoluteString)
            }
            let hash = outcome["transaction"]?["hash"]?.string ?? tx.transaction.hashString
            if let f = outcome["status"]?["Failure"], !f.isNull {
                let raw = (try? String(data: JSONEncoder().encode(f), encoding: .utf8)) ?? "failed"
                throw WalletError.blocked("The NEAR transaction failed (\(hash)): \(NearGuard.failureText(raw))" + earlier)
            }
            sent(i, hash)
            outcomes.append(outcome)
        }
        return outcomes
    }
}
