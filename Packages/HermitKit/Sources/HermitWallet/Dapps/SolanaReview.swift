import Foundation

// What a Solana transaction from a web app would do: each instruction decoded where the program is one Hermit knows the
// layout of (System, SPL Token, Token-2022, Compute Budget, Associated Token Account, Memo), named where it's a known
// app program, and flagged where it isn't. Simulation then shows the wallet's real balance changes.

public enum SolanaPrograms {
    public static let system = "11111111111111111111111111111111"
    public static let token = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    public static let token2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
    public static let computeBudget = "ComputeBudget111111111111111111111111111111"
    public static let ata = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"
    public static let memo = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
    public static let wsol = "So11111111111111111111111111111111111111112"

    /// App programs shown by name. Every id was checked on mainnet as a live executable account (2026-11-10).
    public static let known: [String: String] = [
        "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4": "Jupiter",
        "PERPHjGBqRHArX4DySjwM6UJHiR3sWAatqfdBS2qQJu": "Jupiter Perps",
        "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8": "Raydium AMM",
        "CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK": "Raydium CLMM",
        "CPMMoo8L3F4NbTegBCKVNunggL7H1ZpdTHKxQB5qKP1C": "Raydium CPMM",
        "LanMV9sAd7wArD4vJFi2qDdfnVhFxYSUg6eADduJ3uj": "Raydium LaunchLab",
        "whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc": "Orca Whirlpools",
        "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo": "Meteora DLMM",
        "cpamdpZCGKUy5JxQXB4dcpGPiikHawvSWAd6mEn1sGG": "Meteora DAMM v2",
        "Eo7WjKq67rjJQSZxS6z3YkapzY3eMj6Xy8X5EQVn5UaB": "Meteora DAMM",
        "6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P": "Pump.fun",
        "pAMMBay6oceH9fJKBRHGP5D4bD4sWpmSwMn52FMfXEA": "PumpSwap",
        "KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD": "Kamino Lend",
        "6LtLpnUFNByNXLyCoK9wA2MykKAmQNZKBdY8s47dehDc": "Kamino Liquidity",
        "dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcn33UH": "Drift",
        "PhoeNiXZ8ByJGLkxNfZRnkUfjvmuYqLR89jjFHGqdXY": "Phoenix",
        "L2TExMFKdjpN9kozasaurPirfHy9P8sbXoAN1qA3S95": "Lighthouse (transaction guard)",
        "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s": "Metaplex Token Metadata",
        "MarBmsSgKXdrN1egZf5sqe1TMai9K1rChYNDJgjq7aD": "Marinade",
        "SPoo1Ku8WFXoNDMHPsrGSTSG1Y47rzgn41SLUNakuHy": "SPL Stake Pool",
        "Stake11111111111111111111111111111111111111": "Stake",
        "AddressLookupTab1e1111111111111111111111111": "Address Lookup Table",
    ]

    public static func name(_ p: String) -> String? {
        switch p {
        case system: "System"
        case token: "SPL Token"
        case token2022: "Token-2022"
        case computeBudget: "Compute Budget"
        case ata: "Associated Token Account"
        case memo: "Memo"
        default: known[p]
        }
    }
}

/// A token balance as simulation reports it (pre/postTokenBalances).
public struct SolanaTokenBalance: Sendable, Equatable {
    public let accountIndex: Int
    public let mint: String
    public let owner: String?
    public let programId: String?
    public let amount: UInt128
    public let decimals: Int
}

/// simulateTransaction's answer, with the balances the review needs.
public struct SolanaSimResult: Sendable {
    public var error: String?
    public var logs: [String]
    public var unitsConsumed: UInt64
    public var fee: UInt64?
    public var preBalances: [UInt64]
    public var postBalances: [UInt64]
    public var preToken: [SolanaTokenBalance]
    public var postToken: [SolanaTokenBalance]
    /// The RPC returned pre/post balances (older nodes don't).
    public var hasBalances: Bool { !preBalances.isEmpty && preBalances.count == postBalances.count }

    public init(json v: JSON) {
        error = v["err"].flatMap { $0.isNull ? nil : String(data: (try? JSONEncoder().encode($0)) ?? Data(), encoding: .utf8) }
        logs = (v["logs"]?.array ?? []).compactMap(\.string)
        unitsConsumed = UInt64(v["unitsConsumed"]?.double ?? 0)
        fee = v["fee"]?.double.map { UInt64($0) }
        preBalances = (v["preBalances"]?.array ?? []).compactMap { $0.double.map { UInt64($0) } }
        postBalances = (v["postBalances"]?.array ?? []).compactMap { $0.double.map { UInt64($0) } }
        func tok(_ j: JSON?) -> [SolanaTokenBalance] {
            (j?.array ?? []).compactMap { t in
                guard let i = t["accountIndex"]?.int, let mint = t["mint"]?.string,
                      let amt = t["uiTokenAmount"]?["amount"]?.string.flatMap({ UInt128($0) }), let d = t["uiTokenAmount"]?["decimals"]?.int else { return nil }
                return SolanaTokenBalance(accountIndex: i, mint: mint, owner: t["owner"]?.string, programId: t["programId"]?.string, amount: amt, decimals: d)
            }
        }
        preToken = tok(v["preTokenBalances"]); postToken = tok(v["postTokenBalances"])
    }
}

/// One balance change for the wallet: SOL or a token, signed.
public struct SolanaBalanceChange: Sendable, Equatable {
    public let symbol: String
    public let mint: String?
    public let decimals: Int
    public let delta: Int128
    public var text: String {
        let mag = UInt128(delta.magnitude)
        return (delta < 0 ? "−" : "+") + Units.format(mag, decimals: decimals, maxFraction: 6) + " " + symbol
    }
}

public struct SolanaReview: Sendable {
    public var title: String
    public var lines: [[String]] = []
    public var warnings: [String] = []
    public var checks: [String] = []
    /// Programs Hermit couldn't name.
    public var unknownPrograms: [String] = []
    public var priorityFeeLamports: UInt64 = 0
    public var changes: [SolanaBalanceChange] = []
    /// Dollar value leaving the wallet (nil when something leaving has no price).
    public var outflowUSD: Decimal? = 0
    public var movesFunds = false
    /// The recipient of a direct transfer, when the transaction is one.
    public var payee: String?
    /// What the decoded instructions send out of the wallet directly (used when there's no simulation).
    public var directLamports: UInt64 = 0
    public var directStableUSD: Decimal = 0
    public var directUnpriced = false

    /// Dollar value of the direct transfers alone; nil when one has no price.
    public func directOutflowUSD(chain: Chain, solPrice: Double?) -> Decimal? {
        if chain.isTestnet { return 0 }
        if directUnpriced { return nil }
        var total = directStableUSD
        if directLamports > 0 {
            guard let p = solPrice else { return nil }
            total += (Decimal(string: Units.format(UInt128(directLamports), decimals: 9)) ?? 0) * Decimal(p)
        }
        return total
    }
}

public enum SolanaDecoder {
    static func u64(_ d: [UInt8], _ at: Int) -> UInt64? {
        guard d.count >= at + 8 else { return nil }
        return d[at..<at + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
    static func u32(_ d: [UInt8], _ at: Int) -> UInt32? {
        guard d.count >= at + 4 else { return nil }
        return d[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }
    public static func short(_ s: String) -> String { s.count > 12 ? "\(s.prefix(4))…\(s.suffix(4))" : s }
    static func sol(_ lamports: UInt64) -> String { Units.format(UInt128(lamports), decimals: 9, maxFraction: 9) + " SOL" }

    /// Symbols for mints Hermit knows (its token table and wrapped SOL); anything else is shown by address.
    public static func symbol(_ mint: String, chain: Chain) -> (String, Bool) {
        if mint == SolanaPrograms.wsol { return ("wSOL", true) }
        if let t = (chain.isTestnet ? Chain.solanaDevnet : Chain.solana).tokens.first(where: { $0.address == mint }) { return (t.symbol, true) }
        return ("token \(short(mint))", false)
    }

    /// Decodes every instruction. `keys` is the full account list; `tokenInfo` maps account index to its mint and decimals
    /// (from simulation), so plain Transfer amounts can be shown in tokens.
    public static func review(_ m: SolanaWireMessage, keys: [SolanaPublicKey], wallet: SolanaPublicKey, chain: Chain,
                              tokenInfo: [Int: SolanaTokenBalance] = [:]) -> SolanaReview {
        var r = SolanaReview(title: "Solana transaction")
        let me = wallet.description
        func key(_ i: Int) -> String { i < keys.count ? keys[i].description : "?" }
        func acct(_ ix: SolanaCompiledInstruction, _ n: Int) -> String? { n < ix.accounts.count ? key(ix.accounts[n]) : nil }
        func who(_ s: String?) -> String { guard let s else { return "?" }; return s == me ? "you" : short(s) }
        /// A token account's owner when simulation reported it, else the token account itself.
        func holder(_ ix: SolanaCompiledInstruction, _ n: Int) -> String? {
            guard n < ix.accounts.count else { return nil }
            return tokenInfo[ix.accounts[n]]?.owner ?? key(ix.accounts[n])
        }
        func amountText(_ raw: UInt64, decimals: Int?, mint: String?) -> String {
            guard let decimals else { return "\(raw) units" }
            let sym = mint.map { symbol($0, chain: chain).0 } ?? "tokens"
            return "\(Units.format(UInt128(raw), decimals: decimals, maxFraction: 6)) \(sym)"
        }
        /// A token amount leaving directly: known stablecoins count 1:1, anything else has no price.
        func direct(_ raw: UInt64, _ decimals: Int?, _ mint: String?) {
            guard let decimals, let mint, case let (sym, true) = symbol(mint, chain: chain), TokenTable.stableSymbols.contains(sym) else {
                r.directUnpriced = true; return
            }
            r.directStableUSD += Decimal(string: Units.format(UInt128(raw), decimals: decimals)) ?? 0
        }
        var cuLimit: UInt32?, cuPrice: UInt64?
        var summary: [String] = []
        var named: [String] = []
        for (n, ix) in m.instructions.enumerated() {
            let p = key(ix.programIndex)
            let d = ix.data
            switch p {
            case SolanaPrograms.computeBudget:
                if m.version == .v1 { r.warnings.append("This v1 transaction carries Compute Budget instructions; they do nothing in v1."); continue }
                switch d.first {
                case 2: cuLimit = u32(d, 1)
                case 3: cuPrice = u64(d, 1)
                default: break
                }
            case SolanaPrograms.system:
                let tag = u32(d, 0)
                switch tag {
                case 2:
                    let lamports = u64(d, 4) ?? 0
                    let from = acct(ix, 0), to = acct(ix, 1)
                    r.lines.append(["Send", "\(sol(lamports)) to \(who(to))"])
                    summary.append("Send \(sol(lamports))")
                    if from == me, to != me { r.movesFunds = true; r.payee = r.payee ?? to; r.directLamports += lamports }
                case 0:
                    let lamports = u64(d, 4) ?? 0
                    r.lines.append(["Create account", "\(who(acct(ix, 1))), funded with \(sol(lamports))"])
                case 1:
                    let target = acct(ix, 0)
                    r.lines.append(["Assign", "\(who(target)) to program \(short(Base58.encode(Array(d.dropFirst(4).prefix(32)))))"])
                    if target == me { r.warnings.append("This hands control of your wallet account to another program. Only a scam asks for this.") }
                case 4:
                    r.lines.append(["Durable nonce", short(acct(ix, 0) ?? "?")])
                    if n == 0 { r.warnings.append("This transaction uses a durable nonce: it doesn't expire, so it can be sent much later.") }
                default:
                    r.lines.append(["System", "instruction \(tag.map(String.init) ?? "?")"])
                }
            case SolanaPrograms.token, SolanaPrograms.token2022:
                let t22 = p == SolanaPrograms.token2022
                let prog = t22 ? "Token-2022" : "Token"
                switch d.first {
                case 3: // Transfer
                    let amt = u64(d, 1) ?? 0, src = ix.accounts.first, owner = acct(ix, 2)
                    let info = src.flatMap { tokenInfo[$0] }
                    let text = amountText(amt, decimals: info?.decimals, mint: info?.mint)
                    r.lines.append(["Send", "\(text) to \(who(holder(ix, 1)))"])
                    summary.append("Send \(text)")
                    if owner == me, holder(ix, 1) != me { r.movesFunds = true; r.payee = r.payee ?? holder(ix, 1); direct(amt, info?.decimals, info?.mint) }
                case 12: // TransferChecked
                    let amt = u64(d, 1) ?? 0, dec = d.count > 9 ? Int(d[9]) : nil, owner = acct(ix, 3)
                    let text = amountText(amt, decimals: dec, mint: acct(ix, 1))
                    r.lines.append(["Send", "\(text) to \(who(holder(ix, 2)))"])
                    summary.append("Send \(text)")
                    if owner == me, holder(ix, 2) != me { r.movesFunds = true; r.payee = r.payee ?? holder(ix, 2); direct(amt, dec, acct(ix, 1)) }
                case 26 where t22 && d.count > 1 && d[1] == 1: // TransferCheckedWithFee
                    let amt = u64(d, 2) ?? 0, dec = d.count > 10 ? Int(d[10]) : nil, fee = u64(d, 11) ?? 0
                    let text = amountText(amt, decimals: dec, mint: acct(ix, 1))
                    r.lines.append(["Send", "\(text) to \(who(holder(ix, 2))), fee \(amountText(fee, decimals: dec, mint: acct(ix, 1)))"])
                    summary.append("Send \(text)")
                    if acct(ix, 3) == me, holder(ix, 2) != me { r.movesFunds = true; r.payee = r.payee ?? holder(ix, 2); direct(amt, dec, acct(ix, 1)) }
                case 4, 13: // Approve, ApproveChecked
                    let checked = d.first == 13
                    let amt = u64(d, 1) ?? 0
                    let delegate = acct(ix, checked ? 2 : 1)
                    let info = ix.accounts.first.flatMap { tokenInfo[$0] }
                    let mint = checked ? acct(ix, 1) : info?.mint
                    let dec = checked ? (d.count > 9 ? Int(d[9]) : nil) : info?.decimals
                    let unlimited = amt == .max
                    let text = unlimited ? "Unlimited \(mint.map { symbol($0, chain: chain).0 } ?? "tokens")" : amountText(amt, decimals: dec, mint: mint)
                    r.lines.append(["Approve", "\(who(delegate)) may spend \(text)"])
                    summary.append(unlimited ? "Approve unlimited spending" : "Approve \(text)")
                    r.warnings.append(unlimited
                        ? "Unlimited delegate: \(who(delegate)) could move this whole token balance, now and later, until you revoke it."
                        : "\(who(delegate)) becomes a delegate and can move up to \(text) from this account without asking again.")
                case 5:
                    r.lines.append(["Revoke", "delegate on \(short(acct(ix, 0) ?? "?"))"])
                case 6: // SetAuthority
                    let types = ["mint tokens", "freeze accounts", "account owner", "close account"]
                    let kind = d.count > 1 && Int(d[1]) < types.count ? types[Int(d[1])] : "authority \(d.count > 1 ? Int(d[1]) : -1)"
                    let newAuth = d.count >= 35 && d[2] == 1 ? Base58.encode(Array(d[3..<35])) : nil
                    r.lines.append(["Set authority", "\(kind) of \(short(acct(ix, 0) ?? "?")) to \(newAuth.map(who) ?? "nobody")"])
                    if acct(ix, 1) == me, newAuth != me {
                        r.warnings.append("This gives the \(kind) authority of one of your token accounts to \(newAuth.map(who) ?? "nobody"). You can't undo it.")
                    }
                case 9: // CloseAccount
                    let dest = acct(ix, 1)
                    r.lines.append(["Close account", "\(short(acct(ix, 0) ?? "?")), rent to \(who(dest))"])
                    if acct(ix, 2) == me, dest != me { r.warnings.append("This closes one of your token accounts and sends its SOL deposit to \(who(dest)), not you.") }
                case 8, 15:
                    let amt = u64(d, 1) ?? 0
                    let info = ix.accounts.first.flatMap { tokenInfo[$0] }
                    r.lines.append(["Burn", amountText(amt, decimals: d.first == 15 && d.count > 9 ? Int(d[9]) : info?.decimals, mint: acct(ix, 1) ?? info?.mint)])
                case 17: r.lines.append(["Sync wrapped SOL", short(acct(ix, 0) ?? "?")])
                case 1, 16, 18: r.lines.append(["Open token account", short(acct(ix, 0) ?? "?")])
                default: r.lines.append([prog, "instruction \(d.first.map(String.init) ?? "?")"])
                }
            case SolanaPrograms.ata:
                let owner = acct(ix, 2), mint = acct(ix, 3)
                r.lines.append(["Token account", "create for \(who(owner)), \(mint.map { symbol($0, chain: chain).0 } ?? "?")"])
            case SolanaPrograms.memo:
                r.lines.append(["Memo", String(decoding: d.prefix(120), as: UTF8.self)])
            default:
                if let name = SolanaPrograms.name(p) {
                    if !named.contains(name) { named.append(name); r.lines.append(["App", name]) }
                } else if !r.unknownPrograms.contains(p) {
                    r.unknownPrograms.append(p)
                    r.lines.append(["Program", "\(short(p)) (unknown)"])
                }
            }
        }
        if m.version == .v1 {
            r.priorityFeeLamports = m.config?.priorityFeeLamports ?? 0
        } else if let price = cuPrice {
            let nonBudget = m.instructions.filter { key($0.programIndex) != SolanaPrograms.computeBudget }.count
            let limit = UInt64(cuLimit ?? UInt32(min(200_000 * max(nonBudget, 1), 1_400_000)))
            r.priorityFeeLamports = (limit * price + 999_999) / 1_000_000
        }
        if !r.unknownPrograms.isEmpty {
            r.warnings.append("Hermit doesn't know \(r.unknownPrograms.count == 1 ? "this program" : "these programs"): \(r.unknownPrograms.map(short).joined(separator: ", ")). Only approve if you trust the site.")
        }
        r.title = named.first.map { name in summary.isEmpty ? name : "\(name): \(summary[0])" } ?? summary.first ?? (r.unknownPrograms.isEmpty ? "Solana transaction" : "Unknown Solana transaction")
        return r
    }

    /// The wallet's SOL and token changes from a simulation. `keys` is the full account list.
    public static func changes(_ s: SolanaSimResult, keys: [SolanaPublicKey], wallet: SolanaPublicKey, chain: Chain) -> [SolanaBalanceChange] {
        var out: [SolanaBalanceChange] = []
        if s.hasBalances, let i = keys.firstIndex(of: wallet), i < s.preBalances.count {
            let delta = Int128(s.postBalances[i]) - Int128(s.preBalances[i])
            if delta != 0 { out.append(SolanaBalanceChange(symbol: "SOL", mint: nil, decimals: 9, delta: delta)) }
        }
        let me = wallet.description
        var byMint: [String: (Int128, Int)] = [:]
        for t in s.preToken where t.owner == me { byMint[t.mint, default: (0, t.decimals)].0 -= Int128(t.amount) }
        for t in s.postToken where t.owner == me {
            let cur = byMint[t.mint] ?? (0, t.decimals)
            byMint[t.mint] = (cur.0 + Int128(t.amount), t.decimals)
        }
        for (mint, (delta, dec)) in byMint.sorted(by: { $0.key < $1.key }) where delta != 0 {
            out.append(SolanaBalanceChange(symbol: symbol(mint, chain: chain).0, mint: mint, decimals: dec, delta: delta))
        }
        return out
    }

    /// Dollar value of what leaves the wallet: SOL at its price, known stablecoins 1:1. nil when an outflow has no price.
    public static func outflowUSD(_ changes: [SolanaBalanceChange], chain: Chain, solPrice: Double?) -> Decimal? {
        if chain.isTestnet { return 0 }
        var total: Decimal = 0
        for c in changes where c.delta < 0 {
            let amt = Decimal(string: Units.format(UInt128(c.delta.magnitude), decimals: c.decimals)) ?? 0
            if c.mint == nil || c.mint == SolanaPrograms.wsol {
                guard let p = solPrice else { return nil }
                total += amt * Decimal(p)
            } else if TokenTable.stableSymbols.contains(c.symbol) {
                total += amt
            } else { return nil }
        }
        return total
    }

    /// Token-2022 mint extensions that change what a transfer does: transfer fee, transfer hook, permanent delegate,
    /// pausable, non-transferable. `data` is the mint account.
    public static func mintExtensionWarnings(_ data: [UInt8], symbol: String) -> [String] {
        guard data.count > 166, data[165] == 1 else { return [] }
        var out: [String] = []
        var i = 166
        while i + 4 <= data.count {
            let type = Int(data[i]) | Int(data[i + 1]) << 8, len = Int(data[i + 2]) | Int(data[i + 3]) << 8
            let v = i + 4
            guard v + len <= data.count else { break }
            let val = Array(data[v..<v + len])
            switch type {
            case 1 where len >= 108:   // TransferFeeConfig: newer fee at 90 (epoch u64, maximum u64, basis points u16)
                let bps = Int(val[106]) | Int(val[107]) << 8
                if bps > 0 { out.append("\(symbol) is a Token-2022 token with a \(Double(bps) / 100)% transfer fee, withheld from every transfer.") }
            case 12 where len >= 32:
                if val.contains(where: { $0 != 0 }) {
                    out.append("\(symbol) has a permanent delegate (\(short(Base58.encode(val)))) that can move or burn anyone's balance at any time.")
                }
            case 14 where len >= 64:
                let prog = Array(val[32..<64])
                if prog.contains(where: { $0 != 0 }) { out.append("\(symbol) runs a transfer hook program (\(short(Base58.encode(prog)))) on every transfer, which can block it.") }
            case 9: out.append("\(symbol) can't be transferred (non-transferable).")
            case 26: out.append("\(symbol) is pausable: its issuer can freeze all transfers.")
            default: break
            }
            i = v + len
        }
        return out
    }

    /// Sign-In with Solana message text (the wallet-standard format), built from the site's input.
    public static func signInMessage(domain: String, address: String, input: JSON) -> String {
        var s = "\(domain) wants you to sign in with your Solana account:\n\(address)"
        if let st = input["statement"]?.string, !st.isEmpty { s += "\n\n\(st)" }
        var f: [String] = []
        if let v = input["uri"]?.string { f.append("URI: \(v)") }
        if let v = input["version"]?.string { f.append("Version: \(v)") }
        if let v = input["chainId"]?.string { f.append("Chain ID: \(v)") }
        if let v = input["nonce"]?.string { f.append("Nonce: \(v)") }
        if let v = input["issuedAt"]?.string { f.append("Issued At: \(v)") }
        if let v = input["expirationTime"]?.string { f.append("Expiration Time: \(v)") }
        if let v = input["notBefore"]?.string { f.append("Not Before: \(v)") }
        if let v = input["requestId"]?.string { f.append("Request ID: \(v)") }
        if let rs = input["resources"]?.array, !rs.isEmpty { f.append("Resources:" + rs.compactMap(\.string).map { "\n- \($0)" }.joined()) }
        if !f.isEmpty { s += "\n\n" + f.joined(separator: "\n") }
        return s
    }
}

extension SolanaClient {
    /// simulateTransaction exactly as the site built it: no signature check, its own blockhash.
    public func simulateDapp(_ tx: SolanaWireTransaction) async throws -> SolanaSimResult {
        let r = try await rpc.call("simulateTransaction", [.string(Data(tx.serialized).base64EncodedString()),
                                                          ["encoding": "base64", "sigVerify": false, "replaceRecentBlockhash": false, "commitment": "confirmed"]])
        guard let v = r["value"] else { throw WalletError.badResponse("simulate") }
        return SolanaSimResult(json: v)
    }

    /// Raw account data for several accounts (nil where missing).
    public func accountsData(_ keys: [String]) async throws -> [String: [UInt8]] {
        guard !keys.isEmpty else { return [:] }
        let r = try await rpc.call("getMultipleAccounts", [.array(keys.map { .string($0) }), ["encoding": "base64", "commitment": "confirmed"]])
        var out: [String: [UInt8]] = [:]
        for (k, a) in zip(keys, r["value"]?.array ?? []) {
            if let s = a["data"]?[0]?.string, let d = Data(base64Encoded: s) { out[k] = [UInt8](d) }
        }
        return out
    }

    public func sendRaw(_ tx: SolanaWireTransaction, skipPreflight: Bool) async throws -> String {
        let r = try await rpc.call("sendTransaction", [.string(Data(tx.serialized).base64EncodedString()),
                                                      ["encoding": "base64", "skipPreflight": .bool(skipPreflight), "preflightCommitment": "confirmed", "maxRetries": 5]])
        guard let sig = r.string else { throw WalletError.badResponse("sendTransaction") }
        return sig
    }
}
