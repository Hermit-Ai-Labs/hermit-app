import Foundation
import HermitWallet

/// The cheapest way to put USDC into Hyperliquid, picked per quote so people never have to think about it:
///   bridge      USDC already on Arbitrum goes straight into Hyperliquid's bridge: one transaction, about $0.01 of gas.
///   viaArbitrum USDC elsewhere on a brand-new account: Relay moves it to your own Arbitrum address (about $0.02), then
///               it goes into the bridge. This skips the ~$1.20 Hyperliquid charges Relay to open a new account.
///   (otherwise) Relay's one-step route, which costs about $0.02 once the account exists.
/// The bridge takes 5 USDC or more (less is lost), so smaller amounts always use Relay.
struct HyperliquidRoute {
    enum Kind { case bridge, viaArbitrum(Relay.Quote) }
    let kind: Kind
    /// What lands on Hyperliquid, formatted.
    let amountOut: String
    let feeUSD: Double
    /// What it saves against Relay's one-step quote.
    let savedUSD: Double

    static let minimum: Double = 5
    /// Gas for the bridge deposit on Arbitrum, about a cent.
    static let bridgeGasUSD = 0.01

    var steps: Int { if case .viaArbitrum = kind { return 2 }; return 1 }
    var routeName: String { if case .viaArbitrum = kind { return "Relay to Arbitrum, then Hyperliquid's bridge" }; return "Hyperliquid's bridge" }

    /// Picks the better route for `amount` USDC from `chain`, given Relay's one-step quote. Nil means use Relay.
    static func best(chain: Chain, symbol: String, amount: Double, raw: UInt128, relay: Relay.Quote?, user: String) async -> HyperliquidRoute? {
        guard symbol == "USDC", chain.kind == .evm, !chain.isTestnet else { return nil }
        let relayFee = relay?.feeUSD ?? .infinity
        if chain.id == "arbitrum" {
            guard amount >= minimum, bridgeGasUSD < relayFee else { return nil }
            return HyperliquidRoute(kind: .bridge, amountOut: MoneyFmt.amount(amount), feeUSD: bridgeGasUSD,
                                    savedUSD: relayFee.isFinite ? relayFee - bridgeGasUSD : 0)
        }
        // Only worth a second transaction when Relay's route carries the new-account charge.
        guard let relay, relay.setupUSD > 0, let usdc = Chain.arbitrum.token("USDC"), let tok = chain.token("USDC") else { return nil }
        guard let hop = try? await Relay.quote(from: .chain(chain), fromToken: tok, to: .chain(.arbitrum), toToken: usdc, amount: raw,
                                               user: user, recipient: user),
              let landed = Double(hop.amountOut), landed >= minimum + 0.05 else { return nil }
        let fee = hop.feeUSD + bridgeGasUSD
        guard fee < relay.feeUSD else { return nil }
        return HyperliquidRoute(kind: .viaArbitrum(hop), amountOut: hop.amountOut, feeUSD: fee, savedUSD: relay.feeUSD - fee)
    }
}

extension WalletService {
    /// Runs a HyperliquidRoute: the Relay hop (if any), waits for the USDC to land on Arbitrum, then deposits it into
    /// Hyperliquid's bridge from this wallet, so it's credited to the same address on Hyperliquid.
    @MainActor
    func executeHyperliquid(_ route: HyperliquidRoute, amount raw: UInt128, walletID: UUID) async throws -> String {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = EVMAddress(w.evmAddress),
              let usdc = Chain.arbitrum.token("USDC"), let usdcAddr = EVMAddress(usdc.address),
              let bridge = EVMAddress(Hyperliquid.bridge) else { throw WalletError.vault("That wallet is gone.") }
        let arb = evm(.arbitrum)
        var deposit = raw
        if case .viaArbitrum(let hop) = route.kind {
            let before = try await arb.tokenBalance(token: usdcAddr, owner: me)
            _ = try await execute(hop, walletID: walletID)
            // Relay usually lands in seconds; give it up to five minutes.
            let floor = (try? Units.parse(hop.amountOut, decimals: 6)).map { $0 * 98 / 100 } ?? 0
            var arrived: UInt128 = 0
            for _ in 0..<300 {
                let now = (try? await arb.tokenBalance(token: usdcAddr, owner: me)) ?? before
                if now > before, now - before >= floor { arrived = now - before; break }
                try await Task.sleep(for: .seconds(1))
            }
            guard arrived > 0 else {
                throw WalletError.blocked("Your USDC is on its way to Arbitrum but hasn't landed yet. When it does, add funds to Hyperliquid from USDC on Arbitrum.")
            }
            deposit = arrived
        }
        guard deposit >= 5_000_000 else { throw WalletError.blocked("Hyperliquid's bridge needs at least 5 USDC. The USDC is safe in your wallet on Arbitrum.") }
        let call = ContractCall(to: usdcAddr, data: ERC20.transfer(to: bridge, amount: deposit), label: "Deposit USDC to Hyperliquid")
        return try await executeCalls(walletID: walletID, chain: .arbitrum, [call]).last ?? ""
    }
}
