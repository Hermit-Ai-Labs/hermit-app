import Foundation
import HermitCore
import HermitWallet
import HermitCloud

/// Hermit's agent tools (hermit_tools.json) run here on the phone, for the on-device model and for Private Cloud.
/// Read tools answer with real data (Hyperliquid's public API, this phone's wallets, NEAR Intents, DeFiLlama yields)
/// or an error, never a guess. Money tools only prepare: they return an action whose tap opens the normal approval
/// sheet (Face ID), and the spending policy runs first.
public struct HermitToolbox: AgentToolbox {
    /// Who asked, for the approval sheet's "Asked for by" line.
    public var label: String
    public init(label: String = "Hermit Private Cloud") { self.label = label }

    public static let onDevice = HermitToolbox(label: "Hermit on this device")

    public func run(_ name: String, arguments: String) async -> ToolOutcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        do {
            switch name {
            case "calculator": return json(["result": Calc.text(try Calc.evaluate(args["expression"] as? String ?? ""))])
            case "position_math": return json(try Self.positionMath(args))
            case "get_price": return json(try await Self.price(args["symbol"] as? String ?? ""))
            case "search_markets": return json(["markets": try await Self.searchMarkets(args["query"] as? String ?? "")])
            case "get_balances", "get_quote", "prepare_swap":
                // The wallet's own tools: balances include NEAR, quotes come from NEAR Intents (best of Intents and
                // Relay for prepare_swap), and prepare_swap runs the spending policy and opens the prefilled Swap review.
                return ToolOutcome(content: await WalletsViewModel.shared.tools.call(name, arguments: args))
            case "hyperliquid_account": return json(try await Self.hlAccount())
            case "get_yields": return json(["pools": await Self.yields(asset: args["asset"] as? String, chain: args["chain"] as? String)])
            case "prepare_trade": return try await Self.prepareTrade(args, label: label)
            case "prepare_send": return try await Self.prepareSend(args)
            case "prepare_multisend": return try await Self.prepareMultisend(args, origin: .agent)
            case "prepare_deposit": return try await Self.prepareDeposit(args)
            case "prepare_withdraw": return try await Self.prepareWithdraw(args, label: label)
            case "open_add_funds":
                let hl = (args["goal"] as? String) == "hyperliquid"
                return ToolOutcome(content: #"{"status":"button_shown","screen":"add_funds","goal":"\#(hl ? "hyperliquid" : "wallet")","note":"The user taps it to open Add funds."}"#,
                                   action: Action(hl ? "Add funds to Hyperliquid" : "Add funds", primary: true, symbol: "plus.circle", open: hl ? "fund-hyperliquid" : "fund-wallet"))
            default: return json(["error": "Unknown tool \(name)"])
            }
        } catch {
            return json(["error": "\(error)"])
        }
    }

    private func json(_ v: Any) -> ToolOutcome { Self.json(v) }

    static func json(_ v: Any) -> ToolOutcome {
        // isValidJSONObject first: an invalid object (say a nil boxed as Any) raises an exception instead of throwing.
        guard JSONSerialization.isValidJSONObject(v) else { return ToolOutcome(content: #"{"error":"tool returned no data"}"#) }
        let d = (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data("{}".utf8)
        return ToolOutcome(content: String(decoding: d, as: UTF8.self))
    }

    struct ToolError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }

    // MARK: Markets (Hyperliquid public info API)

    struct Ctx { let coin: String; let mark: Double; let prev: Double; let funding: Double; let volume: Double; let maxLev: Int }

    /// `dex` "xyz" is trade.xyz on Hyperliquid: stocks and indexes (xyz:NVDA, xyz:TSLA…).
    static func contexts(dex: String? = nil) async throws -> [Ctx] {
        var req = URLRequest(url: Hyperliquid.api.appending(path: "info"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data((dex.map { #"{"type":"metaAndAssetCtxs","dex":"\#($0)"}"# } ?? #"{"type":"metaAndAssetCtxs"}"#).utf8)
        let (d, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: d) as? [Any], arr.count == 2,
              let uni = (arr[0] as? [String: Any])?["universe"] as? [[String: Any]], let ctxs = arr[1] as? [[String: Any]] else {
            throw ToolError("Hyperliquid didn't answer")
        }
        func n(_ v: Any?) -> Double { (v as? String).flatMap(Double.init) ?? (v as? NSNumber)?.doubleValue ?? 0 }
        return zip(uni, ctxs).compactMap { u, c in
            guard let coin = u["name"] as? String, u["isDelisted"] as? Bool != true else { return nil }
            return Ctx(coin: coin, mark: n(c["markPx"]), prev: n(c["prevDayPx"]), funding: n(c["funding"]), volume: n(c["dayNtlVlm"]),
                       maxLev: u["maxLeverage"] as? Int ?? 1)
        }
    }

    static func price(_ symbol: String) async throws -> [String: Any] {
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "XYZ:", with: "")
        // Crypto first, then stocks and indexes on trade.xyz (NVDA, TSLA, SPX…).
        var hit = try await contexts().first(where: { $0.coin.uppercased() == sym })
        if hit == nil { hit = try? await contexts(dex: "xyz").first(where: { $0.coin.uppercased() == "XYZ:" + sym }) }
        guard let c = hit, c.mark > 0 else {
            throw ToolError("No Hyperliquid market for \(sym). Answer from what you know instead, and say there's no live price here.")
        }
        let change: Any = c.prev > 0 ? (((c.mark / c.prev - 1) * 100) * 100).rounded() / 100 : NSNull()
        let stock = c.coin.hasPrefix("xyz:")
        return ["symbol": stock ? String(c.coin.dropFirst(4)) : c.coin, "price": c.mark, "change_24h_pct": change,
                "source": stock ? "trade.xyz perp on Hyperliquid (tracks the stock)" : "Hyperliquid mark price"]
    }

    static func searchMarkets(_ query: String) async throws -> [[String: Any]] {
        let words = query.uppercased().split(separator: " ").map(String.init).filter { !["PERP", "PERPS", "USD", "USDC", "POOL", "SPOT"].contains($0) }
        let all = try await contexts()
        let hits = all.filter { c in words.isEmpty || words.contains { c.coin.uppercased().contains($0) } }
            .sorted { $0.volume > $1.volume }.prefix(8)
        return hits.map { h -> [String: Any] in ["name": "\(h.coin)-PERP", "type": "perp", "price": h.mark, "funding_hourly_pct": h.funding * 100,
                                             "volume_24h_usd": h.volume.rounded(), "max_leverage": h.maxLev] }
    }

    // MARK: Wallets (this phone)

    @MainActor static func hlAccount() async throws -> [String: Any] {
        let hl = HyperliquidStore.shared
        guard hl.hasWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        await hl.refresh()
        guard let a = hl.account else { throw ToolError("Couldn't read the Hyperliquid account") }
        return ["account_value": a.accountValue, "margin_used": a.marginUsed, "available_usdc": a.withdrawable,
                "positions": a.positions.map { p -> [String: Any] in
                    ["coin": p.coin, "side": p.size > 0 ? "long" : "short", "size": abs(p.size), "entry": p.entry,
                     "liquidation": p.liquidation.map { $0 as Any } ?? NSNull(), "unrealised_pnl": p.pnl, "leverage": p.leverage]
                },
                "open_orders": a.orders.map { o -> [String: Any] in ["coin": o.coin, "side": o.isBuy ? "buy" : "sell", "price": o.price, "size": o.size] }]
    }

    @MainActor static func yields(asset: String?, chain: String?) async -> [[String: Any]] {
        let feed = YieldsFeed.shared
        await feed.refresh()
        let a = asset?.uppercased(), c = chain?.lowercased()
        return feed.pools
            .filter { p in (a == nil || p.symbol.uppercased().contains(a!)) && (c == nil || EarnData.chainName(p.chain).lowercased().contains(c!) || p.chain.lowercased() == c) }
            .sorted { $0.apy > $1.apy }.prefix(8)
            .map { p -> [String: Any] in
                ["protocol": p.name, "chain": EarnData.chainName(p.chain), "asset": p.symbol, "apy_pct": (p.apy * 100).rounded() / 100, "tvl_usd": p.tvlUsd.rounded()]
            }
    }

    static func findChain(_ name: String) -> Chain? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        let alias = ["bsc": "bnb", "bnbchain": "bnb", "eth": "ethereum", "mainnet": "ethereum", "arb": "arbitrum", "matic": "polygon", "sol": "solana"]
        let key = alias[n] ?? n
        return Chain.mainnets.first { $0.id == key || $0.name.lowercased().replacingOccurrences(of: " ", with: "") == key || $0.name.lowercased().hasPrefix(key) }
    }

    // MARK: Maths

    static func positionMath(_ a: [String: Any]) throws -> [String: Any] {
        func n(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue ?? (a[k] as? String).flatMap(Double.init) }
        guard let side = a["side"] as? String, let entry = n("entry"), let size = n("size_usd"), let lev = n("leverage"), entry > 0, lev > 0 else {
            throw ToolError("Needs side, entry, size_usd and leverage")
        }
        let long = side == "long", mm = n("maintenance_margin") ?? 0
        let margin = size / lev
        // Isolated liquidation: the move that eats the margin, less maintenance.
        let liq = long ? entry * (1 - 1 / lev + mm) : entry * (1 + 1 / lev - mm)
        // Keys and rounding as in training (sim.position_math).
        func r(_ v: Double, _ dp: Double) -> Double { (v * pow(10, dp)).rounded() / pow(10, dp) }
        var out: [String: Any] = ["side": side, "entry": entry, "size_usd": size, "leverage": lev, "margin": r(margin, 2),
                                  "quantity": r(size / entry, 6), "liquidation_price": r(liq, liq < 1 ? 6 : 2),
                                  "distance_to_liq_pct": r(abs(liq - entry) / entry * 100, 2)]
        if let p = n("price") {
            let pnl = (long ? p - entry : entry - p) * size / entry
            out["price"] = p; out["pnl"] = r(pnl, 2); out["roe_pct"] = r(pnl / margin * 100, 2)
        }
        return out
    }

    // MARK: Money moves (prepare only)

    /// What a prepare_ tool tells the model: the review is open and nothing has happened (the training format's shape).
    static func prepared(_ kind: String) -> String {
        #"{"status":"review_opened","kind":"\#(kind)","executed":false,"note":"Waiting for the user to approve with \#(Device.bio)."}"#
    }

    @MainActor static func prepareTrade(_ a: [String: Any], label: String = "Hermit Private Cloud") async throws -> ToolOutcome {
        func n(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
        guard let coin = (a["coin"] as? String)?.uppercased(), let side = a["side"] as? String, let size = n("size_usd"), let levIn = n("leverage") else {
            throw ToolError("Needs coin, side, size_usd and leverage")
        }
        let hl = HyperliquidStore.shared
        guard hl.hasWallet, let trader = hl.trader() else { throw ToolError("No wallet on \(Device.here) to trade with") }
        guard let asset = await hl.asset(coin) else { throw ToolError("\(coin) isn't tradable on Hyperliquid") }
        guard let mark = try await contexts().first(where: { $0.coin.uppercased() == coin })?.mark, mark > 0 else { throw ToolError("No price for \(coin)") }
        await hl.refresh()
        let lev = max(1, min(Int(levIn), asset.maxLeverage))
        let margin = size / Double(lev)
        let available = hl.account?.withdrawable ?? 0
        guard available >= margin else {
            return ToolOutcome(content: #"{"prepared":false,"error":"Not enough margin: \#(String(format: "%.2f", available)) USDC available, \#(String(format: "%.2f", margin)) needed"}"#,
                               action: Action("Add funds to Hyperliquid", primary: true, symbol: "plus.circle", open: "fund-hyperliquid"))
        }
        // The same spending policy as sends and swaps: the margin is what's at stake, so it counts toward the daily limit
        // and the assistant's per-move cap. A block stops here; no review sheet opens.
        let policy = WalletsViewModel.shared.service.policy
        let verdict = policy.evaluateAgentTrade(marginUSD: margin)
        if verdict.decision == .block {
            return Self.json(["status": "blocked", "reasons": verdict.blocks, "note": "Nothing was prepared. Tell the user why."])
        }
        let isBuy = side == "long"
        let limitIn = (a["order_type"] as? String) == "limit" ? n("limit_price") : nil
        let px = limitIn ?? mark
        let qty = Hyperliquid.roundSize(size / px, szDecimals: asset.szDecimals)
        guard qty > 0 else { throw ToolError("Size too small for \(coin)") }
        let price = limitIn.map { Hyperliquid.roundPrice($0, szDecimals: asset.szDecimals) } ?? Hyperliquid.marketPrice(mid: mark, isBuy: isBuy, asset: asset)
        let order = Hyperliquid.Order(asset: asset, isBuy: isBuy, price: price, size: qty, tif: limitIn == nil ? .ioc : .gtc,
                                      takeProfit: n("take_profit"), stopLoss: n("stop_loss"))
        let liq = isBuy ? px * (1 - 0.9 / Double(lev)) : px * (1 + 0.9 / Double(lev))
        var lines: [[String]] = [["Market", "\(coin) perp on Hyperliquid"], ["Side", isBuy ? "Long" : "Short"],
                                 ["Size", "\(Hyperliquid.wire(qty)) \(coin), about $\(String(format: "%.2f", qty * px))"],
                                 ["Margin", "$\(String(format: "%.2f", margin)) at \(lev)x"],
                                 [limitIn == nil ? "Worst price" : "Limit price", "$" + Hyperliquid.wire(price)],
                                 ["Liquidation, est.", "$" + String(format: "%.2f", liq)]]
        if let tp = n("take_profit") { lines.append(["Take profit", "$\(tp)"]) }
        if let sl = n("stop_loss") { lines.append(["Stop loss", "$\(sl)"]) }
        lines.append(["Asked for by", "\(label), from your message"])
        let spent = Decimal(margin)
        let approval = Approval(kind: "Hyperliquid order", title: "\(isBuy ? "Long" : "Short") \(coin)", lines: lines,
                                checks: verdict.passed + ["Signed on \(Device.here) with your wallet's key", "Leveraged trades can lose all their margin"],
                                success: "\(isBuy ? "Long" : "Short") \(coin) sent", warnings: verdict.warnings) {
            let summary = try await trader.place(order, leverage: lev).summary
            policy.limit.record(usd: spent)
            return summary
        }
        return ToolOutcome(content: prepared("trade"), action: Action("Review \(isBuy ? "long" : "short") \(coin)", approval: approval))
    }

    @MainActor static func prepareSend(_ a: [String: Any]) async throws -> ToolOutcome {
        guard let to = a["to_address"] as? String, let amount = (a["amount"] as? NSNumber)?.stringValue ?? a["amount"] as? String,
              let symbol = a["symbol"] as? String else { throw ToolError("Needs to_address, amount and symbol") }
        // No chain the user named: the one where they hold the token, or a question back (never a silent Ethereum).
        let chain: Chain
        switch try await pickChain(a["chain"] as? String, symbol: symbol, candidates: sendChains(symbol: symbol, to: to), doing: "send") {
        case .chain(let c): chain = c
        case .ask(let out): return out
        }
        let vm = WalletsViewModel.shared
        guard let w = vm.wallets.first else { throw ToolError("No wallet on \(Device.here) yet") }
        // The spending policy for an assistant-prepared send: daily limit, the per-move cap, priced tokens only.
        let sym = symbol.uppercased()
        let usd: Double? = try await sendValueUSD(symbol: sym, amount: Double(amount))
        let verdict = vm.service.policy.evaluateAgentSend(usd: usd, payee: (to, chain.kind))
        if verdict.decision == .block {
            return Self.json(["status": "blocked", "reasons": verdict.blocks, "note": "Nothing was prepared. Tell the user why."])
        }
        let p = try await vm.prepareSend(from: w.record.id.uuidString, chain: chain, to: to, amount: amount, token: sym)
        var approval = try vm.approval(for: p)
        approval.warnings += verdict.warnings
        // The network goes back to the model: it may have been picked here, not named by the user.
        var out = json(["status": "review_opened", "kind": "send", "executed": false, "network": chain.name, "amount": "\(p.amountText) \(p.symbol)",
                        "note": "Waiting for the user to approve with \(Device.bio)."])
        out.action = Action("Review send", approval: approval)
        return out
    }

    /// Dollar value of a send for the policy: stablecoins at $1, everything else at the Hyperliquid mark price.
    static func sendValueUSD(symbol: String, amount: Double?) async throws -> Double? {
        guard let amount, amount > 0 else { return nil }
        if ["USDC", "USDT", "USDT0", "DAI", "USDE", "USDC.E"].contains(symbol) { return amount }
        let mark = (try? await contexts())?.first { $0.coin.uppercased() == symbol }?.mark
        return mark.map { $0 * amount }
    }

}

/// A small exact-enough calculator for the model's `calculator` tool: + - * / ** ( ), sqrt ln log10 exp abs min max round.
enum Calc {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// How the calculator reports a result, as in training (hermit_fmt.calc_str): whole numbers without a
    /// decimal point, otherwise up to 10 significant digits.
    static func text(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.10g", v)
        if s.contains("e") {
            s = String(format: "%.12f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func evaluate(_ s: String) throws -> Double {
        var p = Parser(Array(s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: " , ")))
        let v = try p.expr()
        guard p.i == p.c.count else { throw Failure(description: "Unexpected '\(String(p.c[p.i...]))'") }
        guard v.isFinite else { throw Failure(description: "Result is not finite") }
        return v
    }

    struct Parser {
        let c: [Character]; var i = 0
        init(_ c: [Character]) { self.c = c.filter { $0 != " " } }
        mutating func eat(_ ch: Character) -> Bool { if i < c.count, c[i] == ch { i += 1; return true }; return false }
        mutating func expr() throws -> Double {
            var v = try term()
            while true { if eat("+") { v += try term() } else if eat("-") { v -= try term() } else { return v } }
        }
        mutating func term() throws -> Double {
            var v = try power()
            while true {
                if i + 1 < c.count, c[i] == "*", c[i + 1] == "*" { return v }
                if eat("*") { v *= try power() } else if eat("/") { v /= try power() } else { return v }
            }
        }
        mutating func power() throws -> Double {
            let b = try unary()
            if i + 1 < c.count, c[i] == "*", c[i + 1] == "*" { i += 2; return pow(b, try power()) }
            if eat("^") { return pow(b, try power()) }
            return b
        }
        mutating func unary() throws -> Double {
            if eat("-") { return -(try unary()) }
            if eat("+") { return try unary() }
            return try atom()
        }
        mutating func atom() throws -> Double {
            if eat("(") { let v = try expr(); guard eat(")") else { throw Failure(description: "Missing )") }; return v }
            let start = i
            if i < c.count, c[i].isLetter {
                while i < c.count, c[i].isLetter || c[i].isNumber { i += 1 }
                let name = String(c[start..<i]).lowercased()
                if name == "pi" { return .pi }
                if name == "e" { return M_E }
                guard eat("(") else { throw Failure(description: "Unknown name \(name)") }
                var args = [try expr()]
                while eat(",") { args.append(try expr()) }
                guard eat(")") else { throw Failure(description: "Missing )") }
                switch (name, args.count) {
                case ("sqrt", 1): return sqrt(args[0])
                case ("ln", 1): return log(args[0])
                case ("log10", 1), ("log", 1): return log10(args[0])
                case ("exp", 1): return exp(args[0])
                case ("abs", 1): return abs(args[0])
                case ("min", _) where !args.isEmpty: return args.min()!
                case ("max", _) where !args.isEmpty: return args.max()!
                case ("round", 1): return args[0].rounded()
                case ("round", 2): let f = pow(10, args[1].rounded()); return (args[0] * f).rounded() / f
                default: throw Failure(description: "Unknown function \(name)")
                }
            }
            while i < c.count, c[i].isNumber || c[i] == "." || c[i] == "_" { i += 1 }
            if i < c.count, c[i] == "e" || c[i] == "E", i + 1 < c.count, c[i + 1].isNumber || c[i + 1] == "-" || c[i + 1] == "+" {
                i += 2; while i < c.count, c[i].isNumber { i += 1 }
            }
            guard i > start, let v = Double(String(c[start..<i]).replacingOccurrences(of: "_", with: "")) else {
                throw Failure(description: "Expected a number")
            }
            return v
        }
    }
}
