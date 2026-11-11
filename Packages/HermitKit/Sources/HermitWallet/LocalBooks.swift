import Foundation

/// Addresses this device has paid before. Public data only, kept in the app's defaults.
public final class AddressBook: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var address: String
        public var chainKind: ChainKind
        public var label: String?
        public var payments: Int
        public var lastPaid: Date?
        /// When it was first saved with a label (starts the 24-hour hold on new whitelist entries).
        public var added: Date?
    }
    let defaults: UserDefaults
    let key = "hermit.wallet.addressBook"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func normalize(_ address: String, _ kind: ChainKind) -> String { kind == .solana ? address : address.lowercased() }

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
                all.append(Entry(address: address, chainKind: kind, label: label, payments: 1, lastPaid: date, added: date))
            }
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }

    public func setLabel(_ label: String?, for address: String, kind: ChainKind) {
        lock.withLock {
            var all = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
            let n = Self.normalize(address, kind)
            if let i = all.firstIndex(where: { $0.chainKind == kind && Self.normalize($0.address, kind) == n }) { all[i].label = label }
            else { all.append(Entry(address: address, chainKind: kind, label: label, payments: 0, lastPaid: nil, added: Date())) }
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }

    public func remove(_ address: String, kind: ChainKind) {
        lock.withLock {
            var all = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
            let n = Self.normalize(address, kind)
            all.removeAll { $0.chainKind == kind && Self.normalize($0.address, kind) == n }
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

    /// Takes back the newest entry of this amount: a transfer that was counted while it could still land, and then
    /// expired or failed without moving anything. Nothing happens when there is no such entry.
    public func refund(usd: Decimal) {
        lock.withLock {
            var l = ledger
            let tiny = Decimal(string: "0.000001") ?? 0
            guard let i = l.lastIndex(where: { $0.usd - usd < tiny && usd - $0.usd < tiny }) else { return }
            l.remove(at: i)
            defaults.set(try? JSONEncoder().encode(l), forKey: ledgerKey)
        }
    }
}

/// Sends made from this device, newest first. Public data only (hashes, amounts, addresses), kept in the app's defaults.
/// Chains have no cheap "history" call, so this is what the Activity list shows, with explorer links for the rest.
public final class SendLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String { hash }
        public let hash: String
        public let chainID: String
        public let walletID: UUID
        public let amount: String
        public let symbol: String
        public let recipient: String
        public let label: String?
        public let date: Date
        public var chain: Chain? { Chain.with(id: chainID) }
    }
    let defaults: UserDefaults
    let key = "hermit.wallet.sendLog"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var entries: [Entry] {
        lock.withLock { (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? [] }
    }

    public func record(_ e: Entry) {
        lock.withLock {
            var all = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
            all.removeAll { $0.hash == e.hash }
            all.insert(e, at: 0)
            defaults.set(try? JSONEncoder().encode(Array(all.prefix(500))), forKey: key)
        }
    }

    /// Takes one send out of the list: a transfer that was listed while it could still land and never did.
    public func remove(hash: String) {
        lock.withLock {
            let all = ((defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []).filter { $0.hash != hash }
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }

    public func remove(wallet: UUID) {
        lock.withLock {
            let all = ((defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []).filter { $0.walletID != wallet }
            defaults.set(try? JSONEncoder().encode(all), forKey: key)
        }
    }
}
