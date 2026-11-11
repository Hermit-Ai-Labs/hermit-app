import Foundation

/// A small JSON value for building JSON-RPC params and reading results.
public enum JSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSON? { if case .object(let o) = self { o[key] } else { nil } }
    public subscript(i: Int) -> JSON? { if case .array(let a) = self, a.indices.contains(i) { a[i] } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
    public var double: Double? { if case .number(let n) = self { n } else { nil } }
    public var int: Int? { double.flatMap { Int(exactly: $0) } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var isNull: Bool { self == .null }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSON...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSON)...) { self = .object(Dictionary(v, uniquingKeysWith: { $1 })) }
}

/// Plain JSON-RPC 2.0 over HTTPS. Never sends anything secret: only addresses, public calls and signed transactions.
public final class JSONRPCClient: Sendable {
    public let url: URL
    let session: URLSession

    public init(url: URL, session: URLSession = .shared) { self.url = url; self.session = session }

    public func call(_ method: String, _ params: [JSON] = []) async throws -> JSON {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSON = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": .array(params)]
        req.httpBody = try JSONEncoder().encode(body)
        var attempt = 0
        while true {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 { // public endpoints rate-limit: wait as long as they ask (capped), then try again
                guard attempt < Self.maxRetries else { throw Self.busy }
                attempt += 1; try await Task.sleep(for: .seconds(Self.retrySeconds(resp, attempt: attempt))); continue
            }
            guard (200..<300).contains(status) else { throw WalletError.rpc(code: status, message: "HTTP \(status) from \(url.host() ?? "node")") }
            let json = try JSONDecoder().decode(JSON.self, from: data)
            if let err = json["error"], !err.isNull {
                throw WalletError.rpc(code: err["code"]?.int ?? -1, message: err["message"]?.string ?? "error")
            }
            guard let result = json["result"] else { throw WalletError.badResponse(method) }
            return result
        }
    }

    /// Retries after an HTTP 429 before giving up.
    static let maxRetries = 4
    /// What a 429 that outlasted the retries says.
    static let busy = WalletError.rpc(code: 429, message: "The network is busy. Try again in a few seconds.")

    /// Seconds to wait before retry `attempt` (1-based) after a 429, plus a little jitter so parallel calls spread out.
    static func retrySeconds(_ resp: URLResponse?, attempt: Int) -> Double {
        let h = resp as? HTTPURLResponse
        return retrySeconds(retryAfter: h?.value(forHTTPHeaderField: "Retry-After"),
                            reset: h?.value(forHTTPHeaderField: "x-ratelimit-method-reset") ?? h?.value(forHTTPHeaderField: "x-ratelimit-reset"),
                            attempt: attempt) + Double.random(in: 0...0.25)
    }

    /// The server's Retry-After (seconds) or rate-limit reset when it gives one, else a growing pause; never over 5 s.
    static func retrySeconds(retryAfter: String?, reset: String?, attempt: Int) -> Double {
        for header in [retryAfter, reset] {
            if let v = header.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), v.isFinite, v >= 0 { return min(v, 5) }
        }
        return min(0.5 * Double(attempt), 5)
    }
}
