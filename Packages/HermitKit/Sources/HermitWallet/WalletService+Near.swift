import Foundation
import CryptoKit

/// NEAR sends: native NEAR (Transfer) and NEP-141 tokens (ft_transfer, with storage_deposit first when the receiver isn't
/// registered with the token). NEAR has no dry-run RPC, so the checks read the real state instead: the sender exists,
/// the balance covers amount + attached deposits + gas, and the receiver is a valid account.
extension WalletService {
    /// Prepaid gas price ceiling used for the fee shown (the network refunds what isn't burnt).
    static let nearGasPriceCeiling: UInt128 = 200_000_000   // yocto per gas; mainnet sits at 1e8
    /// A Transfer costs about 0.45 Tgas.
    static let nearTransferGas: UInt64 = 450_000_000_000

    /// Adds a NEAR account to a wallet made before NEAR support (one Face ID unlock), then reloads.
    @discardableResult public func addNearAccount(_ id: UUID) async throws -> String {
        let a = try await vault.addNearAccount(id)
        let sel = selectedWalletID
        reload(select: sel)
        Task { await refreshBalances(chains: [.near]) }
        return a
    }

    /// Whether the NEAR account exists on chain yet. An implicit account appears the first time it receives NEAR.
    public func nearAccountState(_ account: String) async throws -> NearClient.AccountState? { try await nearClient.account(account) }

    func prepareNear(_ w: WalletRecord, _ chain: Chain, to input: String, value: UInt128, token: Token?) async throws -> PreparedSend {
        guard let from = w.nearAccount else { throw WalletError.blocked("Add a NEAR account to this wallet first.") }
        let to = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard NearAccount.isValid(to) else { throw WalletError.invalidAddress(input) }
        let client = nearClient

        var simOK = true, simDetail = "Balance, receiver and fee checked against the chain."
        var actions: [NearAction]
        var receiver: String
        if let t = token {
            receiver = t.address
            actions = [.ftTransfer(receiver: to, amount: value)]
            if !(try await client.isRegistered(token: t.address, account: to)) { actions.insert(.storageDeposit(for: to), at: 0) }
            let bal = try await client.ftBalance(token: t.address, owner: from)
            if bal < value { simOK = false; simDetail = "Balance is \(Units.format(bal, decimals: t.decimals)) \(t.symbol)." }
        } else {
            receiver = to
            actions = [.transfer(deposit: value)]
        }
        let gas = actions.reduce(UInt64(0)) { $0 + ($1.gas == 0 ? Self.nearTransferGas : $1.gas) }
        let fee = UInt128(gas) * Self.nearGasPriceCeiling
        let attached = actions.reduce(UInt128(0)) { $0 + $1.attached }

        guard let state = try await client.account(from) else {
            simOK = false
            simDetail = "This NEAR account isn't active yet. It starts once it receives NEAR (about 0.01 is enough)."
            return PreparedSend(walletID: w.id, chain: chain, token: token, amount: value, recipientInput: input, recipient: to,
                                networkFee: fee, checks: hazardChecks(chain: chain, token: token, value: value, recipient: to,
                                                                      simOK: false, simDetail: simDetail),
                                payload: .near(receiver: receiver, actions: actions))
        }
        if state.available < attached + fee {
            simOK = false
            simDetail = "Not enough NEAR for the amount and fee (have \(Units.format(state.available, decimals: 24, maxFraction: 5)))."
        }
        // An implicit receiver that doesn't exist yet is created by a Transfer, but not by ft_transfer.
        if token != nil, NearAccount.isImplicit(to) == false, try await client.account(to) == nil {
            simOK = false; simDetail = "\(to) doesn't exist on NEAR."
        }
        if token == nil, !NearAccount.isImplicit(to), try await client.account(to) == nil {
            simOK = false; simDetail = "\(to) doesn't exist on NEAR. Named accounts must be created first."
        }
        let checks = hazardChecks(chain: chain, token: token, value: value, recipient: to, simOK: simOK, simDetail: simDetail)
        return PreparedSend(walletID: w.id, chain: chain, token: token, amount: value, recipientInput: input.trimmingCharacters(in: .whitespaces),
                            recipient: to, networkFee: fee + (attached - (token == nil ? value : 0)), checks: checks,
                            payload: .near(receiver: receiver, actions: actions))
    }

    /// Fresh nonce and block hash, Face ID, sign, verify our own signature, send, wait for execution.
    func sendNear(_ w: WalletRecord, receiver: String, actions: [NearAction], reason: String) async throws -> TxReceipt {
        guard let from = w.nearAccount else { throw WalletError.blocked("Add a NEAR account to this wallet first.") }
        guard let pub = [UInt8](hex: from), pub.count == 32 else { throw WalletError.invalidKey }
        let client = nearClient
        async let nonceA = client.accessKeyNonce(account: from, publicKey: NearAccount.publicKeyString(pub))
        async let blockA = client.latestBlockHash()
        let (nonce, block) = try await (nonceA, blockA)
        let unsigned = NearTransaction(signer: from, publicKey: pub, nonce: nonce + 1, receiver: receiver, blockHash: block, actions: actions)
        let signed = try await vault.withKey(w.id, kind: .near, reason: reason) { seed in try unsigned.sign(ed25519Seed: seed) }
        guard signed.verify(), signed.transaction == unsigned else {
            throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.")
        }
        let r = try await client.send(signed)
        guard r.success else { throw WalletError.blocked("The NEAR transaction failed (\(r.hash)): \(r.failure ?? "")") }
        return TxReceipt(chain: .near, hash: r.hash, success: true, block: 0)
    }

    /// Plain NEAR transfer or ft_transfer to a 1Click deposit account, as one signed transaction.
    public func executeNear(walletID: UUID, receiver: String, actions: [NearAction], reason: String) async throws -> String {
        guard allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }) else { throw WalletError.vault("That wallet is gone.") }
        let r = try await sendNear(w, receiver: receiver, actions: actions, reason: reason)
        Task { await refreshBalances(chains: [.near]) }
        return r.hash
    }
}
