import Foundation
import HermitWallet

/// The cheapest way to put USDC into Hyperliquid, picked per quote so people never have to think about it:
///   bridge      USDC already on Arbitrum goes straight into Hyperliquid's bridge: one transaction, about $0.01 of gas.
///   viaArbitrum USDC elsewhere on a brand-new account: Relay moves it to your own Arbitrum address (about $0.02), then
///               it goes into the bridge. This skips the ~$1.20 Hyperliquid charges Relay to open a new account.
///   (otherwise) Relay's one-step route, which costs about $0.02 once the account exists.
/// The bridge takes 5 USDC or more (less is lost), so smaller amounts always use Relay.
/// Both routes end with a USDC transfer on Arbitrum, so both need a little ETH there for its gas. Without it Relay's
/// one-step route is used, so nothing is moved to Arbitrum just to get stuck there.
struct HyperliquidRoute {
    enum Kind { case bridge, viaArbitrum(Relay.Quote) }
    let kind: Kind
    /// What lands on Hyperliquid, formatted.
    let amountOut: String
    let feeUSD: Double
    /// What it saves against Relay's one-step quote.
    let savedUSD: Double

    static let minimum: Double = 5
    /// The same minimum in USDC base units.
    static let minimumRaw: UInt128 = 5_000_000
    /// Gas budgeted for the bridge transfer on Arbitrum: an ERC-20 transfer plus room for Arbitrum's L1 data part.
    static let bridgeGas: UInt128 = 400_000
    /// Gas for the bridge deposit on Arbitrum, about a cent.
    static let bridgeGasUSD = 0.01

    var steps: Int { if case .viaArbitrum = kind { return 2 }; return 1 }
    var routeName: String { if case .viaArbitrum = kind { return "Relay to Arbitrum, then Hyperliquid's bridge" }; return "Hyperliquid's bridge" }

    /// Picks the better route for `amount` USDC from `chain`, given Relay's one-step quote. Nil means use Relay.
    /// `arbitrumGas` says the wallet can pay the bridge transfer's gas on Arbitrum (WalletService.canPayArbitrumBridgeGas).
    static func best(chain: Chain, symbol: String, amount: Double, raw: UInt128, relay: Relay.Quote?, user: String,
                     arbitrumGas: Bool) async -> HyperliquidRoute? {
        guard symbol == "USDC", chain.kind == .evm, !chain.isTestnet, arbitrumGas else { return nil }
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

/// A Hyperliquid deposit whose Relay hop to Arbitrum was sent (or may have been) but whose bridge transfer wasn't.
/// Kept on this device, one per wallet, and saved before the hop is sent: a retry never sends a second hop, and USDC that
/// landed after the sheet closed can be finished from Fund Hyperliquid.
struct PendingHyperliquidDeposit: Codable, Equatable {
    let walletID: UUID
    /// What the hop was asked to move, base units of the source token. A retry of the same deposit matches it.
    let amount: String
    /// The wallet's USDC on Arbitrum (base units) just before the hop. What landed is the increase over it.
    let baseline: String
    /// The least that must land to count: 98% of what the hop quoted, base units.
    let floor: String
    let created: Date

    /// Older records are dropped: by then the hop was finished, refunded, or the USDC was used some other way.
    static let maxAge: TimeInterval = 3 * 86_400
    private static let key = "hermit.hyperliquid.pending"

    private static var all: [String: PendingHyperliquidDeposit] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let l = try? JSONDecoder().decode([String: PendingHyperliquidDeposit].self, from: d) else { return [:] }
        return l
    }
    private static func write(_ l: [String: PendingHyperliquidDeposit]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(l), forKey: key)
    }

    static func load(_ walletID: UUID) -> PendingHyperliquidDeposit? {
        guard let p = all[walletID.uuidString], UInt128(p.baseline) != nil, UInt128(p.floor) != nil else { return nil }
        guard Date().timeIntervalSince(p.created) < maxAge else { clear(walletID); return nil }
        return p
    }
    static func save(_ p: PendingHyperliquidDeposit) {
        var l = all
        l[p.walletID.uuidString] = p
        write(l)
    }
    static func clear(_ walletID: UUID) {
        var l = all
        l[walletID.uuidString] = nil
        write(l)
    }

    /// What landed over the baseline, once it reaches the floor. Nil before that.
    func landed(now: UInt128) -> UInt128? {
        guard let base = UInt128(baseline), let least = UInt128(floor), now > base else { return nil }
        let d = now - base
        return d >= least ? d : nil
    }

    /// The hop landed, or was sent recently enough that it may still be on its way: a retry must not send another.
    func isLive(now: UInt128) -> Bool { landed(now: now) != nil || Date().timeIntervalSince(created) < 900 }

    /// True when a failed hop can't have moved anything: it stopped before broadcast, or its transaction reverted.
    static func nothingMoved(_ error: Error) -> Bool {
        guard let e = error as? WalletError else { return false }
        switch e {
        case .simulationFailed, .blocked, .insufficientFunds, .vault, .cancelled, .invalidAmount, .invalidAddress, .invalidKey,
             .unknownToken: return true
        default: return false
        }
    }
}

extension WalletService {
    /// The ETH the bridge transfer needs on Arbitrum at today's fees, and what the wallet has there (wei).
    @MainActor
    func arbitrumBridgeGas(_ me: EVMAddress) async throws -> (have: UInt128, need: UInt128) {
        let arb = evm(.arbitrum)
        async let nativeA = arb.balance(me)
        async let feesA = arb.fees()
        let (have, fees) = try await (nativeA, feesA)
        let (need, overflow) = fees.maxFeePerGas.multipliedReportingOverflow(by: HyperliquidRoute.bridgeGas)
        return (have, overflow ? .max : need)
    }

    /// Whether `address` can pay the bridge transfer's gas on Arbitrum now. False when it can't be read.
    @MainActor
    func canPayArbitrumBridgeGas(_ address: String) async -> Bool {
        guard let me = EVMAddress(address), let g = try? await arbitrumBridgeGas(me) else { return false }
        return g.have >= g.need
    }

    /// Stops before anything moves when the wallet can't pay for the bridge transfer on Arbitrum.
    @MainActor
    private func requireArbitrumBridgeGas(_ me: EVMAddress) async throws {
        let g = try await arbitrumBridgeGas(me)
        guard g.have >= g.need else {
            throw WalletError.insufficientFunds("Needs a little ETH on Arbitrum for the network fee (about \(Units.format(g.need, decimals: 18, maxFraction: 8)) ETH). Nothing was sent.")
        }
    }

    /// What has landed on Arbitrum for this wallet's unfinished Hyperliquid deposit. Nil when there is none, it hasn't
    /// landed yet, or the balance couldn't be read.
    @MainActor
    func hyperliquidLanded(walletID: UUID) async -> UInt128? {
        guard let p = PendingHyperliquidDeposit.load(walletID), let w = wallets.first(where: { $0.id == walletID }),
              let me = EVMAddress(w.evmAddress), let usdc = Chain.arbitrum.token("USDC"), let usdcAddr = EVMAddress(usdc.address),
              let now = try? await evm(.arbitrum).tokenBalance(token: usdcAddr, owner: me) else { return nil }
        return p.landed(now: now)
    }

    /// Finishes a deposit whose hop landed but whose bridge transfer wasn't sent (no gas, a closed sheet, a timeout):
    /// sends exactly `amount`, what the approval sheet showed, into the bridge. The hop is never sent again.
    @MainActor
    func finishHyperliquid(walletID: UUID, amount: UInt128) async throws -> String {
        guard let landed = await hyperliquidLanded(walletID: walletID), landed >= amount else {
            throw WalletError.blocked("Couldn't confirm that USDC on Arbitrum. Nothing was sent. Try again in a minute.")
        }
        return try await bridgeToHyperliquid(amount, walletID: walletID, finishing: true)
    }

    /// The bridge transfer: USDC on Arbitrum into Hyperliquid's bridge, credited to the same address on Hyperliquid.
    /// `finishing` clears the wallet's unfinished-deposit record once the transfer is sent.
    @MainActor
    private func bridgeToHyperliquid(_ deposit: UInt128, walletID: UUID, finishing: Bool) async throws -> String {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = EVMAddress(w.evmAddress),
              let usdc = Chain.arbitrum.token("USDC"), let usdcAddr = EVMAddress(usdc.address),
              let bridge = EVMAddress(Hyperliquid.bridge) else { throw WalletError.vault("That wallet is gone.") }
        guard deposit >= HyperliquidRoute.minimumRaw else {
            if finishing { PendingHyperliquidDeposit.clear(walletID) }
            throw WalletError.blocked("Hyperliquid's bridge needs at least 5 USDC. The USDC is safe in your wallet on Arbitrum.")
        }
        try await requireArbitrumBridgeGas(me)
        let call = ContractCall(to: usdcAddr, data: ERC20.transfer(to: bridge, amount: deposit), label: "Deposit USDC to Hyperliquid")
        do {
            let hashes = try await executeCalls(walletID: walletID, chain: .arbitrum, [call])
            if finishing { PendingHyperliquidDeposit.clear(walletID) }
            return hashes.last ?? ""
        } catch WalletError.pending(let hash, let explorer) {
            // Sent and still confirming: the USDC has left, so there is nothing left to finish.
            if finishing { PendingHyperliquidDeposit.clear(walletID) }
            throw WalletError.pending(hash: hash, explorer: explorer)
        }
    }

    /// Runs a HyperliquidRoute: the Relay hop (if any), waits for the USDC to land on Arbitrum, then deposits it into
    /// Hyperliquid's bridge from this wallet, so it's credited to the same address on Hyperliquid.
    /// Arbitrum gas is checked before anything moves. The hop is recorded (PendingHyperliquidDeposit) before it is sent,
    /// so a retry waits for that hop instead of sending another, and a closed sheet or a timeout can be finished later.
    @MainActor
    func executeHyperliquid(_ route: HyperliquidRoute, amount raw: UInt128, walletID: UUID) async throws -> String {
        guard let w = wallets.first(where: { $0.id == walletID }), let me = EVMAddress(w.evmAddress),
              let usdc = Chain.arbitrum.token("USDC"), let usdcAddr = EVMAddress(usdc.address) else { throw WalletError.vault("That wallet is gone.") }
        try await requireArbitrumBridgeGas(me)
        guard case .viaArbitrum(let hop) = route.kind else { return try await bridgeToHyperliquid(raw, walletID: walletID, finishing: false) }
        let arb = evm(.arbitrum)
        let now = try await arb.tokenBalance(token: usdcAddr, owner: me)
        let pending: PendingHyperliquidDeposit
        if let old = PendingHyperliquidDeposit.load(walletID), old.isLive(now: now) {
            // An earlier try already sent its hop (it landed, or may still be on its way): never send a second one.
            guard old.amount == String(raw) else {
                throw WalletError.blocked("An earlier Hyperliquid deposit is still on its way to Arbitrum. Finish it from Fund Hyperliquid first.")
            }
            pending = old
        } else {
            let least = (try? Units.parse(hop.amountOut, decimals: usdc.decimals)).map { $0 * 98 / 100 } ?? HyperliquidRoute.minimumRaw
            pending = PendingHyperliquidDeposit(walletID: walletID, amount: String(raw), baseline: String(now), floor: String(least), created: Date())
            PendingHyperliquidDeposit.save(pending)
            do { _ = try await execute(hop, walletID: walletID) } catch {
                if PendingHyperliquidDeposit.nothingMoved(error) { PendingHyperliquidDeposit.clear(walletID) }
                throw error
            }
        }
        // Relay usually lands in seconds; give it up to five minutes. A closed sheet or a timeout keeps the record.
        let later = WalletError.blocked("Your USDC is on its way to Arbitrum. When it lands, open Fund Hyperliquid to finish the deposit.")
        var arrived: UInt128?
        for _ in 0..<300 {
            if let bal = try? await arb.tokenBalance(token: usdcAddr, owner: me), let l = pending.landed(now: bal) { arrived = l; break }
            do { try await Task.sleep(for: .seconds(1)) } catch { throw later }
        }
        guard let deposit = arrived else { throw later }
        return try await bridgeToHyperliquid(deposit, walletID: walletID, finishing: true)
    }
}
