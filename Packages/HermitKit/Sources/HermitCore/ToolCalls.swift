import Foundation

/// A JSON value that keeps object key order and the exact text of numbers, so a tool call the model wrote can be
/// rendered back into the prompt the way Python's `json.dumps` wrote it in training (`{"a": 1, "b": "x"}`).
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let x), .bool(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let kv) = self { return kv.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }

    /// Python `json.dumps(v, ensure_ascii=False)`: ", " and ": " separators, keys in their original order.
    public var pythonText: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.quote(s)
        case .array(let a): return "[" + a.map(\.pythonText).joined(separator: ", ") + "]"
        case .object(let kv): return "{" + kv.map { Self.quote($0.0) + ": " + $0.1.pythonText }.joined(separator: ", ") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// Strict parse of one JSON value (whitespace around it allowed). nil when it isn't valid JSON.
    public static func parse(_ text: String) -> JSONValue? {
        var p = Parser(Array(text.unicodeScalars))
        p.skipSpace()
        guard let v = p.value() else { return nil }
        p.skipSpace()
        return p.i == p.c.count ? v : nil
    }

    /// Parse with the repairs small models need: code fences, trailing commas, a missing closing brace or two,
    /// and text after the object. Still nil for anything that isn't recognisably one object.
    public static func parseLenient(_ text: String) -> JSONValue? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix("```") { t = String(t.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if let v = parse(t) { return v }
        guard t.first == "{" else { return nil }
        t = removeTrailingCommas(t)
        if let v = parse(t) { return v }
        // The first complete object, ignoring anything after it.
        if let end = balancedEnd(t), let v = parse(String(t[..<end])) { return v }
        // Close what's still open (outside strings), at most a few levels.
        var stack: [Character] = [], inString = false, escaped = false
        for ch in t {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]": if stack.last == ch { stack.removeLast() } else { return nil }
            default: break
            }
        }
        guard !inString, !stack.isEmpty, stack.count <= 3 else { return nil }
        return parse(removeTrailingCommas(t + String(stack.reversed())))
    }

    static func removeTrailingCommas(_ s: String) -> String {
        var out = "", inString = false, escaped = false
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                out.append(ch); continue
            }
            if ch == "\"" { inString = true }
            if ch == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { continue }
            }
            out.append(ch)
        }
        return out
    }

    /// Index just past the object that starts at the first character, if it closes.
    static func balancedEnd(_ s: String) -> String.Index? {
        var depth = 0, inString = false, escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true }
            else if ch == "{" || ch == "[" { depth += 1 }
            else if ch == "}" || ch == "]" { depth -= 1; if depth == 0 { return s.index(after: i) } }
            i = s.index(after: i)
        }
        return nil
    }

    struct Parser {
        let c: [Unicode.Scalar]; var i = 0
        init(_ c: [Unicode.Scalar]) { self.c = c }
        mutating func skipSpace() { while i < c.count, c[i] == " " || c[i] == "\n" || c[i] == "\t" || c[i] == "\r" { i += 1 } }
        mutating func eat(_ s: String) -> Bool {
            let u = Array(s.unicodeScalars)
            guard i + u.count <= c.count, Array(c[i..<i + u.count]) == u else { return false }
            i += u.count; return true
        }
        mutating func value() -> JSONValue? {
            guard i < c.count else { return nil }
            switch c[i] {
            case "{":
                i += 1; skipSpace()
                var kv: [(String, JSONValue)] = []
                if eat("}") { return .object(kv) }
                while true {
                    skipSpace()
                    guard let k = str() else { return nil }
                    skipSpace(); guard eat(":") else { return nil }; skipSpace()
                    guard let v = value() else { return nil }
                    kv.append((k, v)); skipSpace()
                    if eat(",") { continue }
                    if eat("}") { return .object(kv) }
                    return nil
                }
            case "[":
                i += 1; skipSpace()
                var a: [JSONValue] = []
                if eat("]") { return .array(a) }
                while true {
                    skipSpace(); guard let v = value() else { return nil }
                    a.append(v); skipSpace()
                    if eat(",") { continue }
                    if eat("]") { return .array(a) }
                    return nil
                }
            case "\"": return str().map(JSONValue.string)
            case "t": return eat("true") ? .bool(true) : nil
            case "f": return eat("false") ? .bool(false) : nil
            case "n": return eat("null") ? .null : nil
            default: return number()
            }
        }
        mutating func number() -> JSONValue? {
            let start = i
            if i < c.count, c[i] == "-" { i += 1 }
            let digits = i
            while i < c.count, ("0"..."9").contains(c[i]) { i += 1 }
            guard i > digits else { i = start; return nil }
            if i < c.count, c[i] == "." {
                i += 1; let f = i
                while i < c.count, ("0"..."9").contains(c[i]) { i += 1 }
                guard i > f else { i = start; return nil }
            }
            if i < c.count, c[i] == "e" || c[i] == "E" {
                i += 1
                if i < c.count, c[i] == "+" || c[i] == "-" { i += 1 }
                let e = i
                while i < c.count, ("0"..."9").contains(c[i]) { i += 1 }
                guard i > e else { i = start; return nil }
            }
            var s = String.UnicodeScalarView(); s.append(contentsOf: c[start..<i])
            return .number(String(s))
        }
        mutating func str() -> String? {
            guard i < c.count, c[i] == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while i < c.count {
                let u = c[i]; i += 1
                if u == "\"" { return String(out) }
                if u == "\\" {
                    guard i < c.count else { return nil }
                    let e = c[i]; i += 1
                    switch e {
                    case "\"": out.append("\""); case "\\": out.append("\\"); case "/": out.append("/")
                    case "n": out.append("\n"); case "r": out.append("\r"); case "t": out.append("\t")
                    case "b": out.append("\u{08}"); case "f": out.append("\u{0C}")
                    case "u":
                        guard let v = hex4() else { return nil }
                        if (0xD800..<0xDC00).contains(v), eat("\\u"), let lo = hex4(), (0xDC00..<0xE000).contains(lo) {
                            out.append(Unicode.Scalar(0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00))!)
                        } else { out.append(Unicode.Scalar(v) ?? "\u{FFFD}") }
                    default: return nil
                    }
                } else {
                    out.append(u)
                }
            }
            return nil
        }
        mutating func hex4() -> UInt32? {
            guard i + 4 <= c.count else { return nil }
            var s = String.UnicodeScalarView(); s.append(contentsOf: c[i..<i + 4])
            guard let v = UInt32(String(s), radix: 16) else { return nil }
            i += 4; return v
        }
    }
}

/// One tool call the model asked for: `<tool_call>{"name": ..., "arguments": {...}}</tool_call>`.
public struct ToolCall: Equatable, Sendable {
    public let name: String
    /// The arguments object, in the model's key order.
    public let arguments: JSONValue

    public init(name: String, arguments: JSONValue = .object([])) { self.name = name; self.arguments = arguments }

    /// The arguments as JSON text for the toolbox.
    public var argumentsJSON: String { arguments.pythonText }

    /// The call as the training format renders it inside an assistant turn.
    public var rendered: String { "<tool_call>\n{\"name\": \"" + name + "\", \"arguments\": " + arguments.pythonText + "}\n</tool_call>" }

    /// Reads a call body: `{"name", "arguments"}`, also `parameters` for arguments, arguments given as a JSON string,
    /// or the OpenAI `{"function": {...}}` wrapper. nil when it isn't a call.
    public static func parse(_ body: String) -> ToolCall? {
        guard var o = JSONValue.parseLenient(body), case .object = o else { return nil }
        if let f = o["function"], case .object = f, o["name"] == nil { o = f }
        guard let name = o["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return nil }
        var args = o["arguments"] ?? o["parameters"] ?? .object([])
        if case .string(let s) = args { args = JSONValue.parseLenient(s) ?? .object([]) }
        if case .null = args { args = .object([]) }
        guard case .object = args else { return nil }
        return ToolCall(name: name, arguments: args)
    }
}

/// Splits the model's raw stream into the text the user may see and tool calls. Robust to tags and JSON split across
/// chunks: a possible partial `<tool_call>` at the end of the buffer is held back until it resolves.
public struct ToolCallStream {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case call(ToolCall)
        /// A `<tool_call>` whose body couldn't be read. Never shown.
        case malformed(String)
    }

    static let open = "<tool_call>", close = "</tool_call>"
    private var buffer = ""
    private var inCall = false
    /// Nothing visible has been released this turn yet (a turn that starts with `{` may be a bare JSON call).
    private var atStart = true
    private var bare = false
    /// Tool names this model knows; a bare JSON object is only a call when its name is one of these.
    let known: Set<String>

    public init(known: Set<String> = []) { self.known = known }

    public mutating func push(_ chunk: String) -> [Piece] {
        buffer += chunk
        return drain(final: false)
    }

    /// The end of the turn: anything held back is resolved.
    public mutating func finish() -> [Piece] { drain(final: true) }

    private mutating func drain(final: Bool) -> [Piece] {
        var out: [Piece] = []
        while true {
            if bare {
                // A turn that opened with `{`: hold it until the turn ends, then decide.
                guard final else { return out }
                bare = false
                let t = buffer; buffer = ""
                if let call = ToolCall.parse(t), known.contains(call.name) { out.append(.call(call)) }
                else if t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\"name\"") { out.append(.malformed(t)) }
                else { out.append(.text(t)) }
                return out
            }
            if inCall {
                // Look for the close tag; a new open tag also ends a call that never closed.
                let end = buffer.range(of: Self.close)
                let next = buffer.range(of: Self.open)
                if let e = end, next == nil || e.lowerBound <= next!.lowerBound {
                    out.append(Self.piece(String(buffer[..<e.lowerBound])))
                    buffer = String(buffer[e.upperBound...]); inCall = false; continue
                }
                if let n = next {
                    out.append(Self.piece(String(buffer[..<n.lowerBound])))
                    buffer = String(buffer[n.upperBound...]); continue
                }
                guard final else { return out }
                // The turn ended inside a call (no close tag): read what's there.
                if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(Self.piece(buffer)) }
                buffer = ""; inCall = false
                return out
            }
            if atStart {
                let lead = buffer.drop { $0.isWhitespace }
                if lead.isEmpty { if final { buffer = "" }; return out }
                atStart = false
                if lead.first == "{" && !known.isEmpty { bare = true; continue }
            }
            if let o = buffer.range(of: Self.open) {
                let before = String(buffer[..<o.lowerBound])
                if !before.isEmpty { out.append(.text(before)) }
                buffer = String(buffer[o.upperBound...]); inCall = true; continue
            }
            // A stray close tag outside a call: drop it.
            if let c = buffer.range(of: Self.close) { buffer.removeSubrange(c); continue }
            // Hold back a possible partial tag at the end.
            if !final, let lt = buffer.lastIndex(of: "<"), Self.open.hasPrefix(buffer[lt...]) || Self.close.hasPrefix(buffer[lt...]) {
                let before = String(buffer[..<lt])
                if !before.isEmpty { out.append(.text(before)) }
                buffer = String(buffer[lt...])
                return out
            }
            if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
            return out
        }
    }

    static func piece(_ body: String) -> Piece {
        if let c = ToolCall.parse(body) { return .call(c) }
        return .malformed(body)
    }
}
