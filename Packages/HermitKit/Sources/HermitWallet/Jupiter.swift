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
    }

    public struct Quote: Sendable {
        public let input: Token, output: Token
        public let inAmount, outAmount: UInt64
        public let priceImpactPct: Double
        public let slippageBps: Int
        public let route: [String]
        /// Jupiter's own quote object, handed back when asking for the transaction.
        public let raw: Data
        public var inFormatted: String { Units.format(UInt128(inAmount), decimals: input.decimals, maxFraction: 6) }
        public var outFormatted: String { Units.format(UInt128(outAmount), decimals: output.decimals, maxFraction: 6) }
    }

    public enum Error: Swift.Error, LocalizedError {
        case notVerified(String), rateLimited, bad(String)
        public var errorDescription: String? {
            switch self {
            case .notVerified(let s): "There's no verified \(s) token on Solana, so Hermit won't buy one."
            case .rateLimited: "Jupiter is busy right now. Try again in a few seconds."
            case .bad(let s): "Jupiter didn't answer properly (\(s))."
            }
        }
    }

    /// The token Jupiter marks verified for a symbol, the most traded one when several match. Nil when none is verified.
    public static func verifiedToken(symbol: String) async throws -> Token? {
        var c = URLComponents(string: "\(api)/tokens/v2/search")!
        c.queryItems = [URLQueryItem(name: "query", value: symbol)]
        let d = try await get(c.url!)
        guard let list = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw Error.bad("token search") }
        let matches = list.filter { ($0["symbol"] as? String)?.caseInsensitiveCompare(symbol) == .orderedSame }
            .filter { ($0["isVerified"] as? Bool) == true || (($0["tags"] as? [String]) ?? []).contains("verified") }
            .sorted { (($0["organicScore"] as? Double) ?? 0) > (($1["organicScore"] as? Double) ?? 0) }
        guard let t = matches.first, let mint = t["id"] as? String, let dec = t["decimals"] as? Int else { return nil }
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
    public func executeJupiter(_ q: Jupiter.Quote, walletID: UUID) async throws -> String {
        guard allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }), !w.solanaAddress.isEmpty else { throw WalletError.vault("That wallet is gone.") }
        let raw = try await Jupiter.transaction(for: q, user: w.solanaAddress)
        let tx = try SolanaWireTransaction.parse(raw)
        let signed = try await dappSolanaSign(walletID: walletID, tx, reason: "Buy \(q.output.symbol) on Solana")
        let client = SolanaClient(url: Chain.solana.rpc)
        let sig = try await client.sendRaw(signed, skipPreflight: false)
        let (ok, _, err) = try await client.waitForConfirmation(sig)
        guard ok else { throw WalletError.blocked("The swap failed on Solana (\(err ?? sig)). Nothing was taken.") }
        Task { await refreshBalances(chains: [.solana]) }
        return sig
    }
}
