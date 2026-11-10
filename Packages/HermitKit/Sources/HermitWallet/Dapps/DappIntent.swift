import Foundation

// What a web app's request would do, in plain words, for the approval sheet. Only what the bytes really say: a known
// ERC-20 call is decoded with its amount, anything else is shown as an unknown contract call with a warning.

/// A decoded request: the sheet's title, summary rows and warnings, plus what the spending policy needs.
public struct DappIntent: Sendable, Equatable {
    public var title: String
    public var lines: [[String]] = []
    public var warnings: [String] = []
    /// Who ends up with the money (a plain send's recipient, a token transfer's recipient, or a contract paid native coin).
    public var payee: EVMAddress?
    /// Dollar value leaving the wallet directly: native value plus a known token's transfer amount. nil when there is
    /// something leaving that has no price.
    public var outflowUSD: Decimal?
    /// Something leaves the wallet directly (native value or a token transfer), so the spending policy applies.
    public var movesFunds = false
}

/// A token's symbol and decimals: from Hermit's own token table when it's a known token, otherwise read from the contract.
public struct DappToken: Sendable, Equatable {
    public let address: EVMAddress
    public let symbol: String
    public let decimals: Int
    /// In Hermit's token table (official address). Otherwise the symbol is whatever the contract says about itself.
    public let known: Bool
    public var label: String { known ? symbol : "\(symbol) (unverified)" }
}

public enum DappDecoder {
    static let approveSel = ERC20.selector("approve(address,uint256)")              // 0x095ea7b3
    static let transferSel = ERC20.selector("transfer(address,uint256)")            // 0xa9059cbb
    static let transferFromSel = ERC20.selector("transferFrom(address,address,uint256)") // 0x23b872dd
    static let increaseSel = ERC20.selector("increaseAllowance(address,uint256)")   // 0x39509351
    static let approvalForAllSel = ERC20.selector("setApprovalForAll(address,bool)") // 0xa22cb465
    static let permit2ApproveSel = ERC20.selector("approve(address,address,uint160,uint48)") // 0x87517c45

    /// The 32-byte word at `i` (after the selector).
    static func word(_ d: [UInt8], _ i: Int) -> ArraySlice<UInt8>? {
        let s = 4 + 32 * i
        return d.count >= s + 32 ? d[s..<s + 32] : nil
    }
    static func address(_ d: [UInt8], _ i: Int) -> EVMAddress? {
        guard let w = word(d, i), w.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
        return EVMAddress(bytes: Array(w.suffix(20)))
    }
    /// nil when the number doesn't fit in 128 bits, which for an allowance means "unlimited" in practice.
    static func amount(_ d: [UInt8], _ i: Int) -> UInt128?? {
        guard let w = word(d, i) else { return nil }
        return .some(UInt128(bigEndian: w.drop(while: { $0 == 0 })))
    }

    public static func short(_ a: EVMAddress) -> String { let s = a.checksummed; return "\(s.prefix(6))…\(s.suffix(4))" }
    public static func short(_ s: String) -> String { s.count > 14 ? "\(s.prefix(6))…\(s.suffix(4))" : s }

    /// Treats an allowance at or above 2^128 (or exactly 2^256-1, the usual "max") as unlimited.
    static func allowanceText(_ v: UInt128?, _ t: DappToken?) -> (String, Bool) {
        guard let v, v < UInt128.max / 2 else { return ("Unlimited", true) }
        guard let t else { return ("\(v) units", false) }
        return ("\(Units.format(v, decimals: t.decimals, maxFraction: 6)) \(t.label)", false)
    }

    /// The token at `address` on `chain`: Hermit's table first, then symbol() and decimals() on the contract.
    public static func token(_ address: EVMAddress, chain: Chain, client: EVMClient) async -> DappToken? {
        if let t = chain.tokens.first(where: { EVMAddress($0.address) == address }) {
            return DappToken(address: address, symbol: t.symbol, decimals: t.decimals, known: true)
        }
        async let symA = try? client.call(to: address, data: ERC20.selector("symbol()"))
        async let decA = try? client.call(to: address, data: ERC20.selector("decimals()"))
        let (sym, dec) = await (symA, decA)
        guard let dec, dec.count == 32, let d = UInt128(bigEndian: dec), d <= 36 else { return nil }
        return DappToken(address: address, symbol: abiString(sym ?? []) ?? "token", decimals: Int(d), known: false)
    }

    /// An ABI-encoded string, or the bytes32 some old tokens return. Printable ASCII only, at most 16 characters.
    static func abiString(_ b: [UInt8]) -> String? {
        var raw: [UInt8]
        if b.count >= 64, let off = UInt128(bigEndian: b[0..<32]), off == 32, let len = UInt128(bigEndian: b[32..<64]),
           len <= 64, b.count >= 64 + Int(len) {
            raw = Array(b[64..<64 + Int(len)])
        } else if b.count == 32 {
            raw = Array(b.prefix(while: { $0 != 0 }))
        } else { return nil }
        raw = raw.filter { (0x20...0x7e).contains($0) }
        guard !raw.isEmpty else { return nil }
        return String(decoding: raw.prefix(16), as: UTF8.self)
    }

    // MARK: eth_sendTransaction

    /// Decodes a transaction. `prices` are USD quotes by symbol (mainnet only). Reads token metadata over RPC.
    public static func transaction(_ r: DappTransactionRequest, chain: Chain, client: EVMClient, prices: [String: Double]) async -> DappIntent {
        let d = r.data
        let native = r.value > 0 ? "\(Units.format(r.value, decimals: chain.nativeDecimals, maxFraction: 8)) \(chain.nativeSymbol)" : nil
        let nativeUSD: Decimal? = r.value == 0 || chain.isTestnet ? 0
            : prices[chain.nativeSymbol].flatMap { p in Decimal(string: Units.format(r.value, decimals: chain.nativeDecimals)).map { $0 * Decimal(p) } }
        var i = DappIntent(title: "Contract call")
        if d.isEmpty {
            i.title = "Send \(native ?? "0 \(chain.nativeSymbol)")"
            i.lines = [["Amount", native ?? "0 \(chain.nativeSymbol)"], ["To", short(r.to)]]
            i.payee = r.to; i.outflowUSD = nativeUSD; i.movesFunds = r.value > 0
            return i
        }
        let sel = Array(d.prefix(4))
        if sel == approveSel || sel == increaseSel, let spender = address(d, 0), let amt = amount(d, 1) {
            let t = await token(r.to, chain: chain, client: client)
            let (text, unlimited) = allowanceText(amt, t)
            let sym = t?.label ?? "a token"
            if amt == 0 {
                i.title = "Remove \(sym) permission"
                i.lines = [["Token", t?.label ?? short(r.to)], ["Revokes", short(spender)]]
            } else {
                i.title = unlimited ? "Approve unlimited \(t?.symbol ?? "tokens")" : "Approve \(text)"
                i.lines = [["Token", t.map { "\($0.label), \(short(r.to))" } ?? short(r.to)], ["Spender", short(spender)], ["Allowance", text]]
                if unlimited {
                    i.warnings.append("Unlimited approval: \(short(spender)) could move all of your \(sym), now and later, until you revoke it. Approve an exact amount on the site if it offers one.")
                } else {
                    i.warnings.append("\(short(spender)) will be able to move up to \(text) from this wallet without asking again.")
                }
            }
            if t == nil { i.warnings.append("\(short(r.to)) didn't answer like a token contract.") }
        } else if sel == transferSel, let to = address(d, 0), let amtW = amount(d, 1) {
            let t = await token(r.to, chain: chain, client: client)
            let amt = amtW ?? 0
            let text = t.map { "\(Units.format(amt, decimals: $0.decimals, maxFraction: 6)) \($0.label)" } ?? "\(amt) units of \(short(r.to))"
            i.title = "Send \(text)"
            i.lines = [["Amount", text], ["To", short(to)]]
            i.payee = to; i.movesFunds = true
            if let t, t.known, TokenTable.stableSymbols.contains(t.symbol), !chain.isTestnet {
                i.outflowUSD = Decimal(string: Units.format(amt, decimals: t.decimals)).map { $0 + (nativeUSD ?? 0) }
            } else if let t, t.known, chain.isTestnet {
                i.outflowUSD = 0
            } else {
                i.outflowUSD = nil
            }
            if amtW == nil { i.warnings.append("The amount is larger than any real token supply.") }
        } else if sel == transferFromSel, let from = address(d, 0), let to = address(d, 1), let amtW = amount(d, 2) {
            let t = await token(r.to, chain: chain, client: client)
            let amt = amtW ?? 0
            let text = t.map { "\(Units.format(amt, decimals: $0.decimals, maxFraction: 6)) \($0.label)" } ?? "\(amt) units"
            i.title = "Move \(text)"
            i.lines = [["Amount", text], ["From", short(from)], ["To", short(to)]]
            if from == r.from { i.payee = to; i.movesFunds = true; i.outflowUSD = nil }
        } else if sel == approvalForAllSel, let op = address(d, 0), let on = word(d, 1) {
            let grant = on.last == 1
            i.title = grant ? "Approve all items in a collection" : "Remove collection permission"
            i.lines = [["Collection", short(r.to)], ["Operator", short(op)], ["Access", grant ? "Every item, now and later" : "Revoked"]]
            if grant { i.warnings.append("\(short(op)) could move every item you hold in this collection. Scam sites use this to empty NFT wallets.") }
        } else if sel == permit2ApproveSel, let tokenA = address(d, 0), let spender = address(d, 1), let amt = amount(d, 2) {
            let t = await token(tokenA, chain: chain, client: client)
            let unlimited = amt.map { $0 >= (UInt128(1) << 100) } ?? true
            let (text, _) = allowanceText(unlimited ? nil : amt, t)
            i.title = unlimited ? "Approve unlimited \(t?.symbol ?? "tokens") via Permit2" : "Approve \(text) via Permit2"
            i.lines = [["Token", t?.label ?? short(tokenA)], ["Spender", short(spender)], ["Allowance", text]]
            i.warnings.append(unlimited
                ? "Unlimited Permit2 approval: \(short(spender)) could move all of your \(t?.label ?? "token") until it expires or you revoke it."
                : "\(short(spender)) will be able to move up to \(text) through Permit2.")
        } else {
            i.title = native.map { "Contract call with \($0)" } ?? "Contract call"
            i.lines = [["Contract", short(r.to)], ["Function", "0x" + sel.hex + " (not decoded)"]]
            i.warnings.append("Hermit can't decode this call, so it can't tell which tokens it moves. Only approve it if you trust this site.")
        }
        if r.value > 0 {
            if let native { i.lines.insert(["Pays", native], at: 0) }
            if !i.movesFunds { i.payee = r.to; i.movesFunds = true; i.outflowUSD = nativeUSD }
        }
        return i
    }

    // MARK: eth_signTypedData_v4

    /// Decodes typed data: EIP-2612 permits and Uniswap Permit2 in full, anything else by its type and fields.
    public static func typedData(_ t: EIP712, chain: Chain, client: EVMClient) async -> DappIntent {
        var i = DappIntent(title: "Sign typed data")
        let domainName = t.domain["name"]?.string
        let contract = t.domain["verifyingContract"]?.string.flatMap(EVMAddress.init)
        let m = t.message
        func obj(_ v: JSONValue?) -> [String: JSONValue]? { if case .object(let o)? = v { return o }; return nil }
        func num(_ v: JSONValue?) -> UInt128?? {
            guard let s = v?.string else { return nil }
            if s.hasPrefix("0x") { return .some(UInt128(quantity: s)) }
            return .some(UInt128(s))
        }
        func deadline(_ v: JSONValue?) -> String? {
            guard let n = num(v), let secs = n, secs < UInt128(UInt64.max) else { return nil }
            if secs > 4_000_000_000 { return "Never" }
            return Date(timeIntervalSince1970: TimeInterval(UInt64(secs))).formatted(date: .abbreviated, time: .shortened)
        }
        switch t.primaryType {
        case "Permit" where m["spender"] != nil && m["value"] != nil:
            let spender = m["spender"]?.string.flatMap(EVMAddress.init)
            var tok: DappToken?
            if let contract { tok = await token(contract, chain: chain, client: client) }
            let amt = num(m["value"]) ?? nil
            let (text, unlimited) = allowanceText(amt, tok)
            i.title = unlimited ? "Permit unlimited \(tok?.symbol ?? "tokens")" : "Permit \(text)"
            i.lines = [["Token", tok?.label ?? contract.map(short) ?? "Unknown"], ["Spender", spender.map(short) ?? "Unknown"], ["Allowance", text]]
            if let d = deadline(m["deadline"]) { i.lines.append(["Valid until", d]) }
            i.warnings.append(unlimited
                ? "This signature is an unlimited token approval: \(spender.map(short) ?? "the spender") could move all of your \(tok?.label ?? "token") without another prompt."
                : "This signature lets \(spender.map(short) ?? "the spender") move up to \(text) without another prompt.")
        case "PermitSingle", "PermitBatch":
            let spender = m["spender"]?.string.flatMap(EVMAddress.init)
            var details: [[String: JSONValue]] = []
            if let o = obj(m["details"]) { details = [o] } else if case .array(let a)? = m["details"] { details = a.compactMap(obj) }
            i.title = "Permit2 token approval"
            i.lines = [["Spender", spender.map(short) ?? "Unknown"]]
            var anyUnlimited = false
            for d in details.prefix(4) {
                let ta = d["token"]?.string.flatMap(EVMAddress.init)
                var tok: DappToken?
                if let ta { tok = await token(ta, chain: chain, client: client) }
                let amt = num(d["amount"]) ?? nil
                let unlimited = amt.map { $0 >= (UInt128(1) << 100) } ?? true
                anyUnlimited = anyUnlimited || unlimited
                i.lines.append(["Allowance", allowanceText(unlimited ? nil : amt, tok).0 + (unlimited ? " \(tok?.label ?? ta.map(short) ?? "")" : "")])
                if let e = deadline(d["expiration"]) { i.lines.append(["Expires", e]) }
            }
            if details.count == 1, let first = i.lines.dropFirst().first { i.title = "Permit2: \(first[1])" }
            i.warnings.append(anyUnlimited
                ? "Unlimited Permit2 approval: \(spender.map(short) ?? "the spender") could move these tokens without another prompt until it expires."
                : "This signature lets \(spender.map(short) ?? "the spender") move the amounts above without another prompt.")
        case "PermitTransferFrom", "PermitWitnessTransferFrom", "PermitBatchTransferFrom", "PermitBatchWitnessTransferFrom":
            let spender = m["spender"]?.string.flatMap(EVMAddress.init)
            var permitted: [[String: JSONValue]] = []
            if let o = obj(m["permitted"]) { permitted = [o] } else if case .array(let a)? = m["permitted"] { permitted = a.compactMap(obj) }
            i.title = "Permit2 transfer"
            i.lines = [["Spender", spender.map(short) ?? "Unknown"]]
            for p in permitted.prefix(4) {
                let ta = p["token"]?.string.flatMap(EVMAddress.init)
                var tok: DappToken?
                if let ta { tok = await token(ta, chain: chain, client: client) }
                i.lines.append(["Up to", allowanceText(num(p["amount"]) ?? nil, tok).0])
            }
            if let d = deadline(m["deadline"]) { i.lines.append(["Valid until", d]) }
            i.warnings.append("This signature lets \(spender.map(short) ?? "the spender") take the tokens above from this wallet once.")
        case "OrderComponents":
            i.title = "Marketplace listing (Seaport)"
            i.lines = [["Marketplace", domainName ?? "Seaport"]]
            i.warnings.append("This signs a marketplace order. Check exactly what you're selling and for how much on the site: Hermit doesn't decode orders.")
        default:
            i.title = domainName.map { "Sign for \($0)" } ?? "Sign typed data"
            i.lines = [["Type", t.primaryType]]
            for f in (t.types[t.primaryType] ?? []).prefix(6) {
                guard let v = m[f.name] else { continue }
                switch v {
                case .object, .array: i.lines.append([f.name, f.type])
                default:
                    let s = v.string ?? (v.bool.map { $0 ? "true" : "false" } ?? "")
                    i.lines.append([f.name, f.type == "address" ? short(s) : String(s.prefix(40))])
                }
            }
        }
        if let domainName, t.primaryType != "OrderComponents" { i.lines.append(["App", String(domainName.prefix(40))]) }
        if let contract { i.lines.append(["Contract", short(contract)]) }
        return i
    }

    // MARK: personal_sign

    /// The message as text when it's readable UTF-8, otherwise hex, plus Sign-In with Ethereum (EIP-4361) checks.
    public static func message(_ bytes: [UInt8], host: String) -> DappIntent {
        var i = DappIntent(title: "Sign a message")
        let text = String(bytes: bytes, encoding: .utf8)
        let readable = text.map { s in !s.isEmpty && s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t" } } ?? false
        if let text, readable {
            let shown = text.count > 420 ? String(text.prefix(420)) + "…" : text
            i.lines = [["Message", shown]]
            if let r = text.range(of: " wants you to sign in with your Ethereum account:") {
                let domain = String(text[..<r.lowerBound]).components(separatedBy: "://").last?.lowercased() ?? ""
                let domainHost = domain.split(separator: ":").first.map(String.init) ?? domain
                i.title = "Sign in to \(domainHost)"
                if domainHost != host.lowercased() {
                    i.warnings.append("This sign-in message is for \(domainHost), but the page asking is \(host). Phishing sites do this to steal a login.")
                }
            }
        } else {
            i.lines = [["Message", bytes.count > 64 ? "0x" + Array(bytes.prefix(64)).hex + "…" : bytes.hex0x], ["Length", "\(bytes.count) bytes"]]
            i.warnings.append(bytes.count == 32
                ? "The site asks you to sign a raw 32-byte hash. Hermit can't show what it stands for. Only sign it if you trust the site completely."
                : "This message isn't readable text. Only sign it if you trust the site.")
        }
        return i
    }
}

// MARK: - Site checks

/// Minimal phishing heuristics on the page's host: punycode, raw IP addresses, and names that look like a site in
/// Hermit's Explore directory without being it. Warnings only: nothing is blocked on a guess.
public enum DappSiteCheck {
    /// The last two labels of a host ("app.uniswap.org" -> "uniswap.org"). Good enough for the directory's domains.
    public static func registrable(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }

    /// Whether `host` is one of the directory's sites or a subdomain of one.
    public static func isListed(_ host: String, known: [String]) -> Bool {
        let h = host.lowercased()
        return known.contains { k in
            let k = k.lowercased()
            return h == k || h == registrable(k) || h.hasSuffix("." + registrable(k))
        }
    }

    public static func warnings(host: String, known: [String]) -> [String] {
        let h = host.lowercased()
        var out: [String] = []
        if h.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            out.append("This address uses international characters (punycode \(h)). It can imitate another site's name letter for letter.")
        }
        if h.allSatisfy({ $0.isNumber || $0 == "." }) || h.contains(":") {
            out.append("This page is a bare IP address, not a named site.")
        }
        guard !isListed(h, known: known) else { return out }
        let reg = registrable(h)
        for k in Set(known.map(registrable)) {
            if h.contains(k + ".") {
                out.append("This address contains \(k) but belongs to \(reg). It is not \(k)."); break
            }
            if reg.count >= 5, k.count >= 5, reg != k, (distance(reg, k) <= (min(reg.count, k.count) < 9 ? 1 : 2) || confusable(reg) == confusable(k)) {
                out.append("This looks like \(k), but it's \(reg). Check the address before connecting."); break
            }
        }
        return out
    }

    /// Letters scam domains swap in for each other.
    static func confusable(_ s: String) -> String {
        s.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w")
            .map { c -> Character in
                switch c { case "0": "o"; case "1", "i": "l"; case "5": "s"; case "3": "e"; case "-": "_"; default: c }
            }.reduce(into: "") { $0.append($1) }
            .replacingOccurrences(of: "_", with: "")
    }

    /// Levenshtein distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
