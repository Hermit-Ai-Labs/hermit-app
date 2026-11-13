import Foundation
import HermitCore

/// Hermit AI insurance, our contract on NEAR mainnet: `hermit-insurance.near` (contracts/insurance).
///
/// Opt-in cover: 1 USDC (on NEAR) buys 30 days, and all of it goes into a public pool. If the AI's mistake cost you money,
/// you file a claim with the Black Box record of that move; the contract checks the evidence hashes to the fingerprint.
/// An AI reviewer writes its verdict on chain, the owner decides, and only an approved claim can take money out.
public enum AIInsurance {
    public static let contract = "hermit-insurance.near"
    public static let explorer = URL(string: "https://nearblocks.io/address/hermit-insurance.near")!
    public static let usdc = "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1"
    public static let unit: Decimal = 1_000_000                       // USDC has 6 decimals
    public static let claimDeposit: UInt128 = 50_000_000_000_000_000_000_000   // 0.05 NEAR, the contract's CLAIM_DEPOSIT
    static let tgas: UInt64 = 1_000_000_000_000

    public struct Info: Sendable, Equatable {
        public let owner: String, reviewer: String
        public let price: Decimal, pool: Decimal, paidIn: Decimal, paidOut: Decimal, owed: Decimal
        public let members: Int, claims: Int
    }

    public struct Claim: Sendable, Equatable, Identifiable {
        public let id: Int
        public let by: String, fp: String, evidence: String, note: String, status: String
        public let loss: Decimal, award: Decimal, paid: Decimal
        public let aiVerdict: String?, aiReason: String?, reason: String?
        public let filed: Date
    }

    static func usd(_ j: JSON?) -> Decimal { (j?.string).flatMap { Decimal(string: $0) }.map { $0 / unit } ?? 0 }
    static func date(_ j: JSON?) -> Date { Date(timeIntervalSince1970: ((j?.string).flatMap { Double($0) } ?? 0) / 1e9) }

    public static func info(client: NearClient = NearClient()) async throws -> Info {
        let r = try await client.view(contract, "info")
        return Info(owner: r["owner"]?.string ?? "", reviewer: r["reviewer"]?.string ?? "", price: usd(r["price"]), pool: usd(r["pool"]),
                    paidIn: usd(r["paid_in"]), paidOut: usd(r["paid_out"]), owed: usd(r["owed"]),
                    members: r["members"]?.int ?? 0, claims: r["claims"]?.int ?? 0)
    }

    /// Posted the moment cover is bought on this device, so every screen shows it at once.
    public static let changed = Notification.Name("hermit.insurance.changed")
    static func localKey(_ account: String) -> String { "hermit.insurance.until.\(account)" }

    /// The cover end this device knows about right now: set the instant a purchase succeeds, before NEAR's final view
    /// catches up. nil when there's none running.
    public static func knownUntil(_ account: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: localKey(account))
        return t > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: t) : nil
    }

    static func noteBought(account: String, months: Int) {
        let start = max(knownUntil(account) ?? Date(), Date())
        let end = start.addingTimeInterval(Double(months) * 30 * 86_400)
        UserDefaults.standard.set(end.timeIntervalSince1970, forKey: localKey(account))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// When the account's cover ends, or nil when it has none running. Never earlier than what this device just bought.
    public static func coveredUntil(_ account: String, client: NearClient = NearClient()) async throws -> Date? {
        let r = try await client.view(contract, "cover_of", args: Array(#"{"account_id":"\#(account)"}"#.utf8))
        let chain = r["active"]?.bool == true ? date(r["expires_ns"]) : nil
        if let chain { UserDefaults.standard.set(max(chain, knownUntil(account) ?? chain).timeIntervalSince1970, forKey: localKey(account)) }
        switch (chain, knownUntil(account)) {
        case let (c?, k?): return max(c, k)
        case let (c, k): return c ?? k
        }
    }

    public static func claims(client: NearClient = NearClient()) async throws -> [Claim] {
        let r = try await client.view(contract, "claims", args: Array(#"{"limit":50}"#.utf8))
        return (r.array ?? []).map { c in
            Claim(id: c["id"]?.int ?? 0, by: c["by"]?.string ?? "", fp: c["fp"]?.string ?? "", evidence: c["evidence"]?.string ?? "",
                  note: c["note"]?.string ?? "", status: c["status"]?.string ?? "", loss: usd(c["loss"]), award: usd(c["award"]),
                  paid: usd(c["paid"]), aiVerdict: c["ai_verdict"]?.string, aiReason: c["ai_reason"]?.string,
                  reason: c["reason"]?.string, filed: date(c["filed_ns"]))
        }
    }

    static func json(_ o: [String: Any]) -> [UInt8] {
        Array((try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    static func units(_ usd: Decimal) -> String {
        var v = usd * unit, r = Decimal()
        NSDecimalRound(&r, &v, 0, .down)
        return "\(r)"
    }
}

extension WalletService {
    /// Buys `months` x 30 days of cover: one ft_transfer_call of USDC on NEAR to the insurance contract.
    public func buyInsurance(walletID: UUID, months: Int = 1) async throws -> String {
        let amount = AIInsurance.units(Decimal(months))
        let args = AIInsurance.json(["receiver_id": AIInsurance.contract, "amount": amount, "msg": "cover"])
        let hash = try await executeNear(walletID: walletID, receiver: AIInsurance.usdc,
                                         actions: [.functionCall(method: "ft_transfer_call", args: args, gas: 100 * AIInsurance.tgas, deposit: 1)],
                                         reason: "Buy 30 days of AI insurance for \(months) USDC")
        if let a = wallets.first(where: { $0.id == walletID })?.nearAccount { AIInsurance.noteBought(account: a, months: months) }
        return hash
    }

    /// Files a claim for one Black Box record. The contract checks sha256(evidence) == fp. 0.05 NEAR goes with it.
    public func fileInsuranceClaim(walletID: UUID, record: BlackBox.Entry, lossUSD: Decimal, note: String) async throws -> String {
        let args = AIInsurance.json(["fp": record.fp, "evidence": record.preimage, "loss": AIInsurance.units(lossUSD), "note": String(note.prefix(600))])
        return try await executeNear(walletID: walletID, receiver: AIInsurance.contract,
                                     actions: [.functionCall(method: "file_claim", args: args, gas: 50 * AIInsurance.tgas, deposit: AIInsurance.claimDeposit)],
                                     reason: "File an AI insurance claim")
    }

    /// Owner only: approve (paying `awardUSD` from the pool) or reject, with a reason that goes on chain.
    public func decideInsuranceClaim(walletID: UUID, id: Int, approve: Bool, awardUSD: Decimal, reason: String) async throws -> String {
        let args = AIInsurance.json(["id": id, "approve": approve, "award": AIInsurance.units(approve ? awardUSD : 0), "reason": String(reason.prefix(600))])
        return try await executeNear(walletID: walletID, receiver: AIInsurance.contract,
                                     actions: [.functionCall(method: "decide", args: args, gas: 150 * AIInsurance.tgas, deposit: 1)],
                                     reason: approve ? "Approve claim \(id)" : "Reject claim \(id)")
    }
}
