import Foundation
import HermitCore

/// A swap the assistant prepared for the user to review. Nothing has moved; the Swap sheet opens prefilled and the
/// user taps Review, sees the approval sheet and approves with Face ID (or doesn't).
public struct SwapIntent: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let from: Chain
    public let fromSymbol: String
    public let to: IntentsPlace
    public let toSymbol: String
    public let amount: String
    public let origin: ActionOrigin
    /// The policy's verdict at preparation time (re-checked on Review with the live quote).
    public let verdict: PolicyVerdict
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// Wallet tools the on-device model (and Hermit 1.2) can call. Names and parameters follow the tool contract
/// (hermit-lab/train/hermit_tools.json): `get_balances`, `prepare_swap`; plus `get_quote` for a priced answer without
/// opening anything. Quotes come from NEAR Intents (1Click). The assistant only prepares: `prepare_swap` runs the
/// spending policy as `.agent` and hands a `SwapIntent` to the UI, which still needs the user's approval.
@MainActor
public final class WalletTools {
    public let service: WalletService
    public var oneClick: OneClick
    /// Set by the app: opens the Swap review for a prepared intent.
    public var presentSwap: (@MainActor (SwapIntent) -> Void)?

    public init(service: WalletService, oneClick: OneClick = OneClick()) { self.service = service; self.oneClick = oneClick }

    /// OpenAI-style function definitions, the same shape as hermit_tools.json.
    public static let definitionsJSON = #"""
    [
      {"type": "function", "function": {"name": "get_balances", "description": "Get the user's wallet holdings: a list of {symbol, chain, amount, usd}, NEAR included. Optionally filter to one chain.", "parameters": {"type": "object", "properties": {"chain": {"type": "string", "description": "Optional chain filter, e.g. 'ethereum', 'base', 'arbitrum', 'bsc', 'solana', 'near'."}}, "required": []}}},
      {"type": "function", "function": {"name": "get_quote", "description": "Get a live NEAR Intents (1Click) quote for a swap or bridge without preparing anything: amount out, dollar values, fee and time. Chains: ethereum, base, arbitrum, bsc, polygon, monad, solana, near, bitcoin (destination only), hyperliquid (USDC destination only).", "parameters": {"type": "object", "properties": {"from_symbol": {"type": "string"}, "from_chain": {"type": "string"}, "to_symbol": {"type": "string"}, "to_chain": {"type": "string"}, "amount": {"type": "number", "description": "Amount of from_symbol."}}, "required": ["from_symbol", "from_chain", "to_symbol", "to_chain", "amount"]}}},
      {"type": "function", "function": {"name": "prepare_swap", "description": "Prepare a swap or bridge (best of NEAR Intents and Relay) and open the Swap/Bridge review screen for the user to approve. Nothing is executed by this call. Output always goes to the user's own address.", "parameters": {"type": "object", "properties": {"from_symbol": {"type": "string"}, "from_chain": {"type": "string"}, "to_symbol": {"type": "string"}, "to_chain": {"type": "string"}, "amount": {"type": "number", "description": "Amount of from_symbol to swap."}}, "required": ["from_symbol", "from_chain", "to_symbol", "to_chain", "amount"]}}}
    ]
    """#
    public static let names: Set<String> = ["get_balances", "get_quote", "prepare_swap"]
    /// The route name in tool results and step lines.
    public static let intentsRoute = "NEAR Intents"

    /// "base", "bsc", "near", "btc"… to a place.
    public static func place(_ name: String) -> IntentsPlace? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        switch n {
        case "bitcoin", "btc": return .bitcoin
        case "hyperliquid", "hl", "hypercore": return .hyperliquid
        case "bsc", "bnb", "bnb chain", "binance smart chain": return .chain(.bnb)
        case "eth", "ethereum", "mainnet": return .chain(.ethereum)
        case "arb", "arbitrum", "arbitrum one": return .chain(.arbitrum)
        case "pol", "polygon", "matic": return .chain(.polygon)
        case "sol", "solana": return .chain(.solana)
        case "near", "near protocol": return .chain(.near)
        default: return Chain.mainnets.first { $0.id == n || $0.name.lowercased() == n }.map { .chain($0) }
        }
    }

    /// Runs a tool and returns its JSON result (errors are JSON too, so the model can explain them).
    public func call(_ name: String, arguments: [String: Any]) async -> String {
        do {
            switch name {
            case "get_balances": return try await balances(chain: arguments["chain"] as? String)
            case "get_quote": return try await quote(arguments, prepare: false)
            case "prepare_swap": return try await quote(arguments, prepare: true)
            default: return Self.json(["error": "unknown tool \(name)"])
            }
        } catch {
            return Self.json(["error": (error as? LocalizedError)?.errorDescription ?? "\(error)"])
        }
    }

    public func call(_ name: String, argumentsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        return await call(name, arguments: args)
    }

    func balances(chain: String?) async throws -> String {
        guard let w = service.selected else { return Self.json(["holdings": [Any](), "note": "No wallet on this device yet."]) }
        var chains = Chain.mainnets
        if let c = chain, !c.isEmpty {
            guard let p = Self.place(c), let ch = p.chain else { return Self.json(["error": "Unknown chain \(c)."]) }
            chains = [ch]
        }
        async let tokensA = try? oneClick.tokens()
        let r = await service.fetchBalances(for: w, chains: chains)
        let tokens = await tokensA ?? []
        var rows: [[String: Any]] = []
        for c in chains {
            for b in r.balances[c.id] ?? [] where b.amount > 0 {
                let amount = Units.format(b.amount, decimals: b.decimals)
                var row: [String: Any] = ["symbol": b.symbol, "chain": c.id, "amount": amount]
                if let t = IntentsAssets.token(b.token?.symbol, at: .chain(c), in: tokens, hermitToken: b.token), let px = t.price,
                   let a = Double(amount) { row["usd"] = (a * px * 100).rounded() / 100 }
                rows.append(row)
            }
        }
        var out: [String: Any] = ["holdings": rows]
        if w.nearAccount == nil { out["near"] = "No NEAR account on this wallet yet; the user can add one in Wallets." }
        else { out["near_account"] = w.nearAccount! }
        if !r.failed.isEmpty { out["unreachable"] = r.failed.map(\.id) }
        return Self.json(out)
    }

    func quote(_ a: [String: Any], prepare: Bool) async throws -> String {
        guard let fs = a["from_symbol"] as? String, let fc = (a["from_chain"] as? String).flatMap(Self.place),
              let ts = a["to_symbol"] as? String, let tc = (a["to_chain"] as? String).flatMap(Self.place),
              let amt = (a["amount"] as? NSNumber)?.doubleValue ?? (a["amount"] as? String).flatMap(Double.init), amt > 0 else {
            return Self.json(["error": "Need from_symbol, from_chain, to_symbol, to_chain and a positive amount."])
        }
        guard let from = fc.chain else { return Self.json(["error": "Hermit can't send from \(fc.name); it can only receive there."]) }
        let tokens = try await oneClick.tokens()
        let fromToken = try service.resolveToken(fs, on: from)
        let decimals = fromToken?.decimals ?? from.nativeDecimals
        let value = try Units.parse(String(format: "%.\(min(decimals, 12))f", amt), decimals: decimals)
        let own = service.ownAddress(tc, walletID: nil)
        // Hermit holds no BTC key: a Bitcoin quote is priced against a placeholder recipient (dry only, never shown), and
        // prepare_swap to Bitcoin always stops at the policy because the assistant may not choose a payee.
        let recipient = own ?? (tc == .bitcoin ? IntentsAssets.dryQuoteBitcoinRecipient : nil)
        let req = try service.intentsRequest(walletID: nil, from: from, fromToken: fromToken, to: tc, toSymbol: ts, amount: value,
                                             recipient: recipient, dry: true, tokens: tokens)
        let q = try await oneClick.quote(req)
        // Amounts rounded for reading (a 24-decimal NEAR amount was echoed digit for digit); the route is named as the
        // user should hear it, so a NEAR Intents quote is never called Relay.
        let out_ = Units.approx(q.amountOutFormatted)
        var out: [String: Any] = [
            "route": Self.intentsRoute, "from": "\(q.amountInFormatted) \(fs.uppercased()) on \(from.name)",
            "to": "about \(out_) \(ts.uppercased()) on \(tc.name)", "amount_out": out_,
            "seconds": q.seconds, "fee_bps": q.appFeeBps, "signature_verified": q.signatureValid,
        ]
        if let u = q.amountInUSD { out["amount_in_usd"] = (u * 100).rounded() / 100 }
        if let u = q.amountOutUSD { out["amount_out_usd"] = (u * 100).rounded() / 100 }
        // What the swap costs all in (fees and spread), so it isn't read as gas.
        if let i = q.amountInUSD, let o = q.amountOutUSD { out["total_cost_usd"] = (max(0, i - o) * 100).rounded() / 100 }
        guard prepare else { return Self.json(out) }

        let verdict = service.policy.evaluate(usd: q.amountInUSD, payee: own == nil ? (recipient ?? "", .evm) : nil, origin: .agent)
        out["policy"] = verdict.decision.rawValue
        if verdict.decision == .block {
            out["status"] = "blocked"; out["reasons"] = verdict.blocks
            out["note"] = "Nothing was prepared. Tell the user why."
            return Self.json(out)
        }
        let intent = SwapIntent(from: from, fromSymbol: fromToken?.symbol ?? from.nativeSymbol, to: tc, toSymbol: ts, amount: Units.format(value, decimals: decimals),
                                origin: .agent, verdict: verdict)
        presentSwap?(intent)
        out["status"] = "prepared_for_review"
        if !verdict.warnings.isEmpty { out["warnings"] = verdict.warnings }
        out["note"] = "Nothing has moved. The Swap review is open with this \(Self.intentsRoute) quote; the user approves it with Face ID or cancels."
        return Self.json(out)
    }

    static func json(_ o: [String: Any]) -> String {
        (try? JSONSerialization.safeData(withJSONObject: o, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
