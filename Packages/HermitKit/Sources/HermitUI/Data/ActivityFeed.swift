import SwiftUI
import Observation
import HermitCore
import HermitWallet

/// One thing that happened to a wallet. Read from the chain (Solana and NEAR history; EVM transfers when an explorer
/// key is set), or recorded by Hermit when it did the moving (sends, NEAR Intents swaps, Relay moves, Hyperliquid
/// deposits, and deposits it watched arrive).
struct ActivityItem: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Codable, Sendable { case received, sent, swap, deposit, contract }
    let id: String
    let kind: Kind
    let chainID: String
    let walletID: String
    /// "Received 1.00 SOL", "Sent 0.5 USDC to 0x12…ab", "Swap 1 USDC on Solana to USDC on Base".
    let what: String
    /// Second line: who from, the route, or nothing.
    let detail: String
    /// Signed, in `symbol`. nil when there's no single amount (a swap, a contract call).
    let amount: Double?
    let symbol: String
    let date: Date
    let tx: String?
    /// "Confirmed", "Failed", or an in-flight line like "Waiting for your deposit".
    let status: String
    let link: URL?

    var chain: Chain? { Chain.with(id: chainID) }
    var amountText: String {
        guard let a = amount, a != 0 else { return "" }
        return (a > 0 ? "+" : "−") + MoneyFmt.amount(abs(a)) + " " + symbol
    }
    var when: String { date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
    var icon: String {
        switch kind {
        case .received: "arrow.down.left"
        case .sent: "arrow.up.right"
        case .swap: "arrow.left.arrow.right"
        case .deposit: "tray.and.arrow.down"
        case .contract: "doc.text"
        }
    }
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.status == b.status }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// What Hermit itself moved or saw arrive on this device. Kept here so it shows on networks with no free history API.
@MainActor
final class ActivityLedger {
    static let shared = ActivityLedger()
    /// Its own file (Application Support/Hermit), not UserDefaults: the preferences plist loads whole at launch.
    private let file = "activity.json"
    /// Where it used to live, read once to move it over.
    private let oldKey = "hermit.activity.events"
    private(set) var items: [ActivityItem] = []

    private init() {
        if let l = LocalJSON.load(file, as: [ActivityItem].self) {
            items = l
        } else if let d = UserDefaults.standard.data(forKey: oldKey), let l = try? JSONDecoder().decode([ActivityItem].self, from: d) {
            items = l
            if LocalJSON.save(l, file) { UserDefaults.standard.removeObject(forKey: oldKey) }
        }
    }

    func record(_ item: ActivityItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        items = Array(items.prefix(300))
        LocalJSON.save(items, file)
        ActivityFeed.shared.rebuild()
    }

    static func received(_ a: DepositArrival, walletID: String, address: String) -> ActivityItem {
        ActivityItem(id: "seen-\(a.chain.id)-\(a.symbol)-\(Int(Date().timeIntervalSince1970))", kind: .received, chainID: a.chain.id,
                     walletID: walletID, what: "Received \(MoneyFmt.amount(a.amount)) \(a.symbol)", detail: "Seen arriving in Add funds",
                     amount: a.amount, symbol: a.symbol, date: Date(), tx: nil, status: "Confirmed", link: a.chain.explorerURL(address: address))
    }

    static func moved(amount: String, symbol: String, from chain: Chain, to dest: String, route: String, walletID: String) -> ActivityItem {
        ActivityItem(id: "move-\(Int(Date().timeIntervalSince1970))-\(chain.id)-\(symbol)", kind: .deposit, chainID: chain.id, walletID: walletID,
                     what: "Moved \(amount) \(symbol) to \(dest)", detail: route, amount: -(Double(amount) ?? 0), symbol: symbol,
                     date: Date(), tx: nil, status: "Confirmed", link: nil)
    }
}

/// The Activity tab's list: chain history for every wallet, merged with Hermit's own records, newest first.
@MainActor @Observable
final class ActivityFeed {
    static let shared = ActivityFeed()
    private(set) var items: [ActivityItem] = []
    private(set) var loading = false
    private(set) var loadedOnce = false
    /// Networks whose history couldn't be read this time.
    private(set) var failed: [String] = []
    /// When the history on screen was saved, while it's last launch's copy and the first read hasn't finished.
    private(set) var savedAt: Date?
    @ObservationIgnored private var chainItems: [ActivityItem] = []
    @ObservationIgnored private var last = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?

    /// A free Etherscan key (etherscan.io/myapikey) turns on EVM history from the chain: `HERMIT_ETHERSCAN_KEY` or
    /// the `hermitEtherscanKey` default.
    static var etherscanKey: String? {
        let k = ProcessInfo.processInfo.environment["HERMIT_ETHERSCAN_KEY"] ?? UserDefaults.standard.string(forKey: "hermitEtherscanKey")
        return (k?.isEmpty ?? true) ? nil : k
    }
    var hasExplorerKey: Bool { Self.etherscanKey != nil }

    /// Reads at most once a minute unless forced; always re-merges Hermit's own records.
    func refresh(force: Bool = false) async {
        if let t = task { await t.value; if !force { return } }
        guard force || Date().timeIntervalSince(last) > 60 else { rebuild(); return }
        let t = Task { await load() }
        task = t
        await t.value
        task = nil
    }

    /// One history read: the network's name on screen, the wallet, the chain id its items carry, and the read.
    private typealias Job = (name: String, wallet: String, chain: String, read: @Sendable () async throws -> [ActivityItem])

    private func load() async {
        let wallets = WalletsViewModel.shared.service.wallets
        guard !wallets.isEmpty else { chainItems = []; loadedOnce = true; rebuild(); return }
        // Last launch's history shows at once while the chains are read again.
        if !loadedOnce, chainItems.isEmpty { restoreSaved(wallets.map { $0.id.uuidString }) }
        loading = true
        defer { loading = false }
        let key = Self.etherscanKey
        let jobs: [Job] = wallets.flatMap { w -> [Job] in
            let wid = w.id.uuidString, sol = w.solanaAddress, near = w.nearAccount ?? "", evm = w.evmAddress
            var list: [Job] = []
            if !sol.isEmpty { list.append(("Solana", wid, Chain.solana.id, { try await ChainHistory.solana(address: sol, walletID: wid) })) }
            if !near.isEmpty { list.append(("NEAR", wid, Chain.near.id, { try await ChainHistory.near(account: near, walletID: wid) })) }
            if let key {
                for c in Chain.evmMainnets where c.id != "robinhood" {
                    list.append((c.name, wid, c.id, { try await ChainHistory.etherscan(chain: c, address: evm, walletID: wid, key: key) }))
                }
            } else if let eth = Chain.with(id: "ethereum") {
                list.append(("Ethereum", wid, eth.id, { try await ChainHistory.blockscout(chain: eth, host: "eth.blockscout.com", address: evm, walletID: wid) }))
            }
            list.append(("Hyperliquid", wid, "hyperliquid", { try await ChainHistory.hyperliquid(address: evm, walletID: wid) }))
            return list
        }
        var out: [ActivityItem] = [], bad: [String] = []
        let before = chainItems
        await withTaskGroup(of: (String?, [ActivityItem], String, String).self) { g in
            for job in jobs {
                let name = job.name, wid = job.wallet, chain = job.chain, read = job.read
                g.addTask {
                    do { return (nil, try await read(), wid, chain) }
                    catch let p as PartialHistory { return (name, p.items, wid, chain) }   // shown, and the notice says some is missing
                    catch { return (name, [], wid, chain) }
                }
            }
            for await (err, list, wid, chain) in g {
                out += list
                guard let err else { continue }
                bad.append(err)
                // A network that didn't answer keeps what was last read from it (the notice says it couldn't be read).
                if list.isEmpty { out += before.filter { $0.walletID == wid && $0.chainID == chain } }
            }
        }
        chainItems = out
        failed = Array(Set(bad)).sorted()
        last = Date()
        loadedOnce = true
        savedAt = nil
        rebuild()
        let store = SnapshotStore.live
        for w in wallets.map({ $0.id.uuidString }) { store.save(out.filter { $0.walletID == w }, "activity", wallet: w) }
    }

    /// The chain history saved last time, per wallet. Hermit's own records are already on this device.
    private func restoreSaved(_ walletIDs: [String]) {
        let store = SnapshotStore.live
        var items: [ActivityItem] = [], oldest: Date?
        for w in walletIDs {
            guard let s = store.load("activity", wallet: w, as: [ActivityItem].self, maxAge: 30 * 86_400) else { continue }
            items += s.value
            oldest = min(oldest ?? s.saved, s.saved)
        }
        guard let oldest else { return }
        chainItems = items
        savedAt = oldest
        rebuild()
    }

    /// Chain items first; Hermit's records fill in what the chain can't show or says less about.
    func rebuild() {
        let svc = WalletsViewModel.shared.service
        let ids = Set(svc.wallets.map { $0.id.uuidString })
        var byID: [String: ActivityItem] = [:]
        for i in chainItems { byID[i.id] = i }
        for e in svc.sendLog.entries {
            guard let c = e.chain else { continue }
            byID[e.hash] = ActivityItem(id: e.hash, kind: .sent, chainID: c.id, walletID: e.walletID.uuidString,
                                        what: "Sent \(e.amount) \(e.symbol) to \(e.label ?? shortAddr(e.recipient))", detail: "From Hermit",
                                        amount: -(Double(e.amount) ?? 0), symbol: e.symbol, date: e.date, tx: e.hash, status: "Confirmed",
                                        link: c.explorerURL(tx: e.hash))
        }
        let act = IntentsActivity.shared
        for s in WalletService.intentsLedger.all {
            let st = act.state(s.depositAddress)?.status ?? s.status
            byID["intents-" + s.depositAddress] = ActivityItem(id: "intents-" + s.depositAddress, kind: .swap, chainID: s.fromChainID ?? "near",
                                                               walletID: s.walletID?.uuidString ?? "", what: (s.external ? "Add funds: " : "Swap ") + "\(s.from) to \(s.to)",
                                                               detail: "NEAR Intents, to \(s.toPlaceName)", amount: nil, symbol: s.toSymbol ?? "",
                                                               date: s.created, tx: s.txHash, status: st == .success ? "Confirmed" : st.headline, link: s.explorer)
        }
        for i in ActivityLedger.shared.items {
            if chainItems.contains(where: { $0.id == i.id }) { continue }   // the chain's own record of the same transaction says more
            // The same transfer seen from the chain: keep one. Hermit's "Moved … to Hyperliquid" says more than a raw send.
            let twins = chainItems.filter { c in
                c.chainID == i.chainID && c.symbol == i.symbol && abs(abs(c.amount ?? 0) - abs(i.amount ?? 0)) < 1e-6
                    && abs(c.date.timeIntervalSince(i.date)) < 900
            }
            if twins.isEmpty { byID[i.id] = i }
            else if i.kind == .deposit || i.kind == .swap { for t in twins { byID[t.id] = nil }; byID[i.id] = i }
        }
        items = byID.values.filter { $0.walletID.isEmpty || ids.contains($0.walletID) }.sorted { $0.date > $1.date }
    }
}

/// Some of a network's history was read: these items show, and the page says the rest couldn't be.
struct PartialHistory: Error { let items: [ActivityItem] }

/// History straight from the chains.
enum ChainHistory {
    // MARK: Solana

    /// The last 15 transactions touching the address, read in full and reduced to what changed for it.
    /// Finalized ones never change, so each is read once and then comes from disk. The public node allows about 10
    /// getTransaction calls per 10 seconds, so the rest are read two at a time. One that can't be read still shows (its
    /// signature and explorer link), and the whole list comes back as a PartialHistory so the page says so.
    static func solana(address: String, walletID: String) async throws -> [ActivityItem] {
        let chain = Chain.solana
        let rpc = JSONRPCClient(url: chain.rpc)
        let sigs = try await rpc.call("getSignaturesForAddress", [.string(address), .object(["limit": .number(15)])]).array ?? []
        let cacheName = "sol-history-\(walletID)-\(address)"
        let cached = MarketDiskCache.load(cacheName, maxAge: 30 * 86_400, as: [String: ActivityItem].self) ?? [:]
        var keep: [String: ActivityItem] = [:]
        var out: [ActivityItem] = [], missed = false
        var todo: [(sig: String, when: Date, failed: Bool, final: Bool)] = []
        for s in sigs {
            guard let sig = s["signature"]?.string else { continue }
            if let hit = cached[sig] { out.append(hit); keep[sig] = hit; continue }
            todo.append((sig: sig, when: s["blockTime"]?.double.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                         failed: !(s["err"]?.isNull ?? true), final: s["confirmationStatus"]?.string == "finalized"))
        }
        for start in stride(from: 0, to: todo.count, by: 2) {
            if start > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            let got: [(Int, JSON?)] = await withTaskGroup(of: (Int, JSON?).self) { g in
                for k in start..<min(start + 2, todo.count) {
                    let sig = todo[k].sig
                    g.addTask {
                        // Version 1 too: dapps (Jupiter, Kamino) sign v1 transactions, and asking for 0 drops them.
                        let tx = try? await rpc.call("getTransaction", [.string(sig), .object([
                            "encoding": .string("jsonParsed"), "maxSupportedTransactionVersion": .number(1), "commitment": .string("confirmed")])])
                        return (k, tx)
                    }
                }
                var r: [(Int, JSON?)] = []
                for await x in g { r.append(x) }
                return r
            }
            for (k, tx) in got {
                let t = todo[k]
                if let tx, !tx.isNull {
                    guard let item = solanaItem(tx, sig: t.sig, when: t.when, failed: t.failed, me: address, chain: chain, walletID: walletID) else { continue }
                    out.append(item)
                    if t.final { keep[t.sig] = item }
                } else {
                    missed = true
                    out.append(ActivityItem(id: t.sig, kind: .contract, chainID: chain.id, walletID: walletID, what: "Transaction",
                                            detail: "Details couldn't be read", amount: nil, symbol: "", date: t.when, tx: t.sig,
                                            status: t.failed ? "Failed" : "Confirmed", link: chain.explorerURL(tx: t.sig)))
                }
            }
        }
        // Only the signatures still in the last 15, so the file stays small.
        if keep != cached { MarketDiskCache.save(cacheName, keep) }
        if missed { throw PartialHistory(items: out) }
        return out
    }

    private static func solanaItem(_ tx: JSON, sig: String, when: Date, failed: Bool, me: String, chain: Chain, walletID: String) -> ActivityItem? {
        guard let meta = tx["meta"], let keys = tx["transaction"]?["message"]?["accountKeys"]?.array else { return nil }
        let pubkeys = keys.map { $0["pubkey"]?.string ?? $0.string ?? "" }
        guard let i = pubkeys.firstIndex(of: me) else { return nil }
        let pre = meta["preBalances"]?.array ?? [], post = meta["postBalances"]?.array ?? []
        func bal(_ l: [JSON], _ j: Int) -> Double { l.indices.contains(j) ? (l[j].double ?? 0) : 0 }
        var sol = (bal(post, i) - bal(pre, i)) / 1e9
        if i == 0 { sol += (meta["fee"]?.double ?? 0) / 1e9 }   // the payer: show the transfer, not the fee
        var tokens: [String: Double] = [:]
        for (list, sign) in [(meta["preTokenBalances"]?.array ?? [], -1.0), (meta["postTokenBalances"]?.array ?? [], 1.0)] {
            for b in list where b["owner"]?.string == me {
                guard let mint = b["mint"]?.string else { continue }
                let ui = b["uiTokenAmount"]?["uiAmount"]?.double ?? Double(b["uiTokenAmount"]?["uiAmountString"]?.string ?? "") ?? 0
                tokens[mint, default: 0] += sign * ui
            }
        }
        let moves = tokens.filter { abs($0.value) > 1e-9 }
        func sym(_ mint: String) -> String { chain.tokens.first { $0.address == mint }?.symbol ?? String(mint.prefix(4)) + "…" }
        let status = failed ? "Failed" : "Confirmed", link = chain.explorerURL(tx: sig)
        let other = pubkeys.enumerated().first { j, k in
            j != i && k != me && bal(post, j) != bal(pre, j) && !k.hasPrefix("1111") && !k.hasPrefix("Token") && !k.hasPrefix("Compute")
        }?.element
        if moves.isEmpty, abs(sol) > 1e-9 {
            let recv = sol > 0
            return ActivityItem(id: sig, kind: recv ? .received : .sent, chainID: chain.id, walletID: walletID,
                                what: (recv ? "Received " : "Sent ") + MoneyFmt.amount(abs(sol)) + " SOL" + (recv ? "" : other.map { " to " + shortAddr($0) } ?? ""),
                                detail: recv ? (other.map { "From " + shortAddr($0) } ?? "") : "", amount: sol, symbol: "SOL", date: when, tx: sig, status: status, link: link)
        }
        if moves.count == 1, let m = moves.first {
            let recv = m.value > 0, s = sym(m.key)
            return ActivityItem(id: sig, kind: recv ? .received : .sent, chainID: chain.id, walletID: walletID,
                                what: (recv ? "Received " : "Sent ") + MoneyFmt.amount(abs(m.value)) + " " + s, detail: "",
                                amount: m.value, symbol: s, date: when, tx: sig, status: status, link: link)
        }
        if !moves.isEmpty || abs(sol) > 1e-9 {
            var all = moves.map { (sym($0.key), $0.value) }
            if abs(sol) > 1e-9 { all.append(("SOL", sol)) }
            let gave = all.filter { $0.1 < 0 }, got = all.filter { $0.1 > 0 }
            let what = "Swapped " + gave.map { MoneyFmt.amount(abs($0.1)) + " " + $0.0 }.joined(separator: ", ")
                + " for " + got.map { MoneyFmt.amount($0.1) + " " + $0.0 }.joined(separator: ", ")
            return ActivityItem(id: sig, kind: .swap, chainID: chain.id, walletID: walletID, what: what, detail: "",
                                amount: got.first?.1, symbol: got.first?.0 ?? "", date: when, tx: sig, status: status, link: link)
        }
        return ActivityItem(id: sig, kind: .contract, chainID: chain.id, walletID: walletID, what: "Program call", detail: "No balance change",
                            amount: nil, symbol: "", date: when, tx: sig, status: status, link: link)
    }

    // MARK: NEAR

    /// The last 15 transactions on the account, from nearblocks.io (no key needed).
    static func near(account: String, walletID: String) async throws -> [ActivityItem] {
        let chain = Chain.near
        let d = try await MarketHTTP.data("https://api.nearblocks.io/v1/account/\(account)/txns?per_page=15&page=1")
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let txns = j["txns"] as? [[String: Any]] else { throw MarketError.shape }
        return txns.compactMap { t -> ActivityItem? in
            guard let hash = t["transaction_hash"] as? String else { return nil }
            let ns = Double(t["block_timestamp"] as? String ?? "") ?? (t["block_timestamp"] as? Double) ?? 0
            let when = Date(timeIntervalSince1970: ns / 1e9)
            let signer = (t["signer_account_id"] as? String) ?? (t["predecessor_account_id"] as? String) ?? ""
            let receiver = t["receiver_account_id"] as? String ?? ""
            let actions = t["actions"] as? [[String: Any]] ?? []
            let deposit = actions.reduce(0.0) { $0 + (($1["deposit"] as? Double) ?? Double($1["deposit"] as? String ?? "") ?? 0) } / 1e24
            let ok = ((t["outcomes"] as? [String: Any])?["status"] as? Bool) ?? true
            let status = ok ? "Confirmed" : "Failed", link = chain.explorerURL(tx: hash)
            let method = actions.compactMap { $0["method"] as? String }.first
            if receiver == account, signer != account, deposit > 0 {
                return ActivityItem(id: hash, kind: .received, chainID: chain.id, walletID: walletID, what: "Received \(MoneyFmt.amount(deposit)) NEAR",
                                    detail: signer.isEmpty ? "" : "From \(signer)", amount: deposit, symbol: "NEAR", date: when, tx: hash, status: status, link: link)
            }
            if signer == account, let m = method {
                return ActivityItem(id: hash, kind: .contract, chainID: chain.id, walletID: walletID, what: "Called \(m) on \(receiver)",
                                    detail: deposit > 0 ? "\(MoneyFmt.amount(deposit)) NEAR attached" : "", amount: deposit > 0 ? -deposit : nil,
                                    symbol: "NEAR", date: when, tx: hash, status: status, link: link)
            }
            if signer == account, deposit > 0 {
                return ActivityItem(id: hash, kind: .sent, chainID: chain.id, walletID: walletID, what: "Sent \(MoneyFmt.amount(deposit)) NEAR to \(receiver)",
                                    detail: "", amount: -deposit, symbol: "NEAR", date: when, tx: hash, status: status, link: link)
            }
            return ActivityItem(id: hash, kind: .contract, chainID: chain.id, walletID: walletID,
                                what: method.map { "\($0) from \(signer)" } ?? "Transaction with \(signer == account ? receiver : signer)",
                                detail: "", amount: nil, symbol: "NEAR", date: when, tx: hash, status: status, link: link)
        }
    }

    // MARK: Ethereum (Blockscout, no key)

    static func blockscout(chain: Chain, host: String, address: String, walletID: String) async throws -> [ActivityItem] {
        let me = address.lowercased()
        var out: [ActivityItem] = []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func when(_ s: Any?) -> Date { (s as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? Date() }
        func hash(_ v: Any?) -> String { ((v as? [String: Any])?["hash"] as? String ?? "").lowercased() }
        // Blockscout pages are a fixed size and refuse `limit` and `filter` (HTTP 422), so both reads are plain and
        // trimmed here. Each stands alone: one failing still shows the other, and the page says some is missing.
        var reads = 0
        if let d = try? await MarketHTTP.data("https://\(host)/api/v2/addresses/\(address)/token-transfers"),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let items = j["items"] as? [[String: Any]] {
            reads += 1
            for t in items.prefix(25) {
                guard let tx = t["transaction_hash"] as? String, let total = t["total"] as? [String: Any], let token = t["token"] as? [String: Any] else { continue }
                let dec = Int(token["decimals"] as? String ?? "") ?? 18
                let amt = Double(Units.format(UInt128(total["value"] as? String ?? "") ?? 0, decimals: dec)) ?? 0
                let sym = token["symbol"] as? String ?? "token"
                let from = hash(t["from"]), to = hash(t["to"]), recv = to == me
                out.append(ActivityItem(id: tx + ":" + sym, kind: recv ? .received : .sent, chainID: chain.id, walletID: walletID,
                                        what: (recv ? "Received " : "Sent ") + MoneyFmt.amount(amt) + " " + sym + (recv ? "" : " to " + shortAddr(to)),
                                        detail: recv ? "From " + shortAddr(from) : "", amount: recv ? amt : -amt, symbol: sym,
                                        date: when(t["timestamp"]), tx: tx, status: "Confirmed", link: chain.explorerURL(tx: tx)))
            }
        }
        if let d2 = try? await MarketHTTP.data("https://\(host)/api/v2/addresses/\(address)/transactions"),
           let j = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any], let items = j["items"] as? [[String: Any]] {
            reads += 1
            for t in items.prefix(25) {
                guard let tx = t["hash"] as? String else { continue }
                let amt = Double(Units.format(UInt128(t["value"] as? String ?? "") ?? 0, decimals: 18)) ?? 0
                let from = hash(t["from"]), to = hash(t["to"]), ok = (t["status"] as? String) == "ok"
                let method = t["method"] as? String ?? ""
                if amt > 0, method.isEmpty {
                    let recv = to == me
                    out.append(ActivityItem(id: tx, kind: recv ? .received : .sent, chainID: chain.id, walletID: walletID,
                                            what: (recv ? "Received " : "Sent ") + MoneyFmt.amount(amt) + " ETH" + (recv ? "" : " to " + shortAddr(to)),
                                            detail: recv ? "From " + shortAddr(from) : "", amount: recv ? amt : -amt, symbol: "ETH",
                                            date: when(t["timestamp"]), tx: tx, status: ok ? "Confirmed" : "Failed", link: chain.explorerURL(tx: tx)))
                } else if from == me, !out.contains(where: { $0.tx == tx }) {
                    out.append(ActivityItem(id: tx, kind: .contract, chainID: chain.id, walletID: walletID, what: "\(method.isEmpty ? "Contract call" : method) on \(shortAddr(to))",
                                            detail: amt > 0 ? "\(MoneyFmt.amount(amt)) ETH attached" : "", amount: amt > 0 ? -amt : nil, symbol: "ETH",
                                            date: when(t["timestamp"]), tx: tx, status: ok ? "Confirmed" : "Failed", link: chain.explorerURL(tx: tx)))
                }
            }
        }
        if reads == 0 { throw MarketError.shape }
        if reads == 1 { throw PartialHistory(items: out) }
        return out
    }

    // MARK: Hyperliquid (its own ledger: deposits, withdrawals, transfers)

    static func hyperliquid(address: String, walletID: String) async throws -> [ActivityItem] {
        let d = try await MarketHTTP.data("https://api.hyperliquid.xyz/info", json: #"{"type":"userNonFundingLedgerUpdates","user":"\#(address)","startTime":0}"#)
        guard let rows = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return rows.suffix(30).compactMap { r -> ActivityItem? in
            guard let delta = r["delta"] as? [String: Any], let type = delta["type"] as? String, let ms = r["time"] as? Double else { return nil }
            let usd = Double(delta["usdc"] as? String ?? delta["amount"] as? String ?? "") ?? 0
            let hash = r["hash"] as? String ?? ""
            let when = Date(timeIntervalSince1970: ms / 1000)
            let link = URL(string: "https://app.hyperliquid.xyz/explorer/address/\(address)")
            switch type {
            case "deposit":
                return ActivityItem(id: "hl-" + hash, kind: .deposit, chainID: "hyperliquid", walletID: walletID, what: "Deposited \(MoneyFmt.amount(usd)) USDC to Hyperliquid",
                                    detail: "Hyperliquid", amount: usd, symbol: "USDC", date: when, tx: hash.isEmpty ? nil : hash, status: "Confirmed", link: link)
            case "withdraw":
                return ActivityItem(id: "hl-" + hash, kind: .sent, chainID: "hyperliquid", walletID: walletID, what: "Withdrew \(MoneyFmt.amount(usd)) USDC from Hyperliquid",
                                    detail: "Hyperliquid, to Arbitrum", amount: -usd, symbol: "USDC", date: when, tx: hash.isEmpty ? nil : hash, status: "Confirmed", link: link)
            case "send", "internalTransfer", "accountClassTransfer":
                let dest = (delta["destination"] as? String ?? "").lowercased()
                let recv = dest == address.lowercased()
                return ActivityItem(id: "hl-" + hash + type, kind: recv ? .received : .sent, chainID: "hyperliquid", walletID: walletID,
                                    what: (recv ? "Received " : "Sent ") + "\(MoneyFmt.amount(usd)) USDC on Hyperliquid", detail: "Hyperliquid",
                                    amount: recv ? usd : -usd, symbol: "USDC", date: when, tx: hash.isEmpty ? nil : hash, status: "Confirmed", link: link)
            default: return nil
            }
        }
    }

    // MARK: EVM (Etherscan v2, with a key)

    static func etherscan(chain: Chain, address: String, walletID: String, key: String) async throws -> [ActivityItem] {
        guard let cid = chain.chainId else { return [] }
        let me = address.lowercased()
        func fetch(_ action: String) async throws -> [[String: Any]] {
            let d = try await MarketHTTP.data("https://api.etherscan.io/v2/api?chainid=\(cid)&module=account&action=\(action)&address=\(address)&page=1&offset=20&sort=desc&apikey=\(key)")
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw MarketError.shape }
            if let r = j["result"] as? [[String: Any]] { return r }
            if (j["message"] as? String)?.hasPrefix("No transactions") == true { return [] }
            throw MarketError.shape
        }
        var out: [ActivityItem] = []
        for t in try await fetch("tokentx") {
            guard let hash = t["hash"] as? String, let ts = Double(t["timeStamp"] as? String ?? "") else { continue }
            let from = (t["from"] as? String ?? "").lowercased(), to = (t["to"] as? String ?? "").lowercased()
            let dec = Int(t["tokenDecimal"] as? String ?? "") ?? 18
            let amt = Double(Units.format(UInt128(t["value"] as? String ?? "") ?? 0, decimals: dec)) ?? 0
            let sym = t["tokenSymbol"] as? String ?? "token"
            let recv = to == me
            out.append(ActivityItem(id: hash + ":" + sym, kind: recv ? .received : .sent, chainID: chain.id, walletID: walletID,
                                    what: (recv ? "Received " : "Sent ") + MoneyFmt.amount(amt) + " " + sym + (recv ? "" : " to " + shortAddr(to)),
                                    detail: recv ? "From " + shortAddr(from) : "", amount: recv ? amt : -amt, symbol: sym,
                                    date: Date(timeIntervalSince1970: ts), tx: hash, status: "Confirmed", link: chain.explorerURL(tx: hash)))
        }
        try? await Task.sleep(for: .milliseconds(250))
        for t in try await fetch("txlist") {
            guard let hash = t["hash"] as? String, let ts = Double(t["timeStamp"] as? String ?? "") else { continue }
            let from = (t["from"] as? String ?? "").lowercased(), to = (t["to"] as? String ?? "").lowercased()
            let amt = Double(Units.format(UInt128(t["value"] as? String ?? "") ?? 0, decimals: 18)) ?? 0
            let failed = (t["isError"] as? String) == "1"
            let fn = (t["functionName"] as? String ?? "").split(separator: "(").first.map(String.init) ?? ""
            let when = Date(timeIntervalSince1970: ts), status = failed ? "Failed" : "Confirmed"
            if amt > 0, fn.isEmpty {
                let recv = to == me
                out.append(ActivityItem(id: hash, kind: recv ? .received : .sent, chainID: chain.id, walletID: walletID,
                                        what: (recv ? "Received " : "Sent ") + MoneyFmt.amount(amt) + " " + chain.nativeSymbol + (recv ? "" : " to " + shortAddr(to)),
                                        detail: recv ? "From " + shortAddr(from) : "", amount: recv ? amt : -amt, symbol: chain.nativeSymbol,
                                        date: when, tx: hash, status: status, link: chain.explorerURL(tx: hash)))
            } else if from == me, !fn.isEmpty, !out.contains(where: { $0.tx == hash }) {
                out.append(ActivityItem(id: hash, kind: .contract, chainID: chain.id, walletID: walletID, what: "\(fn) on \(shortAddr(to))",
                                        detail: amt > 0 ? "\(MoneyFmt.amount(amt)) \(chain.nativeSymbol) attached" : "", amount: amt > 0 ? -amt : nil,
                                        symbol: chain.nativeSymbol, date: when, tx: hash, status: status, link: chain.explorerURL(tx: hash)))
            }
        }
        return out
    }
}
