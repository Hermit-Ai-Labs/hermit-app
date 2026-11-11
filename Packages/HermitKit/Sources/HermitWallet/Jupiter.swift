import Foundation

/// Buying and selling a Solana token inside Hermit, no website in between: Jupiter's free swap API gives the quote and
/// builds the transaction; HermitUI checks the token (Jupiter's verified list, or the audit Jupiter's search reports for
/// one that isn't), shows the review, and Hermit signs with the wallet's key on this device and sends it to the chain itself.
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
        let body = try JSONSerialization.jsonObject(with: d)
        // An object instead of a list is Jupiter saying why (a rate limit, usually), not "no such token".
        guard let list = body as? [[String: Any]] else {
            let o = body as? [String: Any]
            if let m = (o?["error"] as? String) ?? (o?["message"] as? String), m.lowercased().contains("rate") { throw Error.rateLimited }
            throw Error.bad((o?["error"] as? String) ?? (o?["message"] as? String) ?? "token search")
        }
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
        // The quote must be for exactly what was asked: these mints, this input amount, exact in. Anything else and the
        // review would show one token while the transaction swaps another.
        guard j["inputMint"] as? String == input.mint, j["outputMint"] as? String == output.mint, inA == amount,
              (j["swapMode"] as? String ?? "ExactIn") == "ExactIn" else { throw Error.bad("a quote for a different swap") }
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

    // MARK: Checking Jupiter's transaction

    /// Jupiter's swap program (v6).
    static let program = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"
    /// The programs a Jupiter swap calls directly. Anything else and Hermit doesn't sign.
    static let allowedPrograms: Set<String> = [program, SolanaPrograms.computeBudget, SolanaPrograms.system, SolanaPrograms.token,
                                               SolanaPrograms.token2022, SolanaPrograms.ata]
    /// SOL the transaction may send by itself beyond a SOL input, and the most it may set as priority fee: 0.01 SOL each.
    static let maxExtraLamports: UInt64 = 10_000_000
    /// How far the wallet's SOL may fall beyond the quote in the test run: network and priority fees plus rent for new
    /// token accounts (0.015 SOL).
    static let feeSlackLamports: Int128 = 15_000_000

    /// Reads Jupiter's transaction before anything is signed. This wallet pays the fee and is the only signer, every
    /// program is one a swap uses, no token account's owner or delegate changes, closed accounts pay back to this wallet,
    /// and the SOL it sends or spends on priority stays within the quote. Throws `WalletError.blocked` otherwise.
    static func checkTransaction(_ m: SolanaWireMessage, wallet: SolanaPublicKey, quote q: Quote) throws {
        func refuse(_ why: String) -> WalletError {
            .blocked("Jupiter's transaction doesn't match this swap: \(why). Nothing was signed.")
        }
        guard m.feePayer == wallet else { throw refuse("another account pays its fee") }
        guard m.numRequiredSignatures == 1 else { throw refuse("it needs another signer") }
        var sent: UInt128 = 0
        var cuLimit: UInt64? = nil, cuPrice: UInt64 = 0
        for ix in m.instructions {
            let p = m.staticKeys[ix.programIndex].description
            guard allowedPrograms.contains(p) else { throw refuse("it calls a program a swap doesn't use (\(SolanaDecoder.short(p)))") }
            let d = ix.data
            switch p {
            case SolanaPrograms.computeBudget:
                if d.first == 2, let v = SolanaDecoder.u32(d, 1) { cuLimit = UInt64(v) }
                if d.first == 3, let v = SolanaDecoder.u64(d, 1) { cuPrice = v }
            case SolanaPrograms.system:
                // Only Transfer (2) and CreateAccount (0), both with the lamports at byte 4. Assign and the rest never.
                guard let kind = SolanaDecoder.u32(d, 0), kind == 0 || kind == 2, let lamports = SolanaDecoder.u64(d, 4) else {
                    throw refuse("it does more than a swap (System instruction \(SolanaDecoder.u32(d, 0).map { String($0) } ?? "?"))")
                }
                sent += UInt128(lamports)
            case SolanaPrograms.token, SolanaPrograms.token2022:
                switch d.first {
                case 17?: break   // SyncNative: wrapped SOL catches up with its lamports
                case 9?:          // CloseAccount: account, destination, owner
                    guard ix.accounts.count >= 2, ix.accounts[1] == 0 else { throw refuse("it closes a token account into another wallet") }
                default:
                    throw refuse("it does more than a swap (SPL Token instruction \(d.first.map { String($0) } ?? "?"))")
                }
            case SolanaPrograms.ata:
                // Create (no data or 0) and CreateIdempotent (1) only.
                guard d.isEmpty || d == [0] || d == [1] else { throw refuse("it does more than a swap (token account instruction)") }
            default:
                break   // Jupiter's own route; the test run checks what it does
            }
        }
        let solIn: UInt128 = q.input.mint == solMint ? UInt128(q.inAmount) : 0
        guard sent <= solIn + UInt128(maxExtraLamports) else { throw refuse("it sends more SOL than the swap needs") }
        let priority: UInt128
        if m.version == .v1 {
            priority = UInt128(m.config?.priorityFeeLamports ?? 0)
        } else {
            let nonBudget = m.instructions.filter { m.staticKeys[$0.programIndex].description != SolanaPrograms.computeBudget }.count
            let limit = cuLimit ?? UInt64(min(200_000 * max(nonBudget, 1), 1_400_000))
            priority = (UInt128(limit) * UInt128(cuPrice) + 999_999) / 1_000_000
        }
        guard priority <= UInt128(maxExtraLamports) else { throw refuse("its priority fee is over 0.01 SOL") }
    }

    /// Compares a test run (simulation) of the transaction with the quote. The wallet gives at most `inAmount` of the input,
    /// gets at least the quote's minimum (after slippage) of the output, and no other token leaves it. SOL and wrapped SOL
    /// count as one balance, with `feeSlackLamports` of room. Returns false when the node reported no balances to compare.
    static func checkSimulation(_ s: SolanaSimResult, keys: [SolanaPublicKey], wallet: SolanaPublicKey, quote q: Quote) throws -> Bool {
        if let e = s.error { throw WalletError.blocked("The swap would fail on Solana: \(plainChainError(e)). Nothing was signed.") }
        guard s.hasBalances else { return false }
        var native: Int128 = 0
        var tokens: [String: Int128] = [:]
        for c in SolanaDecoder.changes(s, keys: keys, wallet: wallet, chain: .solana) {
            if let mint = c.mint, mint != SolanaPrograms.wsol { tokens[mint, default: 0] += c.delta } else { native += c.delta }
        }
        let inAmount = Int128(q.inAmount)
        let keep = UInt128(10_000 - min(max(q.slippageBps, 0), 10_000))
        let minOut = Int128(UInt128(q.outAmount) * keep / 10_000)
        let solIn = q.input.mint == solMint, solOut = q.output.mint == solMint
        func mismatch(_ why: String) -> WalletError {
            .blocked("A test run of Jupiter's transaction doesn't match the quote: \(why). Nothing was signed.")
        }
        let nativeFloor: Int128 = (solIn ? -inAmount : 0) + (solOut ? minOut : 0) - feeSlackLamports
        guard native >= nativeFloor else { throw mismatch(solOut ? "you'd get less SOL than quoted" : "it takes more SOL than quoted") }
        if !solOut { guard (tokens[q.output.mint] ?? 0) >= minOut else { throw mismatch("you'd get less \(q.output.symbol) than quoted") } }
        for (mint, delta) in tokens {
            let floor: Int128 = mint == q.input.mint ? -inAmount : mint == q.output.mint ? minOut : 0
            guard delta >= floor else {
                throw mismatch(mint == q.input.mint ? "it takes more \(q.input.symbol) than quoted" : "another token would leave your wallet")
            }
        }
        return true
    }

    /// What Face ID or Touch ID says it's for: "Sell PUMP on Solana" when the swap pays out USDC or SOL for another
    /// token, else "Buy PUMP on Solana".
    public static func reason(_ q: Quote) -> String {
        let cash: Set<String> = [usdcMint, solMint]
        return cash.contains(q.output.mint) && !cash.contains(q.input.mint) ? "Sell \(q.input.symbol) on Solana" : "Buy \(q.output.symbol) on Solana"
    }

    /// A Solana error in plain words. Custom error 6001 (0x1771) is Jupiter's slippage check.
    static func plainChainError(_ e: String) -> String {
        (e.contains("Custom") && e.contains("6001")) || e.contains("0x1771") ? "the price moved past the slippage limit, try again" : e
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
    /// Runs a Jupiter quote: Jupiter builds the transaction, Hermit reads it and runs it once on Solana as a test
    /// (Jupiter.checkTransaction, Jupiter.checkSimulation), then signs it with the wallet's key (Touch ID or Face ID on
    /// this device) and sends it. Returns the signature once it's confirmed. A transaction that does anything but this
    /// swap is never signed.
    /// The caller records the spend toward the daily limit (TradeBuy does, after this returns), so this doesn't.
    /// Sent but not confirmed in time throws `WalletError.pending`, so the user doesn't buy twice.
    public func executeJupiter(_ q: Jupiter.Quote, walletID: UUID) async throws -> String {
        guard allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == walletID }), let me = SolanaPublicKey(w.solanaAddress) else {
            throw WalletError.vault("That wallet is gone.")
        }
        let raw = try await Jupiter.transaction(for: q, user: w.solanaAddress)
        let tx = try SolanaWireTransaction.parse(raw)
        try Jupiter.checkTransaction(tx.message, wallet: me, quote: q)
        let client = SolanaClient(url: Chain.solana.rpc)
        let sim: SolanaSimResult
        do { sim = try await client.simulateDapp(tx) } catch {
            throw WalletError.blocked("Hermit couldn't test the swap on Solana, so it wasn't signed. Try again in a moment.")
        }
        // The wallet is the fee payer (checked above), so it is static key 0 and the static keys are enough here.
        // A node that reports no balances leaves only the checks on the transaction itself.
        _ = try Jupiter.checkSimulation(sim, keys: tx.message.staticKeys, wallet: me, quote: q)
        let signed = try await dappSolanaSign(walletID: walletID, tx, reason: Jupiter.reason(q))
        let sig = try await client.sendRaw(signed, skipPreflight: false)
        let status: (Bool, UInt64, String?)
        do { status = try await client.waitForConfirmation(sig) } catch WalletError.timeout {
            throw WalletError.pending(hash: sig, explorer: Chain.solana.explorerURL(tx: sig)?.absoluteString)
        }
        // Confirmed as failed: a Solana transaction is all or nothing, so only the network fee was paid.
        guard status.0 else {
            throw WalletError.blocked("The swap failed on Solana, so nothing was swapped. Only the network fee was paid. Transaction \(SolanaDecoder.short(sig)).")
        }
        Task { await refreshBalances(chains: [.solana]) }
        return sig
    }
}
