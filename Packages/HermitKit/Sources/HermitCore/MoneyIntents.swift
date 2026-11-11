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
    /// Arguments as the toolbox should get them. For sends, deposits, withdrawals and payment reminders, a `chain` the
    /// user never named in this chat is dropped, so the toolbox picks the network the user holds the token (or the
    /// deposit) on, or asks which one, instead of the model's guess.
    public static func adjusted(_ name: String, argumentsJSON: String, userText: String) -> String {
        guard ["prepare_send", "prepare_multisend", "prepare_deposit", "prepare_withdraw", "schedule_payment"].contains(name), let v = JSONValue.parse(argumentsJSON), case .object(var kv) = v,
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
/// or "0xabc… 25" lines). A header row and other columns are fine. A header that names the amount column ("Amount",
/// "USDC", "Total") decides which cell is the amount; without one, a row's amount is its only number, and a row with
/// two numbers (a row number or an invoice id next to the amount) is left without one, so the review flags it
/// instead of paying the wrong figure.
public enum RecipientTable {
    public struct Row: Hashable, Sendable {
        public let address: String
        public let amount: String
        /// 1-based line in the source, for "row 31 is invalid" messages.
        public let line: Int
        /// The amount's column (0-based) when a header row named it; nil when the amount was found by what it holds.
        public let column: Int?
        /// The row has an amount Hermit couldn't read ("25,5", two numbers, a cell under the header that isn't one), as
        /// opposed to no amount at all. A "10 each" from the message never fills such a row: the review flags it.
        public let unclear: Bool
        public init(address: String, amount: String, line: Int, column: Int? = nil, unclear: Bool = false) {
            self.address = address; self.amount = amount; self.line = line; self.column = column; self.unclear = unclear
        }
    }

    /// The most rows one batch takes.
    public static let maxRows = 200

    /// Rows that hold something address-like and a positive amount. Lines with an address but no clear amount are
    /// returned with an empty amount (shown as invalid on the review), so nothing the user listed is silently dropped.
    public static func parse(_ text: String) -> [Row] {
        var out: [Row] = []
        var header: (column: Int, width: Int)?
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        for (n, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A blank line ends a table (sheets of a workbook are separated by one): its header no longer applies.
            guard !line.isEmpty else { header = nil; continue }
            let (cells, delimited) = Self.cells(line)
            guard let ai = cells.firstIndex(where: looksLikeAddress) else {
                if delimited, let c = amountColumn(cells) { header = (c, cells.count) }
                // "0xabc… 25,5": the comma split the address from its amount. Listed and flagged, never dropped.
                else if delimited, let a = cells.flatMap({ $0.components(separatedBy: .whitespaces) }).first(where: looksLikeAddress) {
                    out.append(Row(address: a, amount: "", line: n + 1, unclear: true))
                }
                continue
            }
            let a = cells[ai]
            var amount = ""
            var column: Int?
            var unclear = false
            if delimited, let h = header, h.column != ai {
                // Cells past the header's width that hold a number mean the row split differently ("25,5" unquoted).
                let extra = cells.count > h.width && cells[h.width...].contains { Self.amount($0) != nil }
                if !extra, h.column < cells.count { amount = Self.amount(cells[h.column]) ?? "" }
                column = h.column
                if amount.isEmpty { unclear = extra || (h.column < cells.count && !cells[h.column].isEmpty) }
            } else {
                let numbers = cells.indices.filter { $0 != ai }.compactMap { Self.amount(cells[$0]) }
                let fuzzy = cells.indices.contains { $0 != ai && Self.unclearNumber(cells[$0]) }
                if numbers.count == 1 && !fuzzy { amount = numbers[0] } else { unclear = numbers.count > 1 || fuzzy }
            }
            out.append(Row(address: a, amount: amount, line: n + 1, column: column, unclear: unclear))
        }
        return out
    }

    /// The column a header row names as the amount, or nil when the line isn't such a header (a header holds no
    /// numbers and no address).
    static func amountColumn(_ cells: [String]) -> Int? {
        guard cells.count >= 2, !cells.contains(where: { amount($0) != nil }) else { return nil }
        let named = cells.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if let i = named.firstIndex(where: { $0.range(of: #"\bamounts?\b"#, options: .regularExpression) != nil }) { return i }
        return named.firstIndex { c in
            c.range(of: #"\b(amt|value|qty|quantity|total|sum|payment|payout|salary)\b"#, options: .regularExpression) != nil
                || c.range(of: #"^(pay|usd|usdc|usdt|usdt0|dai|eth|sol|near|tokens?)( \(.*\))?$"#, options: .regularExpression) != nil
        }
    }

    /// Cells of one line, without empty ones: CSV-style (quotes may hold separators: "1,000"), split on the separator
    /// the line uses most (, ; tab or |), else on spaces.
    static func split(_ line: String) -> [String] { cells(line).cells.filter { !$0.isEmpty } }

    /// Cells of one line and whether it had a separator. Delimited lines keep their empty cells, so columns line up
    /// with the header. One separator per line: "Alice;0xabc…;25,5" has a decimal comma, not a fourth column.
    static func cells(_ line: String) -> (cells: [String], delimited: Bool) {
        let order: [Character] = ["\t", ";", "|", ","]
        var counts: [Character: Int] = [:], quoted = false
        for c in line {
            if c == "\"" { quoted.toggle() } else if !quoted, order.contains(c) { counts[c, default: 0] += 1 }
        }
        guard let most = counts.values.max(), let sep = order.first(where: { counts[$0] == most }) else {
            let words = line.components(separatedBy: .whitespaces).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) }
            return (words.filter { !$0.isEmpty }, false)
        }
        var cells: [String] = [], cur = ""
        quoted = false
        let it = Array(line); var i = 0
        while i < it.count {
            let c = it[i]
            if c == "\"" {
                if quoted, i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted.toggle() }
            } else if !quoted, c == sep {
                cells.append(cur); cur = ""
            } else { cur.append(c) }
            i += 1
        }
        cells.append(cur)
        return (cells.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '`")) }, true)
    }

    /// 0x + 40 hex, a base58 Solana key, or a NEAR account ("alice.near", 64-hex implicit). ENS names too ("bob.eth").
    public static func looksLikeAddress(_ s: String) -> Bool {
        if s.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[1-9A-HJ-NP-Za-km-z]{32,44}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[a-z0-9_\-]+(\.[a-z0-9_\-]+)*\.(near|eth)$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// "25", "1,000.50", "$25", "25 USDC" -> "25" / "1000.50"; nil for anything else. A comma only counts as a
    /// thousands separator ("1,000", "12,500.25"): "25,5", "1,25" and "1.000,50" are nil (a decimal comma would
    /// otherwise read as 255), and so is "1 000" (the digits after the space would be lost).
    public static func amount(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        if let sp = t.firstIndex(of: " ") {
            if t[sp...].dropFirst().first?.isNumber == true { return nil }
            t = String(t[..<sp])
        }
        guard let plain = ungrouped(t), plain.range(of: #"^[0-9]*\.?[0-9]+$"#, options: .regularExpression) != nil,
              let v = Double(plain), v > 0 else { return nil }
        return plain.hasPrefix(".") ? "0" + plain : plain
    }

    /// A cell that reads like a number with a comma Hermit won't guess at ("25,5", "1.000,50", "$1,25"), or digits split
    /// by a space ("1 000").
    static func unclearNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard amount(t) == nil else { return false }
        return t.range(of: #"^\$?\s*[0-9][0-9.,]*,[0-9]|^\$?\s*[0-9]+ [0-9]"#, options: .regularExpression) != nil
    }

    /// The number without its thousands commas, or nil when a comma in it isn't one.
    public static func ungrouped(_ t: String) -> String? {
        guard t.contains(",") else { return t }
        guard t.range(of: #"^[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return t.replacingOccurrences(of: ",", with: "")
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

    /// Amount, token and chain from a short request. Chain is only set when the text names one. An amount whose comma
    /// isn't a thousands separator ("1,5") is left out: see `unclearAmount`.
    public static func parts(_ text: String) -> (amount: String?, symbol: String?, chain: String?, all: Bool) {
        let t = clean(text)
        var amount: String?, symbol: String?
        let re = try! NSRegularExpression(pattern: #"(?<![a-z0-9.])(?:\$\s*)?([0-9][0-9,]*(?:\.[0-9]+)?)\s*(usdc\.e|usdt0|usdc|usdt|eth|weth|dai)?\b"#)
        if let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) {
            var n = String(t[r])
            while n.hasSuffix(",") { n.removeLast() }   // "10, then" is 10
            amount = RecipientTable.ungrouped(n)
            if let s = Range(m.range(at: 2), in: t) { symbol = String(t[s]) }
        }
        if symbol == nil, let m = t.range(of: #"\b(usdc\.e|usdt0|usdc|usdt|dai)\b"#, options: .regularExpression) { symbol = String(t[m]) }
        let all = t.range(of: #"\b(all|everything|max|whole)\b"#, options: .regularExpression) != nil
        return (amount, symbol.map { $0 == "usdc.e" ? "USDC.e" : $0.uppercased() }, ChainWords.mentioned(in: t).first, all)
    }

    /// The request's first number has a comma that isn't a thousands separator ("withdraw 1,5 USDC"): the app doesn't
    /// guess (it would otherwise read 15, or no amount, which a withdrawal takes as everything). The model asks.
    static func unclearAmount(_ text: String) -> Bool {
        let t = clean(text)
        guard let r = t.range(of: #"(?<![a-z0-9.])[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression) else { return false }
        var n = String(t[r])
        while n.hasSuffix(",") { n.removeLast() }
        return RecipientTable.ungrouped(n) == nil
    }

    /// prepare_deposit arguments for the request, or nil when it isn't one or the amount is missing.
    public static func depositArguments(_ text: String) -> String? {
        guard asksToDeposit(text), !unclearAmount(text) else { return nil }
        let p = parts(text)
        guard let amount = p.amount, let sym = p.symbol else { return nil }
        var kv: [(String, JSONValue)] = [("project", .string("aave-v3")), ("symbol", .string(sym))]
        if let c = p.chain { kv.append(("chain", .string(c))) }
        kv.append(("amount", .number(amount)))
        return JSONValue.object(kv).pythonText
    }

    /// prepare_withdraw arguments: amount, or everything when none is given ("withdraw my USDC from Aave").
    public static func withdrawArguments(_ text: String) -> String? {
        guard asksToWithdraw(text), !unclearAmount(text) else { return nil }
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
            let a: String? = r.amount.isEmpty ? (r.unclear ? nil : each) : r.amount
            return .object([("address", .string(r.address)), ("amount", a.map { .number($0) } ?? .null)])
        })))
        return JSONValue.object(kv).pythonText
    }
}
