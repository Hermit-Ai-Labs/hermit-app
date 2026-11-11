import Foundation

// What a web app's contract call would move in and out of the wallet, from eth_simulateV1 with traceTransfers: the node
// runs the call on the latest block and reports every ERC-20 Transfer log plus a synthetic Transfer log (from the
// 0xeeee…ee pseudo address) for each native coin move. Nothing is signed or sent.

/// One asset's movement in a simulated call, in exact base units. `token` nil is the chain's native coin.
public struct EVMBalanceChange: Sendable, Equatable {
    public let token: EVMAddress?
    public var sent: UInt128
    public var received: UInt128
    public init(token: EVMAddress?, sent: UInt128, received: UInt128) {
        self.token = token; self.sent = sent; self.received = received
    }
    /// What leaves the wallet after netting what comes back (0 when it gains).
    public var netSent: UInt128 { sent > received ? sent - received : 0 }
    public var netReceived: UInt128 { received > sent ? received - sent : 0 }
}

/// An allowance the wallet grants during a simulated call: nothing moves yet, but `spender` can take from `contract` later.
public struct EVMApprovalGrant: Sendable, Equatable {
    public let contract: EVMAddress
    public let spender: EVMAddress
    public init(contract: EVMAddress, spender: EVMAddress) { self.contract = contract; self.spender = spender }
}

/// The wallet's side of a simulated call.
public struct EVMSimulatedTransfers: Sendable, Equatable {
    /// Native coin first, then tokens in the order the call first touched them.
    public var changes: [EVMBalanceChange]
    /// NFT collections an item (an ERC-721 Transfer, id indexed, or an ERC-1155 transfer) leaves the wallet from, once per log.
    public var nftsSent: [EVMAddress]
    /// Allowances the wallet grants (ERC-20 or ERC-721 Approval, ApprovalForAll); revokes are left out.
    public var approvals: [EVMApprovalGrant]
    public init(changes: [EVMBalanceChange], nftsSent: [EVMAddress], approvals: [EVMApprovalGrant] = []) {
        self.changes = changes; self.nftsSent = nftsSent; self.approvals = approvals
    }
}

extension EVMClient {
    static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    static let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"
    static let approvalForAllTopic = "0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31"
    static let transferSingleTopic = "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62"
    static let transferBatchTopic = "0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb"
    static let nativeTransferPseudo = EVMAddress("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")!

    /// Simulates the call (eth_simulateV1, traceTransfers, no gas or nonce validation) and returns what moves in and out
    /// of `from`. Throws when the network doesn't support eth_simulateV1, the call reverts, or the answer can't be read
    /// exactly; callers then fall back to showing the call as undecoded.
    public func simulateDappTransfers(from: EVMAddress, to: EVMAddress, data: [UInt8], value: UInt128) async throws -> EVMSimulatedTransfers {
        let block: JSON = .object(["calls": .array([callObject(to: to, data: data, from: from, value: value)])])
        let opts: JSON = .object(["blockStateCalls": .array([block]), "traceTransfers": .bool(true), "validation": .bool(false)])
        let r = try await rpc.call("eth_simulateV1", [opts, .string("latest")])
        return try Self.parseSimulatedTransfers(r, wallet: from)
    }

    /// Reads an eth_simulateV1 answer for one call. Every amount is kept in exact base units; an amount over 128 bits or a
    /// log that isn't well formed makes the whole answer unusable rather than partly read.
    static func parseSimulatedTransfers(_ r: JSON, wallet: EVMAddress) throws -> EVMSimulatedTransfers {
        guard let call = r[0]?["calls"]?[0] else { throw WalletError.badResponse("eth_simulateV1") }
        guard call["status"]?.string == "0x1" else {
            throw WalletError.simulationFailed(call["error"]?["message"]?.string ?? "the call reverts")
        }
        func topicAddress(_ s: String) -> EVMAddress? {
            guard let b = [UInt8](hex: s), b.count == 32, b.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            return EVMAddress(bytes: Array(b.suffix(20)))
        }
        func logContract(_ entry: JSON) throws -> EVMAddress {
            guard let addrS = entry["address"]?.string, let contract = EVMAddress(addrS.lowercased()) else {
                throw WalletError.badResponse("eth_simulateV1 log")
            }
            return contract
        }
        var changes: [EVMBalanceChange] = []
        var nfts: [EVMAddress] = []
        var approvals: [EVMApprovalGrant] = []
        for entry in call["logs"]?.array ?? [] {
            let topics = (entry["topics"]?.array ?? []).compactMap(\.string).map { $0.lowercased() }
            if topics.first == approvalTopic || topics.first == approvalForAllTopic {
                // A grant by this wallet. A zero amount, a false ApprovalForAll or an ERC-721 approval to nobody revokes.
                guard topics.count == 3 || topics.count == 4, let owner = topicAddress(topics[1]), owner == wallet,
                      let spender = topicAddress(topics[2]) else { continue }
                let grants: Bool
                if topics.count == 4 { grants = spender.bytes.contains { $0 != 0 } }
                else { grants = (entry["data"]?.string.flatMap { [UInt8](hex: $0) } ?? []).contains { $0 != 0 } }
                if grants {
                    let contract = try logContract(entry)
                    approvals.append(EVMApprovalGrant(contract: contract, spender: spender))
                }
                continue
            }
            if topics.first == transferSingleTopic || topics.first == transferBatchTopic {
                // ERC-1155: operator, from, to are indexed; ids and amounts are in the data.
                guard topics.count == 4, let src = topicAddress(topics[2]), let dst = topicAddress(topics[3]),
                      src == wallet, dst != wallet else { continue }
                let contract = try logContract(entry)
                nfts.append(contract)
                continue
            }
            guard topics.first == transferTopic, topics.count == 3 || topics.count == 4 else { continue }
            // A topic that isn't a padded address can't name this wallet.
            guard let src = topicAddress(topics[1]), let dst = topicAddress(topics[2]), src == wallet || dst == wallet else { continue }
            guard let addrS = entry["address"]?.string, let contract = EVMAddress(addrS.lowercased()) else {
                throw WalletError.badResponse("eth_simulateV1 log")
            }
            if topics.count == 4 {
                // ERC-721: the id is indexed and there is no amount.
                if src == wallet, dst != wallet { nfts.append(contract) }
                continue
            }
            guard let d = entry["data"]?.string.flatMap({ [UInt8](hex: $0) }), d.count == 32, let amount = UInt128(bigEndian: d) else {
                throw WalletError.badResponse("eth_simulateV1 amount")
            }
            if src == dst { continue }
            let token: EVMAddress? = contract == nativeTransferPseudo ? nil : contract
            let k: Int
            if let j = changes.firstIndex(where: { $0.token == token }) { k = j }
            else { changes.append(EVMBalanceChange(token: token, sent: 0, received: 0)); k = changes.count - 1 }
            if src == wallet {
                let (v, o) = changes[k].sent.addingReportingOverflow(amount)
                guard !o else { throw WalletError.badResponse("eth_simulateV1 amount") }
                changes[k].sent = v
            } else {
                let (v, o) = changes[k].received.addingReportingOverflow(amount)
                guard !o else { throw WalletError.badResponse("eth_simulateV1 amount") }
                changes[k].received = v
            }
        }
        let native = changes.filter { $0.token == nil }, tokens = changes.filter { $0.token != nil }
        return EVMSimulatedTransfers(changes: native + tokens, nftsSent: nfts, approvals: approvals)
    }
}

extension DappDecoder {
    /// Fills in an undecoded contract call from its simulation: "You send" and "You get" lines, and what the spending
    /// policy counts. With no simulation the call still counts as moving funds, of unknown size beyond its native value.
    /// Decoded requests are left as they are.
    public static func applySimulation(_ i: inout DappIntent, _ sim: EVMSimulatedTransfers?, request r: DappTransactionRequest,
                                       chain: Chain, client: EVMClient, prices: [String: Double]) async {
        guard !i.decoded else { return }
        guard let sim else {
            i.movesFunds = true
            if r.value == 0 { i.outflowUSD = chain.isTestnet ? 0 : nil }   // with value, outflowUSD already counts the native part
            return
        }
        var lines: [[String]] = []
        var priced: Decimal = 0
        var unpricedOut = false, anyOut = false
        for ch in sim.changes {
            var symbol = chain.nativeSymbol, decimals: Int? = chain.nativeDecimals
            var usdEach: Decimal? = chain.isTestnet ? 0 : prices[chain.nativeSymbol].map { Decimal($0) }
            if let addr = ch.token {
                let t = await token(addr, chain: chain, client: client)
                symbol = t?.label ?? "units of \(short(addr))"
                decimals = t?.decimals
                if chain.isTestnet { usdEach = 0 }
                else if let t, t.known, TokenTable.stableSymbols.contains(t.symbol) { usdEach = 1 }
                else { usdEach = nil }
            }
            func text(_ v: UInt128) -> String {
                decimals.map { "\(Units.format(v, decimals: $0, maxFraction: 6)) \(symbol)" } ?? "\(v) \(symbol)"
            }
            if ch.netSent > 0 {
                anyOut = true
                lines.append(["You send", text(ch.netSent)])
                if let usdEach, let decimals, let amt = Decimal(string: Units.format(ch.netSent, decimals: decimals)) {
                    priced += amt * usdEach
                } else { unpricedOut = true }
            }
            if ch.netReceived > 0 { lines.append(["You get", text(ch.netReceived)]) }
        }
        var counts: [EVMAddress: Int] = [:]
        for c in sim.nftsSent { counts[c, default: 0] += 1 }
        for c in sim.nftsSent where counts[c] != nil {
            let n = counts.removeValue(forKey: c) ?? 0
            lines.append(["You send", "\(n) NFT\(n == 1 ? "" : "s") from \(short(c))"])
            anyOut = true; unpricedOut = true
        }
        for g in sim.approvals {
            let t = await token(g.contract, chain: chain, client: client)
            lines.append(["Lets spend", "\(t?.label ?? short(g.contract)), by \(short(g.spender))"])
        }
        if !sim.approvals.isEmpty {
            i.warnings.append("This call lets another address take your tokens later. Only approve it if you trust this site.")
        }
        if lines.isEmpty { lines.append(["Your balances", "No change"]) }
        i.lines += lines
        i.checks.append("Simulated on \(chain.name): balance changes shown")
        if let w = i.warnings.firstIndex(of: undecodedWarning) {
            i.warnings[w] = "Hermit can't decode this call. What you send and get comes from a simulation on \(chain.name), and it can change if the chain does before this lands. Only approve it if you trust this site."
        }
        if anyOut {
            i.movesFunds = true
            if chain.isTestnet { i.outflowUSD = 0 }
            else if unpricedOut {
                // Count what has a price; say plainly that the rest isn't counted.
                i.outflowUSD = priced > 0 ? priced : nil
                if priced > 0 { i.warnings.append("Some of what you send has no price, so only part of it counts toward your daily limit.") }
            } else { i.outflowUSD = priced }
        }
    }
}
