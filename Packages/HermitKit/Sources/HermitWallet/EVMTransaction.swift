import Foundation

// MARK: - RLP

public indirect enum RLP: Equatable, Sendable {
    case bytes([UInt8])
    case list([RLP])

    static func uint<T: FixedWidthInteger & UnsignedInteger>(_ v: T) -> RLP { .bytes(v.minimalBigEndian) }

    public var encoded: [UInt8] {
        switch self {
        case .bytes(let b):
            if b.count == 1 && b[0] < 0x80 { return b }
            return RLP.header(b.count, offset: 0x80) + b
        case .list(let items):
            let body = items.flatMap(\.encoded)
            return RLP.header(body.count, offset: 0xC0) + body
        }
    }

    static func header(_ len: Int, offset: UInt8) -> [UInt8] {
        if len < 56 { return [offset + UInt8(len)] }
        let l = UInt64(len).minimalBigEndian
        return [offset + 55 + UInt8(l.count)] + l
    }

    /// Strict decoder (rejects trailing bytes and non-canonical lengths). Used to check what we built.
    public static func decode(_ data: [UInt8]) -> RLP? {
        guard let (item, used) = decodeOne(data[...]), used == data.count else { return nil }
        return item
    }

    private static func decodeOne(_ d: ArraySlice<UInt8>) -> (RLP, Int)? {
        guard let first = d.first else { return nil }
        let s = d.startIndex
        func len(_ n: Int) -> Int? {
            guard n <= 8, d.count > n else { return nil }
            var v = 0
            for b in d[(s + 1)...(s + n)] { v = v << 8 | Int(b) }
            return v >= 56 && d[s + 1] != 0 ? v : nil
        }
        switch first {
        case 0..<0x80: return (.bytes([first]), 1)
        case 0x80...0xB7:
            let n = Int(first - 0x80)
            guard d.count > n else { return nil }
            let b = Array(d[(s + 1)..<(s + 1 + n)])
            if n == 1 && b[0] < 0x80 { return nil }
            return (.bytes(b), 1 + n)
        case 0xB8...0xBF:
            let ll = Int(first - 0xB7)
            guard let n = len(ll), d.count >= 1 + ll + n else { return nil }
            return (.bytes(Array(d[(s + 1 + ll)..<(s + 1 + ll + n)])), 1 + ll + n)
        default:
            var ll = 0, n: Int
            if first <= 0xF7 { n = Int(first - 0xC0) } else {
                ll = Int(first - 0xF7)
                guard let v = len(ll) else { return nil }
                n = v
            }
            guard d.count >= 1 + ll + n else { return nil }
            var items = [RLP](); var i = s + 1 + ll
            let end = i + n
            while i < end {
                guard let (item, used) = decodeOne(d[i..<end]) else { return nil }
                items.append(item); i += used
            }
            return (.list(items), 1 + ll + n)
        }
    }

    var bytesValue: [UInt8]? { if case .bytes(let b) = self { b } else { nil } }
    var listValue: [RLP]? { if case .list(let l) = self { l } else { nil } }
}

// MARK: - EIP-1559 (type 2) transactions

public struct EIP1559Transaction: Equatable, Sendable {
    public var chainId: UInt64
    public var nonce: UInt64
    public var maxPriorityFeePerGas: UInt128
    public var maxFeePerGas: UInt128
    public var gasLimit: UInt64
    public var to: EVMAddress
    public var value: UInt128
    public var data: [UInt8]

    public init(chainId: UInt64, nonce: UInt64, maxPriorityFeePerGas: UInt128, maxFeePerGas: UInt128, gasLimit: UInt64,
                to: EVMAddress, value: UInt128, data: [UInt8]) {
        self.chainId = chainId; self.nonce = nonce; self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas; self.gasLimit = gasLimit; self.to = to; self.value = value; self.data = data
    }

    var fields: [RLP] {
        [.uint(chainId), .uint(nonce), .uint(maxPriorityFeePerGas), .uint(maxFeePerGas), .uint(gasLimit),
         .bytes(to.bytes), .uint(value), .bytes(data), .list([])]
    }

    /// keccak256(0x02 || rlp([chainId, nonce, tip, maxFee, gas, to, value, data, accessList]))
    public var signingHash: [UInt8] { Hash.keccak256([0x02] + RLP.list(fields).encoded) }

    /// The highest fee this transaction can cost.
    public var maxFee: UInt128 { maxFeePerGas * UInt128(gasLimit) }

    /// Signs with a raw secp256k1 key. The caller wipes the key.
    public func sign(privateKey: [UInt8]) throws -> SignedEVMTransaction {
        let (rs, recid) = try Secp256k1.sign(digest: signingHash, key: privateKey)
        let r = Array(rs[0..<32]), s = Array(rs[32..<64])
        let raw = [0x02] + RLP.list(fields + [.uint(UInt8(recid)), .bytes(stripZeros(r)), .bytes(stripZeros(s))]).encoded
        return SignedEVMTransaction(tx: self, raw: raw, yParity: UInt8(recid), r: r, s: s)
    }

    /// Parses a signed type-2 transaction. Used to double-check the bytes before broadcasting.
    public static func decode(raw: [UInt8]) -> SignedEVMTransaction? {
        guard raw.first == 0x02, let items = RLP.decode(Array(raw.dropFirst()))?.listValue, items.count == 12,
              let f = Optional(items.compactMap(\.bytesValue)), f.count == 11, items[8].listValue?.isEmpty == true,
              let chain = UInt64(exactly: UInt128(bigEndian: f[0]) ?? .max), let nonce = UInt64(exactly: UInt128(bigEndian: f[1]) ?? .max),
              let tip = UInt128(bigEndian: f[2]), let maxFee = UInt128(bigEndian: f[3]),
              let gas = UInt64(exactly: UInt128(bigEndian: f[4]) ?? .max), f[5].count == 20,
              let value = UInt128(bigEndian: f[6]), let v = UInt128(bigEndian: f[8]), v <= 1, f[9].count <= 32, f[10].count <= 32
        else { return nil }
        let tx = EIP1559Transaction(chainId: chain, nonce: nonce, maxPriorityFeePerGas: tip, maxFeePerGas: maxFee, gasLimit: gas,
                                    to: EVMAddress(bytes: f[5]), value: value, data: f[7])
        let pad = { (b: [UInt8]) in [UInt8](repeating: 0, count: 32 - b.count) + b }
        return SignedEVMTransaction(tx: tx, raw: raw, yParity: UInt8(v), r: pad(f[9]), s: pad(f[10]))
    }
}

public struct SignedEVMTransaction: Equatable, Sendable {
    public let tx: EIP1559Transaction
    public let raw: [UInt8]
    public let yParity: UInt8
    public let r: [UInt8]
    public let s: [UInt8]
    public var hash: String { Hash.keccak256(raw).hex0x }
    /// Recovers the sender from the signature.
    public var sender: EVMAddress? {
        Secp256k1.recover(digest: tx.signingHash, rs: r + s, recid: Int32(yParity)).map(EVMAddress.init(publicKey:))
    }
}

func stripZeros(_ b: [UInt8]) -> [UInt8] { Array(b.drop(while: { $0 == 0 })) }

// MARK: - ERC-20 calldata

public enum ERC20 {
    static func word(_ v: UInt128) -> [UInt8] { v.bigEndianBytes(width: 32) }
    static func word(_ a: EVMAddress) -> [UInt8] { [UInt8](repeating: 0, count: 12) + a.bytes }
    static func selector(_ sig: String) -> [UInt8] { Array(Hash.keccak256(Array(sig.utf8))[0..<4]) }

    public static func transfer(to: EVMAddress, amount: UInt128) -> [UInt8] {
        selector("transfer(address,uint256)") + word(to) + word(amount) // 0xa9059cbb
    }
    public static func balanceOf(_ owner: EVMAddress) -> [UInt8] { selector("balanceOf(address)") + word(owner) } // 0x70a08231

    /// Reads (to, amount) back out of transfer calldata, to check it says what the summary says.
    public static func decodeTransfer(_ data: [UInt8]) -> (EVMAddress, UInt128)? {
        guard data.count == 68, Array(data[0..<4]) == selector("transfer(address,uint256)"),
              data[4..<16].allSatisfy({ $0 == 0 }), let amount = UInt128(bigEndian: data[36..<68]) else { return nil }
        return (EVMAddress(bytes: Array(data[16..<36])), amount)
    }
}
