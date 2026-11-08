import Foundation
import Observation
import HermitCore

/// One line of the hazard scan.
public struct HazardCheck: Equatable, Sendable {
    public enum Status: Sendable { case pass, warn, fail }
    public var title: String
    public var status: Status
    public var detail: String
}

public struct Balance: Equatable, Sendable, Identifiable {
    public var id: String { "\(chain.id):\(symbol)" }
    public let chain: Chain
    /// nil for the native coin.
    public let token: Token?
    public let amount: UInt128
    public var symbol: String { token?.symbol ?? chain.nativeSymbol }
    public var decimals: Int { token?.decimals ?? chain.nativeDecimals }
    public var logo: String { token?.logo ?? chain.logo }
    public var formatted: String { Units.format(amount, decimals: decimals, maxFraction: 6) }
}

/// Everything the approval sheet needs before money moves, plus what `execute` needs to send it.
public struct PreparedSend: Sendable, Identifiable {
    public let id = UUID()
    public let walletID: UUID
    public let chain: Chain
    public let token: Token?
    public let amount: UInt128
    /// What the user typed ("alice.eth") and what it resolved to.
    public let recipientInput: String
    public let recipient: String
    public let networkFee: UInt128
    public let checks: [HazardCheck]
    let payload: Payload

    enum Payload: Sendable {
        case evm(EIP1559Transaction)
        case solana(instructions: [SolanaInstruction])
        case near(receiver: String, actions: [NearAction])
    }

    public var symbol: String { token?.symbol ?? chain.nativeSymbol }
    public var amountText: String { Units.format(amount, decimals: token?.decimals ?? chain.nativeDecimals) }
    public var feeText: String { "\(Units.format(networkFee, decimals: chain.nativeDecimals, maxFraction: 8)) \(chain.nativeSymbol)" }
    public var canSend: Bool { !checks.contains { $0.status == .fail } }
    public var blockingReason: String? { checks.first { $0.status == .fail }?.detail }
    var usdValue: Decimal? {
        guard let t = token, TokenTable.stableSymbols.contains(t.symbol) else { return nil }
        return Decimal(string: amountText)
    }

    /// Rows for the summary box.
    public var lines: [[String]] {
        var to = recipientInput == recipient ? short(recipient) : "\(recipientInput) (\(short(recipient)))"
        if to.isEmpty { to = recipient }
        return [["Amount", "\(amountText) \(symbol)"], ["To", to], ["Network", chain.name + (chain.isTestnet ? " (testnet)" : "")],
                ["Network fee", "up to \(feeText)"]]
    }
    func short(_ a: String) -> String { a.count > 14 ? "\(a.prefix(6))…\(a.suffix(4))" : a }

    /// The same send with a different hazard scan (a 1Click deposit swaps the address-book check for the quote's checks).
    func with(checks: [HazardCheck], recipientInput: String? = nil) -> PreparedSend {
        PreparedSend(walletID: walletID, chain: chain, token: token, amount: amount, recipientInput: recipientInput ?? self.recipientInput,
                     recipient: recipient, networkFee: networkFee, checks: checks, payload: payload)
    }
}

public struct TxReceipt: Equatable, Sendable {
    public let chain: Chain
    public let hash: String
    public let success: Bool
    /// Block number (EVM) or slot (Solana).
    public let block: UInt64
    public var explorerURL: URL? { chain.explorerURL(tx: hash) }
}

/// The wallet for the UI: wallets, balances on every chain from one recovery phrase, and sends that go through the
/// approval sheet. Sends default to Base Sepolia; mainnet sends follow `mainnetSendsEnabled`.
@MainActor @Observable
public final class WalletService {
    /// The one switch for real-money sends in this build. On for the first TestFlight beta (team decision, 2026-11-06).
    public nonisolated static let mainnetSendsEnabled = true

    public let vault: KeyVault
    public let addressBook: AddressBook
    public let spendLimit: SpendLimit
    public let sendLog: SendLog

    public private(set) var wallets: [WalletRecord] = []
    public var selectedWalletID: UUID?
    public var showTestnets = true
    /// Whether mainnet sends are allowed. Testnets always are.
    public var allowMainnetSends = WalletService.mainnetSendsEnabled
    public private(set) var balancesByChain: [String: [Balance]] = [:]
    public private(set) var refreshing = false
    public private(set) var lastError: String?

    @ObservationIgnored private var evmClients: [String: EVMClient] = [:]
    @ObservationIgnored private var solClients: [String: SolanaClient] = [:]
    public let nearClient = NearClient()

    public init(vault: KeyVault = .makeDefault(), addressBook: AddressBook = AddressBook(), spendLimit: SpendLimit = SpendLimit(),
                sendLog: SendLog = SendLog()) {
        self.vault = vault; self.addressBook = addressBook; self.spendLimit = spendLimit; self.sendLog = sendLog
        wallets = vault.wallets
        selectedWalletID = wallets.first?.id
    }

    public var selected: WalletRecord? { wallets.first { $0.id == selectedWalletID } ?? wallets.first }
    public var chains: [Chain] { showTestnets ? Chain.all : Chain.mainnets }
    public var defaultSendChain: Chain { Chain.defaultSend }

    /// The selected wallet's address on each chain (one EVM address everywhere, one Solana address).
    public var accounts: [(chain: Chain, address: String)] {
        guard let w = selected else { return [] }
        return chains.map { ($0, w.address(on: $0)) }
    }
    public func address(on chain: Chain) -> String? { selected?.address(on: chain) }
    public func balances(for chain: Chain) -> [Balance] { balancesByChain[chain.id] ?? [] }

    // MARK: Wallets

    @discardableResult public func createWallet(name: String = "Wallet", words: Int = 12) throws -> WalletRecord {
        let r = try vault.create(name: name, words: words); reload(select: r.id); return r
    }
    /// Creates a wallet and returns its recovery phrase once, for the backup screen.
    public func createWalletWithPhrase(name: String = "Wallet", words: Int = 12) throws -> (record: WalletRecord, phrase: String) {
        let r = try vault.createWithPhrase(name: name, words: words); reload(select: r.record.id); return r
    }
    @discardableResult public func importWallet(phrase: String, name: String = "Imported") throws -> WalletRecord {
        let r = try vault.importPhrase(phrase, name: name); reload(select: r.id); return r
    }
    public func exportPhrase(_ id: UUID) async throws -> String { try await vault.exportPhrase(id) }
    public func deleteWallet(_ id: UUID) throws {
        try vault.delete(id); sendLog.remove(wallet: id); reload(select: nil)
    }
    public func markBackedUp(_ id: UUID) throws { try vault.markBackedUp(id); reload(select: id) }

    func reload(select: UUID?) {
        wallets = vault.wallets
        if let select { selectedWalletID = select } else if !wallets.contains(where: { $0.id == selectedWalletID }) { selectedWalletID = wallets.first?.id }
    }

    // MARK: Clients

    public func evm(_ c: Chain) -> EVMClient {
        if let x = evmClients[c.id] { return x }
        let x = EVMClient(url: c.rpc); evmClients[c.id] = x; return x
    }
    func sol(_ c: Chain) -> SolanaClient {
        if let x = solClients[c.id] { return x }
        let x = SolanaClient(url: c.rpc); solClients[c.id] = x; return x
    }

    // MARK: Balances

    /// Native + known stablecoins on each chain, fetched in parallel. A chain that fails keeps its old numbers.
    public func refreshBalances(chains: [Chain]? = nil) async {
        guard let w = selected else { return }
        refreshing = true; defer { refreshing = false }
        let list = chains ?? self.chains
        var failures = [String]()
        await withTaskGroup(of: (String, [Balance]?).self) { g in
            for c in list {
                let address = w.address(on: c)
                let ec = c.kind == .evm ? evm(c) : nil, sc = c.kind == .solana ? sol(c) : nil, nc = nearClient
                g.addTask { (c.id, try? await Self.fetchBalances(chain: c, address: address, evm: ec, solana: sc, near: nc)) }
            }
            for await (id, b) in g {
                if let b { balancesByChain[id] = b } else { failures.append(id) }
            }
        }
        lastError = failures.isEmpty ? nil : "Couldn't reach \(failures.compactMap { Chain.with(id: $0)?.name }.sorted().joined(separator: ", "))."
    }

    /// Native + known stablecoins for any wallet on the given chains, in parallel. Returns what came back and the
    /// chains that failed (their numbers are unknown, not zero).
    public func fetchBalances(for wallet: WalletRecord, chains: [Chain]) async -> (balances: [String: [Balance]], failed: [Chain]) {
        var out: [String: [Balance]] = [:], failed: [Chain] = []
        await withTaskGroup(of: (Chain, [Balance]?).self) { g in
            for c in chains {
                let address = wallet.address(on: c)
                let ec = c.kind == .evm ? evm(c) : nil, sc = c.kind == .solana ? sol(c) : nil, nc = nearClient
                g.addTask { (c, try? await Self.fetchBalances(chain: c, address: address, evm: ec, solana: sc, near: nc)) }
            }
            for await (c, b) in g {
                if let b { out[c.id] = b } else { failed.append(c) }
            }
        }
        return (out, failed)
    }

    nonisolated static func fetchBalances(chain: Chain, address: String, evm: EVMClient?, solana: SolanaClient?,
                                          near: NearClient? = nil) async throws -> [Balance] {
        switch chain.kind {
        case .evm:
            guard let c = evm else { return [] }
            guard let a = EVMAddress(address) else { throw WalletError.invalidAddress(address) }
            var out = [Balance(chain: chain, token: nil, amount: try await c.balance(a))]
            for t in chain.tokens {
                out.append(Balance(chain: chain, token: t, amount: try await c.tokenBalance(token: EVMAddress(t.address)!, owner: a)))
            }
            return out
        case .solana:
            guard let c = solana else { return [] }
            guard let a = SolanaPublicKey(address) else { throw WalletError.invalidAddress(address) }
            var out = [Balance(chain: chain, token: nil, amount: UInt128(try await c.balance(a)))]
            for t in chain.tokens {
                out.append(Balance(chain: chain, token: t, amount: try await c.tokenBalance(owner: a, mint: SolanaPublicKey(t.address)!)))
            }
            return out
        case .near:
            // No NEAR account on this wallet yet: nothing to show (not zero; the wallet page offers to add one).
            guard let c = near, !address.isEmpty else { return [] }
            // An implicit account that has never received NEAR doesn't exist yet: its balance really is 0.
            let state = try await c.account(address)
            var out = [Balance(chain: chain, token: nil, amount: state?.available ?? 0)]
            for t in chain.tokens {
                out.append(Balance(chain: chain, token: t, amount: state == nil ? 0 : try await c.ftBalance(token: t.address, owner: address)))
            }
            return out
        }
    }

    // MARK: Send

    /// Resolves the recipient (ENS for EVM), builds the transaction, simulates it and runs the hazard scan.
    /// `token` nil or the chain's native symbol sends the native coin. Nothing is signed here.
    public func prepareSend(chain: Chain? = nil, to: String, amount: String, token: String? = nil) async throws -> PreparedSend {
        let chain = chain ?? defaultSendChain
        let tok = try resolveToken(token, on: chain)
        let value = try Units.parse(amount, decimals: tok?.decimals ?? chain.nativeDecimals)
        return try await prepareSend(walletID: nil, chain: chain, to: to, value: value, token: tok)
    }

    func resolveToken(_ token: String?, on chain: Chain) throws -> Token? {
        guard let s = token, s.caseInsensitiveCompare(chain.nativeSymbol) != .orderedSame else { return nil }
        guard let t = chain.token(s) else { throw WalletError.unknownToken }
        return t
    }

    /// The same, for an exact amount in the token's smallest unit, from a given wallet (nil = the selected one).
    public func prepareSend(walletID: UUID?, chain: Chain, to: String, value: UInt128, token tok: Token?) async throws -> PreparedSend {
        guard let w = walletID.flatMap({ id in wallets.first { $0.id == id } }) ?? selected else { throw WalletError.vault("Create or import a wallet first.") }
        guard chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Sends on \(chain.name) are off during the beta. Use \(Chain.defaultSend.name).") }
        guard value > 0 else { throw WalletError.invalidAmount("0") }
        switch chain.kind {
        case .evm: return try await prepareEVM(w, chain, to: to, value: value, token: tok)
        case .solana: return try await prepareSolana(w, chain, to: to, value: value, token: tok)
        case .near: return try await prepareNear(w, chain, to: to, value: value, token: tok)
        }
    }

    public func prepareSend(chain: Chain? = nil, to: String, amount: Decimal, token: String? = nil) async throws -> PreparedSend {
        try await prepareSend(chain: chain, to: to, amount: "\(amount)", token: token)
    }

    private func prepareEVM(_ w: WalletRecord, _ chain: Chain, to input: String, value: UInt128, token: Token?) async throws -> PreparedSend {
        let client = evm(chain)
        let to: EVMAddress
        if let a = EVMAddress(input) { to = a }
        else if ENS.looksLikeName(input) { to = try await ENS.resolve(input, client: evm(.ethereum)) }
        else { throw WalletError.invalidAddress(input) }
        let from = EVMAddress(w.evmAddress)!

        let txTo = token.map { EVMAddress($0.address)! } ?? to
        let data = token.map { _ in ERC20.transfer(to: to, amount: value) } ?? []
        let txValue: UInt128 = token == nil ? value : 0

        async let chainIdA = client.chainId()
        async let nonceA = client.nonce(from)
        async let feesA = client.fees()
        async let nativeA = client.balance(from)
        let (cid, nonce, fees, native) = try await (chainIdA, nonceA, feesA, nativeA)
        guard cid == chain.chainId else { throw WalletError.badResponse("RPC for \(chain.name) reports chain \(cid)") }

        // Simulation: estimateGas runs the call; eth_call shows what the token returns.
        var simOK = true, simDetail = "Transfer simulated and matches the summary."
        var gas: UInt64 = token == nil ? 21_000 : 80_000
        do {
            let est = try await client.estimateGas(from: from, to: txTo, data: data, value: txValue)
            gas = est + est / 5 // +20% headroom
            if let t = token {
                let out = try await client.call(to: EVMAddress(t.address)!, data: data, from: from)
                // Standard tokens return true; a few old ones (Ethereum USDT) return nothing.
                if !(out.isEmpty || (out.count == 32 && out[31] == 1 && out[0..<31].allSatisfy { $0 == 0 })) {
                    simOK = false; simDetail = "The token didn't confirm the transfer."
                }
                let bal = try await client.tokenBalance(token: EVMAddress(t.address)!, owner: from)
                if bal < value { simOK = false; simDetail = "Balance is \(Units.format(bal, decimals: t.decimals)) \(t.symbol)." }
            }
        } catch {
            simOK = false; simDetail = (error as? WalletError)?.errorDescription ?? error.localizedDescription
        }
        let tx = EIP1559Transaction(chainId: cid, nonce: nonce, maxPriorityFeePerGas: fees.maxPriorityFeePerGas, maxFeePerGas: fees.maxFeePerGas,
                                    gasLimit: gas, to: txTo, value: txValue, data: data)
        if native < tx.maxFee + txValue {
            simOK = false
            simDetail = "Not enough \(chain.nativeSymbol) for the amount and network fee (have \(Units.format(native, decimals: 18, maxFraction: 6)))."
        }
        // Read our own calldata back: it must say exactly what the summary says.
        if let t = token, let (dTo, dAmt) = ERC20.decodeTransfer(tx.data), dTo != to || dAmt != value || tx.to != EVMAddress(t.address)! {
            simOK = false; simDetail = "Built transaction doesn't match the summary."
        }
        let checks = hazardChecks(chain: chain, token: token, value: value, recipient: to.checksummed, simOK: simOK, simDetail: simDetail)
        return PreparedSend(walletID: w.id, chain: chain, token: token, amount: value, recipientInput: input.trimmingCharacters(in: .whitespaces),
                            recipient: to.checksummed, networkFee: tx.maxFee, checks: checks, payload: .evm(tx))
    }

    private func prepareSolana(_ w: WalletRecord, _ chain: Chain, to input: String, value: UInt128, token: Token?) async throws -> PreparedSend {
        let client = sol(chain)
        guard let to = SolanaPublicKey(input) else { throw WalletError.invalidAddress(input) }
        let from = SolanaPublicKey(w.solanaAddress)!
        guard let amount = UInt64(exactly: value) else { throw WalletError.invalidAmount(input) }

        var body: [SolanaInstruction]
        var watch: SolanaPublicKey
        var pre: UInt128 = 0
        var rent: UInt64 = 0
        if let t = token {
            let mint = SolanaPublicKey(t.address)!
            let dest = SolanaPublicKey.associatedTokenAccount(owner: to, mint: mint)
            let src = SolanaPublicKey.associatedTokenAccount(owner: from, mint: mint)
            body = [.transferChecked(source: src, mint: mint, destination: dest, owner: from, amount: amount, decimals: UInt8(t.decimals))]
            if try await client.accountExists(dest) {
                pre = try await client.tokenAccountAmount(dest) ?? 0
            } else {
                body.insert(.createAssociatedTokenAccountIdempotent(payer: from, owner: to, mint: mint), at: 0)
                rent = try await client.rentExemptMinimum(bytes: 165)
            }
            watch = dest
        } else {
            body = [.transfer(from: from, to: to, lamports: amount)]
            pre = UInt128(try await client.balance(to))
            watch = to
        }
        let price = try await client.priorityFee(accounts: [from, watch])
        let (bh, _) = try await client.latestBlockhash()

        var simOK = true, simDetail = "Transfer simulated and matches the summary."
        var limit: UInt32 = 200_000
        do {
            let draft = SolanaTransaction(message: SolanaMessage(payer: from, instructions: [.setComputeUnitLimit(limit), .setComputeUnitPrice(price)] + body,
                                                                 recentBlockhash: bh))
            let sim = try await client.simulate(draft, accounts: [watch])
            if let e = sim.error { simOK = false; simDetail = Self.solanaError(e, logs: sim.logs) } else {
                limit = UInt32(min(1_400_000, sim.unitsConsumed + sim.unitsConsumed / 5 + 1_000))
                let post: UInt128 = token == nil ? UInt128(sim.accounts.first??.lamports ?? 0) : (sim.accounts.first??.tokenAmount ?? 0)
                if to != from && post != pre + value { simOK = false; simDetail = "Simulated result doesn't match the summary." }
            }
        } catch { simOK = false; simDetail = (error as? WalletError)?.errorDescription ?? error.localizedDescription }

        let fee = 5_000 + (UInt64(limit) * price + 999_999) / 1_000_000 + rent
        let checks = hazardChecks(chain: chain, token: token, value: value, recipient: to.description, simOK: simOK, simDetail: simDetail)
        return PreparedSend(walletID: w.id, chain: chain, token: token, amount: value, recipientInput: input.trimmingCharacters(in: .whitespaces),
                            recipient: to.description, networkFee: UInt128(fee), checks: checks,
                            payload: .solana(instructions: [.setComputeUnitLimit(limit), .setComputeUnitPrice(price)] + body))
    }

    nonisolated static func solanaError(_ e: String, logs: [String]) -> String {
        if e.contains("AccountNotFound") { return "This wallet has no SOL on this network yet." }
        if e.contains("InsufficientFunds") || logs.contains(where: { $0.contains("insufficient") }) { return "Not enough balance for the amount and fee." }
        return "The network rejected it: \(e)"
    }

    func hazardChecks(chain: Chain, token: Token?, value: UInt128, recipient: String, simOK: Bool, simDetail: String) -> [HazardCheck] {
        var checks = [HazardCheck(title: simOK ? "Simulation matches summary" : "Simulation failed", status: simOK ? .pass : .fail, detail: simDetail)]
        checks.append(HazardCheck(title: "Exact-amount token approval", status: .pass,
                                  detail: "A plain transfer: no spending approval is granted to anyone."))
        if let e = addressBook.entry(for: recipient, kind: chain.kind), e.payments > 0 {
            checks.append(HazardCheck(title: "Address matches past payments", status: .pass,
                                      detail: "Paid \(e.payments) time\(e.payments == 1 ? "" : "s") before\(e.label.map { " (\($0))" } ?? "")."))
        } else {
            checks.append(HazardCheck(title: "First payment to this address", status: .warn, detail: "Not in your past payments. Double-check it."))
        }
        if let t = token, TokenTable.stableSymbols.contains(t.symbol), let usd = Decimal(string: Units.format(value, decimals: t.decimals)) {
            let left = spendLimit.remaining()
            checks.append(usd <= left
                ? HazardCheck(title: "Within daily limit", status: .pass, detail: "$\(left - usd) of $\(spendLimit.dailyLimitUSD) left today after this.")
                : HazardCheck(title: "Over daily limit", status: .fail, detail: "Only $\(left) of your $\(spendLimit.dailyLimitUSD) daily limit is left."))
        } else {
            checks.append(HazardCheck(title: "Daily limit covers stablecoins only", status: .warn,
                                      detail: "\(chain.nativeSymbol) has no price feed yet, so it isn't counted."))
        }
        return checks
    }

    /// Unlock with Touch ID / Face ID, sign, double-check the signed bytes, broadcast and wait for confirmation.
    public func execute(_ p: PreparedSend) async throws -> TxReceipt {
        guard p.canSend else { throw WalletError.blocked(p.blockingReason ?? "Blocked by the hazard scan.") }
        guard p.chain.isTestnet || allowMainnetSends else { throw WalletError.blocked("Mainnet sends are off during the beta.") }
        guard let w = wallets.first(where: { $0.id == p.walletID }) else { throw WalletError.vault("That wallet is gone.") }
        let reason = "Send \(p.amountText) \(p.symbol) on \(p.chain.name)"
        let receipt: TxReceipt
        switch p.payload {
        case .evm(var tx):
            let client = evm(p.chain)
            let from = EVMAddress(w.evmAddress)!
            // Fresh nonce and fees; refuse if fees jumped well past what was shown.
            async let nonceA = client.nonce(from)
            async let feesA = client.fees()
            let (nonce, fees) = try await (nonceA, feesA)
            tx.nonce = nonce
            if fees.maxFeePerGas > tx.maxFeePerGas {
                guard fees.maxFeePerGas <= tx.maxFeePerGas * 3 / 2 else { throw WalletError.blocked("Network fees jumped. Review the send again.") }
                tx.maxFeePerGas = fees.maxFeePerGas; tx.maxPriorityFeePerGas = min(fees.maxPriorityFeePerGas, fees.maxFeePerGas)
            }
            let unsigned = tx
            let signed = try await vault.withKey(w.id, kind: .evm, reason: reason) { key in try unsigned.sign(privateKey: key) }
            guard let check = EIP1559Transaction.decode(raw: signed.raw), check.tx == unsigned, check.sender == from else {
                throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.")
            }
            let hash = try await client.sendRawTransaction(signed.raw)
            guard hash.lowercased() == signed.hash else { throw WalletError.badResponse("node returned a different hash") }
            let r = try await client.waitForReceipt(hash)
            receipt = TxReceipt(chain: p.chain, hash: hash, success: r.success, block: r.blockNumber)
        case .solana(let instructions):
            let client = sol(p.chain)
            let from = SolanaPublicKey(w.solanaAddress)!
            let (bh, _) = try await client.latestBlockhash()
            let unsigned = SolanaTransaction(message: SolanaMessage(payer: from, instructions: instructions, recentBlockhash: bh))
            let tx = try await vault.withKey(w.id, kind: .solana, reason: reason) { seed in
                var t = unsigned; try t.sign(ed25519Seed: seed); return t
            }
            guard tx.verifySignature(), tx.message == unsigned.message else {
                throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.")
            }
            let sig = try await client.send(tx)
            let (ok, slot, _) = try await client.waitForConfirmation(sig)
            receipt = TxReceipt(chain: p.chain, hash: sig, success: ok, block: slot)
        case .near(let receiver, let actions):
            receipt = try await sendNear(w, receiver: receiver, actions: actions, reason: reason)
        }
        if receipt.success {
            sendLog.record(SendLog.Entry(hash: receipt.hash, chainID: p.chain.id, walletID: w.id, amount: p.amountText, symbol: p.symbol,
                                         recipient: p.recipient, label: p.recipientInput == p.recipient ? nil : p.recipientInput, date: Date()))
            addressBook.recordPayment(to: p.recipient, kind: p.chain.kind, label: p.recipientInput == p.recipient ? nil : p.recipientInput)
            if let usd = p.usdValue { spendLimit.record(usd: usd) }
        } else {
            throw WalletError.blocked("The transaction was included but failed on chain (\(receipt.hash)).")
        }
        Task { await refreshBalances(chains: [p.chain]) }
        return receipt
    }

    /// An `Approval` for the sheet whose Approve button really sends (via `perform`). Throws if the scan blocked it.
    public func approval(for p: PreparedSend) throws -> Approval {
        guard p.canSend else { throw WalletError.blocked(p.blockingReason ?? "Blocked by the hazard scan.") }
        let svc = self
        return Approval(kind: "Send on \(p.chain.name)", title: "Send \(p.amountText) \(p.symbol)", lines: p.lines,
                        checks: p.checks.map(\.title), success: "Sent \(p.amountText) \(p.symbol)",
                        perform: { try await svc.execute(p).hash })
    }
}

extension SolanaClient {
    public func rentExemptMinimum(bytes: Int) async throws -> UInt64 {
        try u64(try await rpc.call("getMinimumBalanceForRentExemption", [.number(Double(bytes))]), "rent")
    }
    public func tokenAccountAmount(_ account: SolanaPublicKey) async throws -> UInt128? {
        let r = try await rpc.call("getTokenAccountBalance", [.string(account.description), ["commitment": "confirmed"]])
        return r["value"]?["amount"]?.string.flatMap { UInt128($0) }
    }
}
