import Foundation

public struct EVMFees: Equatable, Sendable {
    public var baseFee: UInt128
    public var maxPriorityFeePerGas: UInt128
    public var maxFeePerGas: UInt128
}

public struct EVMReceipt: Equatable, Sendable {
    public var hash: String
    public var success: Bool
    public var blockNumber: UInt64
    public var gasUsed: UInt128
    public var effectiveGasPrice: UInt128
}

/// Read and broadcast on one EVM chain over JSON-RPC.
public final class EVMClient: Sendable {
    public let rpc: JSONRPCClient
    public init(url: URL, session: URLSession = .shared) { rpc = JSONRPCClient(url: url, session: session) }

    func quantity(_ j: JSON, _ what: String) throws -> UInt128 {
        guard let s = j.string, let v = UInt128(quantity: s) else { throw WalletError.badResponse(what) }
        return v
    }
    func u64(_ j: JSON, _ what: String) throws -> UInt64 {
        guard let v = UInt64(exactly: try quantity(j, what)) else { throw WalletError.badResponse(what) }
        return v
    }

    public func chainId() async throws -> UInt64 { try u64(try await rpc.call("eth_chainId"), "eth_chainId") }
    public func blockNumber() async throws -> UInt64 { try u64(try await rpc.call("eth_blockNumber"), "eth_blockNumber") }

    /// Next nonce, counting pending transactions.
    public func nonce(_ a: EVMAddress) async throws -> UInt64 {
        try u64(try await rpc.call("eth_getTransactionCount", [.string(a.checksummed), "pending"]), "nonce")
    }

    /// `block` "pending" reads Base's Flashblocks preconfirmations (about 200 ms after a transfer) on its preconf RPC.
    public func balance(_ a: EVMAddress, block: String = "latest") async throws -> UInt128 {
        try quantity(try await rpc.call("eth_getBalance", [.string(a.checksummed), .string(block)]), "balance")
    }

    public func call(to: EVMAddress, data: [UInt8], from: EVMAddress? = nil, value: UInt128 = 0, block: String = "latest") async throws -> [UInt8] {
        let r = try await rpc.call("eth_call", [callObject(to: to, data: data, from: from, value: value), .string(block)])
        guard let s = r.string, let b = [UInt8](hex: s) else { throw WalletError.badResponse("eth_call") }
        return b
    }

    public func tokenBalance(token: EVMAddress, owner: EVMAddress, block: String = "latest") async throws -> UInt128 {
        let out = try await call(to: token, data: ERC20.balanceOf(owner), block: block)
        guard out.count == 32, let v = UInt128(bigEndian: out) else { throw WalletError.badResponse("balanceOf") }
        return v
    }

    public func estimateGas(from: EVMAddress, to: EVMAddress, data: [UInt8], value: UInt128) async throws -> UInt64 {
        try u64(try await rpc.call("eth_estimateGas", [callObject(to: to, data: data, from: from, value: value)]), "estimateGas")
    }

    /// EIP-1559 fees: the tip is the median 50th-percentile reward of the last 5 blocks (eth_feeHistory),
    /// falling back to eth_maxPriorityFeePerGas; maxFee = 2 x next base fee + tip, so it survives a few full blocks.
    public func fees() async throws -> EVMFees {
        let h = try await rpc.call("eth_feeHistory", ["0x5", "latest", [50]])
        guard let bases = h["baseFeePerGas"]?.array, let next = bases.last else { throw WalletError.badResponse("feeHistory") }
        let baseFee = try quantity(next, "baseFee")
        let rewards = (h["reward"]?.array ?? []).compactMap { $0[0]?.string }.compactMap { UInt128(quantity: $0) }.sorted()
        var tip = rewards.isEmpty ? 0 : rewards[rewards.count / 2]
        if tip == 0, let t = try? await rpc.call("eth_maxPriorityFeePerGas"), let v = t.string.flatMap({ UInt128(quantity: $0) }) { tip = v }
        if baseFee == 0 && tip == 0, let g = try? await rpc.call("eth_gasPrice"), let v = g.string.flatMap({ UInt128(quantity: $0) }) {
            tip = v // chains like BNB with no base fee
        }
        return EVMFees(baseFee: baseFee, maxPriorityFeePerGas: tip, maxFeePerGas: baseFee * 2 + tip)
    }

    public func sendRawTransaction(_ raw: [UInt8]) async throws -> String {
        guard let h = try await rpc.call("eth_sendRawTransaction", [.string(raw.hex0x)]).string else { throw WalletError.badResponse("send") }
        return h
    }

    public func receipt(_ hash: String) async throws -> EVMReceipt? {
        let r = try await rpc.call("eth_getTransactionReceipt", [.string(hash)])
        if r.isNull { return nil }
        guard let st = r["status"] else { throw WalletError.badResponse("receipt") }
        return EVMReceipt(hash: hash, success: try quantity(st, "status") == 1, blockNumber: try u64(r["blockNumber"] ?? .null, "block"),
                          gasUsed: try quantity(r["gasUsed"] ?? .null, "gasUsed"),
                          effectiveGasPrice: (try? quantity(r["effectiveGasPrice"] ?? .null, "price")) ?? 0)
    }

    /// Polls for the receipt (every `every`, up to `timeout`).
    public func waitForReceipt(_ hash: String, timeout: Duration = .seconds(120), every: Duration = .seconds(2)) async throws -> EVMReceipt {
        let clock = ContinuousClock(); let deadline = clock.now + timeout
        while clock.now < deadline {
            try Task.checkCancellation()
            if let r = try? await receipt(hash) { return r }
            try await Task.sleep(for: every)
        }
        throw WalletError.timeout
    }

    func callObject(to: EVMAddress, data: [UInt8], from: EVMAddress?, value: UInt128) -> JSON {
        var o: [String: JSON] = ["to": .string(to.checksummed), "data": .string(data.hex0x)]
        if let from { o["from"] = .string(from.checksummed) }
        if value > 0 { o["value"] = .string(value.quantity) }
        return .object(o)
    }
}

// MARK: - ENS

/// Resolves plain ENS names (alice.eth) on Ethereum mainnet: registry -> resolver -> addr(bytes32).
/// Not supported yet: ENSIP-10 wildcard / CCIP-read (offchain) names such as Basenames or cb.id, and full
/// ENSIP-15 normalisation (we only accept lowercase ASCII names to stay safe).
public enum ENS {
    static let registry = EVMAddress("0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e")!

    public static func looksLikeName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return t.contains(".") && !t.hasPrefix("0x") && t.hasSuffix(".eth")
    }

    public static func namehash(_ name: String) -> [UInt8] {
        var node = [UInt8](repeating: 0, count: 32)
        guard !name.isEmpty else { return node }
        for label in name.split(separator: ".").reversed() {
            node = Hash.keccak256(node + Hash.keccak256(Array(label.utf8)))
        }
        return node
    }

    public static func resolve(_ raw: String, client: EVMClient) async throws -> EVMAddress {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }),
              !name.contains("..") else { throw WalletError.nameNotFound(raw) }
        let node = namehash(name)
        let r = try await client.call(to: registry, data: ERC20.selector("resolver(bytes32)") + node)
        guard r.count == 32, r[0..<12].allSatisfy({ $0 == 0 }) else { throw WalletError.nameNotFound(raw) }
        let resolver = EVMAddress(bytes: Array(r[12..<32]))
        guard resolver.bytes != [UInt8](repeating: 0, count: 20) else { throw WalletError.nameNotFound(raw) }
        let a = try await client.call(to: resolver, data: ERC20.selector("addr(bytes32)") + node)
        guard a.count == 32, a[0..<12].allSatisfy({ $0 == 0 }) else { throw WalletError.nameNotFound(raw) }
        let addr = EVMAddress(bytes: Array(a[12..<32]))
        guard addr.bytes != [UInt8](repeating: 0, count: 20) else { throw WalletError.nameNotFound(raw) }
        return addr
    }
}
