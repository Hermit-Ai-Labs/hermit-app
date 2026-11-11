import Foundation
import HermitCore

/// One recipient of a batch send, and where its transfer is.
public struct BatchRow: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Left out: `problem` says why (bad address, duplicate, no amount). Never sent.
        case invalid
        /// Will be sent (or wasn't reached yet).
        case ready
        /// Broadcast, waiting for its block.
        case sent
        case confirmed
        case failed
    }
    public var id: Int { line }
    /// 1-based row number as the user listed it.
    public let line: Int
    /// What the user gave.
    public let input: String
    /// Checksummed address ("" when invalid).
    public let address: String
    /// Exact decimal amount as given ("" when missing).
    public let amount: String
    public var problem: String?
    public var status: Status
    public var hash: String?
    public var error: String?
    /// Solana token batches: the recipient has no token account for this mint yet, so this row's transfer creates it and
    /// the sender pays its one-time rent (`BatchPlan.solana.rentPerAccount`). nil on other networks.
    public var needsAccount: Bool? = nil
    /// Solana: the last block height at which this row's broadcast transfer can still land. Past it, a transfer that
    /// never showed up is known not to have moved anything, so it is safe to send again.
    public var lastValid: UInt64? = nil

    public init(line: Int, input: String, address: String, amount: String, problem: String?, status: Status) {
        self.line = line; self.input = input; self.address = address; self.amount = amount; self.problem = problem; self.status = status
    }
}

/// A checked batch: every recipient validated, the total and the network fees priced, the spending policy run.
/// Nothing is signed until `runBatch`, which asks for Face ID / Touch ID once for all of it.
public struct BatchPlan: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let walletID: UUID
    public let chainID: String
    public let symbol: String
    /// nil for the chain's native coin.
    public let tokenAddress: String?
    public let decimals: Int
    public var rows: [BatchRow]
    /// Sum of the valid rows, exact.
    public let total: String
    /// Upper bound for all the network fees, in the native coin.
    public let feeText: String
    /// Per-transfer gas limit used when signing.
    public let gasLimit: UInt64
    /// Passed checks, for the review.
    public var checks: [String]
    public var warnings: [String]
    /// Why it can't be sent. Non-empty means the review shows it and Approve stays off.
    public var blocks: [String]
    public let origin: ActionOrigin
    /// "wallets.csv" when the list came from a file.
    public let source: String?
    public let created: Date
    /// Dollars per whole unit of `symbol` when the plan was made (nil when unpriced): what each sent row adds to the daily limit.
    public var unitUSD: String? = nil
    /// Solana batches: fees, account rent and the priority price the review showed (SolanaBatch.swift). nil elsewhere.
    public var solana: SolanaBatchInfo? = nil

    public var chain: Chain? { Chain.with(id: chainID) }
    public var valid: [BatchRow] { rows.filter { $0.status != .invalid } }
    public var invalid: [BatchRow] { rows.filter { $0.status == .invalid } }
    public var remaining: [BatchRow] { rows.filter { $0.status == .ready || $0.status == .failed } }
    public var done: Bool { !valid.isEmpty && valid.allSatisfy { $0.status == .confirmed } }
    public var canSend: Bool { blocks.isEmpty && !remaining.isEmpty }
}

extension WalletService {
    /// The most recipients in one batch.
    public nonisolated static let batchMax = 200
    /// Networks where batches run: EVM (one signed transfer per recipient, sent one after another) and Solana
    /// (SolanaBatch.swift: SOL and SPL tokens, each transfer confirmed before the next).
    public nonisolated static func batchSupported(_ c: Chain) -> Bool { c.kind == .evm || c.kind == .solana }

    /// Checks a batch without signing anything: addresses (format, EIP-55 checksum, duplicates, not this wallet),
    /// amounts, the token and native balances against the total plus every network fee (one transfer simulated),
    /// the daily limit, the assistant's per-move cap when it prepared it, and first-time payees.
    /// `spl`: a Solana token outside Hermit's own list that the wallet holds (the caller found its mint); ignored elsewhere.
    public func planBatch(walletID: UUID?, chain: Chain, symbol: String, recipients: [(address: String, amount: String)],
                          origin: ActionOrigin, source: String? = nil, fromPicture: Bool = false,
                          spl: SolanaBatch.Token? = nil) async throws -> BatchPlan {
        guard let w = walletID.flatMap({ id in wallets.first { $0.id == id } }) ?? selected else { throw WalletError.vault("Create or import a wallet first.") }
        guard Self.batchSupported(chain) else {
            throw WalletError.blocked("Batch sends work on EVM networks (Base, Ethereum, Arbitrum, BNB Chain, Polygon, Monad) and Solana for now. On \(chain.name), send one at a time from Wallets.")
        }
        if chain.kind == .solana {
            return try await planSolanaBatch(wallet: w, chain: chain, symbol: symbol, recipients: recipients, origin: origin, source: source,
                                             fromPicture: fromPicture, spl: spl)
        }
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Sends on \(chain.name) are off in this build.") }
        guard !recipients.isEmpty else { throw WalletError.blocked("No recipients in the list.") }
        guard recipients.count <= Self.batchMax else { throw WalletError.blocked("That's \(recipients.count) recipients. A batch takes up to \(Self.batchMax); split the list.") }
        let token = try resolveToken(symbol, on: chain)
        let decimals = token?.decimals ?? chain.nativeDecimals
        let sym = token?.symbol ?? chain.nativeSymbol
        let me = EVMAddress(w.evmAddress)!

        // Rows.
        var rows: [BatchRow] = [], seen: [String: Int] = [:]
        var total: UInt128 = 0
        for (i, r) in recipients.enumerated() {
            let input = r.address.trimmingCharacters(in: .whitespacesAndNewlines)
            // Thousands commas ("1,000") go; any other comma ("25,5", "1.000,50") makes the row unclear, never a bigger amount.
            let rawAmount = r.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            let amountText = RecipientTable.ungrouped(rawAmount) ?? ""
            var problem: String?, address = ""
            if let a = EVMAddress(input) {
                address = a.checksummed
                // Text read from a picture can swap a character and still parse. Without mixed case there is no
                // checksum to catch it, so only addresses already saved or paid before get through.
                let hex = input.dropFirst(2)
                let noChecksum = hex == hex.lowercased() || hex == hex.uppercased()
                let known = addressBook.entry(for: address, kind: .evm).map { $0.label != nil || $0.payments > 0 } ?? false
                if fromPicture && noChecksum && !known { problem = "Read from a picture without a checksum. Paste this address instead." }
                else if a == me { problem = "That's this wallet" }
                else if let first = seen[address.lowercased()] { problem = "Same address as row \(first)" }
                else if let block = whitelistBlock(chain: chain, to: address) { problem = block }
                else { seen[address.lowercased()] = i + 1 }
            } else if ENS.looksLikeName(input) {
                problem = "Names aren't looked up in a batch; use the 0x address"
            } else if input.hasPrefix("0x") && input.count == 42 {
                problem = "Checksum doesn't match (a mistyped character?)"
            } else {
                problem = "Not a \(chain.name) address"
            }
            var value: UInt128 = 0
            if problem == nil {
                if amountText.isEmpty && !rawAmount.isEmpty { problem = "Unclear amount. Write it with a dot, like 25.5" }
                else if amountText.isEmpty { problem = "No amount" }
                else if let v = try? Units.parse(amountText, decimals: decimals), v > 0 { value = v }
                else { problem = "Amount \(amountText) isn't valid for \(sym)" }
            }
            if problem == nil { total += value }
            rows.append(BatchRow(line: i + 1, input: input, address: address, amount: amountText, problem: problem,
                                 status: problem == nil ? .ready : .invalid))
        }
        let validCount = rows.filter { $0.status == .ready }.count
        var checks: [String] = [], warnings: [String] = [], blocks: [String] = []
        if fromPicture { warnings.append("Read from a picture. Compare every address with the original.") }
        if validCount == 0 { blocks.append("None of the rows can be sent.") }
        let bad = rows.count - validCount
        if bad > 0 { warnings.append("\(bad) row\(bad == 1 ? "" : "s") left out (listed below with the reason).") }
        else { checks.append("Every address is valid, no duplicates") }

        // Balances and fees: one transfer simulated, the fee for each priced at today's max fee.
        let client = evm(chain)
        async let cidA = client.chainId()
        async let feesA = client.fees()
        async let nativeA = client.balance(me)
        let (cid, fees, native) = try await (cidA, feesA, nativeA)
        guard cid == chain.chainId else { throw WalletError.badResponse("RPC for \(chain.name) reports chain \(cid)") }
        var held = native
        if let t = token { held = try await client.tokenBalance(token: EVMAddress(t.address)!, owner: me) }
        var gas: UInt64 = token == nil ? 21_000 : 80_000
        if let first = rows.first(where: { $0.status == .ready }), let to = EVMAddress(first.address) {
            let v = (try? Units.parse(first.amount, decimals: decimals)) ?? 0
            let txTo = token.map { EVMAddress($0.address)! } ?? to
            let data: [UInt8] = token == nil ? [] : ERC20.transfer(to: to, amount: v)
            let txValue: UInt128 = token == nil ? v : 0
            do {
                let est = try await client.estimateGas(from: me, to: txTo, data: data, value: txValue)
                gas = est + est / 4   // headroom: later transfers can touch fresh storage
                checks.append("A transfer simulated and matches the list")
            } catch {
                if held >= total { blocks.append("Simulation failed: \((error as? WalletError)?.errorDescription ?? error.localizedDescription)") }
            }
        }
        let feeAll = UInt128(gas) * fees.maxFeePerGas * UInt128(max(validCount, 1))
        let feeText = "\(Units.format(feeAll, decimals: chain.nativeDecimals, maxFraction: 6)) \(chain.nativeSymbol)"
        if held < total {
            blocks.append("Not enough \(sym): the list needs \(Units.format(total, decimals: decimals)), this wallet has \(Units.format(held, decimals: decimals)).")
        } else { checks.append("Balance covers the total") }
        let needNative = feeAll + (token == nil ? total : 0)
        if native < needNative {
            blocks.append("Not enough \(chain.nativeSymbol) on \(chain.name) for \(validCount) network fees (up to \(feeText)).")
        } else if token != nil { checks.append("\(chain.nativeSymbol) covers \(validCount) network fees") }

        // Spending policy: the whole batch is one move.
        let unit = await usdPerUnit(chain: chain, token: token)
        let usd: Decimal? = unit.flatMap { u in Decimal(string: Units.format(total, decimals: decimals)).map { $0 * u } }
        let p = policy
        let left = p.limit.remaining()
        if let usd {
            if usd > left { blocks.append("Over your daily limit: \(SpendPolicy.money(left)) of \(SpendPolicy.money(p.limit.dailyLimitUSD)) left today.") }
            else { checks.append("Within daily limit (\(SpendPolicy.money(left - usd)) left today)") }
        } else if origin == .agent {
            blocks.append("The assistant can't send tokens without a price. Send \(sym) from Wallets yourself.")
        } else if chain.isTestnet {
            warnings.append("Test coins have no price, so this isn't counted toward your \(SpendPolicy.money(p.limit.dailyLimitUSD)) daily limit.")
        } else {
            blocks.append("There is no price for \(sym) right now, so this can't be checked against your \(SpendPolicy.money(p.limit.dailyLimitUSD)) daily limit. Try again in a minute.")
        }
        if origin == .agent, let usd {
            if usd > p.agentCapUSD { blocks.append("The assistant can prepare up to \(SpendPolicy.money(p.agentCapUSD)) per move. Attach the list and ask again, or split it.") }
            else { checks.append("Under the assistant's \(SpendPolicy.money(p.agentCapUSD)) per-move cap") }
        }
        let fresh = rows.filter { $0.status == .ready && (addressBook.entry(for: $0.address, kind: .evm)?.payments ?? 0) == 0 }.count
        if fresh > 0 { warnings.append("\(fresh) address\(fresh == 1 ? " is" : "es are") new to this wallet. Check the list.") }
        else if validCount > 0 { checks.append("Paid every address before") }
        checks.append("Signed on this device with one \(validCount == 1 ? "approval" : "approval for all \(validCount)")")

        return BatchPlan(id: UUID().uuidString, walletID: w.id, chainID: chain.id, symbol: sym, tokenAddress: token?.address, decimals: decimals,
                         rows: rows, total: Units.format(total, decimals: decimals), feeText: feeText, gasLimit: gas, checks: checks,
                         warnings: warnings, blocks: blocks, origin: origin, source: source, created: Date(),
                         unitUSD: unit.map { "\($0)" })
    }

    /// Why these rows can't go out under the daily limit as it stands right now, or nil. A batch is checked against the
    /// limit when it is reviewed; it is approved later, after other sends or another reviewed batch may have gone out,
    /// so the rows still to go are checked again before the key is asked for. `unit`: dollars per whole token (nil when
    /// the batch has no price, which only a testnet review lets through).
    func batchLimitBlock(_ rows: [BatchRow], unit: Decimal?) -> String? {
        guard let unit else { return nil }
        let usd = rows.reduce(Decimal(0)) { $0 + (Decimal(string: $1.amount) ?? 0) * unit }
        let left = spendLimit.remaining()
        guard usd > left else { return nil }
        return "Over your daily limit: \(SpendPolicy.money(left)) of \(SpendPolicy.money(spendLimit.dailyLimitUSD)) left today, and what is left of this batch is \(SpendPolicy.money(usd)). Nothing was sent."
    }

    /// Sends the rows still to go (ready, or failed on an earlier try): one Face ID / Touch ID unlock signs every
    /// transfer with consecutive nonces, then they go out one after another, each confirmed before the next.
    /// A row reverted on chain is marked failed and the rest continue (its nonce is used); a broadcast error stops the
    /// run (later nonces would be stuck), leaving the rest ready for Resume. `update` gets every row change.
    public func runBatch(_ plan: BatchPlan, update: @escaping @MainActor (BatchRow) -> Void) async throws {
        guard plan.blocks.isEmpty else { throw WalletError.blocked(plan.blocks.joined(separator: " ")) }
        // Solana: no nonces to pre-sign, so each transfer is built, signed and confirmed in turn (SolanaBatch.swift).
        if plan.chain?.kind == .solana { return try await runSolanaBatch(plan, update: update) }
        guard let chain = plan.chain, chain.kind == .evm else { throw WalletError.blocked("Batch sends work on EVM networks and Solana only.") }
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet sends are off in this build.") }
        guard let w = wallets.first(where: { $0.id == plan.walletID }) else { throw WalletError.vault("That wallet is gone.") }
        let todo = plan.remaining
        guard !todo.isEmpty else { return }
        let token = plan.tokenAddress.flatMap { a in chain.tokens.first { $0.address == a } }
        guard plan.tokenAddress == nil || token != nil else { throw WalletError.unknownToken }
        // What each row adds to the daily limit. A plan saved before it carried a price counts stablecoins at face value.
        let isStable = token.map { TokenTable.stableSymbols.contains($0.symbol) } ?? false
        let unit: Decimal? = plan.unitUSD.flatMap { Decimal(string: $0) } ?? (isStable ? Decimal(1) : nil)
        // The daily limit again, now: the review checked it when the list was prepared, and other sends may have gone since.
        if let block = batchLimitBlock(todo, unit: unit) { throw WalletError.blocked(block) }
        let client = evm(chain)
        let from = EVMAddress(w.evmAddress)!
        async let cidA = client.chainId()
        async let nonceA = client.nonce(from)
        async let feesA = client.fees()
        async let nativeA = client.balance(from)
        let (cid, nonce0, fees, native) = try await (cidA, nonceA, feesA, nativeA)
        guard cid == chain.chainId else { throw WalletError.badResponse("RPC for \(chain.name) reports chain \(cid)") }

        var txs: [(row: BatchRow, tx: EIP1559Transaction, value: UInt128)] = []
        var need: UInt128 = 0
        for (i, r) in todo.enumerated() {
            guard let to = EVMAddress(r.address), let v = try? Units.parse(r.amount, decimals: plan.decimals), v > 0 else { continue }
            let tx = EIP1559Transaction(chainId: cid, nonce: nonce0 + UInt64(i), maxPriorityFeePerGas: min(fees.maxPriorityFeePerGas, fees.maxFeePerGas),
                                        maxFeePerGas: fees.maxFeePerGas, gasLimit: plan.gasLimit,
                                        to: token.map { EVMAddress($0.address)! } ?? to, value: token == nil ? v : 0,
                                        data: token == nil ? [] : ERC20.transfer(to: to, amount: v))
            // Read our own calldata back: each transfer must say exactly what its row says.
            if token != nil, let (dTo, dAmt) = ERC20.decodeTransfer(tx.data), dTo != to || dAmt != v {
                throw WalletError.blocked("Row \(r.line) didn't build as listed. Nothing was sent.")
            }
            txs.append((r, tx, v))
            need += tx.maxFee + tx.value
        }
        guard native >= need else {
            throw WalletError.insufficientFunds("Not enough \(chain.nativeSymbol) on \(chain.name) for the network fees.")
        }
        let total = Units.format(txs.reduce(UInt128(0)) { $0 + $1.value }, decimals: plan.decimals)
        let reason = "Send \(total) \(plan.symbol) to \(txs.count) address\(txs.count == 1 ? "" : "es") on \(chain.name)"
        let unsigned = txs.map(\.tx)
        let signed = try await vault.withKey(w.id, kind: .evm, reason: reason) { key in try unsigned.map { try $0.sign(privateKey: key) } }
        for (s, t) in zip(signed, unsigned) {
            guard let check = EIP1559Transaction.decode(raw: s.raw), check.tx == t, check.sender == from else {
                throw WalletError.blocked("A signed transfer failed its self-check. Nothing was sent.")
            }
        }

        for (k, item) in txs.enumerated() {
            var row = item.row
            let hash: String
            do {
                hash = try await client.sendRawTransaction(signed[k].raw)
            } catch {
                row.status = .failed
                row.error = (error as? WalletError)?.errorDescription ?? error.localizedDescription
                update(row)
                // Later transfers carry later nonces; they'd wait forever behind this one. They stay ready for Resume.
                throw WalletError.blocked("Row \(row.line) didn't go out: \(row.error ?? ""). The rest weren't sent; Resume sends them.")
            }
            row.hash = hash; row.status = .sent; row.error = nil
            update(row)
            do {
                let r = try await client.waitForReceipt(hash)
                row.status = r.success ? .confirmed : .failed
                if !r.success { row.error = "Failed on chain" }
            } catch {
                // Not confirmed in time: it may still land. Keep it as sent, with the hash to check.
                row.error = "Not confirmed yet"
            }
            // A row still "sent" may yet land, so it counts as spent (one that failed on chain moved nothing).
            if row.status == .confirmed || row.status == .sent {
                sendLog.record(SendLog.Entry(hash: hash, chainID: chain.id, walletID: w.id, amount: row.amount, symbol: plan.symbol,
                                             recipient: row.address, label: nil, date: Date()))
                if row.status == .confirmed { addressBook.recordPayment(to: row.address, kind: .evm) }
                if let unit, let amount = Decimal(string: row.amount) { spendLimit.record(usd: amount * unit) }
            }
            update(row)
        }
        Task { await refreshBalances(chains: [chain]) }
    }
}
