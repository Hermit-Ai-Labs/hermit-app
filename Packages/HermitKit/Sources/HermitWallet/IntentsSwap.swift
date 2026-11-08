import Foundation

/// A NEAR Intents swap Hermit started, kept so its status can be followed after the sheet closes. Public data only.
public struct TrackedSwap: Codable, Sendable, Identifiable, Equatable {
    public var id: String { depositAddress }
    public let depositAddress: String
    public let depositMemo: String?
    public let walletID: UUID?
    /// "10 USDC on Base"
    public let from: String
    /// "about 2.7 NEAR on NEAR"
    public let to: String
    public let fromChainID: String?
    public let toPlaceName: String
    public let created: Date
    public let deadline: Date?
    public var txHash: String?
    public var status: IntentsStatus
    public var delivered: String?
    public var refunded: String?
    /// true when the user sends from outside Hermit (an exchange): Add funds from any chain.
    public var external: Bool

    public init(depositAddress: String, depositMemo: String?, walletID: UUID?, from: String, to: String, fromChainID: String?,
                toPlaceName: String, created: Date = Date(), deadline: Date?, txHash: String? = nil, status: IntentsStatus = .pendingDeposit,
                external: Bool = false) {
        self.depositAddress = depositAddress; self.depositMemo = depositMemo; self.walletID = walletID; self.from = from; self.to = to
        self.fromChainID = fromChainID; self.toPlaceName = toPlaceName; self.created = created; self.deadline = deadline
        self.txHash = txHash; self.status = status; self.external = external
    }
    public var explorer: URL? { OneClick.explorer(depositAddress: depositAddress) }
}

/// Swaps started on this device, newest first (app defaults).
public final class IntentsLedger: @unchecked Sendable {
    let defaults: UserDefaults
    let key = "hermit.intents.swaps"
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var all: [TrackedSwap] {
        lock.withLock { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([TrackedSwap].self, from: $0) } ?? [] }
    }
    public func upsert(_ s: TrackedSwap) {
        lock.withLock {
            var l = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([TrackedSwap].self, from: $0) } ?? []
            if let i = l.firstIndex(where: { $0.depositAddress == s.depositAddress }) { l[i] = s } else { l.insert(s, at: 0) }
            defaults.set(try? JSONEncoder().encode(Array(l.prefix(200))), forKey: key)
        }
    }
    public func swap(_ depositAddress: String) -> TrackedSwap? { all.first { $0.depositAddress == depositAddress } }
}

extension WalletService {
    public var policy: SpendPolicy { SpendPolicy(limit: spendLimit, book: addressBook) }
    public static let intentsLedger = IntentsLedger()

    /// The user's own address at a place (where swap output lands by default). nil for Bitcoin: Hermit holds no BTC key.
    public func ownAddress(_ place: IntentsPlace, walletID: UUID?) -> String? {
        guard let w = walletID.flatMap({ id in wallets.first { $0.id == id } }) ?? selected else { return nil }
        switch place {
        case .chain(let c): let a = w.address(on: c); return a.isEmpty ? nil : a
        case .hyperliquid: return w.evmAddress
        case .bitcoin: return nil
        }
    }

    /// Builds the 1Click request for a swap out of this wallet. Refunds go back to the sender's own address.
    public func intentsRequest(walletID: UUID?, from: Chain, fromToken: Token?, to: IntentsPlace, toSymbol: String, amount: UInt128,
                               recipient: String? = nil, dry: Bool, slippageBps: Int = 100,
                               confidential: Bool = false, tokens: [IntentsToken]) throws -> IntentsQuoteRequest {
        guard let o = IntentsAssets.token(fromToken?.symbol, at: .chain(from), in: tokens, hermitToken: fromToken) else {
            throw WalletError.blocked("NEAR Intents doesn't list \(fromToken?.symbol ?? from.nativeSymbol) on \(from.name).")
        }
        guard let d = IntentsAssets.token(toSymbol, at: to, in: tokens, hermitToken: to.chain?.token(toSymbol)) else {
            throw WalletError.blocked("NEAR Intents doesn't list \(toSymbol) on \(to.name).")
        }
        guard let refund = ownAddress(.chain(from), walletID: walletID) else {
            throw WalletError.blocked(from.kind == .near ? "Add a NEAR account to this wallet first." : "Create or import a wallet first.")
        }
        guard let rcpt = recipient ?? ownAddress(to, walletID: walletID) else { throw WalletError.blocked("Enter the \(to.name) address to receive at.") }
        return IntentsQuoteRequest(dry: dry, slippageBps: slippageBps, originAsset: o.assetId, destinationAsset: d.assetId, amount: amount,
                                   recipient: rcpt, refundTo: refund, deadline: Date().addingTimeInterval(dry ? 600 : 1800),
                                   confidentiality: confidential ? .basic : .public)
    }

    /// The deposit for a real quote, as a normal send to the quote's deposit address, plus the policy verdict.
    /// The hazard scan's address-book line is replaced by checks on the quote itself.
    public func prepareIntentsDeposit(walletID: UUID?, from: Chain, fromToken: Token?, quote: IntentsQuote, payee: (address: String, kind: ChainKind)?,
                                      origin: ActionOrigin) async throws -> (send: PreparedSend, verdict: PolicyVerdict) {
        guard !quote.request.dry, let deposit = quote.depositAddress else { throw WalletError.blocked("That was a preview quote. Get a live quote first.") }
        guard quote.depositMemo == nil else { throw WalletError.blocked("This route needs a deposit memo, which Hermit can't attach on \(from.name).") }
        if let dl = quote.deadline, dl < Date().addingTimeInterval(60) { throw WalletError.blocked("The quote is about to expire. Get a new one.") }
        let verdict = policy.evaluate(usd: quote.amountInUSD, payee: payee, origin: origin)
        if verdict.decision == .block { throw WalletError.blocked(verdict.blocks.joined(separator: " ")) }
        let p = try await prepareSend(walletID: walletID, chain: from, to: deposit, value: quote.amountIn, token: fromToken)
        var checks = p.checks.filter { !$0.title.contains("payment to this address") && !$0.title.contains("Address matches") && !$0.title.lowercased().contains("daily limit") }
        checks.append(HazardCheck(title: "One-time 1Click deposit address", status: .pass,
                                  detail: "Made for this quote only. 1Click watches it and swaps what arrives."))
        checks.append(quote.signatureValid
            ? HazardCheck(title: "Quote signed by 1Click", status: .pass, detail: "Ed25519 signature checked against 1Click's key.")
            : HazardCheck(title: "Quote signature not confirmed", status: .warn, detail: "Fetched from 1Click over HTTPS, but its signature didn't check out here."))
        checks.append(HazardCheck(title: "Refunds come back to you", status: .pass, detail: "If solvers can't fill it, 1Click refunds \(Self.short(quote.request.refundTo))."))
        return (p.with(checks: checks, recipientInput: "1Click deposit"), verdict)
    }

    /// Sends the deposit (Face ID inside), tells 1Click the hash, and starts tracking. Returns the deposit tx hash.
    public func executeIntentsDeposit(_ p: PreparedSend, quote: IntentsQuote, from: String, to: String, toPlace: IntentsPlace,
                                      oneClick: OneClick = OneClick()) async throws -> String {
        guard let deposit = quote.depositAddress else { throw WalletError.blocked("No deposit address.") }
        var tracked = TrackedSwap(depositAddress: deposit, depositMemo: quote.depositMemo, walletID: p.walletID, from: from, to: to,
                                  fromChainID: p.chain.id, toPlaceName: toPlace.name, deadline: quote.deadline)
        let receipt = try await execute(p)
        tracked.txHash = receipt.hash
        Self.intentsLedger.upsert(tracked)
        if p.usdValue == nil, let usd = quote.amountInUSD { spendLimit.record(usd: Decimal(usd)) }   // stables are counted by execute
        let sender = p.chain.kind == .near ? wallets.first { $0.id == p.walletID }?.nearAccount : nil
        try? await oneClick.submitDeposit(txHash: receipt.hash, depositAddress: deposit, nearSender: sender, memo: quote.depositMemo)
        return receipt.hash
    }

    /// Reads the status once and stores it in the ledger.
    @discardableResult
    public func refreshIntentsStatus(_ depositAddress: String, oneClick: OneClick = OneClick()) async throws -> IntentsSwapState {
        let s = try await oneClick.status(depositAddress: depositAddress, memo: Self.intentsLedger.swap(depositAddress)?.depositMemo)
        if var t = Self.intentsLedger.swap(depositAddress) {
            t.status = s.status
            t.delivered = s.amountOutFormatted
            t.refunded = s.refundedFormatted ?? s.refundedAmount.map(String.init)
            Self.intentsLedger.upsert(t)
        }
        return s
    }

    static func short(_ a: String) -> String { a.count > 14 ? "\(a.prefix(6))…\(a.suffix(4))" : a }
}
