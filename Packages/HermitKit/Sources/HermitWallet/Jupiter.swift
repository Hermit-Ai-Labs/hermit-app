import Foundation

/// Buying a Solana token inside Hermit, no website in between: Jupiter's free swap API gives the quote and builds the
/// transaction; Hermit checks the token is on Jupiter's verified list, shows the review, signs with the wallet's key on
/// this device and sends it to the chain itself.
public enum Jupiter {
    static let api = "https://lite-api.jup.ag"
    public static let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    public static let solMint = "So11111111111111111111111111111111111111112"

    public struct Token: Sendable, Equatable {
        public let mint, symbol, name: String
        public let decimals: Int
        public let verified: Bool
        public init(mint: String, symbol: String, name: String, decimals: Int, verified: Bool) {
            self.mint = mint; self.symbol = symbol; self.name = name; self.decimals = decimals; self.verified = verified
        }
    }

    public struct Quote: Sendable {
        public let input: Token, output: Token
        public let inAmount, outAmount: UInt64
        /// As Jupiter sends it: a fraction (0.0123 is 1.23%). HermitUI shows it times 100 (shownImpactPercent), so don't rescale it here.
        public let priceImpactPct: Double
        public let slippageBps: Int
        public let route: [String]
        /// Jupiter's own quote object, handed back when asking for the transaction.
        public let raw: Data
        public var inFormatted: String { Units.format(UInt128(inAmount), decimals: input.decimals, maxFraction: 6) }
        public var outFormatted: String { Units.format(UInt128(outAmount), decimals: output.decimals, maxFraction: 6) }
    }

    public enum Error: Swift.Error, LocalizedError {
        case notVerified(String), ambiguous(String), rateLimited, bad(String)
        public var errorDescription: String? {
            switch self {
            case .notVerified(let s): "There's no verified \(s) token on Solana, so Hermit won't buy one."
            case .ambiguous(let s): "More than one verified \(s) token is on Solana. Pick it on Spot or Memes, or paste its mint."
            case .rateLimited: "Jupiter is busy right now. Try again in a few seconds."
            case .bad(let s): "Jupiter didn't answer properly (\(s))."
            }
        }
    }

    /// The token Jupiter marks verified for a symbol, with at least $50k of liquidity. When two of them are close in
    /// liquidity it throws `ambiguous` rather than guess. Nil when none is verified.
    public static func verifiedToken(symbol: String) async throws -> Token? {
        var c = URLComponents(string: "\(api)/tokens/v2/search")!
        c.queryItems = [URLQueryItem(name: "query", value: symbol)]
        let d = try await get(c.url!)
        guard let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw Error.bad("token search") }
        let verified = list.filter { ($0["symbol"] as? String)?.caseInsensitiveCompare(symbol) == .orderedSame }
            .filter { ($0["isVerified"] as? Bool) == true || (($0["tags"] as? [String]) ?? []).contains("verified") }
        let ranked: [(t: [String: Any], score: Double, liquidity: Double)] = verified.map { t in
            (t: t, score: (t["organicScore"] as? Double) ?? 0, liquidity: (t["liquidity"] as? Double) ?? 0)
        }
        let matches = ranked.filter { $0.liquidity >= 50_000 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.liquidity > $1.liquidity }
        if matches.count > 1 && matches[1].liquidity >= 0.5 * matches[0].liquidity { throw Error.ambiguous(symbol) }
        guard let t = matches.first?.t, let mint = t["id"] as? String, let dec = t["decimals"] as? Int else { return nil }
        return Token(mint: mint, symbol: t["symbol"] as? String ?? symbol, name: t["name"] as? String ?? symbol, decimals: dec, verified: true)
    }

    public static let usdc = Token(mint: usdcMint, symbol: "USDC", name: "USD Coin", decimals: 6, verified: true)
    public static let sol = Token(mint: solMint, symbol: "SOL", name: "Solana", decimals: 9, verified: true)

    /// A quote for an exact input amount (base units), 0.5% slippage.
    public static func quote(from input: Token, to output: Token, amount: UInt64, slippageBps: Int = 50) async throws -> Quote {
        var c = URLComponents(string: "\(api)/swap/v1/quote")!
        c.queryItems = [.init(name: "inputMint", value: input.mint), .init(name: "outputMint", value: output.mint),
                        .init(name: "amount", value: String(amount)), .init(name: "slippageBps", value: String(slippageBps))]
        let d = try await get(c.url!)
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let inA = UInt64(j["inAmount"] as? String ?? ""), let outA = UInt64(j["outAmount"] as? String ?? "") else {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw Error.bad(msg ?? "quote")
        }
        let route = (j["routePlan"] as? [[String: Any]] ?? []).compactMap { ($0["swapInfo"] as? [String: Any])?["label"] as? String }
        return Quote(input: input, output: output, inAmount: inA, outAmount: outA,
                     priceImpactPct: Double(j["priceImpactPct"] as? String ?? "") ?? 0, slippageBps: j["slippageBps"] as? Int ?? slippageBps,
                     route: route, raw: d)
    }

    /// The unsigned transaction for a quote, built by Jupiter for this wallet (SOL wrapped and unwrapped as needed).
    public static func transaction(for q: Quote, user: String) async throws -> [UInt8] {
        guard let quoteObj = try JSONSerialization.jsonObject(with: q.raw) as? [String: Any] else { throw Error.bad("quote object") }
        let body = try JSONSerialization.data(withJSONObject: ["quoteResponse": quoteObj, "userPublicKey": user, "wrapAndUnwrapSol": true,
                                                               "dynamicComputeUnitLimit": true, "prioritizationFeeLamports": "auto"])
        var r = URLRequest(url: URL(string: "\(api)/swap/v1/swap")!, timeoutInterval: 25)
        r.httpMethod = "POST"; r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let d = try await send(r)
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let b64 = j["swapTransaction"] as? String,
              let bytes = Data(base64Encoded: b64) else { throw Error.bad("swap transaction") }
        return [UInt8](bytes)
    }

    private static func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(r)
    }

    /// The free API rate-limits; a 429 is retried a few times with a short pause.
    private static func send(_ r: URLRequest) async throws -> Data {
        for attempt in 0..<4 {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 { try? await Task.sleep(for: .milliseconds(800 * (attempt + 1))); continue }
            guard (200..<300).contains(code) else { throw Error.bad("HTTP \(code)") }
            return d
        }
        throw Error.rateLimited
    }
}

extension WalletService {
    /// Runs a Jupiter quote: Jupiter builds the transaction, Hermit parses it, signs it with the wallet's key (Touch ID
    /// or Face ID on this device) and sends it. Returns the signature once it's confirmed.
    /// The caller records the spend toward the daily limit (TradeBuy does, after this returns), so this doesn't.
    /// Sent but not confirmed in time throws `WalletError.pending`, so the user doesn't buy twice.
    public func executeJupiter(_ q: Jupiter.Quote, walletID: UUID) async throws -> String {
        guard allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }), !w.solanaAddress.isEmpty else { throw WalletError.vault("That wallet is gone.") }
        let raw = try await Jupiter.transaction(for: q, user: w.solanaAddress)
        let tx = try SolanaWireTransaction.parse(raw)
        let signed = try await dappSolanaSign(walletID: walletID, tx, reason: "Buy \(q.output.symbol) on Solana")
        let client = SolanaClient(url: Chain.solana.rpc)
        let sig = try await client.sendRaw(signed, skipPreflight: false)
        let status: (Bool, UInt64, String?)
        do { status = try await client.waitForConfirmation(sig) } catch WalletError.timeout {
            throw WalletError.pending(hash: sig, explorer: Chain.solana.explorerURL(tx: sig)?.absoluteString)
        }
        let ok = status.0, err = status.2
        guard ok else { throw WalletError.blocked("The swap failed on Solana (\(err ?? sig)). Nothing was taken.") }
        Task { await refreshBalances(chains: [.solana]) }
        return sig
    }
}
