import Foundation

/// Who asked for a money move. The assistant (on-device model or a tool call) only ever prepares; the user approves.
public enum ActionOrigin: String, Sendable, Codable { case user, agent }

/// allow / warn / block, with reasons in plain words. Checked before the approval sheet opens; a block never reaches it.
public struct PolicyVerdict: Sendable, Equatable {
    public enum Decision: String, Sendable, Codable { case allow, warn, block }
    public var decision: Decision
    /// What passed, as approval-sheet check lines.
    public var passed: [String]
    /// Warnings the approval sheet shows above Approve.
    public var warnings: [String]
    /// Why it was blocked (empty unless `decision == .block`).
    public var blocks: [String]
    public var summary: String { blocks.first ?? warnings.first ?? passed.first ?? "" }
}

/// The spending policy for every move that leaves the wallet (sends, swaps, NEAR Intents deposits):
/// - a rolling 24-hour dollar limit (`SpendLimit`), now priced for any token 1Click quotes, not only stablecoins;
/// - a warning the first time money goes to an address this device has never paid;
/// - stricter rules when the assistant prepared it: a per-move cap, no unpriced tokens, and swap output only to the
///   user's own addresses (a prompt-injected "send it to 0xabc" is refused before any sheet opens).
public final class SpendPolicy: @unchecked Sendable {
    public let limit: SpendLimit
    public let book: AddressBook
    let defaults: UserDefaults
    let agentCapKey = "hermit.policy.agentCapUSD"

    public init(limit: SpendLimit, book: AddressBook, defaults: UserDefaults = .standard) {
        self.limit = limit; self.book = book; self.defaults = defaults
    }

    /// The most the assistant may prepare in one move. Default $100.
    public var agentCapUSD: Decimal {
        get { defaults.string(forKey: agentCapKey).flatMap { Decimal(string: $0) } ?? 100 }
        set { defaults.set("\(newValue)", forKey: agentCapKey) }
    }

    /// - Parameters:
    ///   - usd: the dollar value leaving the wallet, nil when there's no price.
    ///   - payee: who ends up with the money and on which kind of chain. nil when it's the user's own address.
    public func evaluate(usd: Double?, payee: (address: String, kind: ChainKind)?, origin: ActionOrigin,
                         now: Date = Date()) -> PolicyVerdict {
        var v = PolicyVerdict(decision: .allow, passed: [], warnings: [], blocks: [])
        let left = limit.remaining(now: now)
        let cap = limit.dailyLimitUSD
        if let usd {
            let d = Decimal(usd)
            if d > left { v.blocks.append("Over your daily limit: \(Self.money(left)) of \(Self.money(cap)) left today.") }
            else { v.passed.append("Within daily limit (\(Self.money(left - d)) left today)") }
        } else {
            v.warnings.append("No price for this token, so it isn't counted toward your \(Self.money(cap)) daily limit.")
        }
        if origin == .agent {
            if let usd {
                if Decimal(usd) > agentCapUSD {
                    v.blocks.append("The assistant can prepare up to \(Self.money(agentCapUSD)) per move. Open Swap yourself for more.")
                } else { v.passed.append("Under the assistant's \(Self.money(agentCapUSD)) per-move cap") }
            } else {
                v.blocks.append("The assistant can't move tokens without a price. Open Swap yourself.")
            }
            if payee != nil { v.blocks.append("The assistant can only send swap output to your own addresses.") }
        }
        if let p = payee {
            if let e = book.entry(for: p.address, kind: p.kind), e.payments > 0 {
                v.passed.append("Paid this address \(e.payments) time\(e.payments == 1 ? "" : "s") before")
            } else {
                v.warnings.append("First payment to \(Self.short(p.address)). Check it character by character.")
            }
        } else {
            v.passed.append("Pays out to your own address")
        }
        v.decision = !v.blocks.isEmpty ? .block : !v.warnings.isEmpty ? .warn : .allow
        return v
    }

    static func money(_ d: Decimal) -> String {
        let n = NSDecimalNumber(decimal: d).doubleValue
        return "$" + n.formatted(.number.precision(.fractionLength(n == n.rounded() ? 0 : 2)).locale(Locale(identifier: "en_US")))
    }
    static func short(_ a: String) -> String { a.count > 14 ? "\(a.prefix(6))…\(a.suffix(4))" : a }
}
