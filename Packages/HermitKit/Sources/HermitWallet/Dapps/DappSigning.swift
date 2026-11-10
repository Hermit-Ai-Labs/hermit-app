import Foundation

// Signing for web apps opened in Hermit's browser (EIP-1193). Every function here runs only after the user approved the
// request on the approval sheet, and each one unlocks the key with Face ID / Touch ID through `KeyVault.withKey`, the
// same path sends, Aave and swaps use. No new cryptography: keccak, secp256k1 and EIP-712 are the wallet's own.

/// A transaction a web app asked for (eth_sendTransaction), checked and parsed.
public struct DappTransactionRequest: Sendable, Equatable {
    public let from: EVMAddress
    public let to: EVMAddress
    public let value: UInt128
    public let data: [UInt8]
    /// The gas limit the app suggested, used only when our own simulation can't estimate it.
    public let gas: UInt64?
    public init(from: EVMAddress, to: EVMAddress, value: UInt128, data: [UInt8], gas: UInt64?) {
        self.from = from; self.to = to; self.value = value; self.data = data; self.gas = gas
    }
}

/// A web app's transaction after simulation, with fees, ready for the approval sheet.
public struct PreparedDappTransaction: Sendable {
    public let walletID: UUID
    public let chain: Chain
    public let request: DappTransactionRequest
    public let tx: EIP1559Transaction
    /// estimateGas ran the call against the current chain state and it didn't revert.
    public let simulated: Bool
    public let simulationDetail: String
    /// The wallet's native balance covers value plus the highest possible fee.
    public let feeCovered: Bool
    public let nativeBalance: UInt128
    public var networkFee: UInt128 { tx.maxFee }
}

extension WalletService {
    /// EIP-191 `personal_sign`: keccak256("\x19Ethereum Signed Message:\n" + len + message), signed with the wallet's EVM
    /// key, returned as r‖s‖v (v = 27/28). The signature is recovered and checked against the wallet's address before it
    /// is handed out.
    public func dappPersonalSign(walletID: UUID, message: [UInt8], reason: String) async throws -> String {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = EVMAddress(w.evmAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let digest = Self.personalMessageDigest(message)
        let (rs, recid) = try await vault.withKey(w.id, kind: .evm, reason: reason) { key in try Secp256k1.sign(digest: digest, key: key) }
        guard let pub = Secp256k1.recover(digest: digest, rs: rs, recid: recid), EVMAddress(publicKey: pub) == me else {
            throw WalletError.blocked("The signature failed its self-check. Nothing was returned to the site.")
        }
        return (rs + [UInt8(27 + recid)]).hex0x
    }

    public nonisolated static func personalMessageDigest(_ message: [UInt8]) -> [UInt8] {
        Hash.keccak256(Array("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message)
    }

    /// `eth_signTypedData_v4` with the wallet's EIP-712 encoder (the one Polymarket orders use), self-checked the same way.
    public func dappSignTypedData(walletID: UUID, typedData: EIP712, reason: String) async throws -> String {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = EVMAddress(w.evmAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let digest = try typedData.digest()
        let (rs, recid) = try await vault.withKey(w.id, kind: .evm, reason: reason) { key in try Secp256k1.sign(digest: digest, key: key) }
        guard let pub = Secp256k1.recover(digest: digest, rs: rs, recid: recid), EVMAddress(publicKey: pub) == me else {
            throw WalletError.blocked("The signature failed its self-check. Nothing was returned to the site.")
        }
        return (rs + [UInt8(27 + recid)]).hex0x
    }

    /// Simulates a web app's transaction (eth_estimateGas runs it against the chain) and prices it. Nothing is signed.
    public func prepareDappTransaction(walletID: UUID, chain: Chain, _ r: DappTransactionRequest) async throws -> PreparedDappTransaction {
        guard chain.kind == .evm, let chainId = chain.chainId else { throw WalletError.blocked("Web apps can only use EVM networks here.") }
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }), EVMAddress(w.evmAddress) == r.from else {
            throw WalletError.blocked("The site asked to send from an address that isn't the connected wallet.")
        }
        let client = evm(chain)
        async let cidA = client.chainId()
        async let nonceA = client.nonce(r.from)
        async let feesA = client.fees()
        async let nativeA = client.balance(r.from)
        let (cid, nonce, fees, native) = try await (cidA, nonceA, feesA, nativeA)
        guard cid == chainId else { throw WalletError.badResponse("RPC for \(chain.name) reports chain \(cid)") }
        var simulated = true, detail = "The transaction ran in a simulation on \(chain.name) and didn't fail."
        var gas: UInt64
        do {
            let est = try await client.estimateGas(from: r.from, to: r.to, data: r.data, value: r.value)
            gas = est + est / 5
        } catch {
            simulated = false
            detail = (error as? WalletError)?.errorDescription ?? error.localizedDescription
            guard let g = r.gas, g > 0 else { throw WalletError.simulationFailed(detail) }
            gas = g
        }
        let tx = EIP1559Transaction(chainId: cid, nonce: nonce, maxPriorityFeePerGas: fees.maxPriorityFeePerGas, maxFeePerGas: fees.maxFeePerGas,
                                    gasLimit: gas, to: r.to, value: r.value, data: r.data)
        let covered = native >= tx.maxFee + r.value
        return PreparedDappTransaction(walletID: w.id, chain: chain, request: r, tx: tx, simulated: simulated, simulationDetail: detail,
                                       feeCovered: covered, nativeBalance: native)
    }

    /// Signs (Face ID / Touch ID), self-checks the signed bytes against what was approved, and broadcasts. Returns the
    /// hash as soon as the node accepts it, as EIP-1193 expects; the site follows the receipt itself.
    public func executeDappTransaction(_ p: PreparedDappTransaction, reason: String, spentUSD: Decimal?) async throws -> String {
        guard p.chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == p.walletID }), let from = EVMAddress(w.evmAddress), from == p.request.from else {
            throw WalletError.vault("That wallet is gone.")
        }
        let client = evm(p.chain)
        var tx = p.tx
        async let nonceA = client.nonce(from)
        async let feesA = client.fees()
        let (nonce, fees) = try await (nonceA, feesA)
        tx.nonce = nonce
        if fees.maxFeePerGas > tx.maxFeePerGas {
            guard fees.maxFeePerGas <= tx.maxFeePerGas * 3 / 2 else { throw WalletError.blocked("Network fees jumped. Ask the site to try again.") }
            tx.maxFeePerGas = fees.maxFeePerGas; tx.maxPriorityFeePerGas = min(fees.maxPriorityFeePerGas, fees.maxFeePerGas)
        }
        let unsigned = tx
        let signed = try await vault.withKey(w.id, kind: .evm, reason: reason) { key in try unsigned.sign(privateKey: key) }
        // What was signed must be exactly what was shown: same target, value and calldata, from this wallet.
        guard let check = EIP1559Transaction.decode(raw: signed.raw), check.tx == unsigned, check.sender == from,
              unsigned.to == p.request.to, unsigned.value == p.request.value, unsigned.data == p.request.data else {
            throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.")
        }
        let hash = try await client.sendRawTransaction(signed.raw)
        guard hash.lowercased() == signed.hash else { throw WalletError.badResponse("node returned a different hash") }
        if let spentUSD, spentUSD > 0, !p.chain.isTestnet { spendLimit.record(usd: spentUSD) }
        Task { [weak self] in
            _ = try? await client.waitForReceipt(hash)
            await self?.refreshBalances(chains: [p.chain])
        }
        return hash
    }
}
