import Foundation

/// A wallet's Aave v3 supply: what's in it now (deposit plus interest, the aToken balance) and the live supply rate.
public struct AavePosition: Sendable, Identifiable, Hashable {
    public var id: String { "\(walletID.uuidString):\(chain.id):\(token.symbol)" }
    public let walletID: UUID
    public let chain: Chain
    public let token: Token
    public let amount: UInt128
    /// Supply APY right now, from the pool's currentLiquidityRate (0.0462 = 4.62%). nil if it couldn't be read.
    public let supplyAPY: Double?
    public var text: String { Units.format(amount, decimals: token.decimals, maxFraction: 4) }
    public init(walletID: UUID, chain: Chain, token: Token, amount: UInt128, supplyAPY: Double?) {
        self.walletID = walletID; self.chain = chain; self.token = token; self.amount = amount; self.supplyAPY = supplyAPY
    }
}

extension AaveV3 {
    /// A reserve's aToken and supply APY, from one getReserveData call. nil when the pool doesn't list the token.
    public struct Reserve: Sendable, Equatable {
        public let aToken: EVMAddress
        public let supplyAPY: Double
    }

    /// getReserveData(asset) on v3 returns ReserveDataLegacy: configuration, liquidityIndex, currentLiquidityRate (ray),
    /// variableBorrowIndex, currentVariableBorrowRate, currentStableBorrowRate, lastUpdateTimestamp, id, aTokenAddress, …
    public static func reserve(chain: Chain, token: Token, client: EVMClient) async throws -> Reserve? {
        guard let pool = pool(on: chain) else { return nil }
        let out = try await client.call(to: pool, data: ERC20.selector("getReserveData(address)") + ERC20.word(EVMAddress(token.address)!))
        return reserve(fromReserveData: out)
    }

    static func reserve(fromReserveData out: [UInt8]) -> Reserve? {
        guard out.count >= 32 * 9 else { return nil }
        let a = Array(out[32 * 8 + 12..<32 * 9])
        guard a.contains(where: { $0 != 0 }) else { return nil }
        let rate = UInt128(bigEndianWord: Array(out[64..<96]))
        return Reserve(aToken: EVMAddress(bytes: a), supplyAPY: apy(liquidityRateRay: rate))
    }

    /// Aave's rates are per-year APRs in ray (1e27), compounded every second: APY = (1 + APR / secs)^secs - 1.
    public static func apy(liquidityRateRay: UInt128) -> Double {
        let apr = Double(liquidityRateRay) / 1e27
        let secs = 31_536_000.0
        return pow(1 + apr / secs, secs) - 1
    }

    /// The tokens Hermit can deposit into Aave on a chain (the ones it knows the contracts of).
    public static func tokens(on chain: Chain) -> [Token] {
        guard pool(on: chain) != nil else { return [] }
        return chain.tokens.filter { TokenTable.stableSymbols.contains($0.symbol) }
    }
}

extension WalletService {
    /// Every wallet's Aave v3 supplies on Ethereum, Base and Arbitrum: one reserve read per token, one balance read per
    /// wallet. Networks that didn't answer are listed in `failed` (their positions are unknown, not zero).
    public func aavePositions(wallets list: [WalletRecord]? = nil) async -> (positions: [AavePosition], failed: [Chain]) {
        let ws = (list ?? wallets).compactMap { w in EVMAddress(w.evmAddress).map { (w.id, $0) } }
        guard !ws.isEmpty else { return ([], []) }
        let jobs = Chain.mainnets.flatMap { c in AaveV3.tokens(on: c).map { (c, $0, evm(c)) } }
        var out: [AavePosition] = [], failed = Set<Chain>()
        await withTaskGroup(of: (Chain, [AavePosition]?).self) { g in
            for (chain, token, client) in jobs {
                g.addTask {
                    guard let r = try? await AaveV3.reserve(chain: chain, token: token, client: client) else {
                        // A pool that answered but doesn't list the token is fine; an RPC failure is not.
                        return (chain, (try? await client.chainId()) == nil ? nil : [])
                    }
                    var rows: [AavePosition] = []
                    for (id, owner) in ws {
                        guard let bal = try? await client.tokenBalance(token: r.aToken, owner: owner) else { return (chain, nil) }
                        if bal > 0 { rows.append(AavePosition(walletID: id, chain: chain, token: token, amount: bal, supplyAPY: r.supplyAPY)) }
                    }
                    return (chain, rows)
                }
            }
            for await (c, rows) in g { if let rows { out += rows } else { failed.insert(c) } }
        }
        let order = Dictionary(uniqueKeysWithValues: (list ?? wallets).enumerated().map { ($1.id, $0) })
        out.sort { (order[$0.walletID] ?? 0, $0.chain.name, $0.token.symbol) < (order[$1.walletID] ?? 0, $1.chain.name, $1.token.symbol) }
        return (out, Chain.mainnets.filter { failed.contains($0) })
    }

    /// Withdraw from Aave v3: `amount` nil takes everything (deposit plus interest). Returns the call for executeCalls.
    public func aaveWithdrawCall(walletID: UUID, chain: Chain, token: Token, amount: UInt128?) throws -> ContractCall {
        guard let w = wallets.first(where: { $0.id == walletID }), let owner = EVMAddress(w.evmAddress) else { throw WalletError.vault("That wallet is gone.") }
        guard let pool = AaveV3.pool(on: chain) else { throw WalletError.blocked("Hermit doesn't use Aave on \(chain.name).") }
        return AaveV3.withdrawCall(token: token, amount: amount, owner: owner, pool: pool)
    }
}
