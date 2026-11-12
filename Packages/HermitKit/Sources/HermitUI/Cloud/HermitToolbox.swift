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

    /// Set by AppModel.pictureInChat: text in this chat was read from a picture, so batch addresses need a checksum.
    @MainActor static var pictureInChat = false

    public func run(_ name: String, arguments: String) async -> ToolOutcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        do {
            switch name {
            case "calculator": return json(["result": Calc.text(try Calc.evaluate(args["expression"] as? String ?? ""))])
            case "position_math":
                // The market's max leverage sets Hyperliquid's maintenance margin: look it up when the model named the coin.
                var maxLev = (args["max_leverage"] as? NSNumber)?.doubleValue
                if maxLev == nil, let coin = args["coin"] as? String, !coin.isEmpty, let c = try? await Self.market(coin) { maxLev = Double(c.maxLev) }
                return json(try Self.positionMath(args, maxLeverage: maxLev))
            case "get_price": return json(try await Self.price(args["symbol"] as? String ?? ""))
            case "search_markets": return json(["markets": try await Self.searchMarkets(args["query"] as? String ?? "")])
            case "get_balances", "get_quote", "prepare_swap":
                // The wallet's own tools: balances include NEAR, quotes come from NEAR Intents (best of Intents and
                // Relay for prepare_swap), and prepare_swap runs the spending policy and opens the prefilled Swap review.
                return ToolOutcome(content: await WalletsViewModel.shared.tools.call(name, arguments: args))
            case "hyperliquid_account": return json(try await Self.hlAccount())
            case "get_yields":
                var out: [String: Any] = ["pools": await Self.yields(asset: args["asset"] as? String, chain: args["chain"] as? String),
                                          "note": "Quote apy_base_pct as the rate and name rewards apart: they can stop. Only pools with can_deposit_in_hermit can be deposited from chat."]
                // Rates from a saved copy (DefiLlama didn't answer): say how old they are, so the reply can too.
                if let at = await YieldsFeed.shared.updated, Date().timeIntervalSince(at) > 3600 {
                    out["rates_as_of_hours_ago"] = Int(Date().timeIntervalSince(at) / 3600)
                }
                return json(out)
            case "prepare_trade": return try await Self.prepareTrade(args, label: label)
            case "prepare_send": return try await Self.prepareSend(args)
            case "prepare_multisend":
                let picture = await Self.pictureInChat
                return try await Self.prepareMultisend(args, origin: .agent, fromPicture: picture)
            case "prepare_deposit": return try await Self.prepareDeposit(args, label: label)
            case "prepare_withdraw": return try await Self.prepareWithdraw(args, label: label)
            case "open_add_funds":
                let hl = (args["goal"] as? String) == "hyperliquid"
                return ToolOutcome(content: #"{"status":"button_shown","screen":"add_funds","goal":"\#(hl ? "hyperliquid" : "wallet")","note":"The user taps it to open Add funds."}"#,
                                   action: Action(hl ? "Add funds to Hyperliquid" : "Add funds", primary: true, symbol: "plus.circle", open: hl ? "fund-hyperliquid" : "fund-wallet"))
            default:
                // The v3 tools (HermitToolbox+V3*.swift): buys, sells, closes and stops, positions and portfolio, token
                // search, addresses and contacts, pages, automations and payment reminders.
                if let out = try await Self.runV3(name, args, label: label) { return out }
                return json(["error": "Unknown tool \(name)"])
            }
        } catch {
            return json(["error": Self.message(error)])
        }
    }

    /// An error in words for the model and the user: WalletError's own text, ToolError's sentence, never the Swift enum
    /// dump (`invalidAddress("0x12")`).
    static func message(_ e: Error) -> String {
        if let d = (e as? LocalizedError)?.errorDescription, !d.isEmpty { return d }
        if let t = e as? ToolError { return t.description }
        if let f = e as? Calc.Failure { return f.description }
        return e.localizedDescription
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

    struct Ctx: Sendable { let coin: String; let mark: Double; let prev: Double; let funding: Double; let volume: Double; let maxLev: Int }

    /// metaAndAssetCtxs per dex for a few seconds, so the price, search and trade calls of one answer share one download.
    actor CtxCache {
        static let shared = CtxCache()
        private var entries: [String: (at: Date, ctxs: [Ctx])] = [:]
        func get(_ dex: String, maxAge: TimeInterval) -> [Ctx]? {
            guard let e = entries[dex], Date().timeIntervalSince(e.at) < maxAge else { return nil }
            return e.ctxs
        }
        func put(_ dex: String, _ ctxs: [Ctx]) { entries[dex] = (at: Date(), ctxs: ctxs) }
    }

    /// `dex` "xyz" is trade.xyz on Hyperliquid: stocks and indexes (xyz:NVDA, xyz:TSLA…). `maxAge` 0 always fetches
    /// (orders price from a fresh mark).
    static func contexts(dex: String? = nil, maxAge: TimeInterval = 5) async throws -> [Ctx] {
        if let hit = await CtxCache.shared.get(dex ?? "", maxAge: maxAge) { return hit }
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
        let out: [Ctx] = zip(uni, ctxs).compactMap { u, c in
            guard let coin = u["name"] as? String, u["isDelisted"] as? Bool != true else { return nil }
            return Ctx(coin: coin, mark: n(c["markPx"]), prev: n(c["prevDayPx"]), funding: n(c["funding"]), volume: n(c["dayNtlVlm"]),
                       maxLev: u["maxLeverage"] as? Int ?? 1)
        }
        await CtxCache.shared.put(dex ?? "", out)
        return out
    }

    /// Hyperliquid lists some memecoins per 1,000 tokens ("kPEPE"): one contract, and its price, is 1,000 PEPE.
    /// The token's own ticker for such a market; nil for every other market.
    static func thousandOf(_ coin: String) -> String? {
        guard coin.count > 1, coin.first == "k", let second = coin.dropFirst().first, second.isUppercase else { return nil }
        return String(coin.dropFirst())
    }

    /// Hyperliquid's own spelling of what the model typed: the exact name (any case), then the 1,000-token market
    /// ("PEPE" finds "kPEPE"), then the trade.xyz stock ("NVDA" finds "xyz:NVDA"). "-PERP" or "/USDC" is dropped first.
    static func resolve(_ input: String, in ctxs: [Ctx]) -> Ctx? {
        var u = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for suffix in ["-PERP", " PERP", "-USDC", "/USDC", "-USD", "/USD"] where u.hasSuffix(suffix) { u = String(u.dropLast(suffix.count)); break }
        guard !u.isEmpty else { return nil }
        if u.hasPrefix("XYZ:") { return ctxs.first { $0.coin.uppercased() == u } }
        return ctxs.first { $0.coin.uppercased() == u } ?? ctxs.first { $0.coin == "k" + u } ?? ctxs.first { $0.coin.uppercased() == "XYZ:" + u }
    }

    /// The Hyperliquid market for a ticker: crypto perps first, then stocks and indexes on trade.xyz (NVDA, TSLA, SPX…).
    static func market(_ input: String, maxAge: TimeInterval = 5) async throws -> Ctx? {
        if !input.uppercased().hasPrefix("XYZ:"), let c = resolve(input, in: try await contexts(maxAge: maxAge)) { return c }
        return resolve(input, in: (try? await contexts(dex: "xyz", maxAge: maxAge)) ?? [])
    }

    static func price(_ symbol: String) async throws -> [String: Any] {
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "XYZ:", with: "")
        guard !sym.isEmpty else { throw ToolError("Needs a symbol") }
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        // Hyperliquid first (crypto, then trade.xyz stocks), then Binance spot, as the tool description says.
        if let c = try? await market(symbol), c.mark > 0 {
            let change: Any = c.prev > 0 ? r2((c.mark / c.prev - 1) * 100) : NSNull()
            if c.coin.hasPrefix("xyz:") {
                return ["symbol": String(c.coin.dropFirst(4)), "price": c.mark, "change_24h_pct": change,
                        "source": "trade.xyz perp on Hyperliquid (tracks the stock)"]
            }
            if let token = thousandOf(c.coin) {
                // kPEPE trades per 1,000 PEPE: one token is the mark / 1,000.
                return ["symbol": token, "price": c.mark / 1000, "change_24h_pct": change, "market": c.coin, "contract_price": c.mark,
                        "source": "Hyperliquid mark price (per token; the market is \(c.coin), 1,000 \(token))"]
            }
            return ["symbol": c.coin, "price": c.mark, "change_24h_pct": change, "source": "Hyperliquid mark price"]
        }
        if let b = await binanceTicker(sym) {
            var change: Any = NSNull()
            if let p = b.change { change = r2(p) }
            return ["symbol": sym, "price": b.price, "change_24h_pct": change, "source": "Binance spot, \(sym)/USDT"]
        }
        throw ToolError("No live price for \(sym) on Hyperliquid or Binance. Answer from what you know instead, and say there's no live price here.")
    }

    /// Binance spot's public 24h ticker for SYMBOL/USDT (no key). data-api.binance.vision serves the same public data
    /// where api.binance.com is blocked by region.
    static func binanceTicker(_ sym: String) async -> (price: Double, change: Double?)? {
        guard sym.range(of: #"^[A-Z0-9]{2,15}$"#, options: .regularExpression) != nil else { return nil }
        for host in ["https://api.binance.com", "https://data-api.binance.vision"] {
            guard let url = URL(string: "\(host)/api/v3/ticker/24hr?symbol=\(sym)USDT"),
                  let res = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
                  (res.1 as? HTTPURLResponse)?.statusCode == 200,
                  let o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any],
                  let p = (o["lastPrice"] as? String).flatMap(Double.init), p > 0 else { continue }
            return (p, (o["priceChangePercent"] as? String).flatMap(Double.init))
        }
        return nil
    }

    static func searchMarkets(_ query: String) async throws -> [[String: Any]] {
        let skip: Set<String> = ["PERP", "PERPS", "USD", "USDC", "POOL", "SPOT"]
        let words = query.uppercased().split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "," })
            .map { w -> String in w.hasSuffix("-PERP") ? String(w.dropLast(5)) : String(w) }
            .filter { !$0.isEmpty && !skip.contains($0) }
        // Stocks and indexes on trade.xyz too; the search still answers when that dex doesn't.
        let crypto = try await contexts()
        let all = crypto + ((try? await contexts(dex: "xyz")) ?? [])
        // Exact names first (PEPE finds kPEPE, NVDA finds xyz:NVDA), then names that start with the word, then the rest,
        // so "ETH" is ETH and not ETHFI. Volume breaks ties.
        func rank(_ c: Ctx) -> Int? {
            guard !words.isEmpty else { return 0 }
            let name = c.coin.uppercased()
            let bare = name.hasPrefix("XYZ:") ? String(name.dropFirst(4)) : name
            let token = thousandOf(c.coin)?.uppercased() ?? bare
            return words.compactMap { (w: String) -> Int? in
                if bare == w || token == w || name == w { return 0 }
                if bare.hasPrefix(w) || token.hasPrefix(w) { return 1 }
                return bare.contains(w) ? 2 : nil
            }.min()
        }
        let ranked: [(c: Ctx, r: Int)] = all.compactMap { c in rank(c).map { (c: c, r: $0) } }
        let hits = ranked.sorted { $0.r != $1.r ? $0.r < $1.r : $0.c.volume > $1.c.volume }.prefix(8).map { $0.c }
        return hits.map { (h: Ctx) -> [String: Any] in
            var o: [String: Any] = ["name": "\(h.coin)-PERP", "type": "perp", "price": h.mark, "funding_hourly_pct": h.funding * 100,
                                    "volume_24h_usd": h.volume.rounded(), "max_leverage": h.maxLev]
            if h.coin.hasPrefix("xyz:") { o["tracks"] = "\(h.coin.dropFirst(4)) on trade.xyz" }
            if let token = thousandOf(h.coin) {
                // One contract is 1,000 tokens: the price is per 1,000, so give the per-token price too.
                o["unit"] = "1000 \(token)"; o["token"] = token; o["price_per_token"] = h.mark / 1000
            }
            return o
        }
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
                "open_orders": a.orders.map { o -> [String: Any] in
                    // A plain order: its limit price and size. A take profit or stop loss: the price it triggers at (its
                    // limit price is only a slippage cap) and, when it covers the whole position, that position's size.
                    guard o.isTrigger else {
                        return ["coin": o.coin, "side": o.isBuy ? "buy" : "sell", "price": o.price, "size": o.size, "order_type": o.orderType, "is_trigger": false]
                    }
                    let whole = o.isPositionTpsl || o.size == 0
                    let held = a.positions.first { $0.coin == o.coin }.map { abs($0.size) }
                    var row: [String: Any] = ["coin": o.coin, "side": o.isBuy ? "buy" : "sell", "price": o.triggerPx > 0 ? o.triggerPx : o.price,
                                              "size": whole ? (held ?? o.size) : o.size, "order_type": o.orderType, "is_trigger": true,
                                              "trigger_condition": o.triggerCondition]
                    if whole { row["whole_position"] = true }
                    return row
                },
                "account_mode": a.mode]
    }

    @MainActor static func yields(asset: String?, chain: String?) async -> [[String: Any]] {
        let feed = YieldsFeed.shared
        await feed.refresh()
        let a = asset?.uppercased(), c = chain?.lowercased()
        // The big lenders first (rates people know; Aave can be deposited from chat), then the lower of today's and the
        // 30-day rate, so a one-day spike or a small synthetic-dollar vault doesn't lead.
        let lenders: Set<String> = ["aave-v3", "kamino-lend", "jupiter-lend", "morpho-blue", "compound-v3", "fluid-lending"]
        func steady(_ p: EarnData.Pool) -> Double { min(p.apy, p.apyMean30d ?? p.apy) }
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        return feed.pools
            .filter { p in (a == nil || p.symbol.uppercased().contains(a!)) && (c == nil || EarnData.chainName(p.chain).lowercased().contains(c!) || p.chain.lowercased() == c) }
            .sorted { (x: EarnData.Pool, y: EarnData.Pool) -> Bool in
                let lx = lenders.contains(x.project), ly = lenders.contains(y.project)
                return lx != ly ? lx : steady(x) > steady(y)
            }
            .prefix(8)
            .map { (p: EarnData.Pool) -> [String: Any] in
                var o: [String: Any] = ["protocol": p.name, "chain": EarnData.chainName(p.chain), "asset": p.symbol, "apy_pct": r2(p.apy),
                                        "tvl_usd": p.tvlUsd.rounded(), "stablecoin": p.stablecoin, "can_deposit_in_hermit": EarnRoute.aave(p) != nil]
                if let v = p.apyBase { o["apy_base_pct"] = r2(v) }
                if let v = p.apyReward, v > 0 { o["apy_reward_pct"] = r2(v) }
                if let v = p.apyMean30d { o["apy_30d_pct"] = r2(v) }
                if let v = p.ilRisk { o["il_risk"] = v }
                if let v = p.poolMeta, !v.isEmpty { o["pool_meta"] = v }
                return o
            }
    }

    static func findChain(_ name: String) -> Chain? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        let alias = ["bsc": "bnb", "bnbchain": "bnb", "eth": "ethereum", "mainnet": "ethereum", "arb": "arbitrum", "matic": "polygon", "sol": "solana"]
        let key = alias[n] ?? n
        return Chain.mainnets.first { $0.id == key || $0.name.lowercased().replacingOccurrences(of: " ", with: "") == key || $0.name.lowercased().hasPrefix(key) }
    }

    // MARK: Maths

    /// "long" or "short" from what the model wrote (Long, buy, sell...). Anything else is an error, never a silent short.
    static func isLong(_ side: String) throws -> Bool {
        switch side.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "long", "buy": return true
        case "short", "sell": return false
        default: throw ToolError("side must be long or short")
        }
    }

    /// Hyperliquid's liquidation price for a position whose margin is notional / leverage: the move that leaves only
    /// the maintenance margin `mm` (a fraction of notional). liq = entry - side * entry * (1/lev - mm) / (1 - side * mm).
    static func liquidation(entry: Double, leverage lev: Double, mm: Double, long: Bool) -> Double {
        let s: Double = long ? 1 : -1
        return max(0, entry - s * entry * (1 / lev - mm) / (1 - s * mm))
    }

    /// `maxLeverage` is the market's (position_math's coin); Hyperliquid's maintenance margin is half the initial
    /// margin at max leverage, 1 / (2 * maxLeverage).
    static func positionMath(_ a: [String: Any], maxLeverage: Double? = nil) throws -> [String: Any] {
        func n(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue ?? (a[k] as? String).flatMap(Double.init) }
        guard let sideIn = a["side"] as? String, let entry = n("entry"), let size = n("size_usd"), let lev = n("leverage"), entry > 0, lev > 0 else {
            throw ToolError("Needs side, entry, size_usd and leverage")
        }
        let long = try isLong(sideIn), side = long ? "long" : "short"
        let maxLev = maxLeverage ?? n("max_leverage")
        let mm: Double
        var note: String?
        if let given = n("maintenance_margin") {
            guard given >= 0, given < 1 else { throw ToolError("maintenance_margin is a fraction, e.g. 0.005 for 0.5%") }
            mm = given
        } else if let m = maxLev, m > 0 {
            mm = 1 / (2 * m)
            if lev > m { note = "This market allows at most \(Int(m))x." }
        } else {
            // Market unknown: as if this leverage were its max, which puts liquidation nearer than it may be (the safe side).
            mm = 1 / (2 * max(lev, 1))
            note = "No coin given, so the maintenance margin assumes this leverage is the market's max. The real liquidation can be further away."
        }
        let margin = size / lev
        let liq = liquidation(entry: entry, leverage: lev, mm: mm, long: long)
        // Keys and rounding as in training (sim.position_math).
        func r(_ v: Double, _ dp: Double) -> Double { (v * pow(10, dp)).rounded() / pow(10, dp) }
        var out: [String: Any] = ["side": side, "entry": entry, "size_usd": size, "leverage": lev, "margin": r(margin, 2),
                                  "quantity": r(size / entry, 6), "liquidation_price": r(liq, liq < 1 ? 6 : 2),
                                  "distance_to_liq_pct": r(abs(liq - entry) / entry * 100, 2), "maintenance_margin_used": r(mm, 6)]
        if let note { out["note"] = note }
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
        guard let coinIn = a["coin"] as? String, let side = a["side"] as? String, let sizeIn = n("size_usd"), let levIn = n("leverage") else {
            throw ToolError("Needs coin, side, size_usd and leverage")
        }
        let isBuy = try isLong(side)
        guard sizeIn > 0, levIn > 0 else { throw ToolError("size_usd and leverage must be positive") }
        // What the app changed so the order can go through. Each one is shown in the review and told to the model, so
        // nothing is changed silently, and the user still approves the exact order.
        var fixes: [String] = []
        let minUSD = 10.0
        var size = sizeIn
        if size < minUSD {
            size = minUSD
            fixes.append("Size raised to a $10 position, Hyperliquid's smallest order (asked for $\(Hyperliquid.wire(sizeIn))).")
        }
        let hl = HyperliquidStore.shared
        guard hl.hasWallet, let trader = hl.trader() else { throw ToolError("No wallet on \(Device.here) to trade with") }
        // Hyperliquid's own spelling ("kPEPE", "xyz:NVDA"): the asset table is keyed by it. A fresh mark, not the cache.
        guard let hit = try await Self.market(coinIn, maxAge: 0) else { throw ToolError("\(coinIn.uppercased()) isn't tradable on Hyperliquid") }
        let coin = hit.coin, mark = hit.mark
        guard let asset = await hl.asset(coin) else { throw ToolError("\(coin) isn't tradable on Hyperliquid") }
        guard mark > 0 else { throw ToolError("No price for \(coin)") }
        await hl.refresh()
        let lev = Int(min(max(levIn, 1), Double(max(asset.maxLeverage, 1))))
        let margin = size / Double(lev)
        let available = hl.account?.withdrawable ?? 0
        guard available >= margin else {
            return ToolOutcome(content: #"{"prepared":false,"error":"Not enough margin: \#(String(format: "%.2f", available)) USDC available, \#(String(format: "%.2f", margin)) needed"}"#,
                               action: Action("Add funds to Hyperliquid", primary: true, symbol: "plus.circle", open: "fund-hyperliquid"))
        }
        // A trade.xyz market ("NVDA" now finds xyz:NVDA) has its own balance in a standard account, as on the Trade page.
        if coin.hasPrefix("xyz:") {
            switch await hl.margin(dex: "xyz") {
            case .shared: break
            case .unknown: throw ToolError("Couldn't read your trade.xyz balance on Hyperliquid. Try again.")
            case .free(let free) where free < margin:
                return Self.json(["status": "blocked", "prepared": false,
                                  "reasons": ["trade.xyz has its own balance: \(String(format: "%.2f", free)) USDC there, \(String(format: "%.2f", margin)) needed"],
                                  "note": "Nothing was prepared. Tell the user why. Moving USDC to trade.xyz from Hermit is coming soon."])
            case .free: break
            }
        }
        // The same spending policy as sends and swaps: the margin is what's at stake, so it counts toward the daily limit
        // and the assistant's per-move cap. A block stops here; no review sheet opens.
        let policy = WalletsViewModel.shared.service.policy
        let verdict = policy.evaluateAgentTrade(marginUSD: margin)
        if verdict.decision == .block {
            return Self.json(["status": "blocked", "reasons": verdict.blocks, "note": "Nothing was prepared. Tell the user why."])
        }
        let limitIn: Double?
        if (a["order_type"] as? String)?.lowercased() == "limit" {
            // Never a silent market order when the user asked for a limit.
            guard let l = n("limit_price"), l > 0 else { throw ToolError("A limit order needs a positive limit_price") }
            limitIn = l
        } else { limitIn = nil }
        let px = limitIn ?? mark
        let tpIn = n("take_profit"), slIn = n("stop_loss")
        if let token = thousandOf(coin), [limitIn, tpIn, slIn].contains(where: { ($0 ?? mark) < mark / 100 }) {
            // A per-token PEPE price given for kPEPE, which is priced per 1,000.
            throw ToolError("\(coin) prices are per 1,000 \(token): the mark is \(Hyperliquid.wire(mark)). Give limit_price, take_profit and stop_loss in that unit.")
        }
        // A take profit or stop loss on the wrong side of the entry would fire at once: put it 2% the right way instead,
        // and say so in the review. Small models get this sign wrong now and then; the order should still be right.
        func off(_ pct: Double) -> Double { Hyperliquid.roundPrice(px * (1 + pct), szDecimals: asset.szDecimals) }
        let money = { (x: Double) in "$" + Hyperliquid.wire(x) }
        var tp = tpIn, sl = slIn
        if let t = tp, t <= 0 || (isBuy ? t <= px : t >= px) {
            tp = off(isBuy ? 0.02 : -0.02)
            fixes.append("Take profit moved to \(money(tp!)), 2% \(isBuy ? "above" : "below") the price: \(money(t)) was on the wrong side and would have closed the order at once.")
        }
        if let l = sl, l <= 0 || (isBuy ? l >= px : l <= px) {
            sl = off(isBuy ? -0.02 : 0.02)
            fixes.append("Stop loss moved to \(money(sl!)), 2% \(isBuy ? "below" : "above") the price: \(money(l)) was on the wrong side and would have closed the order at once.")
        }
        let price = limitIn.map { Hyperliquid.roundPrice($0, szDecimals: asset.szDecimals) } ?? Hyperliquid.marketPrice(mid: mark, isBuy: isBuy, asset: asset)
        // Hyperliquid checks the $10 minimum against each order's own price: a market short sits 5% under the mark, and a
        // stop sits under it too. Size against the lowest, and round up a step rather than down when that drops under $10.
        // The stop and take-profit go in as their own orders at their own prices, so they must clear $10 too.
        let floorPx = [px, price, sl, tp].compactMap { $0 }.filter { $0 > 0 }.min() ?? px
        var qty = Hyperliquid.roundSize(size / px, szDecimals: asset.szDecimals)
        if qty * floorPx < minUSD {
            let step = pow(10, -Double(asset.szDecimals))
            repeat { qty = Hyperliquid.roundSize(qty + step, szDecimals: asset.szDecimals) } while qty * floorPx < minUSD
        }
        guard qty > 0 else { throw ToolError("Size too small for \(coin)") }
        let order = Hyperliquid.Order(asset: asset, isBuy: isBuy, price: price, size: qty, tif: limitIn == nil ? .ioc : .gtc,
                                      takeProfit: tp, stopLoss: sl)
        // Hyperliquid's maintenance margin is half the initial margin at the market's max leverage. Estimated as if
        // isolated, so the account's other margin can only push it further away.
        let liq = liquidation(entry: px, leverage: Double(lev), mm: 1 / (2 * Double(max(asset.maxLeverage, 1))), long: isBuy)
        var lines: [[String]] = [["Market", "\(coin) perp on Hyperliquid"], ["Side", isBuy ? "Long" : "Short"],
                                 ["Size", "\(Hyperliquid.wire(qty)) \(coin), about $\(String(format: "%.2f", qty * px))"],
                                 ["Margin", "$\(String(format: "%.2f", margin)) at \(lev)x"],
                                 [limitIn == nil ? "Worst price" : "Limit price", "$" + Hyperliquid.wire(price)],
                                 ["Liquidation, est.", "$" + String(format: liq < 1 ? "%.6f" : "%.2f", liq)]]
        if let token = thousandOf(coin) { lines.insert(["Contract", "1 \(coin) = 1,000 \(token), prices are per 1,000"], at: 1) }
        if let tp { lines.append(["Take profit", money(tp)]) }
        if let sl { lines.append(["Stop loss", money(sl)]) }
        lines.append(["Asked for by", "\(label), from your message"])
        // Leverage is per coin: changing it also changes an open position in this coin (as on the Trade page).
        let cur = hl.account?.positions.first { $0.coin == asset.coin }
        var warnings = fixes + verdict.warnings + ["Leveraged trades can lose all their margin"]
        if !(cur?.leverage == lev && cur?.cross == !asset.onlyIsolated) {
            lines.insert(["Leverage", "Sets \(coin) to \(lev)x"], at: 4)
            if cur != nil { warnings.append("This also changes the leverage of your open \(coin) position.") }
        }
        let spent = Decimal(margin)
        let approval = Approval(kind: "Hyperliquid order", title: "\(isBuy ? "Long" : "Short") \(coin)", lines: lines,
                                checks: verdict.passed + ["Signed on \(Device.here) with your wallet's key"],
                                success: "\(isBuy ? "Long" : "Short") \(coin) sent", warnings: warnings) {
            let summary = try await trader.place(order, leverage: lev, current: cur).summary
            policy.limit.record(usd: spent)
            return summary
        }
        var content = prepared("trade")
        if !fixes.isEmpty, let d = try? JSONSerialization.data(withJSONObject: ["status": "review_opened", "kind": "trade", "executed": false,
                                                                            "adjusted": fixes,
                                                                            "note": "Waiting for the user to approve with \(Device.bio). Tell the user what was adjusted, in one sentence."] as [String: Any],
                                                               options: [.sortedKeys]) {
            content = String(decoding: d, as: UTF8.self)
        }
        return ToolOutcome(content: content, action: Action("Review \(isBuy ? "long" : "short") \(coin)", approval: approval))
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
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        // The spending policy for an assistant-prepared send: daily limit, the per-move cap, priced tokens only.
        let sym = symbol.uppercased()
        // Read the way prepareSend reads it (English numbers, "1,000" is a thousand), so the policy prices the same amount.
        let usd: Double? = try await sendValueUSD(symbol: sym, amount: AmountText.normalize(amount, decimalSeparator: ".").flatMap { TradeAmount.value($0) })
        let verdict = vm.service.policy.evaluateAgentSend(usd: usd, payee: (to, chain.kind))
        if verdict.decision == .block {
            return Self.json(["status": "blocked", "reasons": verdict.blocks, "note": "Nothing was prepared. Tell the user why."])
        }
        // From the wallet get_balances reads, in exact base units, without changing the wallet picked in Wallets
        // (WalletsViewModel.prepareSend does both, the same as Send).
        let p = try await vm.prepareSend(from: w.record.id.uuidString, chain: chain, to: to, amount: amount, token: sym)
        var approval = try vm.approval(for: p)
        approval.warnings += verdict.warnings
        // The network goes back to the model: it may have been picked here, not named by the user.
        var result: [String: Any] = ["status": "review_opened", "kind": "send", "executed": false, "network": chain.name,
                                     "amount": "\(p.amountText) \(p.symbol)", "note": "Waiting for the user to approve with \(Device.bio)."]
        if vm.wallets.count > 1 { result["wallet"] = w.name }
        var out = json(result)
        out.action = Action("Review send", approval: approval)
        return out
    }

    /// Dollar value of a send for the policy: stablecoins at $1, everything else at the Hyperliquid mark price per token.
    static func sendValueUSD(symbol: String, amount: Double?) async throws -> Double? {
        guard let amount, amount > 0 else { return nil }
        if ["USDC", "USDT", "USDT0", "DAI", "USDE", "USDC.E"].contains(symbol) { return amount }
        // Crypto perps only (not trade.xyz stocks); kPEPE is priced per 1,000 PEPE.
        guard let c = (try? await contexts()).flatMap({ resolve(symbol, in: $0) }), c.mark > 0 else { return nil }
        return (thousandOf(c.coin) == nil ? c.mark : c.mark / 1000) * amount
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
