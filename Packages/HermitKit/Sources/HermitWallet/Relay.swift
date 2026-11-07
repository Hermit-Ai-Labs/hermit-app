import Foundation

/// Relay (relay.link, docs.relay.link/references/api/get-quote): swaps and bridges between chains, including straight
/// into Hyperliquid (chain 1337, perps USDC) and out of Solana. A quote is a list of steps; each step is either EVM
/// transactions (approve, deposit) or Solana instructions. Hermit signs them on this phone, in order.
public enum Relay {
    public static let api = URL(string: "https://api.relay.link")!

    /// Where money can go or come from: a chain id on Relay plus how to name its currencies.
    public enum Place: Hashable, Sendable {
        case chain(Chain)
        case hyperliquid

        public var relayID: Int? {
            switch self {
            case .hyperliquid: return 1337
            case .chain(let c):
                if c.kind == .solana { return c.isTestnet ? nil : 792_703_809 }
                guard let id = c.chainId, !c.isTestnet, c.id != "robinhood" else { return nil }
                return Int(id)
            }
        }
        public var name: String { switch self { case .hyperliquid: "Hyperliquid"; case .chain(let c): c.name } }
        public var logo: String { switch self { case .hyperliquid: "hyperliquid"; case .chain(let c): c.logo } }

        /// Relay's id for a token here: contract or mint, or the native placeholder.
        func currency(_ token: Token?) -> String {
            switch self {
            case .hyperliquid: return "0x00000000000000000000000000000000"   // perps USDC
            case .chain(let c):
                if let token { return token.address }
                return c.kind == .solana ? "11111111111111111111111111111111" : "0x0000000000000000000000000000000000000000"
            }
        }
    }

    public enum Step: Sendable {
        case evm(chainID: Int, calls: [ContractCall])
        case solana(instructions: [SolanaInstruction])
    }

    public struct Quote: Sendable {
        public let steps: [Step]
        public let amountOut: String          // formatted, e.g. "19.97"
        public let amountOutUSD: Double?
        public let feeUSD: Double
        public let seconds: Int
        public let requestID: String?
    }

    public static func quote(from: Place, fromToken: Token?, to: Place, toToken: Token?, amount: UInt128,
                             user: String, recipient: String) async throws -> Quote {
        guard let o = from.relayID, let d = to.relayID else { throw WalletError.blocked("Relay doesn't cover this network.") }
        let body: [String: Any] = ["user": user, "recipient": recipient, "originChainId": o, "destinationChainId": d,
                                   "originCurrency": from.currency(fromToken), "destinationCurrency": to.currency(toToken),
                                   "tradeType": "EXACT_INPUT", "amount": String(amount)]   // no "referrer": Relay wants an API key for it
        var req = URLRequest(url: api.appending(path: "quote"), timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let m = j["message"] as? String ?? "No route right now."
            let l = m.lowercased()
            throw WalletError.blocked(l.contains("amount too low") || l.contains("too small") ? "That amount is too small to move. Try a little more."
                                      : l.contains("no routes") || l.contains("unsupported") ? "No route for this right now. Try USDC or another network." : m)
        }
        var steps: [Step] = []
        var requestID: String?
        for s in j["steps"] as? [[String: Any]] ?? [] {
            requestID = requestID ?? s["requestId"] as? String
            let label = (s["id"] as? String) == "approve" ? "Allow Relay to move \(fromToken?.symbol ?? "it")" : "Move funds with Relay"
            for item in s["items"] as? [[String: Any]] ?? [] {
                guard let dd = item["data"] as? [String: Any] else { continue }
                if let ins = dd["instructions"] as? [[String: Any]] {
                    steps.append(.solana(instructions: try ins.map(solanaInstruction)))
                } else if let to = (dd["to"] as? String).flatMap(EVMAddress.init), let cid = dd["chainId"] as? Int {
                    let value = (dd["value"] as? String).flatMap { UInt128($0) } ?? 0
                    let call = ContractCall(to: to, data: [UInt8](hex: dd["data"] as? String ?? "0x") ?? [], value: value, label: label)
                    if case .evm(let c, let calls) = steps.last, c == cid { steps[steps.count - 1] = .evm(chainID: c, calls: calls + [call]) }
                    else { steps.append(.evm(chainID: cid, calls: [call])) }
                }
            }
        }
        guard !steps.isEmpty else { throw WalletError.badResponse("Relay returned nothing to sign") }
        let det = j["details"] as? [String: Any]
        let out = det?["currencyOut"] as? [String: Any]
        let fees = (j["fees"] as? [String: [String: Any]] ?? [:]).filter { ["gas", "relayer", "app"].contains($0.key) }
            .reduce(0.0) { $0 + (Double($1.value["amountUsd"] as? String ?? "") ?? 0) }
        return Quote(steps: steps, amountOut: out?["amountFormatted"] as? String ?? "?",
                     amountOutUSD: Double(out?["amountUsd"] as? String ?? ""), feeUSD: fees,
                     seconds: det?["timeEstimate"] as? Int ?? 30, requestID: requestID)
    }

    static func solanaInstruction(_ i: [String: Any]) throws -> SolanaInstruction {
        guard let p = (i["programId"] as? String).flatMap(SolanaPublicKey.init) else { throw WalletError.badResponse("Relay Solana program") }
        let keys = try (i["keys"] as? [[String: Any]] ?? []).map { k -> SolanaAccountMeta in
            guard let pk = (k["pubkey"] as? String).flatMap(SolanaPublicKey.init) else { throw WalletError.badResponse("Relay Solana account") }
            return SolanaAccountMeta(pk, signer: k["isSigner"] as? Bool ?? false, writable: k["isWritable"] as? Bool ?? false)
        }
        return SolanaInstruction(program: p, accounts: keys, data: [UInt8](hex: i["data"] as? String ?? "") ?? [])
    }

    /// "pending", "success", "failure"… for a request, to show the arriving state.
    public static func status(_ requestID: String) async -> String? {
        var c = URLComponents(url: api.appending(path: "intents/status/v2"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "requestId", value: requestID)]
        guard let (d, _) = try? await URLSession.shared.data(from: c.url!),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["status"] as? String
    }
}

extension WalletService {
    /// Runs a Relay quote's steps in order: EVM transactions through executeCalls, Solana instructions as one transaction.
    public func execute(_ q: Relay.Quote, walletID: UUID) async throws -> String {
        var last = ""
        for step in q.steps {
            switch step {
            case .evm(let cid, let calls):
                guard let chain = Chain.mainnets.first(where: { $0.chainId == UInt64(cid) }) else { throw WalletError.blocked("Unknown network \(cid)") }
                last = try await executeCalls(walletID: walletID, chain: chain, calls).last ?? last
            case .solana(let ins):
                last = try await executeSolana(walletID: walletID, chain: .solana, instructions: ins, reason: "Move funds with Relay")
            }
        }
        return last
    }

    /// Signs and sends arbitrary Solana instructions (simulated by the node on send), with a priority fee.
    public func executeSolana(walletID: UUID, chain: Chain, instructions: [SolanaInstruction], reason: String) async throws -> String {
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }), let from = SolanaPublicKey(w.solanaAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let client = sol(chain)
        let (bh, _) = try await client.latestBlockhash()
        let body = [SolanaInstruction.setComputeUnitLimit(300_000), SolanaInstruction.setComputeUnitPrice(50_000)] + instructions
        let unsigned = SolanaTransaction(message: SolanaMessage(payer: from, instructions: body, recentBlockhash: bh))
        let tx = try await vault.withKey(w.id, kind: .solana, reason: reason) { seed in var t = unsigned; try t.sign(ed25519Seed: seed); return t }
        guard tx.verifySignature(), tx.message == unsigned.message else { throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.") }
        let sig = try await client.send(tx)
        let (ok, _, _) = try await client.waitForConfirmation(sig)
        guard ok else { throw WalletError.blocked("The Solana transaction failed (\(sig)).") }
        Task { await refreshBalances(chains: [chain]) }
        return sig
    }
}
