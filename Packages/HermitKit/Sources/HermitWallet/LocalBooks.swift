import Foundation

/// Addresses this device has paid before. Public data only, kept in the app's defaults.
public final class AddressBook: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var address: String
        public var chainKind: ChainKind
        public var label: String?
        public var payments: Int
        public var lastPaid: Date?
    }
    let defaults: UserDefaults
    let key = "hermit.wallet.addressBook"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func normalize(_ address: String, _ kind: ChainKind) -> String { kind == .evm ? address.lowercased() : address }

    public var entries: [Entry] {
        lock.withLock { (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? [] }
    }

    public func entry(for address: String, kind: ChainKind) -> Entry? {
        let n = Self.normalize(address, kind)
        return entries.first { $0.chainKind == kind && Self.normalize($0.address, kind) == n }
    }

    public func recordPayment(to address: String, kind: ChainKind, label: String? = nil, at date: Date = Date()) {
        lock.withLock {
            var all = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
            let n = Self.normalize(address, kind)
            if let i = all.firstIndex(where: { $0.chainKind == kind && Self.normalize($0.address, kind) == n }) {
                all[i].payments += 1; all[i].lastPaid = date
                if let label { all[i].label = label }
            } else {
                all.append(Entry(address: address, chainKind: kind, label: label, payments: 1, lastPaid: date))
            }
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }

    public func setLabel(_ label: String?, for address: String, kind: ChainKind) {
        lock.withLock {
            var all = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
            let n = Self.normalize(address, kind)
            if let i = all.firstIndex(where: { $0.chainKind == kind && Self.normalize($0.address, kind) == n }) { all[i].label = label }
            else { all.append(Entry(address: address, chainKind: kind, label: label, payments: 0, lastPaid: nil)) }
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }
}

/// A rolling 24-hour limit on stablecoin sends, in dollars. Stablecoins count 1:1; native coins have no price
/// feed yet, so the check says so instead of pretending.
public final class SpendLimit: @unchecked Sendable {
    struct Spend: Codable { var date: Date; var usd: Decimal }
    let defaults: UserDefaults
    let limitKey = "hermit.wallet.dailyLimitUSD", ledgerKey = "hermit.wallet.spendLedger"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Default $500 a day.
    public var dailyLimitUSD: Decimal {
        get { (defaults.string(forKey: limitKey)).flatMap { Decimal(string: $0) } ?? 500 }
        set { defaults.set("\(newValue)", forKey: limitKey) }
    }

    private var ledger: [Spend] {
        (defaults.data(forKey: ledgerKey).flatMap { try? JSONDecoder().decode([Spend].self, from: $0) }) ?? []
    }

    public func spentLast24h(now: Date = Date()) -> Decimal {
        lock.withLock { ledger.filter { now.timeIntervalSince($0.date) < 86_400 }.reduce(0) { $0 + $1.usd } }
    }

    public func remaining(now: Date = Date()) -> Decimal { max(0, dailyLimitUSD - spentLast24h(now: now)) }

    public func record(usd: Decimal, at date: Date = Date()) {
        lock.withLock {
            var l = ledger.filter { date.timeIntervalSince($0.date) < 86_400 * 2 }
            l.append(Spend(date: date, usd: usd))
            defaults.set(try? JSONEncoder().encode(l), forKey: ledgerKey)
        }
    }
}
