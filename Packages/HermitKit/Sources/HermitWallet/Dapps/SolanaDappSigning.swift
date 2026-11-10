import Foundation
import CryptoKit

// Signing for Solana web apps. The key comes from `KeyVault.withKey(.solana)` (Face ID / Touch ID), the same SLIP-10
// ed25519 key and CryptoKit signing that Hermit's own Solana sends use. Only the wallet's own signature slot is filled,
// and every signature is verified against the wallet's public key before it leaves this file.

extension WalletService {
    /// The wallet's signer slot in a message, or why it can't sign.
    public nonisolated static func signerSlot(_ m: SolanaWireMessage, wallet: SolanaPublicKey) throws -> Int {
        guard let i = m.staticKeys.firstIndex(of: wallet) else {
            throw WalletError.blocked("This transaction doesn't involve your wallet, so Hermit won't sign it.")
        }
        guard i < m.numRequiredSignatures else {
            throw WalletError.blocked("This transaction uses your wallet but doesn't ask for its signature. Hermit won't sign it.")
        }
        return i
    }

    /// Signs the message bytes as received (never re-encoded) in the wallet's slot and returns the updated transaction.
    public func dappSolanaSign(walletID: UUID, _ tx: SolanaWireTransaction, reason: String) async throws -> SolanaWireTransaction {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = SolanaPublicKey(w.solanaAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let slot = try Self.signerSlot(tx.message, wallet: me)
        let bytes = tx.message.bytes
        let sig = try await vault.withKey(w.id, kind: .solana, reason: reason) { seed -> [UInt8] in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard key.publicKey.rawRepresentation.bytes == me.bytes else { throw WalletError.invalidKey }
            return try key.signature(for: bytes).bytes
        }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: me.bytes), pub.isValidSignature(sig, for: bytes) else {
            throw WalletError.blocked("The signature failed its self-check. Nothing was returned to the site.")
        }
        var out = tx
        out.signatures[slot] = sig
        return out
    }

    /// signMessage: an ed25519 signature over the bytes, self-checked.
    public func dappSolanaSignMessage(walletID: UUID, _ message: [UInt8], reason: String) async throws -> [UInt8] {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = SolanaPublicKey(w.solanaAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let sig = try await vault.withKey(w.id, kind: .solana, reason: reason) { seed -> [UInt8] in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard key.publicKey.rawRepresentation.bytes == me.bytes else { throw WalletError.invalidKey }
            return try key.signature(for: message).bytes
        }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: me.bytes), pub.isValidSignature(sig, for: message) else {
            throw WalletError.blocked("The signature failed its self-check. Nothing was returned to the site.")
        }
        return sig
    }

    /// Every other required signature is present and valid (needed before Hermit broadcasts).
    public nonisolated static func otherSignaturesValid(_ tx: SolanaWireTransaction, except slot: Int) -> Bool {
        for (i, k) in tx.message.signers.enumerated() where i != slot {
            let s = tx.signatures[i]
            guard s.contains(where: { $0 != 0 }), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: k.bytes),
                  pub.isValidSignature(s, for: tx.message.bytes) else { return false }
        }
        return true
    }
}
