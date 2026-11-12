import Foundation
import HermitCore

// Withdrawing USDC from Hyperliquid to the wallet's own address on Arbitrum ("withdraw3").
//
// Unlike orders (L1 actions, signed as a phantom "Agent"), withdraw3 is a user-signed action: an EIP-712 message of
// primary type "HyperliquidTransaction:Withdraw" with the fields hyperliquidChain, destination, amount (a string) and
// time (uint64, the same millisecond value as the request nonce), under the domain
// {name: "HyperliquidSignTransaction", version: "1", chainId: signatureChainId, verifyingContract: 0x00…00}.
// The action carries "signatureChainId" itself, so the server verifies against that chain id; it can be any chain.
// Hermit signs with 0xa4b1 (Arbitrum One), the chain the money lands on.
//
// Spec: hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint ("Initiate a withdrawal request"):
// "There is a $1 fee for withdrawing at the time of this writing and withdrawals take approximately 5 minutes to
// finalize." Field types: hyperliquid-python-sdk utils/signing.py (WITHDRAW_SIGN_TYPES, sign_withdraw_from_bridge_action).
// Unified and portfolio-margin accounts withdraw from their single USDC balance (account abstraction modes, Hyperliquid docs).

extension Hyperliquid {
    /// What Hyperliquid charges per withdrawal, in USDC (docs: "$1 fee ... at the time of this writing").
    public static let withdrawFee: Decimal = 1
    /// How long it takes to arrive, as the docs say it.
    public static let withdrawMinutes = 5
    /// The chain id the withdrawal is signed under: Arbitrum One.
    static let withdrawSignatureChainID = "0xa4b1"

    // MARK: Review

    /// A withdrawal that was checked against the account and is ready to sign. Always to the wallet's own address.
    public struct WithdrawReview: Sendable {
        public let walletID: UUID
        /// The wallet's own EVM address, lowercase. The only place a withdrawal from Hermit can go.
        public let destination: String
        /// What leaves the Hyperliquid account.
        public let amount: Decimal
        public var fee: Decimal { Hyperliquid.withdrawFee }
        /// What arrives on Arbitrum.
        public var receive: Decimal { amount - Hyperliquid.withdrawFee }
        public let checks: [HazardCheck]
        /// Margin left free after it, when positions are open.
        public let freeAfter: Decimal
        public let positionsOpen: Bool

        public var amountText: String { Hyperliquid.usdcText(amount) }
        public var receiveText: String { Hyperliquid.usdcText(receive) }
        public var canSend: Bool { !checks.contains { $0.status == .fail } }
        public var blockingReason: String? { checks.first { $0.status == .fail }?.detail }
    }

    /// "12.5", "100": a USDC amount as the exchange writes it (at most 6 decimals, no trailing zeros, no exponent).
    public static func usdcText(_ d: Decimal) -> String {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 6, .down)
        return NSDecimalNumber(decimal: r).stringValue
    }

    /// A typed USDC amount: digits and at most one ".", at most 6 decimals, above zero. Anything else (commas, exponents,
    /// "inf") is nil, so a number can never be read differently from how it was typed.
    public static func parseUSDC(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), t.filter({ $0 == "." }).count <= 1,
              !t.hasPrefix("."), !t.hasSuffix(".") else { return nil }
        if let dot = t.firstIndex(of: "."), t.distance(from: dot, to: t.endIndex) - 1 > 6 { return nil }
        guard let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")), d > 0 else { return nil }
        return d
    }

    /// Checks a withdrawal against the account as just read. Nothing is signed or sent. `ownAddress` is the wallet's EVM
    /// address; the destination is always that address. Throws only for an amount that isn't a clear number.
    public static func withdrawReview(walletID: UUID, ownAddress: String, destination: String? = nil, amount text: String,
                                      account: Account) throws -> WithdrawReview {
        guard let amount = parseUSDC(text) else { throw WalletError.invalidAmount(text) }
        let own = ownAddress.lowercased()
        let dest = (destination ?? ownAddress).lowercased()
        let fee = withdrawFee
        let withdrawable = Decimal(string: String(format: "%.6f", account.withdrawable), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        let value = Decimal(string: String(format: "%.6f", account.accountValue), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        let open = account.positions.contains { $0.size != 0 }
        let freeAfter = max(0, withdrawable - amount)
        var checks: [HazardCheck] = []

        if account.isUnified {
            // Unified and portfolio margin keep one USDC balance for spot and every perp dex. Hyperliquid's withdraw3 takes
            // from that balance; `withdrawable` is already the part free after maintenance margin (account(states:...)).
            checks.append(HazardCheck(title: "One balance for spot and perps", status: open ? .warn : .pass,
                                      detail: open ? "Your account shares one USDC balance across spot and perps, and it also backs your open positions."
                                                   : "Your account shares one USDC balance across spot and perps."))
        }
        if dest == own, EVMAddress(own) != nil {
            checks.append(HazardCheck(title: "Goes to your own address on Arbitrum", status: .pass, detail: "Paid out as USDC to \(own)."))
        } else {
            checks.append(HazardCheck(title: "Destination", status: .fail, detail: "Hermit only withdraws to your own wallet address."))
        }
        if amount <= fee {
            checks.append(HazardCheck(title: "Amount", status: .fail,
                                      detail: "Hyperliquid charges \(usdcText(fee)) USDC per withdrawal. Withdraw more than that."))
        } else {
            checks.append(HazardCheck(title: "Fee is \(usdcText(fee)) USDC", status: .pass, detail: "You get \(usdcText(amount - fee)) USDC."))
        }
        if amount > withdrawable {
            checks.append(HazardCheck(title: "Amount", status: .fail,
                                      detail: "Only \(usdcText(withdrawable)) USDC can be withdrawn right now" + (open ? ". The rest backs your open positions." : ".")))
        } else {
            checks.append(HazardCheck(title: "Within what you can withdraw", status: .pass, detail: "\(usdcText(withdrawable)) USDC is free."))
        }
        if open {
            // Free margin is what keeps a position from being liquidated by a small move. Under a fifth of the account left
            // free is a warning, not a block: it is the person's money and position.
            if amount <= withdrawable, value > 0, freeAfter < value / 5 {
                checks.append(HazardCheck(title: "Open positions", status: .warn,
                                          detail: "Your open positions keep their margin. After this only \(usdcText(freeAfter)) USDC is free, so a small price move could liquidate them."))
            } else if amount <= withdrawable {
                checks.append(HazardCheck(title: "Open positions keep their margin", status: .pass, detail: "\(usdcText(freeAfter)) USDC stays free."))
            }
        }
        return WithdrawReview(walletID: walletID, destination: own, amount: amount, checks: checks, freeAfter: freeAfter, positionsOpen: open)
    }

    // MARK: Signing

    /// The EIP-712 message Hyperliquid verifies for `withdraw3`.
    static func withdrawTypedData(destination: String, amount: String, time: UInt64, chain: String = Hyperliquid.withdrawSignatureChainID,
                                  mainnet: Bool = true) -> EIP712 {
        let primary = "HyperliquidTransaction:Withdraw"
        return EIP712(
            types: [primary: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("amount", "string"), .init("time", "uint64")]],
            primaryType: primary,
            domain: ["name": .string("HyperliquidSignTransaction"), "version": .string("1"),
                     "chainId": .string(String(UInt64(chain.dropFirst(2), radix: 16) ?? 0)),
                     "verifyingContract": .string("0x0000000000000000000000000000000000000000")],
            message: ["hyperliquidChain": .string(mainnet ? "Mainnet" : "Testnet"), "destination": .string(destination),
                      "amount": .string(amount), "time": .string(String(time))])
    }

    /// The action as it goes in the request body.
    static func withdrawAction(destination: String, amount: String, time: UInt64, chain: String = Hyperliquid.withdrawSignatureChainID,
                               mainnet: Bool = true) -> [String: Any] {
        ["type": "withdraw3", "hyperliquidChain": mainnet ? "Mainnet" : "Testnet", "signatureChainId": chain,
         "destination": destination, "amount": amount, "time": time]
    }

    /// The whole /exchange body: the action, the nonce (the same as the action's `time`) and the signature.
    static func withdrawBody(action: [String: Any], time: UInt64, signature: [String: Any]) -> [String: Any] {
        ["action": action, "nonce": time, "signature": signature]
    }
}

extension HyperliquidTrader {
    public var walletID: UUID { wallet.id }
    /// The wallet's own EVM address: the only place a withdrawal goes.
    public var ownAddress: String { wallet.evmAddress }

    /// Signs the checked withdrawal after one Face ID / Touch ID and posts it. Returns a line for the receipt. The
    /// destination is the review's own-address one, re-checked against the wallet here. A request that can't be confirmed
    /// is never retried: it may have gone through.
    public func withdraw(_ review: Hyperliquid.WithdrawReview) async throws -> String {
        guard review.canSend else { throw WalletError.blocked(review.blockingReason ?? "This withdrawal is blocked.") }
        guard review.walletID == wallet.id, review.destination == wallet.evmAddress.lowercased() else {
            throw WalletError.blocked("Hermit only withdraws to your own wallet address.")
        }
        let time = UInt64(Date().timeIntervalSince1970 * 1000)
        let amount = review.amountText
        let digest = try Hyperliquid.withdrawTypedData(destination: review.destination, amount: amount, time: time).digest()
        let sig = try await vault.withKey(wallet.id, kind: .evm, reason: "Withdraw \(amount) USDC from Hyperliquid to Arbitrum") { key in
            try Hyperliquid.signature(digest: digest, key: key)
        }
        let action = Hyperliquid.withdrawAction(destination: review.destination, amount: amount, time: time)
        let body = Hyperliquid.withdrawBody(action: action, time: time, signature: sig)
        let out: Any
        do {
            out = try await Hyperliquid.post("exchange", body)
        } catch {
            throw WalletError.blocked("Couldn't confirm the withdrawal with Hyperliquid. It may still go through: check your Hyperliquid balance before trying again.")
        }
        guard let o = out as? [String: Any] else { throw WalletError.badResponse("Hyperliquid") }
        if o["status"] as? String != "ok" {
            throw WalletError.blocked(Self.plainWithdrawError(o["response"] as? String))
        }
        return "About \(review.receiveText) USDC arrives on Arbitrum in about \(Hyperliquid.withdrawMinutes) minutes."
    }

    /// Hyperliquid's refusal, said plainly.
    static func plainWithdrawError(_ e: String?) -> String {
        guard let e, !e.isEmpty else { return "Hyperliquid refused the withdrawal." }
        let l = e.lowercased()
        if l.contains("insufficient") { return "Not enough free USDC on Hyperliquid for this withdrawal. Lower the amount." }
        if l.contains("does not exist") { return "This wallet has no Hyperliquid account yet." }
        if l.contains("restricted") || l.contains("jurisdiction") { return "Hyperliquid isn't available in your region." }
        return plain(e)
    }
}
