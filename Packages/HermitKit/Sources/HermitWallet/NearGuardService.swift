import Foundation
import CryptoKit

// Hermit Guard: reading the contract, and preparing and sending the owner's calls (the checks are in NearGuard.swift).

// MARK: Decoding what the contract returns

private extension KeyedDecodingContainer {
    /// U128 and U64 come as strings in the contract's JSON.
    func u128(_ k: Key) throws -> UInt128 {
        let s = try decode(String.self, forKey: k)
        guard let v = UInt128(s) else { throw DecodingError.dataCorruptedError(forKey: k, in: self, debugDescription: "not a number: \(s)") }
        return v
    }
    func u64(_ k: Key) throws -> UInt64 {
        let s = try decode(String.self, forKey: k)
        guard let v = UInt64(s) else { throw DecodingError.dataCorruptedError(forKey: k, in: self, debugDescription: "not a number: \(s)") }
        return v
    }
    func optU64(_ k: Key) throws -> UInt64? {
        guard contains(k), try !decodeNil(forKey: k) else { return nil }
        return try u64(k)
    }
}

extension NearGuard.GuardBalance: Codable {
    enum CodingKeys: String, CodingKey { case token, amount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(token: try c.decode(String.self, forKey: .token), amount: try c.u128(.amount))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token); try c.encode(String(amount), forKey: .amount)
    }
}

extension NearGuard.GuardVault: Codable {
    enum CodingKeys: String, CodingKey {
        case owner, frozen, balances, pockets, orders, requests
        case receiptsTotal = "receipts_total", pendingOut = "pending_out", storagePaid = "storage_paid"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(owner: try c.decode(String.self, forKey: .owner), frozen: try c.decode(Bool.self, forKey: .frozen),
                  balances: try c.decode([NearGuard.GuardBalance].self, forKey: .balances), pockets: try c.decode(Int.self, forKey: .pockets),
                  orders: try c.decode(Int.self, forKey: .orders), requests: try c.decode(Int.self, forKey: .requests),
                  receiptsTotal: try c.decode(UInt64.self, forKey: .receiptsTotal), pendingOut: try c.decode(Int.self, forKey: .pendingOut),
                  storagePaid: try c.u128(.storagePaid))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(owner, forKey: .owner); try c.encode(frozen, forKey: .frozen); try c.encode(balances, forKey: .balances)
        try c.encode(pockets, forKey: .pockets); try c.encode(orders, forKey: .orders); try c.encode(requests, forKey: .requests)
        try c.encode(receiptsTotal, forKey: .receiptsTotal); try c.encode(pendingOut, forKey: .pendingOut)
        try c.encode(String(storagePaid), forKey: .storagePaid)
    }
}

extension NearGuard.GuardPocket: Codable {
    enum CodingKeys: String, CodingKey {
        case name, token, spent, paused
        case publicKey = "public_key", perPaymentCap = "per_payment_cap", dailyCap = "daily_cap", windowStart = "window_start"
        case allowedRecipients = "allowed_recipients", expiresAt = "expires_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), publicKey: try c.decodeIfPresent(String.self, forKey: .publicKey),
                  token: try c.decode(String.self, forKey: .token), perPaymentCap: try c.u128(.perPaymentCap), dailyCap: try c.u128(.dailyCap),
                  spent: try c.u128(.spent), windowStart: try c.u64(.windowStart),
                  allowedRecipients: try c.decodeIfPresent([String].self, forKey: .allowedRecipients) ?? [],
                  expiresAt: try c.optU64(.expiresAt), paused: try c.decode(Bool.self, forKey: .paused))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(publicKey, forKey: .publicKey); try c.encode(token, forKey: .token)
        try c.encode(String(perPaymentCap), forKey: .perPaymentCap); try c.encode(String(dailyCap), forKey: .dailyCap)
        try c.encode(String(spent), forKey: .spent); try c.encode(String(windowStart), forKey: .windowStart)
        try c.encode(allowedRecipients, forKey: .allowedRecipients); try c.encode(expiresAt.map { String($0) }, forKey: .expiresAt)
        try c.encode(paused, forKey: .paused)
    }
}

extension NearGuard.GuardOrder: Codable {
    enum CodingKeys: String, CodingKey {
        case id, pocket, token, amount, recipient, remaining, memo
        case intervalSeconds = "interval_seconds", nextDueNs = "next_due_ns"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UInt64.self, forKey: .id), pocket: try c.decode(String.self, forKey: .pocket), token: try c.decode(String.self, forKey: .token),
                  amount: try c.u128(.amount), recipient: try c.decode(String.self, forKey: .recipient),
                  intervalSeconds: try c.decode(UInt64.self, forKey: .intervalSeconds), nextDueNs: try c.u64(.nextDueNs),
                  remaining: try c.decodeIfPresent(UInt32.self, forKey: .remaining), memo: try c.decode(String.self, forKey: .memo))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(pocket, forKey: .pocket); try c.encode(token, forKey: .token)
        try c.encode(String(amount), forKey: .amount); try c.encode(recipient, forKey: .recipient)
        try c.encode(intervalSeconds, forKey: .intervalSeconds); try c.encode(String(nextDueNs), forKey: .nextDueNs)
        try c.encode(remaining, forKey: .remaining); try c.encode(memo, forKey: .memo)
    }
}

extension NearGuard.GuardRequest: Codable {
    enum CodingKeys: String, CodingKey { case id, pocket, token, amount, recipient, reason, createdNs = "created_ns" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UInt64.self, forKey: .id), pocket: try c.decode(String.self, forKey: .pocket), token: try c.decode(String.self, forKey: .token),
                  amount: try c.u128(.amount), recipient: try c.decode(String.self, forKey: .recipient), reason: try c.decode(String.self, forKey: .reason),
                  createdNs: try c.u64(.createdNs))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(pocket, forKey: .pocket); try c.encode(token, forKey: .token)
        try c.encode(String(amount), forKey: .amount); try c.encode(recipient, forKey: .recipient)
        try c.encode(reason, forKey: .reason); try c.encode(String(createdNs), forKey: .createdNs)
    }
}

extension NearGuard.GuardReceipt.Kind: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch s {
        case "spend": self = .spend
        case "order": self = .order
        case "approved": self = .approved
        case "withdraw": self = .withdraw
        default: self = .other(s)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .spend: try c.encode("spend")
        case .order: try c.encode("order")
        case .approved: try c.encode("approved")
        case .withdraw: try c.encode("withdraw")
        case .other(let s): try c.encode(s)
        }
    }
}

extension NearGuard.GuardReceipt: Codable {
    enum CodingKeys: String, CodingKey { case id, pocket, token, amount, recipient, reason, kind, ok, timeNs = "time" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UInt64.self, forKey: .id), timeNs: try c.u64(.timeNs), pocket: try c.decode(String.self, forKey: .pocket),
                  token: try c.decode(String.self, forKey: .token), amount: try c.u128(.amount), recipient: try c.decode(String.self, forKey: .recipient),
                  reason: try c.decode(String.self, forKey: .reason), kind: try c.decode(Kind.self, forKey: .kind), ok: try c.decode(Bool.self, forKey: .ok))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(String(timeNs), forKey: .timeNs); try c.encode(pocket, forKey: .pocket)
        try c.encode(token, forKey: .token); try c.encode(String(amount), forKey: .amount); try c.encode(recipient, forKey: .recipient)
        try c.encode(reason, forKey: .reason); try c.encode(kind, forKey: .kind); try c.encode(ok, forKey: .ok)
    }
}

extension NearGuard {
    /// A view answer decoded into `T`. `bytes` is what the contract returned (the JSON text), `null` decodes into an optional.
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: bytes) } catch { throw WalletError.badResponse("Budgets: \(error.localizedDescription)") }
    }

    /// A U128 view answer such as `storage_cost`: a JSON string.
    public static func decodeAmount(_ bytes: Data) throws -> UInt128 {
        guard let s = try? JSONDecoder().decode(String.self, from: bytes), let v = UInt128(s) else { throw WalletError.badResponse("Budgets: not an amount") }
        return v
    }

    /// The receipts the contract lists oldest first, newest first.
    public static func newestFirst(_ receipts: [GuardReceipt]) -> [GuardReceipt] { receipts.sorted { $0.id > $1.id } }
}

// MARK: A key shown once

/// A pocket key's two halves, made on this device when a pocket with a key is approved. The private half is shown on one
/// sheet so the user can hand it to an app or an agent; Hermit doesn't save it anywhere. Printing one hides the secret.
public struct IssuedKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let account: String
    public let pocket: String
    /// "ed25519:<base58>" of the 32-byte public key.
    public let publicKey: String
    /// "ed25519:<base58>" of seed + public key (64 bytes), the form near-cli and near/guard.py read.
    public let privateKey: String

    public init(account: String, pocket: String, seed: [UInt8], publicKey: [UInt8]) {
        self.account = account; self.pocket = pocket
        self.publicKey = NearAccount.publicKeyString(publicKey)
        self.privateKey = "ed25519:" + Base58.encode(seed + publicKey)
    }

    /// The JSON near-cli writes for an access key, which `near/guard.py --key-file` reads.
    public var keyFile: String {
        NearGuard.J.obj([("account_id", NearGuard.J.str(account)), ("public_key", NearGuard.J.str(publicKey)), ("private_key", NearGuard.J.str(privateKey))])
    }
    public var description: String { "Pocket key for \(pocket) (secret hidden)" }
    public var debugDescription: String { description }
}

extension NearGuard {
    /// What a sent move returns.
    public struct Outcome: Equatable, Sendable {
        public let hash: String
        /// Set when the move made a pocket key. Shown once, then dropped.
        public let issuedKey: IssuedKey?
    }
}

// MARK: Reading

extension NearClient {
    static func viewBytes(_ r: JSON) -> Data {
        Data((r["result"]?.array ?? []).compactMap { $0.double.flatMap { UInt8(exactly: $0) } })
    }

    /// A contract view, as the bytes it returned. Reads the latest block (not the last final one), so a screen that opens right
    /// after the user's own call shows it; the contract checks everything again when a call runs.
    func guardData(_ contract: String, _ method: String, _ args: String = "{}") async throws -> Data {
        let r = try await call("query", ["request_type": "call_function", "finality": "optimistic", "account_id": .string(contract),
                                         "method_name": .string(method), "args_base64": .string(Data(args.utf8).base64EncodedString())])
        if let e = r["error"]?.string { throw WalletError.badResponse("\(method): \(e)") }
        return Self.viewBytes(r)
    }

    /// Symbol and decimals of an allowlisted token: from Hermit's own table, else the token's `ft_metadata`. nil when unreadable.
    func guardTokenInfo(_ id: String) async -> NearGuard.TokenInfo? {
        if let k = NearGuard.knownToken(id) { return k }
        guard let j = try? await view(id, "ft_metadata"), let symbol = j["symbol"]?.string, let decimals = j["decimals"]?.int,
              (0...38).contains(decimals), !symbol.isEmpty else { return nil }
        return NearGuard.TokenInfo(id: id, symbol: symbol, decimals: decimals)
    }

    /// Everything the Budgets screen shows for one owner.
    public func guardSnapshot(contract: String, owner: String) async throws -> NearGuard.Snapshot {
        async let costA = guardData(contract, "storage_cost")
        async let tokensA = guardData(contract, "get_tokens")
        async let vaultA = guardData(contract, "get_vault", NearGuard.ownerArgs(owner))
        let (costD, tokensD, vaultD) = try await (costA, tokensA, vaultA)
        let cost = try NearGuard.decodeAmount(costD)
        let allow = try NearGuard.decode([String].self, from: tokensD)
        let vault = try NearGuard.decode(NearGuard.GuardVault?.self, from: vaultD)

        var infos: [String: NearGuard.TokenInfo] = [:]
        await withTaskGroup(of: (String, NearGuard.TokenInfo?).self) { g in
            for id in allow { g.addTask { (id, await self.guardTokenInfo(id)) } }
            for await (id, t) in g { if let t { infos[id] = t } }
        }
        let tokens = allow.compactMap { infos[$0] }
        let unknown = allow.filter { infos[$0] == nil }

        guard vault != nil else {
            return NearGuard.Snapshot(contract: contract, vault: nil, tokens: tokens, unknownTokens: unknown, storageCost: cost)
        }
        let args = NearGuard.ownerArgs(owner)
        async let pocketsA = guardData(contract, "get_pockets", args)
        async let ordersA = guardData(contract, "get_orders", args)
        async let requestsA = guardData(contract, "get_requests", args)
        async let receiptsA = guardData(contract, "get_receipts", args)
        let (p, o, rq, rc) = try await (pocketsA, ordersA, requestsA, receiptsA)
        return NearGuard.Snapshot(contract: contract, vault: vault,
                                  pockets: try NearGuard.decode([NearGuard.GuardPocket].self, from: p),
                                  orders: try NearGuard.decode([NearGuard.GuardOrder].self, from: o),
                                  requests: try NearGuard.decode([NearGuard.GuardRequest].self, from: rq),
                                  receipts: NearGuard.newestFirst(try NearGuard.decode([NearGuard.GuardReceipt].self, from: rc)),
                                  tokens: tokens, unknownTokens: unknown, storageCost: cost)
    }

    /// What an access key can do on an account; nil when the account has no such key.
    func accessKeyPermission(account: String, publicKey: String) async throws -> NearGuard.KeyPermission? {
        do {
            let r = try await call("query", ["request_type": "view_access_key", "finality": "optimistic", "account_id": .string(account),
                                             "public_key": .string(publicKey)])
            guard let p = r["permission"], let perm = NearGuard.KeyPermission(p) else { throw WalletError.badResponse("view_access_key") }
            return perm
        } catch let e as RPCError where e.cause == "UNKNOWN_ACCESS_KEY" { return nil }
    }
}

// MARK: Preparing and sending

extension WalletService {
    /// The vault, pockets, orders, requests and receipts for a wallet's NEAR account.
    public func nearGuardSnapshot(walletID: UUID) async throws -> NearGuard.Snapshot {
        guard let contract = GuardConfig.contractID else { throw WalletError.blocked("Budgets isn't available in this version yet.") }
        guard let w = wallets.first(where: { $0.id == walletID }), let account = w.nearAccount else {
            throw WalletError.blocked("Add a NEAR account to this wallet first.")
        }
        return try await GuardConfig.client(for: contract, mainnet: nearClient).guardSnapshot(contract: contract, owner: account)
    }

    /// The most of a token this wallet can put into the vault right now: its token balance, or its NEAR less fee and reserve.
    /// nil when it couldn't be read.
    public func nearGuardMaxDeposit(walletID: UUID, token: NearGuard.TokenInfo) async -> UInt128? {
        guard let contract = GuardConfig.contractID, let w = wallets.first(where: { $0.id == walletID }), let account = w.nearAccount else { return nil }
        let client = GuardConfig.client(for: contract, mainnet: nearClient)
        if token.isNative {
            guard let state = try? await client.account(account) else { return nil }
            return NearGuard.maxDeposit(available: state.available)
        }
        return try? await client.ftBalance(token: token.id, owner: account)
    }

    /// Reads what a review needs (the account, the vault, the contract's code and, for some moves, a token or a key) and
    /// checks it. Nothing is signed here.
    public func prepareNearGuard(walletID: UUID, move: NearGuard.Move, origin: ActionOrigin = .user) async throws -> NearGuard.Review {
        guard let contract = GuardConfig.contractID else { throw WalletError.blocked("Budgets isn't available in this version yet.") }
        guard let w = wallets.first(where: { $0.id == walletID }) else { throw WalletError.vault("That wallet is gone.") }
        guard let account = w.nearAccount else { throw WalletError.blocked("Add a NEAR account to this wallet first.") }
        let client = GuardConfig.client(for: contract, mainnet: nearClient)
        async let stateA = client.account(account)
        async let snapA = client.guardSnapshot(contract: contract, owner: account)
        async let infoA = try? await client.contractInfo(contract)
        let (state, snap) = try await (stateA, snapA)
        let info = await infoA
        var c = NearGuard.Context(contract: contract, configured: GuardConfig.contractID, snapshot: snap, available: state?.available,
                                  nowNs: NearGuard.ns(Date()))
        c.codeHash = info?.codeHash
        c.accessKeys = info?.accessKeys

        switch move {
        case .depositToken(let id, _):
            if let t = snap.token(id), !t.isNative {
                c.token = t
                async let balA = try? await client.ftBalance(token: id, owner: account)
                async let regA = try? await client.isRegistered(token: id, account: account)
                async let guardRegA = try? await client.isRegistered(token: id, account: contract)
                c.walletTokenBalance = await balA
                c.walletRegistered = await regA
                c.guardRegistered = await guardRegA
            }
        case .withdraw(let id, _):
            if let t = snap.token(id), !t.isNative {
                c.token = t
                c.walletRegistered = try? await client.isRegistered(token: id, account: account)
            }
        case .approve(let rid):
            if let r = snap.requests.first(where: { $0.id == rid }), let t = snap.token(r.token) {
                if t.isNative {
                    if NearAccount.isImplicit(r.recipient) { c.recipientReady = true }
                    else { do { c.recipientReady = try await client.account(r.recipient) != nil } catch { c.recipientReady = nil } }
                } else {
                    c.recipientReady = try? await client.isRegistered(token: r.token, account: r.recipient)
                }
            }
        case .removePocket(let name):
            if let key = snap.pocket(name)?.publicKey {
                do {
                    c.pocketKeyPermission = try await client.accessKeyPermission(account: account, publicKey: key)
                    c.pocketKeyRead = true
                } catch { c.pocketKeyRead = false }
            }
        default: break
        }

        // Dollars for the daily limit, for the moves that put money into the vault (mainnet prices only).
        if !GuardConfig.isTestnet(contract) {
            switch move {
            case .openVault, .depositNear:
                c.usdPerUnit = await usdPerUnit(chain: .near, token: nil)
            case .depositToken(let id, _):
                if let tk = TokenTable.all.first(where: { $0.chainID == "near" && $0.address == id }) { c.usdPerUnit = await usdPerUnit(chain: .near, token: tk) }
            default: break
            }
        }
        return try NearGuard.review(move, walletID: walletID, account: account, context: c, policy: policy, origin: origin)
    }

    /// Signs and sends a reviewed move with one Face ID check, waits for each transaction to execute and returns the last
    /// hash. For a pocket with a key it makes the key here (so it never exists before the user approves), sends AddKey then
    /// create_pocket, and if create_pocket is refused it deletes the key again with a transaction signed in the same unlock.
    public func executeNearGuard(_ r: NearGuard.Review) async throws -> NearGuard.Outcome {
        guard let configured = GuardConfig.contractID, configured == r.contract else {
            throw WalletError.blocked("That isn't the Budgets contract this version of Hermit uses. Nothing was sent.")
        }
        guard GuardConfig.isTestnet(r.contract) || allowMainnetSends else { throw WalletError.blocked("Mainnet transactions are off in this build.") }
        guard let w = wallets.first(where: { $0.id == r.walletID }) else { throw WalletError.vault("That wallet is gone.") }
        guard w.nearAccount == r.account else { throw WalletError.blocked("This wallet's NEAR account changed. Nothing was sent.") }
        let client = GuardConfig.client(for: r.contract, mainnet: nearClient)

        var seed: [UInt8] = []
        var publicKey: [UInt8]?
        if r.issuesKey {
            let key = Curve25519.Signing.PrivateKey()
            seed = [UInt8](key.rawRepresentation)
            publicKey = [UInt8](key.publicKey.rawRepresentation)
        }
        defer { seed.wipe() }
        let plan = try NearGuard.plan(r.move, contract: r.contract, account: r.account, newPocketKey: publicKey, deleteKey: r.deleteKey)
        let hashes = try await sendNearSteps(w, plan: plan, client: client, reason: r.reason)

        if case .depositToken(let token, let amount) = r.move, let before = r.balanceBefore {
            // ft_transfer_call succeeds even when the contract hands the tokens back, so look at the vault.
            let after = try await client.guardSnapshot(contract: r.contract, owner: r.account).vault?.balance(token) ?? 0
            guard after >= before + amount else {
                throw WalletError.blocked("The Budgets contract sent the tokens back, so nothing was added. They are still in your wallet.")
            }
        }
        if let usd = r.usd { spendLimit.record(usd: usd) }
        Task { await refreshBalances(chains: [.near]) }
        var issued: IssuedKey?
        if let pub = publicKey, case .createPocket(let d) = r.move { issued = IssuedKey(account: r.account, pocket: d.name, seed: seed, publicKey: pub) }
        return NearGuard.Outcome(hash: hashes.last ?? "", issuedKey: issued)
    }

    private enum StepResult { case done(String), refused(String), unknown(String) }

    private func sendGuardTx(_ tx: SignedNearTransaction, via client: NearClient) async -> StepResult {
        do {
            let r = try await client.send(tx)
            return r.success ? .done(r.hash) : .refused(NearGuard.failureText(r.failure ?? "The transaction failed."))
        } catch let e as NearClient.RPCError where e.cause != "TIMEOUT_ERROR" {
            return .refused(e.message)
        } catch {
            return .unknown(tx.transaction.hashString)
        }
    }

    /// Signs every transaction of a plan in one unlock (consecutive nonces), then sends them one at a time, each only after
    /// the one before it went through.
    func sendNearSteps(_ w: WalletRecord, plan: NearGuard.Plan, client: NearClient, reason: String) async throws -> [String] {
        guard let from = w.nearAccount, let pub = [UInt8](hex: from), pub.count == 32 else { throw WalletError.invalidKey }
        async let nonceA = client.accessKeyNonce(account: from, publicKey: NearAccount.publicKeyString(pub))
        async let blockA = client.latestBlockHash()
        let (nonce, block) = try await (nonceA, blockA)

        var all = plan.steps
        if let rb = plan.rollback { all.append(rb) }
        var built: [NearTransaction] = []
        for (i, s) in all.enumerated() {
            built.append(NearTransaction(signer: from, publicKey: pub, nonce: nonce + UInt64(i) + 1, receiver: s.receiver, blockHash: block, actions: s.actions))
        }
        let unsigned = built
        let signed = try await vault.withKey(w.id, kind: .near, reason: reason) { seed in try unsigned.map { try $0.sign(ed25519Seed: seed) } }
        for (u, s) in zip(unsigned, signed) {
            guard s.verify(), s.transaction == u else { throw WalletError.blocked("Signed transaction failed its self-check. Nothing was sent.") }
        }

        var hashes: [String] = []
        for i in 0..<plan.steps.count {
            switch await sendGuardTx(signed[i], via: client) {
            case .done(let h):
                hashes.append(h)
            case .unknown(let h):
                // Sent, not confirmed: it may still land. Nothing more is sent and nothing is undone.
                throw WalletError.pending(hash: h, explorer: Chain.near.explorerURL(tx: h)?.absoluteString)
            case .refused(let why):
                if i == 0 { throw WalletError.blocked(why) }
                if let rb = plan.rollback, signed.count > plan.steps.count {
                    if case .done = await sendGuardTx(signed[plan.steps.count], via: client) {
                        throw WalletError.blocked("\(why) The key Hermit had added for this pocket was removed again.")
                    }
                    let key = rb.actions.compactMap { a -> String? in
                        if case .deleteKey(let k) = a { return NearAccount.publicKeyString(k) } else { return nil }
                    }.first ?? ""
                    throw WalletError.blocked("\(why) The new key (\(key)) is still on your account and can't do anything. Remove it in your NEAR wallet.")
                }
                throw WalletError.blocked("\(why) The first part already went through. Open Budgets to see where things stand.")
            }
        }
        return hashes
    }
}
