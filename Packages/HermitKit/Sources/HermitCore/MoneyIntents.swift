import Foundation

/// Which networks a message names. A model trained on "chain" as a required field fills it in even when the user
/// never said one (usually "ethereum"); a send must not quietly pick a network for the user.
public enum ChainWords {
    /// Chain id -> the words that name it in a message. "eth" alone is the coin, not the network, so it doesn't count.
    public static let names: [(id: String, words: [String])] = [
        ("ethereum", ["ethereum", "mainnet", "eth mainnet", "on eth", "erc20", "erc-20", "l1"]),
        ("base", ["base"]),
        ("arbitrum", ["arbitrum", "arb", "arbitrum one"]),
        ("bnb", ["bnb chain", "bnb", "bsc", "bep20", "bep-20", "binance smart chain"]),
        ("polygon", ["polygon", "matic", "pol"]),
        ("monad", ["monad"]),
        ("robinhood", ["robinhood"]),
        ("solana", ["solana", "sol", "spl"]),
        ("near", ["near"]),
    ]

    /// The chain id a free-text chain argument means ("Base", "bsc", "Arbitrum One"), or nil.
    public static func id(_ arg: String) -> String? {
        let a = arg.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        if let hit = names.first(where: { $0.id == a || $0.words.contains(a) }) { return hit.id }
        let alias = ["eth": "ethereum", "binance": "bnb", "bnbchain": "bnb", "arb1": "arbitrum"]
        return alias[a.replacingOccurrences(of: " ", with: "")] ?? names.first { a.hasPrefix($0.id) }?.id
    }

    /// The text names this chain as a whole word ("on Base", "base network"), not as part of another word.
    public static func mentions(_ chainID: String, in text: String) -> Bool {
        guard let words = names.first(where: { $0.id == chainID })?.words else { return false }
        let t = " " + text.lowercased().replacingOccurrences(of: #"[^a-z0-9\- ]"#, with: " ", options: .regularExpression) + " "
        return words.contains { t.contains(" " + $0 + " ") }
    }

    /// Every chain the text names.
    public static func mentioned(in text: String) -> [String] { names.map(\.id).filter { mentions($0, in: text) } }
}

extension ToolGuard {
    /// Arguments as the toolbox should get them. For sends, a `chain` the user never named in this chat is dropped,
    /// so the toolbox picks the network the user holds the token on, or asks which one, instead of the model's guess.
    public static func adjusted(_ name: String, argumentsJSON: String, userText: String) -> String {
        guard ["prepare_send", "prepare_multisend"].contains(name), let v = JSONValue.parse(argumentsJSON), case .object(var kv) = v,
              let i = kv.firstIndex(where: { $0.0 == "chain" }) else { return argumentsJSON }
        let given = kv[i].1.string ?? ""
        if let id = ChainWords.id(given), ChainWords.mentions(id, in: userText) { return argumentsJSON }
        kv.remove(at: i)
        return JSONValue.object(kv).pythonText
    }

    /// prepare_multisend: every recipient must come from the user, typed in this chat or in a file the user attached
    /// here (their own spreadsheet). An address the model read in a tool result or a web page is refused.
    public static func multisendRefusal(_ arguments: [String: Any], userTextWithFiles: String) -> String? {
        let rows = (arguments["recipients"] as? [Any]) ?? []
        for r in rows {
            guard let a = ((r as? [String: Any])?["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { continue }
            if !userTyped(a, in: userTextWithFiles) {
                return #"{"error":"Refused: \#(a.prefix(12))… isn't in the user's messages or attached file. Only send to addresses the user gave you. Ask them for the list."}"#
            }
        }
        return nil
    }
}

/// A list of payees read from the user's own text or file: one `address, amount` per row (CSV, TSV, XLSX rows,
/// or "0xabc… 25" lines). A header row and other columns are fine; the address and the amount columns are found by
/// what they hold.
public enum RecipientTable {
    public struct Row: Hashable, Sendable {
        public let address: String
        public let amount: String
        /// 1-based line in the source, for "row 31 is invalid" messages.
        public let line: Int
        public init(address: String, amount: String, line: Int) { self.address = address; self.amount = amount; self.line = line }
    }

    /// The most rows one batch takes.
    public static let maxRows = 200

    /// Rows that hold something address-like and a positive amount. Lines with an address but no amount are returned
    /// with an empty amount (shown as invalid on the review), so nothing the user listed is silently dropped.
    public static func parse(_ text: String) -> [Row] {
        var out: [Row] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let cells = split(line)
            guard let a = cells.first(where: looksLikeAddress) else { continue }
            let amount = cells.lazy.filter { $0 != a }.compactMap(Self.amount).first ?? ""
            out.append(Row(address: a, amount: amount, line: n + 1))
        }
        return out
    }

    /// Cells of one line: CSV-style (quotes may hold separators: "1,000"), split on , ; tab or |, else on spaces.
    static func split(_ line: String) -> [String] {
        let seps: Set<Character> = [",", ";", "\t", "|"]
        guard line.contains(where: seps.contains) else {
            return line.components(separatedBy: .whitespaces).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) }.filter { !$0.isEmpty }
        }
        var cells: [String] = [], cur = "", quoted = false
        let it = Array(line); var i = 0
        while i < it.count {
            let c = it[i]
            if c == "\"" {
                if quoted, i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted.toggle() }
            } else if !quoted, seps.contains(c) {
                cells.append(cur); cur = ""
            } else { cur.append(c) }
            i += 1
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '`")) }.filter { !$0.isEmpty }
    }

    /// 0x + 40 hex, a base58 Solana key, or a NEAR account ("alice.near", 64-hex implicit). ENS names too ("bob.eth").
    public static func looksLikeAddress(_ s: String) -> Bool {
        if s.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[a-z0-9_\-]+(\.[a-z0-9_\-]+)*\.(near|eth)$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// "25", "1,000.50", "$25", "25 USDC" -> "25" / "1000.50"; nil for anything else.
    static func amount(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        if let sp = t.firstIndex(of: " ") { t = String(t[..<sp]) }
        guard t.range(of: #"^[0-9]*\.?[0-9]+$"#, options: .regularExpression) != nil, let v = Double(t), v > 0 else { return nil }
        return t.hasPrefix(".") ? "0" + t : t
    }
}

/// Plain requests for a money move that the app can route itself when the model doesn't call the tool: the review still
/// opens, and the user still approves with Face ID. Questions ("how much would I earn") are not requests.
public enum MoneyIntent {
    static func clean(_ text: String) -> String {
        ToolChat.withoutFiles(text).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func isQuestion(_ t: String) -> Bool {
        t.hasPrefix("how ") || t.hasPrefix("what") || t.hasPrefix("should") || t.hasPrefix("is ") || t.hasPrefix("which")
            || t.contains("how much") || t.contains("would i")
    }

    /// "send 10 USDC to each of these", "pay everyone in this spreadsheet", "multisend", "batch send".
    public static func asksToMultisend(_ text: String) -> Bool {
        let t = clean(text)
        guard !isQuestion(t) else { return false }
        return t.range(of: #"multi.?send|batch (send|pay)|airdrop .*(to|these)|(send|pay|distribute)\b.*\b(everyone|every (wallet|address|row|one)|all (the |these |of these )?(wallets|addresses|rows|people)|each (of these|wallet|address|row)|these (wallets|addresses)|the (list|file|sheet|spreadsheet|csv))"#,
                       options: .regularExpression) != nil
    }

    /// "deposit 50 USDC into Aave on Base", "supply my USDC to aave", "put 20 usdc in aave".
    public static func asksToDeposit(_ text: String) -> Bool {
        let t = clean(text)
        guard !isQuestion(t) else { return false }
        return t.range(of: #"^(please\s+|can you\s+|could you\s+)?(deposit|supply|lend|put|stake)\b.*\baave\b"#, options: .regularExpression) != nil
    }

    /// "withdraw my USDC from Aave", "take my usdc out of aave".
    public static func asksToWithdraw(_ text: String) -> Bool {
        let t = clean(text)
        guard !isQuestion(t) else { return false }
        return t.range(of: #"^(please\s+|can you\s+|could you\s+)?(withdraw|redeem|take|pull|remove)\b.*\baave\b"#, options: .regularExpression) != nil
    }

    /// Amount, token and chain from a short request. Chain is only set when the text names one.
    public static func parts(_ text: String) -> (amount: String?, symbol: String?, chain: String?, all: Bool) {
        let t = clean(text)
        var amount: String?, symbol: String?
        let re = try! NSRegularExpression(pattern: #"(?<![a-z0-9.])(?:\$\s*)?([0-9][0-9,]*(?:\.[0-9]+)?)\s*(usdc\.e|usdt0|usdc|usdt|eth|weth|dai)?\b"#)
        if let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) {
            amount = t[r].replacingOccurrences(of: ",", with: "")
            if let s = Range(m.range(at: 2), in: t) { symbol = String(t[s]) }
        }
        if symbol == nil, let m = t.range(of: #"\b(usdc\.e|usdt0|usdc|usdt|dai)\b"#, options: .regularExpression) { symbol = String(t[m]) }
        let all = t.range(of: #"\b(all|everything|max|whole)\b"#, options: .regularExpression) != nil
        return (amount, symbol.map { $0 == "usdc.e" ? "USDC.e" : $0.uppercased() }, ChainWords.mentioned(in: t).first, all)
    }

    /// prepare_deposit arguments for the request, or nil when it isn't one or the amount is missing.
    public static func depositArguments(_ text: String) -> String? {
        guard asksToDeposit(text) else { return nil }
        let p = parts(text)
        guard let amount = p.amount, let sym = p.symbol else { return nil }
        var kv: [(String, JSONValue)] = [("project", .string("aave-v3")), ("symbol", .string(sym))]
        if let c = p.chain { kv.append(("chain", .string(c))) }
        kv.append(("amount", .number(amount)))
        return JSONValue.object(kv).pythonText
    }

    /// prepare_withdraw arguments: amount, or everything when none is given ("withdraw my USDC from Aave").
    public static func withdrawArguments(_ text: String) -> String? {
        guard asksToWithdraw(text) else { return nil }
        let p = parts(text)
        guard let sym = p.symbol else { return nil }
        var kv: [(String, JSONValue)] = [("symbol", .string(sym))]
        if let c = p.chain { kv.append(("chain", .string(c))) }
        if let a = p.amount, !p.all { kv.append(("amount", .number(a))) }
        return JSONValue.object(kv).pythonText
    }

    /// prepare_multisend arguments from typed rows ("0xabc… 10" per line), with the token and chain from the text.
    /// nil without rows or a token.
    public static func multisendArguments(_ text: String) -> String? {
        guard asksToMultisend(text) else { return nil }
        let typed = ToolChat.withoutFiles(text)
        let rows = RecipientTable.parse(typed)
        guard rows.count >= 2 else { return nil }
        let p = parts(typed.components(separatedBy: .newlines).first ?? typed)
        guard let sym = p.symbol ?? parts(typed).symbol else { return nil }
        // "10 USDC to each of these": rows without their own amount get that one.
        let each = typed.lowercased().range(of: #"\b(each|every|per)\b"#, options: .regularExpression) != nil ? p.amount : nil
        var kv: [(String, JSONValue)] = [("symbol", .string(sym))]
        if let c = ChainWords.mentioned(in: typed).first { kv.append(("chain", .string(c))) }
        kv.append(("recipients", .array(rows.prefix(RecipientTable.maxRows).map { r in
            let a = r.amount.isEmpty ? each : r.amount
            return .object([("address", .string(r.address)), ("amount", a.map { .number($0) } ?? .null)])
        })))
        return JSONValue.object(kv).pythonText
    }
}
