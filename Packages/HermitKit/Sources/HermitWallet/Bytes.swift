import Foundation

// Small byte, hex and amount helpers shared by the wallet code.

public enum WalletError: Error, LocalizedError, Equatable {
    case invalidMnemonic
    case invalidKey
    case invalidAddress(String)
    case invalidAmount(String)
    case unknownToken
    case nameNotFound(String)
    case rpc(code: Int, message: String)
    case badResponse(String)
    case simulationFailed(String)
    case blocked(String)
    case insufficientFunds(String)
    case vault(String)
    case cancelled
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidMnemonic: "That recovery phrase isn't valid."
        case .invalidKey: "Key derivation failed."
        case .invalidAddress(let a): "Not a valid address: \(a)"
        case .invalidAmount(let a): "Not a valid amount: \(a)"
        case .unknownToken: "That token isn't supported on this network."
        case .nameNotFound(let n): "Couldn't resolve \(n)."
        case .rpc(_, let m): "Network error: \(m)"
        case .badResponse(let m): "Unexpected response: \(m)"
        case .simulationFailed(let m): "Simulation failed: \(m)"
        case .blocked(let m): m
        case .insufficientFunds(let m): m
        case .vault(let m): m
        case .cancelled: "Cancelled."
        case .timeout: "Timed out waiting for confirmation."
        }
    }
}

extension Array where Element == UInt8 {
    public init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        if s.count % 2 == 1 { s = "0" + s }
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        self = out
    }
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
    public var hex0x: String { "0x" + hex }

    /// Overwrites the bytes with zeros (best effort: Swift may have made copies elsewhere).
    public mutating func wipe() {
        let n = count
        withUnsafeMutableBytes { p in
            guard let base = p.baseAddress else { return }
            _ = memset_s(base, n, 0, n)
        }
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}

/// A secret held in its own heap buffer and wiped when released. Seeds and private keys live in these.
public final class SecretBytes: @unchecked Sendable {
    private let ptr: UnsafeMutableRawBufferPointer
    private let _count: Int
    public var count: Int { _count }
    public init(_ bytes: [UInt8]) {
        let p = UnsafeMutableRawBufferPointer.allocate(byteCount: Swift.max(bytes.count, 1), alignment: 16)
        p.initializeMemory(as: UInt8.self, repeating: 0)
        bytes.withUnsafeBytes { src in if let b = src.baseAddress { p.baseAddress!.copyMemory(from: b, byteCount: bytes.count) } }
        ptr = p
        _count = bytes.count
    }
    /// Hands the bytes to `body` as a temporary array that is wiped afterwards.
    public func withBytes<T>(_ body: ([UInt8]) throws -> T) rethrows -> T {
        var copy = [UInt8](UnsafeRawBufferPointer(rebasing: ptr[0..<_count]))
        defer { copy.wipe() }
        return try body(copy)
    }
    deinit {
        _ = memset_s(ptr.baseAddress!, ptr.count, 0, ptr.count)
        ptr.deallocate()
    }
}

// MARK: - Big-endian integers

extension FixedWidthInteger where Self: UnsignedInteger {
    /// Minimal big-endian bytes (zero becomes an empty array), as RLP wants.
    var minimalBigEndian: [UInt8] {
        var v = self; var out = [UInt8]()
        while v != 0 { out.insert(UInt8(truncatingIfNeeded: v), at: 0); v >>= 8 }
        return out
    }
    func bigEndianBytes(width: Int) -> [UInt8] {
        let m = minimalBigEndian
        return [UInt8](repeating: 0, count: Swift.max(0, width - m.count)) + m
    }
    func littleEndianBytes(width: Int) -> [UInt8] {
        var v = self; var out = [UInt8]()
        for _ in 0..<width { out.append(UInt8(truncatingIfNeeded: v)); v >>= 8 }
        return out
    }
}

extension UInt128 {
    /// Parses big-endian bytes; fails if the value doesn't fit in 128 bits.
    init?(bigEndian bytes: some Collection<UInt8>) {
        var v: UInt128 = 0
        for b in bytes {
            if v >> 120 != 0 { return nil }
            v = (v << 8) | UInt128(b)
        }
        self = v
    }
    /// Parses a JSON-RPC quantity like "0x1a".
    init?(quantity: String) {
        var s = Substring(quantity)
        if s.hasPrefix("0x") { s = s.dropFirst(2) }
        if s.isEmpty { self = 0; return }
        let trimmed = s.drop(while: { $0 == "0" })
        guard trimmed.count <= 32, let v = UInt128(trimmed.isEmpty ? "0" : trimmed, radix: 16) else { return nil }
        self = v
    }
    var quantity: String { "0x" + String(self, radix: 16) }
}

// MARK: - Amounts

public enum Units {
    /// "1.5" with 6 decimals -> 1_500_000. Rejects more decimals than the token has, negatives and junk.
    public static func parse(_ text: String, decimals: Int) throws -> UInt128 {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !t.isEmpty, parts.count <= 2, parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              !(parts[0].isEmpty && (parts.count == 1 || parts[1].isEmpty)) else { throw WalletError.invalidAmount(text) }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        var frac = parts.count == 2 ? String(parts[1]) : ""
        guard frac.count <= decimals else { throw WalletError.invalidAmount(text) }
        frac += String(repeating: "0", count: decimals - frac.count)
        let digits = (whole + frac).drop(while: { $0 == "0" })
        guard digits.count <= 38, let v = UInt128(digits.isEmpty ? "0" : String(digits)) else { throw WalletError.invalidAmount(text) }
        return v
    }

    /// 1_500_000 with 6 decimals -> "1.5". `maxFraction` trims (rounds down) long tails for display.
    public static func format(_ value: UInt128, decimals: Int, maxFraction: Int? = nil) -> String {
        var s = String(value)
        if decimals == 0 { return s }
        if s.count <= decimals { s = String(repeating: "0", count: decimals - s.count + 1) + s }
        let cut = s.index(s.endIndex, offsetBy: -decimals)
        var frac = String(s[cut...])
        if let m = maxFraction, frac.count > m { frac = String(frac.prefix(m)) }
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? String(s[..<cut]) : "\(s[..<cut]).\(frac)"
    }
}
