import Foundation

/// Tool packs for models trained on the v3 tool set (hermit-lab/train/spec/APP_TOOLS_v3.md, section 4).
///
/// Thirty tool lines are about 4,350 tokens, too much to put in front of every chat on a phone. So a chat gets the
/// twelve core tools plus the packs its first message asks for, and keeps that set until New chat: changing the tool
/// block later would throw away the cached prompt prefix. A tool the chat lacks is answered by the model with
/// open_page (core), as its training data does.
///
/// The router is the lab's, rule for rule (hermit-lab/train/gen4/packs.py): the same words, the same counting, the same
/// ranking and caps, so the app sends the tool block the model saw in training for the same first message. The lab's
/// fixture (Tests/HermitCoreTests/Fixtures/render_golden_v3.json, `router.cases` and `router.keywords`) is checked
/// against this file by the tests. When packs.py changes, change this with it.
public enum ToolPacks {
    /// Always offered.
    public static let core: [String] = ["calculator", "get_price", "get_balances", "get_portfolio", "get_address", "get_activity", "prepare_send",
                                        "prepare_swap", "get_quote", "open_page", "open_app", "open_add_funds"]

    /// The packs, in the router's fixed order (the last tie-break).
    public static let packs: [(name: String, tools: [String])] = [
        ("trade", ["hyperliquid_account", "position_math", "search_markets", "prepare_trade", "prepare_close", "cancel_order", "set_tp_sl", "get_positions"]),
        ("solana", ["search_tokens", "prepare_buy", "prepare_sell", "get_positions"]),
        ("earn", ["get_yields", "prepare_deposit", "prepare_withdraw", "get_positions"]),
        ("pay", ["prepare_multisend", "add_contact", "schedule_payment", "create_automation"]),
    ]

    /// Hermit Lite's trade pack is the short one, so core plus one pack stays within 16 tools.
    public static let liteTrade: [String] = ["hyperliquid_account", "prepare_trade", "prepare_close", "cancel_order"]

    /// Hermit 4B: core plus at most two packs and at most 22 tools. Hermit Lite: core plus at most one pack, 16 tools.
    public static let maxPacks = 2, maxTools = 22
    public static let liteMaxPacks = 1, liteMaxTools = 16

    /// The words that call for a pack: packs.py `KEYWORDS`, word for word. Matched as whole words, any case.
    public static let keywords: [String: [String]] = [
        "trade": [
            "long", "longs", "longing", "short", "shorts", "shorting", "leverage", "leveraged", "perp", "perps", "perpetual",
            "perpetuals", "position", "positions", "stop", "stops", "stop loss", "stop-loss", "stoploss", "take profit",
            "take-profit", "tp", "sl", "tp/sl", "cancel order", "cancel my order", "limit order", "limit orders", "liquidation",
            "liquidated", "liq", "funding", "hyperliquid", "hl", "nvda", "nvidia", "tsla", "tesla", "aapl", "apple", "msft",
            "microsoft", "meta", "facebook", "amzn", "amazon", "googl", "goog", "google", "alphabet", "coinbase", "mstr",
            "microstrategy", "hood", "robinhood", "spx", "s&p", "s&p 500", "s&p500", "sp500", "nasdaq", "stock", "stocks",
            "shares",
        ],
        "solana": [
            "buy", "buying", "sell", "selling", "sold", "token", "tokens", "mint", "memecoin", "memecoins", "meme coin", "pump",
            "pumpfun", "pump.fun", "jupiter", "safe",
        ],
        "earn": [
            "aave", "deposit", "deposits", "depositing", "withdraw", "withdrawal", "withdrawing", "yield", "yields", "apy", "apr",
            "earn", "earning", "save", "savings", "lend", "lending",
        ],
        "pay": [
            "contact", "contacts", "payee", "payees", "schedule", "scheduled", "scheduling", "remind", "reminder", "reminders",
            "every day", "every week", "every month", "automation", "automations", "automate", "recurring", "every morning",
            "every evening", "every night", "every hour", "every monday", "every tuesday", "every wednesday", "every thursday",
            "every friday", "every saturday", "every sunday", "every weekday", "weekdays", "daily", "weekly", "monthly",
            "address book",
        ],
    ]

    /// "every 5 minutes", "every 2 hours": a repeat, so pay (packs.py `EVERY_N`).
    static let everyN = #"\bevery\s+\d+\s*(?:min|mins|minutes?|h|hrs?|hours?|days?|weeks?)\b"#
    /// A base58 run as long as a Solana address (packs.py `B58_MINT`); it counts when it has a digit and a letter.
    static let base58Run = #"(?<![1-9A-HJ-NP-Za-km-z])[1-9A-HJ-NP-Za-km-z]{32,44}(?![1-9A-HJ-NP-Za-km-z])"#
    /// An EVM address (packs.py `EVM_ADDR`).
    static let evmAddress = #"0x[0-9a-fA-F]{40}"#
    /// A spreadsheet attachment calls for the pay pack; any other file doesn't (packs.py `SHEET_EXT`).
    public static let sheetExtensions: [String] = [".csv", ".xlsx", ".xls", ".tsv"]

    /// What a chat was given: the packs by name, best first, and every tool name in the registry's order.
    public struct Choice: Equatable, Sendable {
        public let packs: [String]
        public let names: [String]
        /// The tool lines for the prompt, in the registry's order.
        public var lines: [String] { ToolPacks.lines(names) }
    }

    /// The 30 tools in the order of hermit_tools_v3.json, with their prompt lines.
    public static let registry: [(name: String, line: String)] = HermitPrompt.toolLinesV3.compactMap { (line: String) -> (name: String, line: String)? in
        guard let name = JSONValue.parse(line)?["function"]?["name"]?.string else { return nil }
        return (name: name, line: line)
    }

    /// Every v3 tool name, in order.
    public static var allNames: [String] { registry.map { $0.name } }

    /// The tools of one pack for a model family.
    public static func tools(of pack: String, family: HermitPrompt.Family) -> [String] {
        if family == .thinking && pack == "trade" { return liteTrade }
        return packs.first { $0.name == pack }?.tools ?? []
    }

    /// The prompt lines for these tool names, in the registry's order (the order training renders them in).
    public static func lines(_ names: [String]) -> [String] {
        let wanted = Set(names)
        return registry.filter { wanted.contains($0.name) }.map { $0.line }
    }

    /// The names in the registry's order.
    public static func ordered(_ names: Set<String>) -> [String] { allNames.filter { names.contains($0) } }

    /// Core plus the given packs, in the registry's order.
    public static func names(packs chosen: [String], family: HermitPrompt.Family) -> [String] {
        var set = Set(core)
        for p in chosen { set.formUnion(tools(of: p, family: family)) }
        return ordered(set)
    }

    /// A file name that is a spreadsheet ("payroll.xlsx").
    public static func isSheet(_ fileName: String) -> Bool {
        let n = fileName.lowercased()
        return sheetExtensions.contains { n.hasSuffix($0) }
    }

    /// The message as the app hands it to the model carries a spreadsheet: "The user attached the file payees.csv …"
    /// before the file's text.
    public static func sheetAttached(in prompt: String) -> Bool {
        guard let file = prompt.range(of: "<file>", options: .caseInsensitive) else { return false }
        let header = prompt[..<file.lowerBound].lowercased()
        return sheetExtensions.contains { ext in
            header.range(of: NSRegularExpression.escapedPattern(for: ext) + "(?![a-z0-9])", options: .regularExpression) != nil
        }
    }

    /// Where a pattern matches in `text`, left to right, without overlaps.
    static func matches(_ pattern: String, in text: String, anyCase: Bool = false) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: anyCase ? [.caseInsensitive] : []) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { $0.range }
    }

    /// One pattern for a pack's words: whole words only (no letter or digit on either side), the longest word first.
    static func keywordPattern(_ words: [String]) -> String {
        let alternatives = Set(words).map { NSRegularExpression.escapedPattern(for: $0) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        return "(?<![a-z0-9])(?:" + alternatives.joined(separator: "|") + ")(?![a-z0-9])"
    }

    /// How strongly the typed text asks for each pack: the number of hits and where the first one is. Only packs with
    /// a hit are in the result (packs.py `hits`).
    /// - Keywords count once per occurrence.
    /// - solana: every base58 mint in the text.
    /// - pay: every "every N minutes/hours/days"; two or more different addresses (one hit, at the first of them); a
    ///   spreadsheet attachment (one hit, after the text).
    static func hits(_ text: String, sheetAttached: Bool) -> [String: (count: Int, first: Int)] {
        let ns = text as NSString
        let evm = matches(evmAddress, in: text)
        // An EVM address is never read as a base58 mint: blank each one out (42 characters), positions unchanged.
        var blanked = text
        if !evm.isEmpty, let re = try? NSRegularExpression(pattern: evmAddress) {
            blanked = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: String(repeating: " ", count: 42))
        }
        let blankedNS = blanked as NSString
        let mints = matches(base58Run, in: blanked).filter { r in
            let token = blankedNS.substring(with: r)
            return token.contains(where: { $0.isNumber }) && token.contains(where: { $0.isLetter })
        }
        let differentAddresses = Set(evm.map { ns.substring(with: $0) }).count + Set(mints.map { blankedNS.substring(with: $0) }).count
        var out: [String: (count: Int, first: Int)] = [:]
        for pack in packs.map({ $0.name }) {
            var at = matches(keywordPattern(keywords[pack] ?? []), in: text, anyCase: true).map { $0.location }
            if pack == "pay" {
                at += matches(everyN, in: text, anyCase: true).map { $0.location }
                if differentAddresses >= 2, let first = (evm + mints).first { at.append(first.location) }
                if sheetAttached { at.append(ns.length) }
            }
            if pack == "solana" { at += mints.map { $0.location } }
            if let first = at.min() { out[pack] = (count: at.count, first: first) }
        }
        return out
    }

    /// The pack for a chat, from its first message (packs.py `choose_packs` and `choose`).
    /// - Parameters:
    ///   - firstMessage: what the user typed. If it is the whole message with an attached file between its markers, the
    ///     file is left out first: a file's text never picks a pack.
    ///   - hasAttachment: a spreadsheet (csv, xlsx, xls, tsv) is attached. Any other file is `false`.
    ///   - family: `.instruct` is Hermit 4B (two packs, 22 tools), `.thinking` is Hermit Lite (one pack, 16 tools).
    /// Packs are ranked by hits, then by the earliest hit, then in the order trade, solana, earn, pay. The best ones are
    /// taken while the caps hold. No hit: core only.
    public static func choose(firstMessage: String, hasAttachment: Bool, family: HermitPrompt.Family) -> Choice {
        let typed = ToolChat.withoutFiles(firstMessage)
        let found = hits(typed, sheetAttached: hasAttachment)
        let order = packs.map { $0.name }
        let ranked = order.filter { found[$0] != nil }.sorted { a, b in
            let x = found[a] ?? (count: 0, first: 0), y = found[b] ?? (count: 0, first: 0)
            if x.count != y.count { return x.count > y.count }
            if x.first != y.first { return x.first < y.first }
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }
        let lite = family == .thinking
        let packLimit = lite ? liteMaxPacks : maxPacks, toolLimit = lite ? liteMaxTools : maxTools
        var chosen: [String] = []
        var set = Set(core)
        for p in ranked {
            guard chosen.count < packLimit else { break }
            let with = set.union(tools(of: p, family: family))
            if with.count <= toolLimit { chosen.append(p); set = with }
        }
        return Choice(packs: chosen, names: ordered(set))
    }

    /// Older exchanges are dropped once the prompt passes this many characters. The v3 block is longer (up to 22 tool
    /// lines), so Hermit 4B gets more room; Lite's 16 lines fit the old cap.
    public static func maxPromptChars(_ set: HermitPrompt.ToolSet, family: HermitPrompt.Family) -> Int {
        set == .v3 && family == .instruct ? 32_000 : 22_000
    }
}
