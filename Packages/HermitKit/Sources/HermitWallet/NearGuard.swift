import Foundation
import CryptoKit

// Hermit Guard, the app side. The contract lives in contracts/guard/ (README.md, SECURITY.md, src/lib.rs); this file is
// only the client: it reads a vault, writes the owner's calls, and checks each one before the approval sheet opens.
// Every method name, argument and number below was checked against src/lib.rs and against the testnet deployment
// (hermit-guard-1794510023.testnet) with read-only RPC calls on 2026-11-12:
//   open_vault {}                     payable, attach storage_cost (0.5 NEAR) plus anything extra, which goes in the vault
//   deposit_near {}                   payable, credits the attached NEAR
//   ft_transfer_call on the token     {receiver_id: guard, amount, msg: ""}, 1 yocto, the token calls ft_on_transfer
//   withdraw {token, amount|null}     always allowed, also frozen; pays the owner's own account only
//   close_vault {} freeze {} unfreeze {}
//   create_pocket / update_pocket {config: {name, public_key, token, per_payment_cap, daily_cap, allowed_recipients, expires_at}}
//   remove_pocket / pause_pocket / resume_pocket {name}
//   create_order {pocket, amount, recipient, interval_seconds, first_due_ns, remaining, memo}   cancel_order {order_id}
//   approve {request_id}   reject {request_id}
// Owner calls attach exactly 1 yoctoNEAR (the contract asserts it, which is also what keeps a function-call key out), and
// the payout paths need at least 120 TGas (the contract's constant; its message says 125, README says attach 150).
// Views: get_vault, get_pockets, get_orders, get_requests, get_receipts (oldest first), storage_cost, get_tokens.

/// Where the Budgets contract is, and whether the feature exists in this build.
public enum GuardConfig {
    /// The mainnet contract. nil until it's deployed: while it's nil the whole feature is hidden.
    public static let mainnetContractID: String? = nil
    /// The code hash (base58 of the wasm's sha256) Hermit expects on the mainnet contract. Pasted in with the id.
    public static let mainnetCodeHash: String? = nil
    /// The hash of the testnet deployment's code (contracts/guard/DEPLOYMENTS.md, sha256 714aaaa4...a994).
    public static let testnetCodeHash = "8dF77PJ84FYaezm4w7mvmGb54mFN9rP5jaPDmXmiD5W3"
    /// Debug builds only: a launch argument (`-hermit.guard.contract name.testnet`) or this UserDefaults key points the app at
    /// another contract. A ".testnet" id also switches Budgets to the testnet RPC.
    public static let overrideKey = "hermit.guard.contract"
    public static let testnetRPC = URL(string: "https://test.rpc.fastnear.com")!

    /// The contract to use: the debug override when allowed and valid, else the mainnet id, else nil.
    public static func resolve(mainnet: String?, override: String?, allowOverride: Bool) -> String? {
        if allowOverride, let o = override?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), NearAccount.isValid(o) { return o }
        if let m = mainnet, NearAccount.isValid(m), !m.hasSuffix(".testnet") { return m }
        return nil
    }

    /// nil hides Budgets everywhere.
    public static var contractID: String? {
        #if DEBUG
        resolve(mainnet: mainnetContractID, override: UserDefaults.standard.string(forKey: overrideKey), allowOverride: true)
        #else
        resolve(mainnet: mainnetContractID, override: nil, allowOverride: false)
        #endif
    }

    public static var isEnabled: Bool { contractID != nil }
    public static func isTestnet(_ contract: String) -> Bool { contract.hasSuffix(".testnet") }

    /// The code hash Hermit has checked for this contract, nil when none is pinned.
    public static func expectedCodeHash(for contract: String) -> String? {
        if isTestnet(contract) { return testnetCodeHash }
        return contract == mainnetContractID ? mainnetCodeHash : nil
    }

    /// The NEAR RPC to read and send through: mainnet's, or the testnet's for a ".testnet" contract (debug builds only).
    public static func client(for contract: String, mainnet: NearClient) -> NearClient {
        isTestnet(contract) ? NearClient(url: testnetRPC) : mainnet
    }
}

public enum NearGuard {
    // MARK: Numbers

    /// Gas on every call to the contract. The contract refuses a payout (withdraw, approve) with less than 120 TGas left
    /// (its message says 125) and its README says to attach 150; what isn't used is refunded. near/guard.py attaches the
    /// same 150 on every call and the testnet run used it.
    public static let gas: UInt64 = 150 * NearAction.tgas
    /// ft_transfer_call needs the token's own work, the contract's ft_on_transfer and the token's resolve step. near/guard.py uses 200.
    public static let tokenDepositGas: UInt64 = 200 * NearAction.tgas
    /// The most a call can cost: its gas at twice mainnet's gas price, the same ceiling NEAR sends show.
    public static let feeCeiling: UInt128 = UInt128(gas) * 200_000_000
    public static let tokenDepositFeeCeiling: UInt128 = UInt128(tokenDepositGas) * 200_000_000
    /// Attached to every owner call. The contract asserts exactly this, and a function-call key can't attach it.
    public static let oneYocto: UInt128 = NearAction.oneYocto
    /// The vault's storage deposit (storage_cost). Read from the contract each time; this is only what's expected.
    public static let storageDeposit: UInt128 = 500_000_000_000_000_000_000_000
    /// A storage_cost above this is not what Hermit was built for, so it prepares nothing.
    public static let maxStorageDeposit: UInt128 = 1_000_000_000_000_000_000_000_000
    /// NEAR that always stays in the account (0.05), so there's gas left to withdraw and freeze later.
    public static let reserve: UInt128 = 50_000_000_000_000_000_000_000
    /// The gas budget of a pocket key: 0.25 NEAR. The key pays for its own calls from this and stops when it's used up.
    public static let keyAllowance: UInt128 = 250_000_000_000_000_000_000_000
    /// NEAR kept back for the access key's storage (0.01) when a pocket gets a key.
    public static let keyReserve: UInt128 = 10_000_000_000_000_000_000_000
    /// The only methods a pocket key may call.
    public static let keyMethods = ["spend", "request"]

    // The contract's limits (constants at the top of lib.rs).
    public static let maxPockets = 8
    public static let maxOrders = 20
    public static let maxRecipients = 20
    public static let maxReceipts = 50
    public static let maxNameBytes = 24
    public static let maxTextBytes = 140
    public static let minIntervalSeconds: UInt64 = 3_600
    public static let maxIntervalSeconds: UInt64 = 315_360_000
    public static let dayNs: UInt64 = 86_400_000_000_000
    public static let requestTTLNs: UInt64 = 7 * dayNs

    // MARK: Tokens

    /// A token the vault can hold: "near" or an NEP-141 contract on the contract's allowlist.
    public struct TokenInfo: Equatable, Hashable, Sendable, Identifiable {
        public let id: String
        public let symbol: String
        public let decimals: Int
        public init(id: String, symbol: String, decimals: Int) { self.id = id; self.symbol = symbol; self.decimals = decimals }
        public static let near = TokenInfo(id: "near", symbol: "NEAR", decimals: 24)
        public var isNative: Bool { id == "near" }

        /// "12.5", cut (never rounded up) to five decimals for NEAR and six for tokens; "<0.00001" when it's more than nothing but less.
        public func number(_ v: UInt128) -> String {
            let places = isNative ? 5 : min(decimals, 6)
            let s = Units.format(v, decimals: decimals, maxFraction: places)
            if v > 0 && s == "0" && places > 0 { return "<0." + String(repeating: "0", count: places - 1) + "1" }
            return s
        }
        /// "12.5 NEAR".
        public func text(_ v: UInt128) -> String { "\(number(v)) \(symbol)" }
        public func parse(_ text: String) throws -> UInt128 { try Units.parse(text, decimals: decimals) }
    }

    /// The tokens Hermit knows without asking the chain: NEAR, and the NEP-141 tokens in the token table.
    public static func knownToken(_ id: String) -> TokenInfo? {
        if id == "near" { return .near }
        return TokenTable.all.first { $0.chainID == "near" && $0.address == id }.map { TokenInfo(id: id, symbol: $0.symbol, decimals: $0.decimals) }
    }

    // MARK: What the contract returns

    public struct GuardBalance: Equatable, Sendable {
        public let token: String
        public let amount: UInt128
        public init(token: String, amount: UInt128) { self.token = token; self.amount = amount }
    }

    /// `get_vault`.
    public struct GuardVault: Equatable, Sendable {
        public let owner: String
        public let frozen: Bool
        public let balances: [GuardBalance]
        public let pockets: Int
        public let orders: Int
        public let requests: Int
        public let receiptsTotal: UInt64
        /// Payouts sent but not settled yet; the vault can't be closed while this isn't 0.
        public let pendingOut: Int
        public let storagePaid: UInt128
        public func balance(_ token: String) -> UInt128 { balances.first { $0.token == token }?.amount ?? 0 }
        public init(owner: String, frozen: Bool, balances: [GuardBalance], pockets: Int, orders: Int, requests: Int,
                    receiptsTotal: UInt64, pendingOut: Int, storagePaid: UInt128) {
            self.owner = owner; self.frozen = frozen; self.balances = balances; self.pockets = pockets; self.orders = orders
            self.requests = requests; self.receiptsTotal = receiptsTotal; self.pendingOut = pendingOut; self.storagePaid = storagePaid
        }
    }

    /// `get_pockets`.
    public struct GuardPocket: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let publicKey: String?
        public let token: String
        public let perPaymentCap: UInt128
        public let dailyCap: UInt128
        /// Spent in the current window; only meaningful while that window is open (`spentToday`).
        public let spent: UInt128
        public let windowStart: UInt64
        public let allowedRecipients: [String]
        public let expiresAt: UInt64?
        public let paused: Bool

        public enum State: Equatable, Sendable { case active, paused, expired }
        public func isExpired(nowNs: UInt64) -> Bool { expiresAt.map { nowNs >= $0 } ?? false }
        public func state(nowNs: UInt64) -> State { paused ? .paused : isExpired(nowNs: nowNs) ? .expired : .active }
        /// What counts against the daily limit right now: the window is a fixed 24 hours from the first spend.
        public func spentToday(nowNs: UInt64) -> UInt128 {
            windowStart == 0 || nowNs >= windowStart &+ NearGuard.dayNs ? 0 : spent
        }
        public func leftToday(nowNs: UInt64) -> UInt128 {
            let used = spentToday(nowNs: nowNs)
            return dailyCap > used ? dailyCap - used : 0
        }
        public init(name: String, publicKey: String?, token: String, perPaymentCap: UInt128, dailyCap: UInt128, spent: UInt128,
                    windowStart: UInt64, allowedRecipients: [String], expiresAt: UInt64?, paused: Bool) {
            self.name = name; self.publicKey = publicKey; self.token = token; self.perPaymentCap = perPaymentCap; self.dailyCap = dailyCap
            self.spent = spent; self.windowStart = windowStart; self.allowedRecipients = allowedRecipients; self.expiresAt = expiresAt; self.paused = paused
        }
    }

    /// `get_orders`.
    public struct GuardOrder: Equatable, Sendable, Identifiable {
        public let id: UInt64
        public let pocket: String
        public let token: String
        public let amount: UInt128
        public let recipient: String
        public let intervalSeconds: UInt64
        public let nextDueNs: UInt64
        /// Runs left; nil = until cancelled.
        public let remaining: UInt32?
        public let memo: String
        public init(id: UInt64, pocket: String, token: String, amount: UInt128, recipient: String, intervalSeconds: UInt64,
                    nextDueNs: UInt64, remaining: UInt32?, memo: String) {
            self.id = id; self.pocket = pocket; self.token = token; self.amount = amount; self.recipient = recipient
            self.intervalSeconds = intervalSeconds; self.nextDueNs = nextDueNs; self.remaining = remaining; self.memo = memo
        }
    }

    /// `get_requests`: what a pocket key asked for beyond its limits. Nothing is paid until the owner approves.
    public struct GuardRequest: Equatable, Sendable, Identifiable {
        public let id: UInt64
        public let pocket: String
        public let token: String
        public let amount: UInt128
        public let recipient: String
        /// Written by whoever holds the pocket key. Shown as theirs, never as Hermit's.
        public let reason: String
        public let createdNs: UInt64
        public var expiresNs: UInt64 { createdNs &+ NearGuard.requestTTLNs }
        public init(id: UInt64, pocket: String, token: String, amount: UInt128, recipient: String, reason: String, createdNs: UInt64) {
            self.id = id; self.pocket = pocket; self.token = token; self.amount = amount; self.recipient = recipient
            self.reason = reason; self.createdNs = createdNs
        }
    }

    /// `get_receipts` (the contract keeps the last 50, oldest first).
    public struct GuardReceipt: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case spend, order, approved, withdraw, other(String) }
        public let id: UInt64
        public let timeNs: UInt64
        /// Empty for a withdrawal.
        public let pocket: String
        public let token: String
        public let amount: UInt128
        public let recipient: String
        public let reason: String
        public let kind: Kind
        /// false once the transfer is known to have failed; the money is then back in the vault.
        public let ok: Bool
        public init(id: UInt64, timeNs: UInt64, pocket: String, token: String, amount: UInt128, recipient: String, reason: String, kind: Kind, ok: Bool) {
            self.id = id; self.timeNs = timeNs; self.pocket = pocket; self.token = token; self.amount = amount
            self.recipient = recipient; self.reason = reason; self.kind = kind; self.ok = ok
        }
    }

    /// Everything one screen shows, read in one go.
    public struct Snapshot: Equatable, Sendable {
        public var contract: String
        public var vault: GuardVault?
        public var pockets: [GuardPocket]
        public var orders: [GuardOrder]
        public var requests: [GuardRequest]
        /// Latest first.
        public var receipts: [GuardReceipt]
        /// The allowlist tokens Hermit could name (NEAR first).
        public var tokens: [TokenInfo]
        /// Allowlist entries whose symbol and decimals couldn't be read: shown by id only, never moved.
        public var unknownTokens: [String]
        public var storageCost: UInt128
        public init(contract: String, vault: GuardVault?, pockets: [GuardPocket] = [], orders: [GuardOrder] = [], requests: [GuardRequest] = [],
                    receipts: [GuardReceipt] = [], tokens: [TokenInfo] = [.near], unknownTokens: [String] = [], storageCost: UInt128 = NearGuard.storageDeposit) {
            self.contract = contract; self.vault = vault; self.pockets = pockets; self.orders = orders; self.requests = requests
            self.receipts = receipts; self.tokens = tokens; self.unknownTokens = unknownTokens; self.storageCost = storageCost
        }
        public func token(_ id: String) -> TokenInfo? { tokens.first { $0.id == id } }
        public func pocket(_ name: String) -> GuardPocket? { pockets.first { $0.name == name } }
    }

    // MARK: JSON the contract takes

    /// Arguments are written the way near-api-js writes them (JSON.stringify of the same object, same key order), so the
    /// transaction bytes match byte for byte. 128-bit and 64-bit amounts and times (U128, U64) are strings; plain u64 and
    /// u32 (ids, interval_seconds, remaining) are numbers.
    enum J {
        static func str(_ s: String) -> String {
            var out = "\""
            for u in s.unicodeScalars {
                switch u.value {
                case 0x22: out += "\\\""
                case 0x5C: out += "\\\\"
                case 0x08: out += "\\b"
                case 0x0C: out += "\\f"
                case 0x0A: out += "\\n"
                case 0x0D: out += "\\r"
                case 0x09: out += "\\t"
                case 0..<0x20: out += String(format: "\\u%04x", u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            return out + "\""
        }
        static func big(_ v: UInt128) -> String { "\"\(v)\"" }
        static func opt(_ s: String?) -> String { s.map(str) ?? "null" }
        static func obj(_ pairs: [(String, String)]) -> String { "{" + pairs.map { "\(str($0.0)):\($0.1)" }.joined(separator: ",") + "}" }
        static func arr(_ items: [String]) -> String { "[" + items.joined(separator: ",") + "]" }
    }

    static func call(_ method: String, _ args: String = "{}", deposit: UInt128 = oneYocto, gas: UInt64 = NearGuard.gas) -> NearAction {
        .functionCall(method: method, args: Array(args.utf8), gas: gas, deposit: deposit)
    }

    // The storage deposit comes with open_vault: nothing else on this contract takes more than 1 yocto except deposit_near.
    public static func openVault(attaching deposit: UInt128) -> NearAction { call("open_vault", deposit: deposit) }
    public static func depositNear(_ amount: UInt128) -> NearAction { call("deposit_near", deposit: amount) }
    /// Sent to the token contract: the token calls the guard's `ft_on_transfer`, which credits the sender's vault.
    public static func depositToken(guardContract: String, amount: UInt128) -> NearAction {
        call("ft_transfer_call", J.obj([("receiver_id", J.str(guardContract)), ("amount", J.big(amount)), ("msg", J.str(""))]), gas: tokenDepositGas)
    }
    /// `amount` nil withdraws everything the vault holds of the token.
    public static func withdraw(token: String, amount: UInt128?) -> NearAction {
        call("withdraw", J.obj([("token", J.str(token)), ("amount", amount.map(J.big) ?? "null")]))
    }
    public static var closeVault: NearAction { call("close_vault") }
    public static var freeze: NearAction { call("freeze") }
    public static var unfreeze: NearAction { call("unfreeze") }

    /// `{"name": ..., ...}`, the PocketConfig of create_pocket and update_pocket. `publicKey` nil leaves the pocket without a key.
    static func configJSON(_ d: PocketDraft, publicKey: String?) -> String {
        J.obj([("name", J.str(d.name)), ("public_key", J.opt(publicKey)), ("token", J.str(d.token)),
               ("per_payment_cap", J.big(d.perPayment)), ("daily_cap", J.big(d.daily)),
               ("allowed_recipients", J.arr(d.recipients.map(J.str))),
               ("expires_at", d.expiresAtNs.map { "\"\($0)\"" } ?? "null")])
    }
    public static func createPocket(_ d: PocketDraft, publicKey: String?) -> NearAction {
        call("create_pocket", J.obj([("config", configJSON(d, publicKey: publicKey))]))
    }
    public static func updatePocket(_ d: PocketDraft) -> NearAction {
        // update_pocket REPLACES the key with config.public_key, so a pocket that has one must send it back.
        call("update_pocket", J.obj([("config", configJSON(d, publicKey: d.publicKey))]))
    }
    public static func removePocket(_ name: String) -> NearAction { call("remove_pocket", J.obj([("name", J.str(name))])) }
    public static func pausePocket(_ name: String) -> NearAction { call("pause_pocket", J.obj([("name", J.str(name))])) }
    public static func resumePocket(_ name: String) -> NearAction { call("resume_pocket", J.obj([("name", J.str(name))])) }
    public static func createOrder(_ d: OrderDraft) -> NearAction {
        call("create_order", J.obj([("pocket", J.str(d.pocket)), ("amount", J.big(d.amount)), ("recipient", J.str(d.recipient)),
                                    ("interval_seconds", String(d.intervalSeconds)), ("first_due_ns", "null"),
                                    ("remaining", d.remaining.map { String($0) } ?? "null"), ("memo", J.str(d.memo))]))
    }
    public static func cancelOrder(_ id: UInt64) -> NearAction { call("cancel_order", J.obj([("order_id", String(id))])) }
    public static func approve(_ id: UInt64) -> NearAction { call("approve", J.obj([("request_id", String(id))])) }
    public static func reject(_ id: UInt64) -> NearAction { call("reject", J.obj([("request_id", String(id))])) }

    static func ownerArgs(_ owner: String) -> String { J.obj([("owner", J.str(owner))]) }

    // MARK: What the owner asks for

    /// A pocket as the form describes it. Changing an existing pocket keeps `publicKey` as it is.
    public struct PocketDraft: Equatable, Sendable {
        public var name: String
        public var token: String
        public var perPayment: UInt128
        public var daily: UInt128
        public var recipients: [String]
        public var expiresAtNs: UInt64?
        /// The key already on an existing pocket (update only); nil for a new pocket and for one without a key.
        public var publicKey: String?
        /// A new pocket: make a key for it and add it to the account.
        public var withKey: Bool
        public init(name: String, token: String, perPayment: UInt128, daily: UInt128, recipients: [String] = [], expiresAtNs: UInt64? = nil,
                    publicKey: String? = nil, withKey: Bool = false) {
            self.name = name; self.token = token; self.perPayment = perPayment; self.daily = daily; self.recipients = recipients
            self.expiresAtNs = expiresAtNs; self.publicKey = publicKey; self.withKey = withKey
        }
    }

    public struct OrderDraft: Equatable, Sendable {
        public var pocket: String
        public var amount: UInt128
        public var recipient: String
        public var intervalSeconds: UInt64
        /// Runs before it stops; nil runs until cancelled.
        public var remaining: UInt32?
        public var memo: String
        public init(pocket: String, amount: UInt128, recipient: String, intervalSeconds: UInt64, remaining: UInt32? = nil, memo: String = "") {
            self.pocket = pocket; self.amount = amount; self.recipient = recipient; self.intervalSeconds = intervalSeconds
            self.remaining = remaining; self.memo = memo
        }
    }

    public enum Move: Equatable, Sendable {
        /// Open the vault: `storage` is the contract's storage_cost, `initial` NEAR goes in on top of it.
        case openVault(storage: UInt128, initial: UInt128)
        case depositNear(UInt128)
        case depositToken(token: String, amount: UInt128)
        /// nil amount = everything.
        case withdraw(token: String, amount: UInt128?)
        case closeVault
        case setFrozen(Bool)
        case createPocket(PocketDraft)
        case updatePocket(PocketDraft)
        case removePocket(name: String)
        case setPaused(name: String, paused: Bool)
        case createOrder(OrderDraft)
        case cancelOrder(UInt64)
        case approve(UInt64)
        case reject(UInt64)
    }

    /// One transaction: where it goes and what it does.
    public struct Step: Equatable, Sendable {
        public let receiver: String
        public let actions: [NearAction]
        public init(receiver: String, actions: [NearAction]) { self.receiver = receiver; self.actions = actions }
    }

    /// The transactions a move is made of, in order. `rollback` is sent only if the last step fails for good after the
    /// earlier ones went through.
    public struct Plan: Equatable, Sendable {
        public let steps: [Step]
        public let rollback: Step?
    }

    /// Builds the transactions for a move.
    ///
    /// A pocket with a key is two transactions, in this order:
    ///   1. AddKey on the owner's own account (a function-call key: receiver = the guard contract, methods spend and request,
    ///      0.25 NEAR of gas), then 2. create_pocket on the contract with that key's public part.
    /// If step 2 is refused, `rollback` (DeleteKey of the same key) is sent, so no key is left behind. Why this order: until
    /// step 2 the contract knows nothing of the key, so a key that was added but not registered can only fail (the contract
    /// answers "not a pocket key"), and it is deleted again at once; nobody ever sees its private half unless step 2
    /// went through. The other order could leave a pocket on the contract that names a key no account holds.
    ///
    /// Removing a pocket is remove_pocket first and DeleteKey second: the contract stops honouring the key before the key goes.
    public static func plan(_ move: Move, contract: String, account: String, newPocketKey: [UInt8]? = nil, deleteKey: String? = nil) throws -> Plan {
        func one(_ a: NearAction, to receiver: String? = nil) -> Plan { Plan(steps: [Step(receiver: receiver ?? contract, actions: [a])], rollback: nil) }
        switch move {
        case .openVault(let storage, let initial):
            let (total, over) = storage.addingReportingOverflow(initial)
            guard !over else { throw WalletError.invalidAmount("\(initial)") }
            return one(openVault(attaching: total))
        case .depositNear(let a): return one(depositNear(a))
        case .depositToken(let token, let a): return one(depositToken(guardContract: contract, amount: a), to: token)
        case .withdraw(let token, let a): return one(withdraw(token: token, amount: a))
        case .closeVault: return one(closeVault)
        case .setFrozen(let f): return one(f ? freeze : unfreeze)
        case .createPocket(let d):
            guard d.withKey else { return one(createPocket(d, publicKey: nil)) }
            guard let key = newPocketKey, key.count == 32 else { throw WalletError.invalidKey }
            let text = NearAccount.publicKeyString(key)
            let add = NearAction.addFunctionCallKey(publicKey: key, allowance: keyAllowance, receiver: contract, methods: keyMethods)
            return Plan(steps: [Step(receiver: account, actions: [add]), Step(receiver: contract, actions: [createPocket(d, publicKey: text)])],
                        rollback: Step(receiver: account, actions: [.deleteKey(publicKey: key)]))
        case .updatePocket(let d): return one(updatePocket(d))
        case .removePocket(let name):
            var steps = [Step(receiver: contract, actions: [removePocket(name)])]
            if let k = deleteKey {
                guard let raw = publicKeyBytes(k) else { throw WalletError.invalidKey }
                steps.append(Step(receiver: account, actions: [.deleteKey(publicKey: raw)]))
            }
            return Plan(steps: steps, rollback: nil)
        case .setPaused(let name, let p): return one(p ? pausePocket(name) : resumePocket(name))
        case .createOrder(let d): return one(createOrder(d))
        case .cancelOrder(let id): return one(cancelOrder(id))
        case .approve(let id): return one(approve(id))
        case .reject(let id): return one(reject(id))
        }
    }

    /// The 32 bytes of an "ed25519:<base58>" public key; nil for any other kind of key or a bad length.
    public static func publicKeyBytes(_ text: String) -> [UInt8]? {
        guard text.hasPrefix("ed25519:"), let raw = Base58.decode(String(text.dropFirst(8))), raw.count == 32 else { return nil }
        return raw
    }

    /// What `view_access_key` says a key can do.
    public enum KeyPermission: Equatable, Sendable {
        case fullAccess
        case functionCall(receiver: String, methods: [String])
        public init?(_ j: JSON) {
            if j.string == "FullAccess" { self = .fullAccess; return }
            guard let f = j["FunctionCall"], let r = f["receiver_id"]?.string else { return nil }
            self = .functionCall(receiver: r, methods: (f["method_names"]?.array ?? []).compactMap { $0.string })
        }
    }

    /// Whether removing a pocket may also delete its key from the account. Only a key Hermit makes qualifies: a function-call
    /// key for this contract that can call nothing but spend and request. A pocket made from the command line can name any
    /// key, even the owner's own full-access key, and deleting that would lock the owner out.
    public static func isHermitPocketKey(_ p: KeyPermission, contract: String) -> Bool {
        guard case .functionCall(let receiver, let methods) = p else { return false }
        return receiver == contract && !methods.isEmpty && methods.allSatisfy { keyMethods.contains($0) }
    }

    // MARK: Words and numbers

    /// The most NEAR the wallet can put into the vault: everything but the fee for the call and the reserve.
    public static func maxDeposit(available: UInt128) -> UInt128 {
        let keep = reserve + feeCeiling
        return available > keep ? available - keep : 0
    }

    /// "every day", "every 2 weeks", "every 6 hours".
    public static func everyText(_ seconds: UInt64) -> String {
        let h: UInt64 = 3_600, d = 24 * h, w = 7 * d
        func unit(_ n: UInt64, _ s: String) -> String { n == 1 ? "every \(s)" : "every \(n) \(s)s" }
        if seconds % w == 0 { return unit(seconds / w, "week") }
        if seconds % d == 0 { return unit(seconds / d, "day") }
        if seconds % h == 0 { return unit(seconds / h, "hour") }
        return "every \(seconds) seconds"
    }

    public static func date(ns: UInt64) -> Date { Date(timeIntervalSince1970: Double(ns) / 1_000_000_000) }
    public static func ns(_ d: Date) -> UInt64 { UInt64(max(0, d.timeIntervalSince1970) * 1_000_000_000) }
    static func dateText(ns: UInt64) -> String { date(ns: ns).formatted(date: .abbreviated, time: .shortened) }

    /// The plain words for a failure: the contract's own panic message when there is one, in everyday language.
    public static func failureText(_ raw: String) -> String {
        var message = raw
        if let data = raw.data(using: .utf8), let j = try? JSONDecoder().decode(JSON.self, from: data) {
            func find(_ j: JSON) -> String? {
                if case .object(let o) = j {
                    if let e = o["ExecutionError"]?.string { return e }
                    for v in o.values { if let s = find(v) { return s } }
                }
                return nil
            }
            if let m = find(j) { message = m }
        }
        let prefix = "Smart contract panicked: "
        if message.hasPrefix(prefix) { message = String(message.dropFirst(prefix.count)) }
        let known: [String: String] = [
            "vault frozen": "Budgets is frozen.",
            "pocket name already used": "You already have a pocket with that name.",
            "pocket limit reached (8)": "You already have 8 pockets, the most there can be.",
            "order limit reached (20)": "You already have 20 standing orders, the most there can be.",
            "insufficient vault balance": "The vault doesn't hold enough for that.",
            "no vault for this account": "There is no Budgets vault for this account yet.",
            "vault already exists": "You already have a Budgets vault.",
            "no such pocket": "That pocket doesn't exist any more.",
            "no such order": "That order doesn't exist any more.",
            "no such request": "That request is gone: it was already answered or it expired.",
            "request expired": "That request expired.",
            "withdraw every balance first": "Withdraw everything from the vault first.",
            "payouts still in flight, try again in a moment": "A payment is still on its way. Try again in a minute.",
            "nothing to withdraw": "There is nothing to withdraw.",
        ]
        return known[message] ?? message
    }

    // MARK: Checks on what the owner typed (the contract's own rules, in plain words)

    static func blocked(_ s: String) -> WalletError { .blocked(s) }

    static func validAccount(_ s: String) -> Bool { NearAccount.isValid(s) && s == s.lowercased() }

    /// Parses recipients typed one per line or separated by commas or spaces. Lower-cased, duplicates dropped, order kept.
    public static func parseRecipients(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            let a = part.lowercased()
            if seen.insert(a).inserted { out.append(a) }
        }
        return out
    }

    public static func validate(_ d: PocketDraft, tokens: [TokenInfo], contract: String, nowNs: UInt64) throws {
        let name = d.name
        guard !name.isEmpty, name.utf8.count <= maxNameBytes else { throw blocked("A pocket's name must be 1 to \(maxNameBytes) letters or digits long.") }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }), name == name.trimmingCharacters(in: .whitespaces) else {
            throw blocked("A pocket's name can't start or end with a space or hold line breaks.")
        }
        guard tokens.contains(where: { $0.id == d.token }) else { throw blocked("The Budgets contract doesn't take that token.") }
        guard d.perPayment > 0 else { throw blocked("The limit per payment must be more than 0.") }
        guard d.daily >= d.perPayment else { throw blocked("The daily limit can't be lower than the limit per payment.") }
        guard d.recipients.count <= maxRecipients else { throw blocked("A pocket can have at most \(maxRecipients) allowed recipients.") }
        for r in d.recipients {
            guard validAccount(r) else { throw blocked("\(r) isn't a NEAR account name.") }
            guard r != contract else { throw blocked("A pocket can't pay the Budgets contract itself.") }
        }
        if let e = d.expiresAtNs { guard e > nowNs else { throw blocked("The expiry has to be in the future.") } }
    }

    public static func validate(_ d: OrderDraft, pocket: GuardPocket, contract: String) throws {
        guard d.amount > 0, d.amount <= pocket.perPaymentCap else { throw blocked("An order's amount must be more than 0 and within the pocket's limit per payment.") }
        guard validAccount(d.recipient) else { throw blocked("\(d.recipient) isn't a NEAR account name.") }
        guard d.recipient != contract else { throw blocked("An order can't pay the Budgets contract itself.") }
        guard pocket.allowedRecipients.isEmpty || pocket.allowedRecipients.contains(d.recipient) else {
            throw blocked("The pocket \(pocket.name) doesn't allow payments to \(d.recipient).")
        }
        guard (minIntervalSeconds...maxIntervalSeconds).contains(d.intervalSeconds) else { throw blocked("An order can repeat as often as every hour and as rarely as every 10 years.") }
        if let r = d.remaining { guard r > 0 else { throw blocked("An order has to run at least once.") } }
        guard d.memo.utf8.count <= maxTextBytes else { throw blocked("The note is too long (\(maxTextBytes) bytes at most).") }
    }

    // MARK: Review

    /// What was read for a review.
    public struct Context: Sendable {
        public var contract: String
        /// `GuardConfig.contractID` when the review is written. They must agree.
        public var configured: String?
        public var codeHash: String?
        /// Access keys on the contract's account (0 = nobody can replace its code); nil = not read.
        public var accessKeys: Int?
        /// The account's available NEAR, nil when the account isn't active yet.
        public var available: UInt128?
        public var snapshot: Snapshot
        /// The token a deposit or withdrawal is about.
        public var token: TokenInfo?
        public var walletTokenBalance: UInt128?
        /// The wallet is registered with the token (it has paid the token's storage), nil = not read.
        public var walletRegistered: Bool?
        /// The Budgets contract is registered with the token.
        public var guardRegistered: Bool?
        /// For approve: the recipient can receive the payment (registered with the token, or an account that exists).
        public var recipientReady: Bool?
        /// For remove: what the pocket's key can do on the account; nil = the key isn't there (or couldn't be read).
        public var pocketKeyPermission: KeyPermission?
        public var pocketKeyRead = false
        public var usdPerUnit: Decimal?
        public var nowNs: UInt64
        public init(contract: String, configured: String?, snapshot: Snapshot, available: UInt128?, nowNs: UInt64) {
            self.contract = contract; self.configured = configured; self.snapshot = snapshot; self.available = available; self.nowNs = nowNs
        }
    }

    /// A checked move, ready for the approval sheet. Nothing has been signed.
    public struct Review: Equatable, Sendable {
        public let move: Move
        public let walletID: UUID
        public let account: String
        public let contract: String
        public let kind: String
        public let title: String
        public let success: String
        /// The Face ID prompt.
        public let reason: String
        public let lines: [[String]]
        public let checks: [String]
        public let warnings: [String]
        /// Dollars counted toward the daily limit once it goes through (money leaving the wallet). nil for the rest.
        public let usd: Decimal?
        /// A new pocket key is made when this is approved.
        public let issuesKey: Bool
        /// The key to delete from the account after the pocket is removed (a Hermit-made key only).
        public let deleteKey: String?
        /// The vault's balance of the token before a token deposit, to check the tokens really arrived.
        public let balanceBefore: UInt128?
    }

    /// Checks a move against what the chain says and the spending policy, and writes the review. Throws
    /// `WalletError.blocked` with the reason when it shouldn't go ahead; nothing reaches the approval sheet then.
    public static func review(_ move: Move, walletID: UUID, account: String, context c: Context, policy: SpendPolicy,
                              origin: ActionOrigin = .user) throws -> Review {
        guard let configured = c.configured, configured == c.contract else {
            throw blocked("That isn't the Budgets contract this version of Hermit uses, so nothing was prepared.")
        }
        let snap = c.snapshot
        let now = c.nowNs
        let nearToken = TokenInfo.near
        func near(_ v: UInt128) -> String { nearToken.number(v) }
        func feeLine(_ f: UInt128) -> [String] { ["Network fee", "Up to \(near(f)) NEAR"] }

        // Moves that give the contract money or authority need its code to be the version Hermit checked. Moves that take
        // money back or stop things (withdraw, freeze, remove, cancel, reject) must keep working whatever happens to it.
        var checks: [String] = ["Contract is \(c.contract), the one this version of Hermit uses"]
        var warnings: [String] = []
        func trustContract() throws {
            if let want = GuardConfig.expectedCodeHash(for: c.contract) {
                guard let have = c.codeHash else { throw blocked("Couldn't read the Budgets contract's code, so nothing was prepared. Try again in a moment.") }
                guard have == want else { throw blocked("The Budgets contract's code isn't the version Hermit checked, so nothing was prepared.") }
                checks.append("Contract code is the version Hermit checked")
            } else {
                warnings.append("Hermit hasn't pinned this contract's code, so it can't confirm it's the checked version.")
            }
            if let keys = c.accessKeys {
                if keys == 0 { checks.append("No one can change the contract's code") }
                else { warnings.append("The contract's account still has \(keys) access key\(keys == 1 ? "" : "s"), so whoever holds \(keys == 1 ? "it" : "them") could replace the contract's code.") }
            }
        }
        func add(_ a: UInt128, _ b: UInt128) -> UInt128 { let (r, o) = a.addingReportingOverflow(b); return o ? UInt128.max : r }
        func needAccount(_ extra: UInt128, fee: UInt128) throws -> UInt128 {
            guard let a = c.available else { throw blocked("This NEAR account isn't active yet. It starts once it receives NEAR.") }
            let need = add(extra, fee)
            guard a >= add(need, reserve) else {
                throw blocked(extra == 0
                    ? "You need about \(near(fee + reserve)) NEAR in the account to pay for this. Add a little NEAR first."
                    : "Not enough NEAR. This needs \(near(extra)) NEAR plus about \(near(fee)) NEAR in fees, and Hermit keeps \(near(reserve)) NEAR in the account. \(near(a)) is available.")
            }
            return a
        }
        func needVault() throws -> GuardVault {
            guard let v = snap.vault else { throw blocked("Set up Budgets first: you don't have a vault yet.") }
            return v
        }
        func tokenInfo(_ id: String) throws -> TokenInfo {
            guard let t = snap.token(id) else { throw blocked("Hermit can't read that token's name and decimals, so it won't move it.") }
            return t
        }
        func moneyVerdict(_ amount: UInt128, _ t: TokenInfo) -> (usd: Decimal?, verdict: PolicyVerdict) {
            let usd: Decimal? = c.usdPerUnit.flatMap { p in Decimal(string: Units.format(amount, decimals: t.decimals)).map { $0 * p } }
            return (usd, policy.evaluate(usd: usd.map { NSDecimalNumber(decimal: $0).doubleValue }, payee: nil, origin: origin, now: Date()))
        }
        func make(_ kind: String, _ title: String, _ success: String, _ reason: String, _ lines: [[String]], _ checks: [String], _ warnings: [String],
                  usd: Decimal? = nil, issuesKey: Bool = false, deleteKey: String? = nil, before: UInt128? = nil) -> Review {
            Review(move: move, walletID: walletID, account: account, contract: c.contract, kind: kind, title: title, success: success, reason: reason,
                   lines: lines, checks: checks, warnings: warnings, usd: usd, issuesKey: issuesKey, deleteKey: deleteKey, balanceBefore: before)
        }
        func recipientsText(_ list: [String]) -> String {
            list.isEmpty ? "Anyone" : list.count <= 2 ? list.joined(separator: ", ") : "\(list[0]), \(list[1]) and \(list.count - 2) more"
        }
        func limitsSentence(_ per: UInt128, _ daily: UInt128, _ t: TokenInfo, name: String) -> String {
            "The pocket \(name) can pay up to \(t.text(per)) per payment and \(t.text(daily)) per day without asking you."
        }
        let dayEdge = "A day is a fixed 24 hours from the first payment. Around the edge of two days, up to twice the daily limit can go out."

        switch move {
        case .openVault(let storage, let initial):
            guard snap.vault == nil else { throw blocked("You already have a Budgets vault.") }
            guard storage > 0, storage <= maxStorageDeposit, storage == snap.storageCost else {
                throw blocked("The deposit the contract asks for isn't what Hermit expects, so nothing was prepared.")
            }
            let total = add(storage, initial)
            _ = try needAccount(total, fee: feeCeiling)
            try trustContract()
            let (usd, verdict) = moneyVerdict(total, nearToken)
            if verdict.decision == .block { throw blocked(verdict.blocks.joined(separator: " ")) }
            var lines: [[String]] = [["Contract", c.contract], ["Storage deposit", "\(near(storage)) NEAR, refunded when you close the vault"]]
            if initial > 0 { lines.append(["Put in right away", "\(near(initial)) NEAR"]) }
            lines.append(["Leaves your account", "\(near(total)) NEAR"]); lines.append(feeLine(feeCeiling))
            warnings += verdict.warnings
            warnings.append("Budgets is new software and hasn't been audited. Only keep in it what you're comfortable risking.")
            checks += ["The storage deposit is yours: closing the vault sends it back", "Only you can withdraw. A pocket key never can"] + verdict.passed.filter { !$0.hasPrefix("Pays out") }
            return make("Budgets on NEAR", "Set up Budgets", "Budgets is set up", "Set up Budgets", lines, checks, warnings, usd: usd)

        case .depositNear(let amount):
            let v = try needVault()
            guard amount > 0 else { throw blocked("Not a valid amount.") }
            _ = try needAccount(amount, fee: feeCeiling)
            try trustContract()
            let (usd, verdict) = moneyVerdict(amount, nearToken)
            if verdict.decision == .block { throw blocked(verdict.blocks.joined(separator: " ")) }
            warnings += verdict.warnings
            checks += ["Goes into your own vault, which only you can withdraw from"] + verdict.passed.filter { !$0.hasPrefix("Pays out") }
            return make("Budgets on NEAR", "Add \(near(amount)) NEAR to Budgets", "Added \(near(amount)) NEAR", "Add \(near(amount)) NEAR to Budgets",
                        [["Amount", "\(near(amount)) NEAR"], ["Into", "Your Budgets vault"], ["In the vault now", "\(near(v.balance("near"))) NEAR"], feeLine(feeCeiling)],
                        checks, warnings, usd: usd)

        case .depositToken(let id, let amount):
            let v = try needVault()
            let t = try tokenInfo(id)
            guard !t.isNative, amount > 0 else { throw blocked("Not a valid amount.") }
            guard let have = c.walletTokenBalance else { throw blocked("Couldn't read your \(t.symbol) balance, so nothing was prepared.") }
            guard have >= amount else { throw blocked("You have \(t.text(have)) in this wallet.") }
            guard c.walletRegistered == true else {
                throw blocked("This wallet isn't registered with \(t.symbol) on NEAR, so it can't send it. Receive some \(t.symbol) here first.")
            }
            guard c.guardRegistered == true else {
                throw blocked("The Budgets contract isn't registered with \(t.symbol) yet, so it can't receive it. Nothing was prepared and nothing was sent.")
            }
            _ = try needAccount(0, fee: tokenDepositFeeCeiling)
            try trustContract()
            let (usd, verdict) = moneyVerdict(amount, t)
            if verdict.decision == .block { throw blocked(verdict.blocks.joined(separator: " ")) }
            warnings += verdict.warnings
            checks += ["Your wallet and the Budgets contract are both registered with \(t.symbol)", "Goes into your own vault, which only you can withdraw from",
                       "If the contract can't take it, \(t.symbol) sends it back and Hermit tells you"] + verdict.passed.filter { !$0.hasPrefix("Pays out") }
            return make("Budgets on NEAR", "Add \(t.text(amount)) to Budgets", "Added \(t.text(amount))", "Add \(t.text(amount)) to Budgets",
                        [["Amount", t.text(amount)], ["Into", "Your Budgets vault"], ["In the vault now", t.text(v.balance(id))], feeLine(tokenDepositFeeCeiling)],
                        checks, warnings, usd: usd, before: v.balance(id))

        case .withdraw(let id, let asked):
            let v = try needVault()
            let t = try tokenInfo(id)
            let held = v.balance(id)
            guard held > 0 else { throw blocked("There is no \(t.symbol) in the vault.") }
            if let a = asked { guard a > 0, a <= held else { throw blocked("The vault holds \(t.text(held)).") } }
            if !t.isNative {
                guard c.walletRegistered == true else {
                    throw blocked("This wallet isn't registered with \(t.symbol) on NEAR, so it can't receive it. Nothing was prepared.")
                }
            }
            _ = try needAccount(0, fee: feeCeiling)
            let amount = asked ?? held
            let all = asked == nil || asked == held
            checks += ["Always works, also while the vault is frozen", "Pays only your own account"]
            if v.pendingOut > 0 { warnings.append("A payment is still on its way. It isn't counted in the vault's balance.") }
            return make("Budgets on NEAR", "Withdraw \(all ? "all " : "")\(t.text(amount)) from Budgets", "Withdrew \(t.text(amount))", "Withdraw \(t.text(amount)) from Budgets",
                        [["Amount", all ? "All, \(t.text(amount))" : t.text(amount)], ["To", "Your NEAR account"], ["Left in the vault", t.text(held - amount)], feeLine(feeCeiling)],
                        checks, warnings)

        case .closeVault:
            let v = try needVault()
            guard v.balances.allSatisfy({ $0.amount == 0 }) else { throw blocked("Withdraw everything from the vault first.") }
            guard v.pendingOut == 0 else { throw blocked("A payment is still on its way. Try again in a minute.") }
            guard snap.pockets.isEmpty else { throw blocked("Remove your pockets first. That also deletes their keys from your account.") }
            _ = try needAccount(0, fee: feeCeiling)
            checks += ["The vault is empty", "No pockets are left, so no pocket key is left on your account"]
            return make("Budgets on NEAR", "Close Budgets", "Budgets is closed", "Close Budgets",
                        [["You get back", "\(near(v.storagePaid)) NEAR, the storage deposit"], feeLine(feeCeiling)], checks, warnings)

        case .setFrozen(let freeze):
            let v = try needVault()
            if freeze { guard !v.frozen else { throw blocked("Budgets is already frozen.") } }
            else { guard v.frozen else { throw blocked("Budgets isn't frozen.") } }
            _ = try needAccount(0, fee: feeCeiling)
            if freeze {
                checks += ["Stops every pocket, every standing order and every approval at once", "You can still withdraw while it's frozen"]
                return make("Budgets on NEAR", "Freeze Budgets", "Budgets is frozen", "Freeze Budgets",
                            [["Effect", "No pocket can pay and no order runs"], ["Your money", "Stays in the vault. Withdraw works"], ["To undo", "Unfreeze"], feeLine(feeCeiling)],
                            checks, warnings)
            }
            warnings.append("Pockets can pay again right away, within their limits.")
            return make("Budgets on NEAR", "Unfreeze Budgets", "Budgets is on again", "Unfreeze Budgets",
                        [["Effect", "Pockets and standing orders work again"], ["Limits", "Each pocket keeps its own limits"], feeLine(feeCeiling)], checks, warnings)

        case .createPocket(let d):
            let v = try needVault()
            _ = v
            try validate(d, tokens: snap.tokens, contract: c.contract, nowNs: now)
            guard snap.pockets.count < maxPockets else { throw blocked("You already have \(maxPockets) pockets, the most there can be.") }
            guard !snap.pockets.contains(where: { $0.name == d.name }) else { throw blocked("You already have a pocket called \(d.name).") }
            let t = try tokenInfo(d.token)
            let fee = d.withKey ? 2 * feeCeiling : feeCeiling
            _ = try needAccount(d.withKey ? keyReserve : 0, fee: fee)
            try trustContract()
            var lines: [[String]] = [["Pocket", d.name], ["Token", t.symbol], ["Per payment", "Up to \(t.text(d.perPayment))"], ["Per day", "Up to \(t.text(d.daily))"],
                                     ["Can pay", recipientsText(d.recipients)], ["Expires", d.expiresAtNs.map { dateText(ns: $0) } ?? "Never"]]
            warnings.append(limitsSentence(d.perPayment, d.daily, t, name: d.name))
            if d.recipients.isEmpty { warnings.append("No recipient list: whoever holds the key can pay any address, up to these limits.") }
            warnings.append(dayEdge)
            checks += ["The contract enforces these limits, not the app that holds the key", "A pocket key can't withdraw, freeze or change any rule"]
            if d.withKey {
                lines.append(["Key", "A new key, added to your account"])
                lines.append(["The key can", "Only call spend and request on \(c.contract)"])
                lines.append(["The key's own fees", "From a \(near(keyAllowance)) NEAR budget; it stops when that's used"])
                checks += ["The key is made on this device and shown once; Hermit doesn't keep it", "If the pocket can't be created, Hermit removes the key again"]
            } else {
                lines.append(["Key", "None. Only standing orders can pay from it"])
            }
            lines.append(feeLine(fee))
            return make("Budgets on NEAR", "Create pocket \(d.name)", "Pocket \(d.name) created", "Create pocket \(d.name)", lines, checks, warnings, issuesKey: d.withKey)

        case .updatePocket(let d):
            _ = try needVault()
            guard let old = snap.pocket(d.name) else { throw blocked("There is no pocket called \(d.name).") }
            guard d.token == old.token else { throw blocked("A pocket's token can't be changed. Make a new pocket instead.") }
            guard d.publicKey == old.publicKey else { throw blocked("A pocket's key can't be changed here, so nothing was prepared.") }
            try validate(d, tokens: snap.tokens, contract: c.contract, nowNs: now)
            let t = try tokenInfo(d.token)
            _ = try needAccount(0, fee: feeCeiling)
            try trustContract()
            var lines: [[String]] = [["Pocket", d.name]]
            func change(_ label: String, _ was: String, _ now: String) { lines.append([label, was == now ? now : "\(was) to \(now)"]) }
            change("Per payment", "Up to \(t.text(old.perPaymentCap))", "Up to \(t.text(d.perPayment))")
            change("Per day", "Up to \(t.text(old.dailyCap))", "Up to \(t.text(d.daily))")
            change("Can pay", recipientsText(old.allowedRecipients), recipientsText(d.recipients))
            change("Expires", old.expiresAt.map { dateText(ns: $0) } ?? "Never", d.expiresAtNs.map { dateText(ns: $0) } ?? "Never")
            lines.append(["Key", old.publicKey == nil ? "None" : "Stays as it is"]); lines.append(feeLine(feeCeiling))
            if d.perPayment > old.perPaymentCap || d.daily > old.dailyCap { warnings.append("This raises what the pocket can pay.") }
            if old.allowedRecipients.isEmpty == false && d.recipients.isEmpty { warnings.append("The pocket will be able to pay any address.") }
            warnings.append(limitsSentence(d.perPayment, d.daily, t, name: d.name))
            warnings.append(dayEdge)
            checks += ["The pocket's key, spent amount and pause switch are kept"]
            return make("Budgets on NEAR", "Change pocket \(d.name)", "Pocket \(d.name) changed", "Change pocket \(d.name)", lines, checks, warnings)

        case .removePocket(let name):
            _ = try needVault()
            guard let p = snap.pocket(name) else { throw blocked("There is no pocket called \(name).") }
            let orders = snap.orders.filter { $0.pocket == name }.count
            let requests = snap.requests.filter { $0.pocket == name }.count
            var delete: String?
            var keyLine = "None"
            if let k = p.publicKey {
                if c.pocketKeyRead == false { throw blocked("Couldn't check this pocket's key on your account, so nothing was prepared. Try again in a moment.") }
                if let perm = c.pocketKeyPermission {
                    if isHermitPocketKey(perm, contract: c.contract), publicKeyBytes(k) != nil, k != account.hexKeyText {
                        delete = k; keyLine = "Deleted from your account"
                    } else {
                        keyLine = "Stays on your account: it isn't a key Hermit made, so Hermit won't delete it"
                        warnings.append("This pocket uses a key Hermit didn't make. It stays on your account; remove it yourself if you don't want it.")
                    }
                } else {
                    keyLine = "Already gone from your account"
                }
            }
            let fee = delete == nil ? feeCeiling : 2 * feeCeiling
            _ = try needAccount(0, fee: fee)
            var lines: [[String]] = [["Pocket", name], ["Key", keyLine]]
            if orders > 0 { lines.append(["Standing orders deleted", "\(orders)"]) }
            if requests > 0 { lines.append(["Waiting requests deleted", "\(requests)"]) }
            lines.append(feeLine(fee))
            if orders > 0 { warnings.append("This also deletes the pocket's \(orders) standing order\(orders == 1 ? "" : "s").") }
            checks += ["The pocket stops working first, then its key is deleted"]
            return make("Budgets on NEAR", "Remove pocket \(name)", "Pocket \(name) removed", "Remove pocket \(name)", lines, checks, warnings, deleteKey: delete)

        case .setPaused(let name, let paused):
            _ = try needVault()
            guard let p = snap.pocket(name) else { throw blocked("There is no pocket called \(name).") }
            guard p.paused != paused else { throw blocked(paused ? "\(name) is already paused." : "\(name) isn't paused.") }
            _ = try needAccount(0, fee: feeCeiling)
            if paused {
                checks += ["Its key and its standing orders can't pay until you resume it"]
                return make("Budgets on NEAR", "Pause pocket \(name)", "Pocket \(name) paused", "Pause pocket \(name)",
                            [["Pocket", name], ["Effect", "Nothing can be paid from it"], feeLine(feeCeiling)], checks, warnings)
            }
            if let t = snap.token(p.token) { warnings.append(limitsSentence(p.perPaymentCap, p.dailyCap, t, name: name)) }
            return make("Budgets on NEAR", "Resume pocket \(name)", "Pocket \(name) resumed", "Resume pocket \(name)",
                        [["Pocket", name], ["Effect", "It can pay again, within its limits"], feeLine(feeCeiling)], checks, warnings)

        case .createOrder(let d):
            _ = try needVault()
            guard let p = snap.pocket(d.pocket) else { throw blocked("There is no pocket called \(d.pocket).") }
            try validate(d, pocket: p, contract: c.contract)
            guard snap.orders.count < maxOrders else { throw blocked("You already have \(maxOrders) standing orders, the most there can be.") }
            let t = try tokenInfo(p.token)
            _ = try needAccount(0, fee: feeCeiling)
            try trustContract()
            let first = now &+ d.intervalSeconds &* 1_000_000_000
            var lines: [[String]] = [["From pocket", d.pocket], ["Pays", "\(t.text(d.amount)) to \(d.recipient)"], ["How often", everyText(d.intervalSeconds).capitalizedFirst],
                                     ["First payment", dateText(ns: first)]]
            lines.append(["Runs", d.remaining.map { n -> String in
                let (all, over) = d.amount.multipliedReportingOverflow(by: UInt128(n))
                return "\(n) time\(n == 1 ? "" : "s")" + (over ? "" : ", \(t.text(all)) in all")
            } ?? "Until you cancel it"])
            if !d.memo.isEmpty { lines.append(["Note", d.memo]) }
            lines.append(feeLine(feeCeiling))
            warnings.append("It runs on NEAR even when your phone is off. Anyone can trigger an order once it's due, and the contract pays only that amount to that recipient.")
            warnings.append("It counts against the pocket's limits. If the pocket is paused, expired, over its daily limit or the vault is short, the run waits.")
            if p.state(nowNs: now) != .active { warnings.append("The pocket is \(p.paused ? "paused" : "expired") right now, so nothing is paid until that changes.") }
            checks += ["The recipient and amount are fixed; a missed run pays once, never in a burst"]
            return make("Budgets on NEAR", "Standing order: \(t.text(d.amount)) to \(d.recipient)", "Standing order created", "Create a standing order", lines, checks, warnings)

        case .cancelOrder(let id):
            _ = try needVault()
            guard let o = snap.orders.first(where: { $0.id == id }) else { throw blocked("That standing order doesn't exist any more.") }
            _ = try needAccount(0, fee: feeCeiling)
            let t = snap.token(o.token)
            let what = t.map { $0.text(o.amount) } ?? "\(o.amount)"
            return make("Budgets on NEAR", "Cancel the order to \(o.recipient)", "Order cancelled", "Cancel a standing order",
                        [["Order", "\(what) to \(o.recipient), \(everyText(o.intervalSeconds))"], ["From pocket", o.pocket], feeLine(feeCeiling)],
                        checks, warnings)

        case .approve(let id):
            let v = try needVault()
            guard let r = snap.requests.first(where: { $0.id == id }) else { throw blocked("That request is gone: it was already answered or it expired.") }
            guard now < r.expiresNs else { throw blocked("That request expired.") }
            guard !v.frozen else { throw blocked("Budgets is frozen. Unfreeze it to approve a payment.") }
            let t = try tokenInfo(r.token)
            guard v.balance(r.token) >= r.amount else { throw blocked("The vault holds \(t.text(v.balance(r.token))), not enough for this.") }
            guard r.recipient != c.contract else { throw blocked("This request would pay the Budgets contract itself.") }
            guard let ready = c.recipientReady else { throw blocked("Couldn't check whether \(r.recipient) can receive this. Try again in a moment.") }
            guard ready else {
                throw blocked(t.isNative ? "\(r.recipient) doesn't exist on NEAR, so it can't receive this. Reject the request instead."
                                         : "\(r.recipient) isn't registered with \(t.symbol), so it can't receive this. Reject the request instead.")
            }
            _ = try needAccount(0, fee: feeCeiling)
            var lines: [[String]] = [["Pays", t.text(r.amount)], ["To", r.recipient], ["Asked by", "The key of pocket \(r.pocket)"]]
            if !r.reason.isEmpty { lines.append(["Their reason", "\u{201C}\(r.reason)\u{201D}"]) }
            lines.append(["Asked", dateText(ns: r.createdNs)]); lines.append(feeLine(feeCeiling))
            if let p = snap.pocket(r.pocket) {
                if r.amount > p.perPaymentCap { warnings.append("This is more than the pocket's limit of \(t.text(p.perPaymentCap)) per payment. Approving overrides the limit.") }
                if !p.allowedRecipients.isEmpty && !p.allowedRecipients.contains(r.recipient) { warnings.append("\(r.recipient) isn't on the pocket's list of recipients. Approving overrides that.") }
            }
            if policy.book.entry(for: r.recipient, kind: .near).map({ $0.payments > 0 }) != true {
                warnings.append("First payment to \(r.recipient). Check it character by character.")
            }
            warnings.append("The reason is written by whoever holds the key, not by Hermit.")
            checks += ["The vault holds enough", "Pays out of the vault, not out of your account"]
            return make("Budgets on NEAR", "Approve \(t.text(r.amount)) to \(r.recipient)", "Paid \(t.text(r.amount))", "Approve a payment of \(t.text(r.amount)) to \(r.recipient)", lines, checks, warnings)

        case .reject(let id):
            _ = try needVault()
            guard let r = snap.requests.first(where: { $0.id == id }) else { throw blocked("That request is gone: it was already answered or it expired.") }
            _ = try needAccount(0, fee: feeCeiling)
            let what = snap.token(r.token).map { $0.text(r.amount) } ?? "\(r.amount)"
            return make("Budgets on NEAR", "Reject the request for \(what)", "Request rejected", "Reject a request",
                        [["Request", "\(what) to \(r.recipient)"], ["From pocket", r.pocket], ["Effect", "Nothing is paid"], feeLine(feeCeiling)], checks, warnings)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    /// For an implicit account (64 hex), the "ed25519:" text of its own key; "" for any other account.
    var hexKeyText: String { NearAccount.isImplicit(self) ? ("ed25519:" + Base58.encode([UInt8](hex: self) ?? [])) : "" }
}
