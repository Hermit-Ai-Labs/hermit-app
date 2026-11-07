import Foundation

/// One contract call: where, the calldata and any native value. `label` is what the review screen and Face ID prompt say.
public struct ContractCall: Sendable {
    public let to: EVMAddress
    public let data: [UInt8]
    public let value: UInt128
    public let label: String
    public init(to: EVMAddress, data: [UInt8], value: UInt128 = 0, label: String) {
        self.to = to; self.data = data; self.value = value; self.label = label
    }
}

extension WalletService {
    /// Runs calls in order on one chain, each simulated first (estimateGas), signed with Face ID / Touch ID, broadcast and
    /// confirmed before the next one, so an approve lands before the deposit that needs it. Returns the transaction hashes.
    public func executeCalls(walletID: UUID, chain: Chain, _ calls: [ContractCall]) async throws -> [String] {
        guard chain.kind == .evm else { throw WalletError.blocked("Contract calls are EVM only.") }
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }) else { throw WalletError.vault("That wallet is gone.") }
        let client = evm(chain)
        let from = EVMAddress(w.evmAddress)!
        let cid = try await client.chainId()
        guard cid == chain.chainId else { throw WalletError.badResponse("RPC for \(chain.name) reports chain \(cid)") }
        var hashes: [String] = []
        for call in calls {
            let est: UInt64
            do { est = try await client.estimateGas(from: from, to: call.to, data: call.data, value: call.value) }
            catch { throw WalletError.simulationFailed("\(call.label): \((error as? WalletError)?.errorDescription ?? error.localizedDescription)") }
            async let nonceA = client.nonce(from)
            async let feesA = client.fees()
            async let nativeA = client.balance(from)
            let (nonce, fees, native) = try await (nonceA, feesA, nativeA)
            let tx = EIP1559Transaction(chainId: cid, nonce: nonce, maxPriorityFeePerGas: fees.maxPriorityFeePerGas, maxFeePerGas: fees.maxFeePerGas,
                                        gasLimit: est + est / 5, to: call.to, value: call.value, data: call.data)
            guard native >= tx.maxFee + call.value else {
                throw WalletError.insufficientFunds("Not enough \(chain.nativeSymbol) on \(chain.name) for the network fee.")
            }
            let signed = try await vault.withKey(w.id, kind: .evm, reason: call.label) { key in try tx.sign(privateKey: key) }
            guard let check = EIP1559Transaction.decode(raw: signed.raw), check.tx == tx, check.sender == from else {
                throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.")
            }
            let hash = try await client.sendRawTransaction(signed.raw)
            let r = try await client.waitForReceipt(hash)
            guard r.success else { throw WalletError.blocked("\(call.label) failed on chain (\(hash)).") }
            hashes.append(hash)
        }
        Task { await refreshBalances(chains: [chain]) }
        return hashes
    }

    /// Reads an ERC-20 allowance.
    public func allowance(chain: Chain, token: EVMAddress, owner: EVMAddress, spender: EVMAddress) async throws -> UInt128 {
        let out = try await evm(chain).call(to: token, data: ERC20.selector("allowance(address,address)") + ERC20.word(owner) + ERC20.word(spender))
        guard out.count >= 32 else { return 0 }
        return UInt128(bigEndianWord: Array(out[out.count - 32..<out.count]))
    }
}

/// Aave v3: supply and withdraw an ERC-20 the wallet holds. Pool addresses from docs.aave.com/developers/deployed-contracts.
public enum AaveV3 {
    public static let pools: [String: String] = [
        "ethereum": "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
        "base": "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5",
        "arbitrum": "0x794a61358D6845594F94dc1DB02A234b7B5f3fe8",
    ]

    public static func pool(on chain: Chain) -> EVMAddress? { pools[chain.id].flatMap(EVMAddress.init) }

    /// approve (only when the allowance is short) + supply(asset, amount, onBehalfOf, 0).
    public static func supplyCalls(token: Token, amount: UInt128, owner: EVMAddress, pool: EVMAddress, allowance: UInt128) -> [ContractCall] {
        let asset = EVMAddress(token.address)!
        var calls: [ContractCall] = []
        if allowance < amount {
            calls.append(ContractCall(to: asset, data: ERC20.selector("approve(address,uint256)") + ERC20.word(pool) + ERC20.word(amount),
                                      label: "Allow Aave to use \(Units.format(amount, decimals: token.decimals)) \(token.symbol)"))
        }
        calls.append(ContractCall(to: pool, data: ERC20.selector("supply(address,uint256,address,uint16)") + ERC20.word(asset)
                                    + ERC20.word(amount) + ERC20.word(owner) + ERC20.word(UInt128(0)),
                                  label: "Deposit \(Units.format(amount, decimals: token.decimals)) \(token.symbol) into Aave"))
        return calls
    }

    /// withdraw(asset, amount, to). `UInt128.max` style "everything" uses type(uint256).max, which Aave reads as the full balance.
    public static func withdrawCall(token: Token, amount: UInt128?, owner: EVMAddress, pool: EVMAddress) -> ContractCall {
        let all = [UInt8](repeating: 0xff, count: 32)
        let amt = amount.map { ERC20.word($0) } ?? all
        return ContractCall(to: pool, data: ERC20.selector("withdraw(address,uint256,address)") + ERC20.word(EVMAddress(token.address)!) + amt + ERC20.word(owner),
                            label: "Withdraw \(amount.map { Units.format($0, decimals: token.decimals) } ?? "all") \(token.symbol) from Aave")
    }

    /// The aToken balance (what's deposited plus interest), read through the pool's getReserveData is heavy; the
    /// balance of the aToken is enough, and its address comes from getReserveData's 9th word (aTokenAddress).
    public static func aToken(chain: Chain, token: Token, client: EVMClient) async throws -> EVMAddress? {
        guard let pool = pool(on: chain) else { return nil }
        let out = try await client.call(to: pool, data: ERC20.selector("getReserveData(address)") + ERC20.word(EVMAddress(token.address)!))
        guard out.count >= 32 * 9 else { return nil }
        return EVMAddress(bytes: Array(out[32 * 8 + 12..<32 * 9]))
    }
}

extension UInt128 {
    init(bigEndianWord w: [UInt8]) {
        var v: UInt128 = 0
        for b in w.suffix(16) { v = v << 8 | UInt128(b) }
        self = v
    }
}
