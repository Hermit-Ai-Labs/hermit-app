import Foundation
import HermitCore
import HermitWallet

/// The thinking part of the v3 tools (hermit-lab/train/spec/APP_TOOLS_v3.md): which order a cancel means, whether a
/// stop sits on the right side of the price, what a date or a schedule says, which contact a name is, and the exact
/// result each tool hands the model. Nothing here reads the network, the wallet or the screen: HermitToolbox+V3*.swift
/// gathers that and calls in, and the tests call in with made-up values.
///
/// Result keys follow hermit_tools_v3.meta.json. One rule for every string a result carries: it never names a
/// prepare_ tool, because ToolResult.clean hides text that does (it reads like an order to the assistant).
enum ToolsV3 {
    static let en = Locale(identifier: "en_US")
    static let nothingPrepared = "Nothing was prepared. Tell the user why."
    static let askWhich = "Nothing was prepared. Ask the user which one."

    // MARK: Arguments

    static func text(_ a: [String: Any], _ key: String) -> String {
        ((a[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func number(_ a: [String: Any], _ key: String) -> Double? {
        if let n = a[key] as? NSNumber { return n.doubleValue }
        return (a[key] as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The argument is there (not missing, not null).
    static func has(_ a: [String: Any], _ key: String) -> Bool { a[key] != nil && !(a[key] is NSNull) }

    /// A positive amount argument as plain decimal text ("0.5", "1200"), for exact parsing. nil when it isn't one.
    static func decimalText(_ a: [String: Any], _ key: String) -> String? {
        var raw: String
        if let n = a[key] as? NSNumber {
            raw = n.stringValue
            if raw.contains("e") || raw.contains("E") {
                raw = String(format: "%.12f", n.doubleValue)
                while raw.hasSuffix("0") { raw.removeLast() }
                if raw.hasSuffix(".") { raw.removeLast() }
            }
        } else if let s = a[key] as? String {
            raw = s
        } else {
            return nil
        }
        return PayAmount.exact(raw)
    }

    // MARK: Words and numbers

    static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// A price at four significant digits (1.74, 0.00031, 142.4); from 1,000 up, to the cent.
    static func sig(_ v: Double, _ digits: Int = 4) -> Double {
        guard v.isFinite, v != 0 else { return 0 }
        if abs(v) >= 1000 { return r2(v) }
        let scale = pow(10, Double(digits) - ceil(log10(abs(v))))
        return (v * scale).rounded() / scale
    }

    /// "7,500", "1,234.5": grouped the English way whatever the device's region.
    static func grouped(_ v: Double, maxFraction: Int = 2) -> String {
        v.formatted(.number.grouping(.automatic).precision(.fractionLength(0...maxFraction)).locale(en))
    }

    /// A token amount as chat reads it: "7,500", "6.02", "0.07712".
    static func amount(_ v: Double) -> String { abs(v) >= 1000 ? grouped(v) : Units.approx(v) }

    /// "$128", "$3,100", "$0.0098".
    static func dollars(_ v: Double) -> String { "$" + (abs(v) >= 1000 ? grouped(v) : Hyperliquid.wire(v)) }

    static func shortMint(_ m: String) -> String { m.count > 12 ? "\(m.prefix(4))…\(m.suffix(4))" : m }

    /// "A or B", "A, B or C".
    static func either(_ items: [String]) -> String {
        items.count <= 1 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " or " + (items.last ?? "")
    }

    /// "A and B", "A, B and C".
    static func both(_ items: [String]) -> String {
        items.count <= 1 ? (items.first ?? "") : items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }

    static func capFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// "2026-12-01 09:00", in the calendar's time zone.
    static func stamp(_ d: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func blocked(_ reasons: [String]) -> [String: Any] {
        ["status": "blocked", "reasons": reasons, "note": nothingPrepared]
    }

    // MARK: open_page

    /// The pages chat may point to, and the tabs of the ones that have them. Nothing here shows a recovery phrase or a key.
    static let pages: [String] = ["home", "wallets", "trade", "earn", "payments", "explore", "calendar", "projects", "automations", "files",
                                  "connectors", "settings"]
    static let tabs: [String: [String]] = ["trade": ["markets", "positions"], "earn": ["save", "positions", "explore"],
                                           "payments": ["schedule", "payees", "transfer", "apis"],
                                           "settings": ["profile", "safety", "memory", "models", "cloud"]]
    /// A page or tab asked for with one of these words is refused outright, whatever else it says.
    static let secretWords: [String] = ["phrase", "recovery", "seed", "secret", "private", "key", "backup", "export", "reveal", "security"]

    enum PageCheck: Equatable {
        case ok(Route, String?)
        case badTab(String)
        case notAllowed
    }

    static func pageTitle(_ r: Route) -> String { r == .home ? "Home" : r.title }

    static func checkPage(_ pageIn: String, tab tabIn: String?) -> PageCheck {
        let page = pageIn.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var tab = tabIn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if tab?.isEmpty == true { tab = nil }
        if secretWords.contains(where: { page.contains($0) || (tab ?? "").contains($0) }) { return .notAllowed }
        guard pages.contains(page), let route = Route(rawValue: page) else { return .notAllowed }
        guard let t = tab else { return .ok(route, nil) }
        let title = pageTitle(route)
        guard let allowed = tabs[page] else { return .badTab("\(title) has no tabs to open from chat.") }
        guard allowed.contains(t) else { return .badTab("\(title) has no tab called \(t). Tabs: \(allowed.joined(separator: ", ")).") }
        return .ok(route, t)
    }

    /// A button's link ("page:earn:positions") back to a page, checked against the same list.
    static func pageTarget(_ page: String, tab: String?) -> (route: Route, tab: String?)? {
        if case .ok(let r, let t) = checkPage(page, tab: tab) { return (route: r, tab: t) }
        return nil
    }

    /// open_page: a button in chat, like open_add_funds. Nothing opens until the user taps it.
    static func openPage(_ a: [String: Any]) -> ToolOutcome {
        let tabText = text(a, "tab")
        switch checkPage(text(a, "page"), tab: tabText.isEmpty ? nil : tabText) {
        case .notAllowed:
            return HermitToolbox.json(["error": "That page can't be opened from chat."])
        case .badTab(let why):
            return HermitToolbox.json(["error": why])
        case .ok(let route, let tab):
            let title = pageTitle(route)
            var out: [String: Any] = ["status": "button_shown", "screen": route.rawValue, "page": route.rawValue, "note": "The user taps it to open \(title)."]
            if let tab { out["tab"] = tab }
            var o = HermitToolbox.json(out)
            o.action = Action(tab.map { "Open \(title), \(capFirst($0))" } ?? "Open \(title)", primary: true, symbol: route.symbol,
                              open: "page:" + route.rawValue + (tab.map { ":" + $0 } ?? ""))
            return o
        }
    }

    // MARK: open_app

    /// A host as it is compared: lowercase, no trailing dot, no leading "www.".
    static func bareHost(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// The domains written in the user's own messages: "uniswap.org", "https://app.aave.com/markets" (the host only,
    /// never a domain-looking word inside a path or a query), "jup.ag." at the end of a sentence. An email address
    /// names no site, and a scheme other than http(s) isn't a link Hermit opens.
    static func typedHosts(_ texts: [String]) -> Set<String> {
        var out = Set<String>()
        for text in texts {
            for raw in text.lowercased().components(separatedBy: .whitespacesAndNewlines) {
                var t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()<>[]{}\"'`,;!?*.:"))
                if let r = t.range(of: "://") {
                    let scheme = String(t[..<r.lowerBound])
                    guard scheme == "http" || scheme == "https" else { continue }
                    t = String(t[r.upperBound...])
                }
                if let cut = t.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { t = String(t[..<cut]) }
                guard !t.contains("@") else { continue }
                if let colon = t.lastIndex(of: ":"), t[t.index(after: colon)...].allSatisfy(\.isNumber) { t = String(t[..<colon]) }
                t = bareHost(t.trimmingCharacters(in: CharacterSet(charactersIn: ".:")))
                if t.range(of: #"^([a-z0-9]([a-z0-9\-]*[a-z0-9])?\.)+[a-z][a-z0-9\-]*[a-z0-9]$"#, options: .regularExpression) != nil { out.insert(t) }
            }
        }
        return out
    }

    /// Whether open_app may open a page by itself. An app from Explore's own list may. A web address may only when the
    /// user typed that very domain in this chat: the whole host has to match ("uniswap.org" typed vouches neither for
    /// "uniswap.org.evil.io" nor for another subdomain). Everything else waits for one tap.
    static func opensDirectly(fromExplore: Bool, host: String?, typed: [String]) -> Bool {
        if fromExplore { return true }
        guard let host, !host.isEmpty else { return false }
        return typedHosts(typed).contains(bareHost(host))
    }

    // MARK: Addresses and contacts

    struct Contact: Equatable {
        let name: String
        let address: String
    }

    enum ContactMatch: Equatable {
        case one(Contact)
        case several([Contact])
        case none
    }

    /// The address family: EVM (a 0x address or an ENS name), Solana or NEAR. nil for anything else.
    static func family(of address: String) -> ChainKind? {
        switch PayAddress.kind(address) {
        case .evm, .ens: return .evm
        case .solana: return .solana
        case .near: return .near
        case .none, .invalid: return nil
        }
    }

    /// The networks one address of a family works on, the big ones first.
    static func networks(_ kind: ChainKind) -> [String] {
        let ids = Chain.mainnets.filter { $0.kind == kind }.map(\.id)
        let first = ["ethereum", "base", "arbitrum", "bnb", "polygon", "monad"].filter { ids.contains($0) }
        return first + ids.filter { !first.contains($0) }
    }

    /// The saved contact a name means. The whole name first ("alice" is Alice, not Alice Smith); else every contact
    /// with that word in the name, and more than one of those is a question back to the user.
    static func findContact(_ query: String, in list: [Contact]) -> ContactMatch {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ContactMatch.none }
        var unique: [Contact] = []
        for c in list where !unique.contains(where: { $0.name.lowercased() == c.name.lowercased() && $0.address == c.address }) { unique.append(c) }
        func pick(_ hits: [Contact]) -> ContactMatch? {
            // The same address saved twice (in Payments and in the wallet's address book) is one contact.
            var byAddress: [Contact] = []
            for c in hits where !byAddress.contains(where: { $0.address.lowercased() == c.address.lowercased() }) { byAddress.append(c) }
            if byAddress.count == 1 { return .one(byAddress[0]) }
            return byAddress.isEmpty ? nil : .several(byAddress)
        }
        if let exact = pick(unique.filter { $0.name.lowercased() == q }) { return exact }
        let partial = unique.filter { c in
            let name = c.name.lowercased()
            return name.hasPrefix(q + " ") || name.split(separator: " ").contains { $0 == q }
        }
        if let some = pick(partial) { return some }
        return ContactMatch.none
    }

    /// What to call each of several contacts: the name, with the start and end of the address when names repeat.
    static func contactLabels(_ cs: [Contact]) -> [String] {
        let names = cs.map { $0.name.lowercased() }
        return cs.map { c in names.filter { $0 == c.name.lowercased() }.count > 1 ? "\(c.name) (\(shortAddr(c.address)))" : c.name }
    }

    /// get_address with a contact's name.
    static func contactResult(_ query: String, in list: [Contact], only: ChainKind?) -> [String: Any] {
        switch findContact(query, in: list) {
        case .none:
            return ["status": "not_found", "note": "No saved contact called \(query). Ask the user for the address."]
        case .several(let cs):
            let labels = contactLabels(cs)
            return ["status": "needs_choice", "options": labels, "question": "Which \(query)? \(either(labels)).",
                    "note": "Nothing was returned. Ask the user which one."]
        case .one(let c):
            let kind = family(of: c.address)
            if let only, let kind, kind != only {
                return ["status": "not_found",
                        "note": "\(c.name)'s saved address is \(kind.article) \(kind.shortName) address, so it can't be used there. Ask the user for another address."]
            }
            let row: [String: Any] = ["name": c.name, "address": c.address, "family": kind?.rawValue ?? "unknown", "networks": kind.map(networks) ?? []]
            return ["contacts": [row]]
        }
    }

    /// get_address for the wallet's own receive addresses, one per family. Public addresses only.
    static func ownAddresses(_ own: [(kind: ChainKind, address: String)], wallet: String, only: ChainKind?) -> [String: Any] {
        let rows: [[String: Any]] = own.filter { !$0.address.isEmpty && (only == nil || $0.kind == only) }.map { o in
            ["family": o.kind.rawValue, "address": o.address, "networks": networks(o.kind), "wallet": wallet]
        }
        guard !rows.isEmpty else {
            return ["error": "This wallet has no \(only?.shortName ?? "") address yet. The user can add one in Wallets."]
        }
        return ["addresses": rows, "note": "Only send tokens on these networks to these addresses. The QR code is in Add funds."]
    }

    enum ContactPlan: Equatable {
        case error(String)
        case nameTaken(String)
        /// Already saved with this address, under this name.
        case exists(String)
        case ok(name: String, address: String, kind: ChainKind)
    }

    /// add_contact: the address must be a real one, and neither it nor the name may be saved already.
    static func contactPlan(name nameIn: String, address addressIn: String, network: String?, payees: [Contact]) -> ContactPlan {
        let name = String(nameIn.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let typed = addressIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !typed.isEmpty else { return .error("Needs a name and an address") }
        guard PayAddress.valid(typed), let kind = family(of: typed) else { return .error("That doesn't look like a valid address.") }
        let address = PayAddress.normalized(typed)
        if let n = network?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            guard let c = HermitToolbox.findChain(n) else { return .error("Unknown network \(n).") }
            if c.kind != kind { return .error("That is \(kind.article) \(kind.shortName) address, so it can't be used on \(c.name).") }
        }
        func same(_ a: String, _ b: String) -> Bool { kind == .solana ? a == b : a.caseInsensitiveCompare(b) == .orderedSame }
        if let p = payees.first(where: { same($0.address, address) }) { return .exists(p.name) }
        if payees.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return .nameTaken(name) }
        return .ok(name: name, address: address, kind: kind)
    }

    // MARK: search_tokens

    /// Up to five rows, the most liquid first. A token whose mint or ticker is exactly what was asked for is never
    /// pushed out by bigger tokens that only resemble it.
    static func searchResult(_ found: [JupiterTokens.Found], query: String) -> [String: Any] {
        let q = JupiterTokens.plain(query.trimmingCharacters(in: .whitespacesAndNewlines))
        func liquidity(_ f: JupiterTokens.Found) -> Double { f.row?.liquidity ?? f.check?.liquidity ?? 0 }
        let exact = found.filter { $0.id == q || JupiterTokens.plain($0.symbol).caseInsensitiveCompare(q) == .orderedSame }
            .sorted { liquidity($0) > liquidity($1) }
        let rest = found.filter { f in !exact.contains { $0.id == f.id } }.sorted { liquidity($0) > liquidity($1) }
        let picked = Array((exact + rest).prefix(5)).sorted { liquidity($0) > liquidity($1) }
        guard !picked.isEmpty else {
            return ["tokens": [[String: Any]](), "note": "No Solana token matched. Check the spelling or paste the mint."]
        }
        return ["tokens": picked.map(tokenRow)]
    }

    static func tokenRow(_ f: JupiterTokens.Found) -> [String: Any] {
        let check = f.check ?? f.row?.check
        let tags: [String] = check.map { c in c.tags.map { $0.0 } } ?? (f.verified ? [] : ["Unverified"])
        var row: [String: Any] = ["symbol": f.symbol, "name": f.name, "mint": f.id, "verified": f.verified, "tags": tags,
                                  "liquidity_usd": (f.row?.liquidity ?? check?.liquidity ?? 0).rounded(),
                                  "volume_24h_usd": (f.row?.volume24h ?? 0).rounded()]
        if let r = f.row {
            row["price"] = sig(r.price)
            row["change_24h_pct"] = r2(r.change24h)
        } else {
            row["price"] = NSNull()
            row["change_24h_pct"] = NSNull()
        }
        // Why Hermit won't buy it (too little liquidity, an unverified token its creator can freeze). Selling still works.
        if let why = check?.refusal { row["refusal"] = why }
        return row
    }

    // MARK: prepare_buy

    enum BuyPick {
        case token(JupiterTokens.Row)
        case none
        /// Two verified tokens share the ticker and the runner-up has at least half the liquidity: Hermit won't guess.
        case clash([JupiterTokens.Row])
    }

    static func pickVerified(_ symbol: String, rows: [JupiterTokens.Row]) -> BuyPick {
        let want = JupiterTokens.plain(symbol).uppercased()
        let matches = rows.filter { JupiterTokens.plain($0.symbol).uppercased() == want }.sorted { $0.liquidity > $1.liquidity }
        guard let best = matches.first else { return .none }
        if matches.count > 1, matches[1].liquidity >= best.liquidity * 0.5 { return .clash(Array(matches.prefix(2))) }
        return .token(best)
    }

    static func buyChoice(_ symbol: String, _ rows: [JupiterTokens.Row]) -> [String: Any] {
        let options: [[String: Any]] = rows.map { ["symbol": $0.symbol, "mint": $0.id, "liquidity_usd": $0.liquidity.rounded()] }
        return ["status": "needs_choice", "prepared": false, "options": options, "note": askWhich,
                "question": "Two tokens are called \(symbol). Pick the one you mean on Spot or Memes, or paste its mint."]
    }

    // MARK: prepare_sell

    /// SOL and USDC aren't sold with prepare_sell, by ticker ("$usdc" too) or by mint: why, or nil for any other token.
    /// USDC "sold" could only go to SOL: that is a swap out of dollars, not a sale that lowers risk, and a swap is held
    /// to the assistant's per-move cap. It stays with the swap tool.
    static func sellRefusal(_ token: String) -> String? {
        let t = JupiterTokens.plain(token.trimmingCharacters(in: .whitespacesAndNewlines))
        if t.uppercased() == "SOL" || t == Jupiter.solMint { return "SOL isn't sold here. Swap it instead." }
        if t.uppercased() == "USDC" || t == Jupiter.usdcMint { return "USDC isn't sold here. Swap it instead." }
        return nil
    }

    /// What a sale pays out: USDC, or SOL when asked for (`receive` is "", "USDC" or "SOL"). USDC itself sells for SOL.
    static func sellOutput(mint: String, receive: String) -> Jupiter.Token {
        receive.uppercased() != "SOL" && mint != Jupiter.usdcMint ? Jupiter.usdc : Jupiter.sol
    }

    /// Who the spending policy checks a sale as. A sale lowers risk, so it is checked like the user's own (the daily
    /// limit, not the assistant's per-move cap). A dollar stablecoin sold for SOL adds risk instead, so that one is
    /// checked as the assistant: the cap applies, like a swap.
    static func sellOrigin(outMint: String, soldIsStable: Bool) -> ActionOrigin {
        outMint == Jupiter.solMint && soldIsStable ? .agent : .user
    }

    enum SellPlan {
        case error(String)
        /// Nothing held under that ticker or mint; the word to call it by.
        case notHeld(String)
        case choose([SolanaHoldings.Holding])
        case frozen(SolanaHoldings.Holding)
        case insufficient(SolanaHoldings.Holding)
        /// What to sell, in exact base units, and how to say the share ("50% of your WIF", "all of your WIF", or "" for an amount).
        case sell(SolanaHoldings.Holding, base: UInt64, part: String)
    }

    /// Which holding a sale means and how much of it. `percent` is 1 to 100 (any number, not only 25, 50 and 100);
    /// `amountText` is token units as plain decimal text. Exactly one of the two.
    static func sellPlan(token: String, percent: Double?, amountText: String?, hasAmount: Bool, holdings: [SolanaHoldings.Holding]) -> SellPlan {
        let t = JupiterTokens.plain(token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !t.isEmpty else { return .error("Needs token") }
        if percent != nil && hasAmount { return .error("Give percent or amount, not both.") }
        guard percent != nil || hasAmount else { return .error("Needs percent (1 to 100) or amount (in token units).") }
        let held = holdings.filter { $0.amount > 0 }
        let isMint = ToolGuard.looksLikeMint(t)
        let matches: [SolanaHoldings.Holding]
        if isMint { matches = held.filter { $0.id == t } }
        else { matches = held.filter { JupiterTokens.plain($0.symbol).caseInsensitiveCompare(t) == .orderedSame } }
        guard let h = matches.first else { return .notHeld(isMint ? shortMint(t) : t.uppercased()) }
        if matches.count > 1 { return .choose(matches) }
        if h.frozen { return .frozen(h) }
        let share: UInt128
        var part = ""
        if let p = percent {
            guard p >= 1, p <= 100 else { return .error("percent must be between 1 and 100") }
            if p >= 100 {
                share = h.amount
                part = "all of your \(h.symbol)"
            } else {
                // Hundredths of a percent, in whole base units, rounded down.
                share = h.amount * UInt128((p * 100).rounded()) / 10_000
                part = "\(Hyperliquid.wire(p))% of your \(h.symbol)"
            }
        } else {
            guard let text = amountText, let v = try? Units.parse(text, decimals: h.decimals), v > 0 else {
                return .error("That isn't an amount of \(h.symbol) Hermit can sell. Use a number with up to \(h.decimals) decimals.")
            }
            guard v <= h.amount else { return .insufficient(h) }
            share = v
            if v == h.amount { part = "all of your \(h.symbol)" }
        }
        guard share > 0 else { return .error("That's too little \(h.symbol) to sell.") }
        guard let base = UInt64(exactly: share) else { return .error("That's more \(h.symbol) than one swap can sell. Try a smaller part.") }
        return .sell(h, base: base, part: part)
    }

    // MARK: Batch send on Solana

    /// The family a batch's recipients are written in: Solana when the addresses that read as one are all Solana, EVM
    /// when they are all 0x (or .eth). nil for a mixed list or one with no address in it: the list then can't pick the
    /// network, and the review flags the rows that don't fit.
    static func batchFamily(_ addresses: [String]) -> ChainKind? {
        var evm = 0, solana = 0
        for a in addresses {
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("0x") || t.hasPrefix("0X") || t.lowercased().hasSuffix(".eth") { evm += 1 }
            else if SolanaPublicKey(t) != nil || t.lowercased().hasSuffix(".sol") { solana += 1 }
        }
        if solana > 0 && evm == 0 { return .solana }
        if evm > 0 && solana == 0 { return .evm }
        return nil
    }

    enum BatchToken: Equatable {
        /// SOL, or a token Hermit lists on Solana (USDC, USDT): the wallet engine knows it.
        case listed
        /// A token the wallet holds, with its mint, decimals and Jupiter's price.
        case held(SolanaBatch.Token)
        case notHeld(String)
        case choose([SolanaHoldings.Holding])
        case frozen(SolanaHoldings.Holding)
    }

    /// Which Solana token a batch means. SOL and the listed stablecoins are themselves whatever else the wallet holds
    /// under that name (a look-alike called USDC never stands in for USDC). Anything else has to be held: by symbol,
    /// or by mint. Two holdings with the same symbol are a question back, never a guess.
    static func batchToken(_ symbolIn: String, holdings: [SolanaHoldings.Holding]) -> BatchToken {
        let t = JupiterTokens.plain(symbolIn.trimmingCharacters(in: .whitespacesAndNewlines))
        if t.caseInsensitiveCompare(Chain.solana.nativeSymbol) == .orderedSame || Chain.solana.token(t) != nil { return .listed }
        let held = holdings.filter { $0.amount > 0 }
        let isMint = ToolGuard.looksLikeMint(t)
        let matches: [SolanaHoldings.Holding]
        if isMint { matches = held.filter { $0.id == t } }
        else { matches = held.filter { JupiterTokens.plain($0.symbol).caseInsensitiveCompare(t) == .orderedSame } }
        guard let h = matches.first else { return .notHeld(isMint ? shortMint(t) : t.uppercased()) }
        if matches.count > 1 { return .choose(matches) }
        if h.frozen { return .frozen(h) }
        let usd: Decimal? = h.price.flatMap { $0.isFinite && $0 > 0 ? Decimal($0) : nil }
        return .held(SolanaBatch.Token(mint: h.id, symbol: h.symbol, decimals: h.decimals, usd: usd, verified: h.verified))
    }

    static func sellChoice(_ hs: [SolanaHoldings.Holding]) -> [String: Any] {
        let options: [[String: Any]] = hs.map { ["symbol": $0.symbol, "mint": $0.id, "amount": Units.approx($0.tokens)] }
        let said = hs.map { "\(Units.approx($0.tokens)) (\(shortMint($0.id)))" }
        let count = hs.count == 2 ? "two" : "\(hs.count)"
        return ["status": "needs_choice", "prepared": false, "options": options, "note": askWhich,
                "question": "You hold \(count) tokens called \(hs.first?.symbol ?? ""): \(both(said)). Which one?"]
    }

    // MARK: get_positions

    /// One Solana token: amount, value, and what Hermit's own buys cost. Cost and P&L are null when the cost book has
    /// nothing for it; P&L also when some of it came from outside Hermit.
    static func spotRow(_ h: SolanaHoldings.Holding, basis: SpotBook.Basis?) -> [String: Any] {
        var row: [String: Any] = ["symbol": h.symbol, "mint": h.id, "amount": Units.approx(h.tokens), "frozen": h.frozen,
                                  "avg_cost": NSNull(), "pnl_pct": NSNull()]
        if let v = h.value { row["usd"] = r2(v) } else { row["usd"] = NSNull() }
        if let b = basis, b.average > 0 {
            row["avg_cost"] = sig(b.average)
            // The book covers what's held (2% slack for rounding and fees): the P&L is for all of it.
            if b.tokens >= h.tokens * 0.98, let p = h.price { row["pnl_pct"] = r2((p / b.average - 1) * 100) }
        }
        return row
    }

    /// The holdings worth listing, the most valuable first, at most `limit`; `left` is how many were left out.
    static func spotRows(_ items: [SolanaHoldings.Holding], limit: Int = 12, basis: (String) -> SpotBook.Basis?) -> (rows: [[String: Any]], left: Int) {
        // Dust (under a cent) is left out; a token with no price stays, since its worth is unknown.
        let worth = items.filter { h in h.amount > 0 && (h.value ?? 1) >= 0.01 }
        let sorted = worth.sorted { a, b in
            switch (a.value, b.value) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.symbol < b.symbol
            }
        }
        let shown = Array(sorted.prefix(limit))
        return (shown.map { spotRow($0, basis: basis($0.id)) }, items.filter { $0.amount > 0 }.count - shown.count)
    }

    static func earnRows(_ positions: [AavePosition]) -> [[String: Any]] {
        positions.map { p in
            var row: [String: Any] = ["symbol": p.token.symbol, "chain": p.chain.id, "amount": p.text]
            if let apy = p.supplyAPY { row["apy_pct"] = r2(apy * 100) } else { row["apy_pct"] = NSNull() }
            return row
        }
    }

    /// "limit", "take_profit" or "stop_loss", from Hyperliquid's own order type ("Take Profit Market", "Stop Market").
    static func orderKind(_ o: Hyperliquid.OpenOrder) -> String {
        guard o.isTrigger else { return "limit" }
        return o.orderType.lowercased().contains("take") ? "take_profit" : "stop_loss"
    }

    /// A trigger attached to the whole position (Hyperliquid lists it with size 0).
    static func isWhole(_ o: Hyperliquid.OpenOrder) -> Bool { o.isTrigger && (o.isPositionTpsl || o.size == 0) }

    /// The price that matters: where a trigger fires (its limit price is only a slippage cap), a limit order's limit.
    static func orderPrice(_ o: Hyperliquid.OpenOrder) -> Double { o.isTrigger && o.triggerPx > 0 ? o.triggerPx : o.price }

    static func orderSize(_ o: Hyperliquid.OpenOrder, positions: [Hyperliquid.Position]) -> Double {
        guard isWhole(o), let p = positions.first(where: { $0.coin == o.coin }) else { return o.size }
        return abs(p.size)
    }

    static func positionRow(_ p: Hyperliquid.Position) -> [String: Any] {
        var row: [String: Any] = ["coin": p.coin, "side": p.size > 0 ? "long" : "short", "size": abs(p.size), "entry": p.entry,
                                  "unrealised_pnl": p.pnl, "leverage": p.leverage]
        if let l = p.liquidation { row["liquidation"] = l } else { row["liquidation"] = NSNull() }
        return row
    }

    /// One open order with the id cancel_order takes.
    static func orderRow(_ o: Hyperliquid.OpenOrder, positions: [Hyperliquid.Position]) -> [String: Any] {
        var row: [String: Any] = ["coin": o.coin, "id": String(o.oid), "kind": orderKind(o), "price": orderPrice(o),
                                  "side": o.isBuy ? "buy" : "sell", "size": orderSize(o, positions: positions)]
        if isWhole(o) { row["whole_position"] = true }
        return row
    }

    static func perps(_ account: Hyperliquid.Account?) -> [String: Any] {
        let positions = (account?.positions ?? []).filter { $0.size != 0 }
        return ["positions": positions.map(positionRow), "open_orders": (account?.orders ?? []).map { orderRow($0, positions: positions) }]
    }

    // MARK: Perp coins

    /// What the model typed against Hyperliquid's own name: "SOL", "sol-perp", "NVDA" or "xyz:NVDA" for xyz:NVDA,
    /// "PEPE" for kPEPE.
    static func sameCoin(_ input: String, _ coin: String) -> Bool {
        var u = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for suffix in ["-PERP", " PERP", "-USDC", "/USDC", "-USD", "/USD"] where u.hasSuffix(suffix) { u = String(u.dropLast(suffix.count)); break }
        if u.hasPrefix("XYZ:") { u = String(u.dropFirst(4)) }
        guard !u.isEmpty else { return false }
        let c = PerpFmt.sym(coin)
        return c.uppercased() == u || c == "k" + u
    }

    /// The open position a coin means. Hyperliquid's own full name ("xyz:NVDA") wins over a bare ticker.
    static func position(_ coin: String, in positions: [Hyperliquid.Position]) -> Hyperliquid.Position? {
        let open = positions.filter { $0.size != 0 }
        let typed = coin.trimmingCharacters(in: .whitespacesAndNewlines)
        return open.first { $0.coin.caseInsensitiveCompare(typed) == .orderedSame } ?? open.first { sameCoin(coin, $0.coin) }
    }

    /// The same ticker open on more than one venue ("xyz:NVDA" and "flx:NVDA") and the call didn't say which: their
    /// full names, for a question back. Empty when the coin means one position (or none).
    static func positionClash(_ coin: String, in positions: [Hyperliquid.Position]) -> [String] {
        let open = positions.filter { $0.size != 0 }
        let typed = coin.trimmingCharacters(in: .whitespacesAndNewlines)
        if open.contains(where: { $0.coin.caseInsensitiveCompare(typed) == .orderedSame }) { return [] }
        let hits = open.filter { sameCoin(coin, $0.coin) }.map(\.coin)
        return hits.count > 1 ? hits : []
    }

    // MARK: cancel_order

    enum CancelPlan {
        case error(String)
        /// Nothing matches; the note for the model.
        case nothing(String)
        case choose(sym: String, orders: [Hyperliquid.OpenOrder])
        case cancel(orders: [Hyperliquid.OpenOrder], text: String, warning: String?)
    }

    /// "SOL stop loss at $128", "ETH buy limit, 0.5 ETH at $3,100".
    static func describe(_ o: Hyperliquid.OpenOrder) -> String {
        let sym = PerpFmt.sym(o.coin)
        switch orderKind(o) {
        case "take_profit": return "\(sym) take profit at \(dollars(orderPrice(o)))"
        case "stop_loss": return "\(sym) stop loss at \(dollars(orderPrice(o)))"
        default: return "\(sym) \(o.isBuy ? "buy" : "sell") limit, \(amount(o.size)) \(sym) at \(dollars(o.price))"
        }
    }

    /// Which order (or orders) a cancel means. An id wins. "all" is every plain limit order and never a take profit or
    /// a stop loss. A coin with several orders and no kind is a question back to the user.
    static func cancelPlan(coin coinIn: String, kind kindIn: String?, orderID: String?, orders: [Hyperliquid.OpenOrder],
                           positions: [Hyperliquid.Position]) -> CancelPlan {
        var kind = kindIn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind?.isEmpty == true { kind = nil }
        if let k = kind, !["order", "take_profit", "stop_loss"].contains(k) { return .error("kind is order, take_profit or stop_loss") }
        func warning(_ o: Hyperliquid.OpenOrder) -> String? {
            guard orderKind(o) == "stop_loss" else { return nil }
            let another = orders.contains { $0.oid != o.oid && $0.coin == o.coin && orderKind($0) == "stop_loss" }
            guard !another, let p = positions.first(where: { $0.coin == o.coin && $0.size != 0 }) else { return nil }
            return "Without it the \(PerpFmt.sym(o.coin)) \(p.size > 0 ? "long" : "short") has no stop loss."
        }
        let coin = coinIn.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = orderID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            guard let o = orders.first(where: { String($0.oid) == id }) else { return .nothing("The user has no open order with id \(id). Tell them.") }
            // The id must be an order of the coin and the kind the call names. A mismatch means the model mixed two
            // orders up, and the wrong one could be the position's only stop loss: no card, an error instead.
            if !coin.isEmpty, coin.lowercased() != "all", !sameCoin(coin, o.coin) {
                return .error("Order \(id) is \(describe(o)), not \(PerpFmt.sym(coin).uppercased()). Nothing was prepared. Check which order the user means.")
            }
            if let k = kind, orderKind(o) != (k == "order" ? "limit" : k) {
                return .error("Order \(id) is \(describe(o)), not a \(k == "order" ? "limit order" : k.replacingOccurrences(of: "_", with: " ")). Nothing was prepared. Check which order the user means.")
            }
            return .cancel(orders: [o], text: describe(o), warning: warning(o))
        }
        guard !coin.isEmpty else { return .error("Needs coin") }
        if coin.lowercased() == "all" {
            if let k = kind, k != "order" { return .error("Coin all only cancels open limit orders. Name the coin to cancel a take profit or a stop loss.") }
            let plain = orders.filter { !$0.isTrigger }
            guard !plain.isEmpty else { return .nothing("The user has no open limit orders. Tell them.") }
            if plain.count == 1 { return .cancel(orders: plain, text: describe(plain[0]), warning: nil) }
            var coins: [String] = []
            for o in plain where !coins.contains(PerpFmt.sym(o.coin)) { coins.append(PerpFmt.sym(o.coin)) }
            return .cancel(orders: plain, text: "\(plain.count) open limit orders (\(coins.joined(separator: ", ")))", warning: nil)
        }
        let mine = orders.filter { sameCoin(coin, $0.coin) }
        let sym = mine.first.map { PerpFmt.sym($0.coin) } ?? PerpFmt.sym(coin).uppercased()
        let wantedKind = kind == "order" ? "limit" : kind
        let wanted = mine.filter { wantedKind == nil || orderKind($0) == wantedKind }
        guard !wanted.isEmpty else {
            let what = kind == "take_profit" ? "take profit" : kind == "stop_loss" ? "stop loss" : kind == "order" ? "limit orders" : "orders"
            return .nothing("The user has no open \(sym) \(what). Tell them.")
        }
        if wanted.count == 1 { return .cancel(orders: wanted, text: describe(wanted[0]), warning: warning(wanted[0])) }
        return .choose(sym: sym, orders: wanted)
    }

    /// The question when a coin has several orders. Each option carries its id when two are of the same kind, so the
    /// next call can name it.
    static func cancelChoice(sym: String, orders: [Hyperliquid.OpenOrder]) -> [String: Any] {
        let kinds = orders.map(orderKind)
        let distinct = Set(kinds).count == kinds.count
        func option(_ o: Hyperliquid.OpenOrder) -> String {
            let k = orderKind(o)
            let base = k == "limit" ? "limit \(o.isBuy ? "buy" : "sell") \(amount(o.size)) at \(dollars(o.price))" : "\(k) at \(dollars(orderPrice(o)))"
            return distinct ? base : base + " (id \(o.oid))"
        }
        func said(_ o: Hyperliquid.OpenOrder) -> String {
            let base: String
            switch orderKind(o) {
            case "take_profit": base = "a take profit at \(dollars(orderPrice(o)))"
            case "stop_loss": base = "a stop loss at \(dollars(orderPrice(o)))"
            default: base = "a \(o.isBuy ? "buy" : "sell") limit at \(dollars(o.price))"
            }
            return distinct ? base : base + " (id \(o.oid))"
        }
        return ["status": "needs_choice", "prepared": false, "options": orders.map(option), "note": askWhich,
                "question": "Which \(sym) order? \(capFirst(either(orders.map(said))))."]
    }

    // MARK: set_tp_sl

    /// The price a take profit or stop loss is really placed at. Hyperliquid holds a trigger at 5 significant figures
    /// (and 6 minus the coin's size decimals); the side check, the review and the signed order all use this price, so
    /// the sheet shows what is signed.
    static func triggerPrice(_ asked: Double, szDecimals: Int) -> Double {
        asked > 0 ? Hyperliquid.roundPrice(asked, szDecimals: szDecimals) : asked
    }

    /// How the review prints a trigger price: the same text the order carries, with a dollar sign.
    static func triggerText(_ price: Double) -> String { "$" + Hyperliquid.wire(price) }

    /// nil when the prices sit on the right sides of the current price; else the sentence that says which one doesn't.
    /// A long's stop goes below the price and its take profit above; a short's the other way round.
    static func wrongSide(long: Bool, takeProfit: Double?, stopLoss: Double?, mark: Double) -> String? {
        let side = long ? "long" : "short", price = Hyperliquid.wire(sig(mark, 5))
        if let sl = stopLoss, sl <= 0 || (long ? sl >= mark : sl <= mark) {
            return "A stop loss for a \(side) must be \(long ? "below" : "above") the current price (\(price))."
        }
        if let tp = takeProfit, tp <= 0 || (long ? tp <= mark : tp >= mark) {
            return "A take profit for a \(side) must be \(long ? "above" : "below") the current price (\(price))."
        }
        return nil
    }

    /// The triggers a new take profit or stop loss takes the place of: the ones of the same kind on that coin.
    static func replaced(coin: String, takeProfit: Bool, stopLoss: Bool, orders: [Hyperliquid.OpenOrder]) -> [Hyperliquid.OpenOrder] {
        orders.filter { o in
            guard o.coin == coin, o.isTrigger else { return false }
            let k = orderKind(o)
            return (takeProfit && k == "take_profit") || (stopLoss && k == "stop_loss")
        }
    }

    /// "stop loss at $120", "stop loss at $120 and take profit at $170".
    static func replacedText(_ orders: [Hyperliquid.OpenOrder]) -> String? {
        guard !orders.isEmpty else { return nil }
        return both(orders.map { "\(orderKind($0) == "take_profit" ? "take profit" : "stop loss") at \(dollars(orderPrice($0)))" })
    }

    /// "SOL long, 10 SOL".
    static func positionText(_ p: Hyperliquid.Position) -> String {
        let sym = PerpFmt.sym(p.coin)
        return "\(sym) \(p.size > 0 ? "long" : "short"), \(amount(abs(p.size))) \(sym)"
    }

    // MARK: create_automation

    enum AutomationPlan: Equatable {
        case error(String)
        case blocked(String)
        /// `trigger` is what the scheduler runs ("Every day 08:00"); `schedule` is how it reads ("Every day at 08:00").
        case ok(name: String, trigger: String, schedule: String, prompt: String)
    }

    /// The limits for automations made from chat. The Automations page itself allows shorter repeats; the assistant
    /// doesn't offer them.
    static let minRepeatMinutes = 5, maxAutomations = 10
    static let badSchedule = "I couldn't read that schedule. Use words like 'every morning at 8', 'every 5 minutes' or 'every Friday at 18:00'."

    /// The schedule goes through the same reader as the Automations page (AutomationDraft.from).
    static func automationPlan(name nameIn: String, prompt promptIn: String, schedule scheduleIn: String, existing: Int) -> AutomationPlan {
        let name = String(nameIn.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let prompt = String(promptIn.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        let schedule = scheduleIn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty, !schedule.isEmpty else { return .error("Needs name, prompt and schedule") }
        let trigger = AutomationDraft.from(schedule).trigger
        guard trigger != AutomationDraft.unplanned, Automation.nextRun(trigger, after: Date()) != nil else { return .error(badSchedule) }
        if let n = Automation.minutes(in: trigger, prefix: "Every "), n < minRepeatMinutes {
            return .blocked("The shortest repeat is every \(minRepeatMinutes) minutes.")
        }
        if existing >= maxAutomations { return .blocked("You already have \(maxAutomations) automations. Delete one in Automations first.") }
        return .ok(name: name, trigger: trigger, schedule: scheduleText(trigger), prompt: prompt)
    }

    /// "Every day 08:00" reads "Every day at 08:00"; "In 2 minutes" reads "Once, in 2 minutes"; the rest as they are.
    static func scheduleText(_ trigger: String) -> String {
        let words = trigger.split(separator: " ").map(String.init)
        if words.count == 3, words[0] == "Every", words[2].count == 5, words[2].contains(":") { return "Every \(words[1]) at \(words[2])" }
        if let n = Automation.minutes(in: trigger, prefix: "In ") { return n == 1 ? "Once, in 1 minute" : "Once, in \(n) minutes" }
        return trigger
    }

    // MARK: schedule_payment

    enum PaymentPlan {
        case error(String)
        case payeeNotFound(String)
        /// Several saved contacts fit the name: the name asked for and what to call each.
        case chooseContact(String, [String])
        /// The token is held on several networks and none was named: each with how much is there.
        case chooseChain(symbol: String, options: [(chain: Chain, held: Double)])
        /// `shown` is who it pays as chat says it: the contact's name, or the address shortened.
        case ok(ScheduledPayment, network: Chain, shown: String)
    }

    /// "0x5290… 9EE7" for a long address; a short one (alice.near) as it is.
    static func shortPayee(_ a: String) -> String { a.count > 14 ? "\(a.prefix(6))… \(a.suffix(4))" : a }

    /// The networks a payment of `symbol` to an address of this family can go out on, the wallet's default first
    /// (the same pool Pay now picks from).
    static func payChains(kind: ChainKind, symbol: String) -> [Chain] {
        let pool = [Chain.defaultSend] + (WalletService.mainnetSendsEnabled ? Chain.mainnets : Chain.testnets)
        var out: [Chain] = []
        for c in pool where c.kind == kind && HermitToolbox.hasToken(symbol, on: c) && !out.contains(c) { out.append(c) }
        return out
    }

    /// schedule_payment: a reminder, never a send. `payee` is a saved contact's name or an address (the guard has
    /// already checked a typed address). `candidates` are the networks per address family (payChains), `held` what the
    /// wallet holds of the token per chain id.
    static func paymentPlan(payee payeeIn: String, amountText: String?, symbol symbolIn: String, when: String, chain: String?, repeats: String?,
                            payees: [Payee], candidates: [ChainKind: [Chain]], held: [String: Double],
                            now: Date = Date(), calendar: Calendar = .current) -> PaymentPlan {
        let payee = payeeIn.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = symbolIn.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !payee.isEmpty, !symbol.isEmpty else { return .error("Needs payee, amount, symbol and when") }
        guard let exact = amountText, let value = Double(exact), value > 0 else { return .error("That isn't an amount Hermit can schedule. Use a number like 25 or 1200.50.") }
        guard PaymentsData.tokens.contains(symbol) else { return .error("Payments can schedule \(either(PaymentsData.tokens)).") }
        let rep: PayRepeat
        switch (repeats ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "once": rep = .once
        case "weekly": rep = .weekly
        case "monthly": rep = .monthly
        default: return .error("repeat is once, weekly or monthly")
        }

        // Who: an address as it is, or a saved contact by name. Only what ToolGuard checked as an address (typed by the
        // user, or a contact's) is ever paid as one: anything else is a name, looked up among the saved contacts.
        let name: String, address: String, shown: String
        var payeeID: UUID?
        if ToolGuard.namesAddress(payee) {
            guard PayAddress.valid(payee) else { return .error("That doesn't look like a valid address.") }
            address = PayAddress.normalized(payee)
            shown = shortPayee(address)
            name = shown
        } else {
            switch findContact(payee, in: payees.map { Contact(name: $0.name, address: $0.addr) }) {
            case .none: return .payeeNotFound(payee)
            case .several(let cs): return .chooseContact(payee, contactLabels(cs))
            case .one(let c):
                name = c.name; address = c.address; shown = c.name
                payeeID = payees.first { $0.name == c.name && $0.addr == c.address }?.id
            }
        }
        guard let kind = family(of: address) else { return .error("That doesn't look like a valid address.") }

        // When.
        guard let due = parseWhen(when, now: now, calendar: calendar) else {
            return .error("I couldn't read that date. Use words like 'Dec 1 9:00', 'tomorrow 18:00' or 'in 3 days'.")
        }
        guard due > now else { return .error("That date is in the past.") }

        // Where: the network named, the only one that fits, or the only one that holds the token.
        let fits = candidates[kind] ?? []
        guard !fits.isEmpty else { return .error("\(symbol) can't be sent to that address. Pick another token.") }
        let network: Chain
        if let named = chain?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            guard let c = HermitToolbox.findChain(named) else { return .error("Unknown network \(named).") }
            guard fits.contains(c) else { return .error("\(symbol) can't be paid on \(c.name) to that address.") }
            network = c
        } else if fits.count == 1 {
            network = fits[0]
        } else {
            let holding = fits.filter { (held[$0.id] ?? 0) > 0 }
            if holding.count > 1 { return .chooseChain(symbol: symbol, options: holding.map { (chain: $0, held: held[$0.id] ?? 0) }) }
            network = holding.first ?? fits[0]
        }
        let payment = ScheduledPayment(payee: name, addr: address, amount: value, token: symbol, note: "", next: due, repeats: rep,
                                       payeeID: payeeID, exact: exact, chain: network.id)
        return .ok(payment, network: network, shown: shown)
    }

    static func chainChoice(symbol: String, options: [(chain: Chain, held: Double)]) -> [String: Any] {
        let names = options.map { $0.chain.name }
        let amounts = options.map { "\($0.chain.name): \(Units.approx($0.held))" }.joined(separator: ", ")
        return ["status": "needs_chain", "prepared": false, "options": options.map { $0.chain.id },
                "question": "Which network should the payment use? You hold \(symbol) on \(both(names)) (\(amounts)).",
                "note": "Nothing was prepared. Ask the user which network, in one short question."]
    }

    // MARK: Dates

    /// The capture groups of the first match (group 0 is the whole match), nil for a group that didn't take part.
    static func groups(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
    }

    static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// When a payment is first due, from how people say it: an ISO date ("2026-12-01 09:00"), "Dec 1 9:00",
    /// "1 December 2026", "tomorrow 18:00", "today", "friday", "next friday", "in 3 days", "in 2 weeks", "next month",
    /// "the 15th". With no time of day it is 09:00. A month and day with no year is the next one to come. nil for
    /// anything else. An explicit date in the past comes back as it is, for the caller to refuse.
    static func parseWhen(_ raw: String, now: Date, calendar cal: Calendar) -> Date? {
        var s = raw.lowercased().replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let today = cal.startOfDay(for: now)
        func day(_ offset: Int) -> Date? { cal.date(byAdding: .day, value: offset, to: today) }
        func at(_ d: Date?, _ h: Int, _ m: Int) -> Date? { d.flatMap { cal.date(bySettingHour: h, minute: m, second: 0, of: $0) } }
        func built(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
            guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute),
                  let d = cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)),
                  cal.component(.month, from: d) == month, cal.component(.day, from: d) == day else { return nil }
            return d
        }

        // An ISO date, with or without a time.
        if let g = groups(#"^(\d{4})-(\d{1,2})-(\d{1,2})(?:[t\s]+(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?)?\s*z?$"#, in: s),
           let y = g[1].flatMap({ Int($0) }), let mo = g[2].flatMap({ Int($0) }), let d = g[3].flatMap({ Int($0) }) {
            return built(year: y, month: mo, day: d, hour: g[4].flatMap { Int($0) } ?? 9, minute: g[5].flatMap { Int($0) } ?? 0)
        }

        // The time of day, taken out of the text so the rest is only the date.
        var hour = 9, minute = 0, hasTime = false
        func half(_ h: Int, _ ampm: String?) -> Int {
            guard let a = ampm else { return h }
            return a == "pm" ? (h % 12) + 12 : h % 12
        }
        let clocks = [#"\b(?:at\s+)?(\d{1,2}):(\d{2})\s*(am|pm)?\b"#, #"\b(?:at\s+)?(\d{1,2})()\s*(am|pm)\b"#, #"\bat\s+(\d{1,2})()()\b(?!\s*(?:st|nd|rd|th))"#]
        for p in clocks {
            guard let g = groups(p, in: s), let h = g[1].flatMap({ Int($0) }) else { continue }
            let m = g[2].flatMap { Int($0) } ?? 0
            let h24 = half(h, g.count > 3 ? g[3].flatMap { $0.isEmpty ? nil : $0 } : nil)
            guard (0...23).contains(h24), (0...59).contains(m) else { return nil }
            hour = h24; minute = m; hasTime = true
            if let whole = g[0] { s = s.replacingOccurrences(of: whole, with: " ") }
            break
        }
        if !hasTime {
            for (word, h) in [("noon", 12), ("midnight", 0), ("morning", 9), ("afternoon", 15), ("evening", 18), ("tonight", 20), ("night", 21)] where s.contains(word) {
                hour = h; hasTime = true
                // "tonight" is also a day (today); the other words only say a time.
                if word != "tonight" { s = s.replacingOccurrences(of: word, with: " ") }
                break
            }
        }
        s = s.replacingOccurrences(of: #"\b(at|on|in the|this)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)

        // "in 3 days", "in 2 weeks", "in an hour".
        if let g = groups(#"\bin\s+(\d+|a|an|one|two|three|four|five|six|seven)\s+(minute|min|hour|hr|day|week|month)s?\b"#, in: raw.lowercased()),
           let unit = g[2], let word = g[1] {
            let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7]
            guard let n = Int(word) ?? words[word], n > 0, n < 10_000 else { return nil }
            switch unit {
            case "minute", "min": return cal.date(byAdding: .minute, value: n, to: now)
            case "hour", "hr": return cal.date(byAdding: .hour, value: n, to: now)
            case "day": return at(day(n), hour, minute)
            case "week": return at(day(n * 7), hour, minute)
            default: return at(cal.date(byAdding: .month, value: n, to: today), hour, minute)
            }
        }
        if s.contains("day after tomorrow") { return at(day(2), hour, minute) }
        if s.contains("tomorrow") { return at(day(1), hour, minute) }
        if s.contains("today") || s.contains("tonight") {
            if hasTime { return at(today, hour, minute) }
            // No time given: 09:00, or the next full hour once that has passed.
            if let nine = at(today, 9, 0), nine > now { return nine }
            return cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
        }
        if s.contains("next week") { return at(day(7), hour, minute) }
        if s.contains("next month") { return at(cal.date(byAdding: .month, value: 1, to: today), hour, minute) }

        // "Dec 1", "December 1st 2026", "1 Dec", "1st of December".
        let months = monthNames.joined(separator: "|")
        var monthDay: (month: Int, day: Int, year: Int?)?
        if let g = groups(#"\b("# + months + #")[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+(\d{4}))?\b"#, in: s),
           let mi = g[1].flatMap({ monthNames.firstIndex(of: $0) }), let d = g[2].flatMap({ Int($0) }) {
            monthDay = (mi + 1, d, g[3].flatMap { Int($0) })
        } else if let g = groups(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + months + #")[a-z]*\.?(?:\s+(\d{4}))?\b"#, in: s),
                  let d = g[1].flatMap({ Int($0) }), let mi = g[2].flatMap({ monthNames.firstIndex(of: $0) }) {
            monthDay = (mi + 1, d, g[3].flatMap { Int($0) })
        }
        if let md = monthDay {
            let thisYear = cal.component(.year, from: now)
            if let y = md.year { return built(year: y, month: md.month, day: md.day, hour: hour, minute: minute) }
            if let d = built(year: thisYear, month: md.month, day: md.day, hour: hour, minute: minute), d > now { return d }
            return built(year: thisYear + 1, month: md.month, day: md.day, hour: hour, minute: minute)
        }

        // "friday", "next friday": the next one after today.
        let weekday = #"\b(sun(?:day)?|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?)\b"#
        if let g = groups(weekday, in: s), let wi = g[1].flatMap({ weekdayNames.firstIndex(of: String($0.prefix(3))) }) {
            let current = cal.component(.weekday, from: today) - 1
            var delta = (wi - current + 7) % 7
            if delta == 0 { delta = 7 }
            return at(day(delta), hour, minute)
        }

        // "the 15th": that day of this month, or of the next once it has passed.
        if let g = groups(#"\b(\d{1,2})(?:st|nd|rd|th)\b"#, in: s), let d = g[1].flatMap({ Int($0) }) {
            let y = cal.component(.year, from: now), m = cal.component(.month, from: now)
            if let date = built(year: y, month: m, day: d, hour: hour, minute: minute), date > now { return date }
            return built(year: m == 12 ? y + 1 : y, month: m == 12 ? 1 : m + 1, day: d, hour: hour, minute: minute)
        }
        return nil
    }

    // MARK: get_portfolio

    /// One thing the wallet owns, where it sits, and what it is worth.
    struct Part {
        let place: String
        let what: String
        let usd: Double
    }

    /// "SOL" for Solana's own coin, "USDC on Base", "ETH on Arbitrum".
    static func holdingName(_ symbol: String, _ chain: Chain) -> String {
        symbol == chain.nativeSymbol && chain.kind != .evm ? symbol : "\(symbol) on \(chain.name)"
    }

    /// The total across the wallet, Solana tokens, Aave, staked NEAR and Hyperliquid. Each place is rounded to the cent
    /// and the total is their sum, so the two always agree; places worth nothing are left out. The three biggest single
    /// holdings follow.
    static func portfolio(wallet: String, parts: [Part], unreachable: [String], note: String? = nil) -> [String: Any] {
        var byPlace: [[String: Any]] = []
        var total = 0.0
        for place in ["Wallet", "Spot tokens", "Aave", "NEAR staking", "Hyperliquid"] {
            let sum = r2(parts.filter { $0.place == place }.reduce(0) { $0 + $1.usd })
            if sum >= 0.01 { byPlace.append(["place": place, "usd": sum]); total += sum }
        }
        let top: [[String: Any]] = parts.filter { $0.usd >= 0.01 }.sorted { $0.usd > $1.usd }.prefix(3).map {
            ["place": $0.place, "what": $0.what, "usd": r2($0.usd)]
        }
        var out: [String: Any] = ["by_place": byPlace, "top": top, "total_usd": r2(total), "wallet": wallet]
        if !unreachable.isEmpty { out["unreachable"] = unreachable }
        if let note { out["note"] = note }
        return out
    }

    // MARK: get_activity

    /// "confirmed", "failed" or "in_progress", from the Activity page's own words.
    static func activityStatus(_ s: String) -> String {
        let l = s.lowercased()
        if l == "confirmed" || l == "delivered" { return "confirmed" }
        if l.contains("fail") || l.contains("refund") || l.contains("less than the quote") { return "failed" }
        return "in_progress"
    }

    /// The newest rows as the Activity page words them. Only a confirmed row lets the model say something happened.
    static func activity(_ items: [ActivityItem], limit: Int, calendar: Calendar = .current) -> [String: Any] {
        let rows: [[String: Any]] = items.sorted { $0.date > $1.date }.prefix(max(limit, 1)).map {
            ["what": $0.what, "status": activityStatus($0.status), "time": stamp($0.date, calendar: calendar)]
        }
        let waiting = items.filter { activityStatus($0.status) == "in_progress" }.count
        let tail = "Reviews the user has not approved yet do not appear here."
        return ["activity": rows, "in_progress": waiting, "note": rows.isEmpty ? "No activity yet. " + tail : tail]
    }
}
