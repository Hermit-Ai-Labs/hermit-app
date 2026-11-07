import Foundation

/// EIP-712 typed data (eth_signTypedData_v4): the hash a wallet signs for structured messages. Handles nested
/// structs, arrays, and the atomic types (address, bool, bytes, bytesN, intN, uintN, string).
/// Used by Polymarket orders and by apps connected through WalletConnect.
public struct EIP712: Sendable {
    public struct Field: Sendable, Hashable { public let name: String; public let type: String
        public init(_ name: String, _ type: String) { self.name = name; self.type = type } }

    public let types: [String: [Field]]
    public let primaryType: String
    public let domain: [String: JSONValue]
    public let message: [String: JSONValue]

    public init(types: [String: [Field]], primaryType: String, domain: [String: JSONValue], message: [String: JSONValue]) {
        self.types = types; self.primaryType = primaryType; self.domain = domain; self.message = message
    }

    /// Parses the JSON that dApps send ({types, primaryType, domain, message}).
    public init(json: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let t = o["types"] as? [String: [[String: String]]], let p = o["primaryType"] as? String,
              let d = o["domain"] as? [String: Any], let m = o["message"] as? [String: Any] else {
            throw WalletError.badResponse("Not EIP-712 typed data")
        }
        types = t.mapValues { $0.compactMap { f in f["name"].flatMap { n in f["type"].map { Field(n, $0) } } } }
        primaryType = p
        domain = d.mapValues(JSONValue.init(any:))
        message = m.mapValues(JSONValue.init(any:))
    }

    /// keccak(0x1901 ‖ domainSeparator ‖ hashStruct(message)).
    public func digest() throws -> [UInt8] {
        var all = types
        if all["EIP712Domain"] == nil { all["EIP712Domain"] = Self.domainFields(domain) }
        let ds = try Self.hashStruct("EIP712Domain", domain, all)
        let mh = try Self.hashStruct(primaryType, message, all)
        return Hash.keccak256([0x19, 0x01] + ds + mh)
    }

    public func sign(key: [UInt8]) throws -> String {
        let (rs, recid) = try Secp256k1.sign(digest: try digest(), key: key)
        return (rs + [UInt8(27 + recid)]).hex0x
    }

    static func domainFields(_ d: [String: JSONValue]) -> [Field] {
        [("name", "string"), ("version", "string"), ("chainId", "uint256"), ("verifyingContract", "address"), ("salt", "bytes32")]
            .filter { d[$0.0] != nil }.map { Field($0.0, $0.1) }
    }

    static func encodeType(_ name: String, _ types: [String: [Field]]) -> String {
        var deps = Set<String>()
        func collect(_ t: String) {
            for f in types[t] ?? [] {
                let base = String(f.type.prefix { $0 != "[" })
                if types[base] != nil, base != name, !deps.contains(base) { deps.insert(base); collect(base) }
            }
        }
        collect(name)
        return ([name] + deps.sorted()).map { t in "\(t)(" + (types[t] ?? []).map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")" }.joined()
    }

    static func hashStruct(_ name: String, _ v: [String: JSONValue], _ types: [String: [Field]]) throws -> [UInt8] {
        var enc = Hash.keccak256(Array(encodeType(name, types).utf8))
        for f in types[name] ?? [] { enc += try encodeValue(f.type, v[f.name] ?? .null, types) }
        return Hash.keccak256(enc)
    }

    static func encodeValue(_ type: String, _ v: JSONValue, _ types: [String: [Field]]) throws -> [UInt8] {
        if type.hasSuffix("]") {
            let inner = String(type[..<type.lastIndex(of: "[")!])
            guard case .array(let items) = v else { throw WalletError.badResponse("\(type) expects an array") }
            return Hash.keccak256(try items.flatMap { try encodeValue(inner, $0, types) })
        }
        if types[type] != nil {
            guard case .object(let o) = v else { throw WalletError.badResponse("\(type) expects an object") }
            return try hashStruct(type, o, types)
        }
        switch type {
        case "string": return Hash.keccak256(Array((v.string ?? "").utf8))
        case "bytes": return Hash.keccak256([UInt8](hex: v.string ?? "0x") ?? [])
        case "bool": return word(v.bool == true ? 1 : 0)
        case "address":
            guard let a = v.string.flatMap(EVMAddress.init) else { throw WalletError.badResponse("bad address in typed data") }
            return [UInt8](repeating: 0, count: 12) + a.bytes
        default:
            if type.hasPrefix("bytes"), let n = Int(type.dropFirst(5)), (1...32).contains(n) {
                let b = [UInt8](hex: v.string ?? "") ?? []
                guard b.count <= 32 else { throw WalletError.badResponse("\(type) value is too long") }
                return b + [UInt8](repeating: 0, count: 32 - b.count)   // bytesN is left-aligned
            }
            if type.hasPrefix("uint") || type.hasPrefix("int") { return try integer(v, signed: type.hasPrefix("int")) }
            throw WalletError.badResponse("Unsupported typed-data type \(type)")
        }
    }

    /// Numbers arrive as JSON numbers, decimal strings or 0x hex; up to 2^128 here, which covers amounts and ids we sign.
    static func integer(_ v: JSONValue, signed: Bool) throws -> [UInt8] {
        let s: String
        switch v {
        case .number(let d): s = String(format: "%.0f", d)
        case .string(let t): s = t
        case .bool(let b): s = b ? "1" : "0"
        default: s = "0"
        }
        let neg = s.hasPrefix("-")
        let body = neg ? String(s.dropFirst()) : s
        let mag: [UInt8]
        if body.hasPrefix("0x") { mag = [UInt8](hex: body) ?? [] }
        else { mag = try decimalBytes(body) }
        var w = [UInt8](repeating: 0, count: max(0, 32 - mag.count)) + mag.suffix(32)
        if neg && signed {   // two's complement
            w = w.map { ~$0 }
            var i = 31; while i >= 0 { w[i] &+= 1; if w[i] != 0 { break }; i -= 1 }
        }
        return w
    }

    /// Arbitrary-length decimal string → big-endian bytes (token ids are often longer than 2^128).
    static func decimalBytes(_ s: String) throws -> [UInt8] {
        var out: [UInt8] = []   // little-endian base-256
        for ch in s {
            guard let d = ch.wholeNumberValue else { throw WalletError.badResponse("bad number \(s)") }
            var carry = d
            for i in 0..<out.count { let v = Int(out[i]) * 10 + carry; out[i] = UInt8(v & 0xff); carry = v >> 8 }
            while carry > 0 { out.append(UInt8(carry & 0xff)); carry >>= 8 }
        }
        return out.reversed()
    }

    static func word(_ x: UInt8) -> [UInt8] { [UInt8](repeating: 0, count: 31) + [x] }
}

/// Plain JSON values for typed data.
public enum JSONValue: Sendable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(any v: Any) {
        switch v {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too; CFBoolean tells them apart.
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; if case .number(let d) = self { return String(format: "%.0f", d) }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}
