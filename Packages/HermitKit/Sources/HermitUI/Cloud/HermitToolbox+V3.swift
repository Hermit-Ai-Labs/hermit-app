import Foundation
import HermitCore
import HermitWallet

// The v3 tools (hermit-lab/train/spec/APP_TOOLS_v3.md), on the phone for the on-device model and for Private Cloud.
// This file: the dispatch, the read tools (addresses, token search, positions, portfolio, activity) and the two that
// only show a button or open a page. Money tools are in HermitToolbox+V3Money.swift, confirm cards in
// HermitToolbox+V3Cards.swift, and everything that only computes in ToolsV3.swift.
//
// The rules they all keep: a read answers with real data or an error, never a guess; a money tool only prepares a
// review the user approves with Face ID or Touch ID; a card tool only drafts something the user confirms with a tap;
// and no result ever says a thing happened that the user still has to approve.

/// The window chat's tools act in. RootView sets it; tools that open something (open_app) use it.
@MainActor
final class ToolHost {
    static let shared = ToolHost()
    weak var model: AppModel?
}

extension HermitToolbox {
    /// Runs a v3 tool. nil when `name` isn't one (the caller reports the unknown tool).
    static func runV3(_ name: String, _ a: [String: Any], label: String) async throws -> ToolOutcome? {
        switch name {
        case "get_address": return try await getAddress(a)
        case "open_page": return ToolsV3.openPage(a)
        case "search_tokens": return await searchTokens(a)
        case "get_positions": return try await getPositions(a)
        case "get_portfolio": return try await getPortfolio()
        case "get_activity": return try await getActivity(a)
        case "open_app": return try await openApp(a)
        case "prepare_buy": return try await prepareBuy(a, label: label)
        case "prepare_sell": return try await prepareSell(a, label: label)
        case "prepare_close": return try await prepareClose(a, label: label)
        case "set_tp_sl": return try await setProtection(a, label: label)
        case "cancel_order": return try await cancelOrder(a)
        case "create_automation": return await createAutomation(a)
        case "schedule_payment": return await schedulePayment(a)
        case "add_contact": return await addContact(a)
        default: return nil
        }
    }

    // MARK: get_address

    /// The contacts a name can mean: the payees saved in Payments, then the wallet's own labelled addresses. Both are
    /// only ever made by the user (or by add_contact, on a card that shows the full address).
    @MainActor static func contacts() -> [ToolsV3.Contact] {
        PaymentsStore.shared.payees.map { ToolsV3.Contact(name: $0.name, address: $0.addr) }
            + WalletsViewModel.shared.whitelist.map { ToolsV3.Contact(name: $0.label, address: $0.address) }
    }

    /// get_address: the selected wallet's public receive addresses (one per family), or a saved contact's address by
    /// name. Never a key or a phrase.
    @MainActor static func getAddress(_ a: [String: Any]) throws -> ToolOutcome {
        let contact = ToolsV3.text(a, "contact"), chainText = ToolsV3.text(a, "chain")
        var only: ChainKind?
        if !chainText.isEmpty {
            guard let c = findChain(chainText) else { throw ToolError("Unknown chain \(chainText)") }
            only = c.kind
        }
        if !contact.isEmpty { return json(ToolsV3.contactResult(contact, in: contacts(), only: only)) }
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        var own: [(kind: ChainKind, address: String)] = [(kind: .evm, address: w.record.evmAddress), (kind: .solana, address: w.record.solanaAddress)]
        if let near = w.record.nearAccount, !near.isEmpty { own.append((kind: .near, address: near)) }
        return json(ToolsV3.ownAddresses(own, wallet: w.name, only: only))
    }

    // MARK: search_tokens

    /// search_tokens: Jupiter's search over every Solana token, with what its audit says about each.
    static func searchTokens(_ a: [String: Any]) async -> ToolOutcome {
        let q = ToolsV3.text(a, "query")
        guard !q.isEmpty else { return json(["error": "Needs a query"]) }
        do {
            let found = try await JupiterTokens.search(JupiterTokens.looksLikeMint(q) ? q : JupiterTokens.plain(q))
            return json(ToolsV3.searchResult(found, query: q))
        } catch {
            return json(["error": "Token search is unavailable right now."])
        }
    }

    // MARK: Solana holdings

    /// The Solana tokens `w` holds, and whether the read failed. The first wallet is the one Trade's own list reads
    /// (SolanaHoldings); any other wallet is read here the same way: the chain for balances, Jupiter for names and prices.
    @MainActor static func spotHoldings(_ w: WalletAccount) async -> (items: [SolanaHoldings.Holding], failed: Bool) {
        let owner = w.record.solanaAddress
        guard !owner.isEmpty else { return ([], false) }
        if WalletsViewModel.shared.wallets.first?.id == w.id {
            let store = SolanaHoldings.shared
            await store.refresh()
            return (store.items, store.lastFailed)
        }
        do {
            let raw = try await SolanaHoldings.readAccounts(owner: owner)
            let mints = raw.keys.sorted()
            let listed = Dictionary(JupiterTokens.shared.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let unknown = mints.filter { listed[$0] == nil }
            var found: [String: JupiterTokens.Found] = [:]
            for start in stride(from: 0, to: min(unknown.count, 80), by: 40) {
                let chunk = Array(unknown[start..<min(start + 40, unknown.count, 80)])
                let hits = (try? await JupiterTokens.search(chunk.joined(separator: ","))) ?? []
                for f in hits { found[f.id] = f }
            }
            let prices = await SolanaHoldings.prices(mints) ?? [:]
            var items: [SolanaHoldings.Holding] = []
            for m in mints {
                guard let r = raw[m] else { continue }
                let l = listed[m], f = found[m]
                let price: Double? = prices[m] ?? l?.price ?? f?.row?.price
                items.append(SolanaHoldings.Holding(id: m, symbol: l?.symbol ?? f?.symbol ?? String(m.prefix(4)) + "…", name: l?.name ?? f?.name ?? "Unknown token",
                                                    decimals: r.decimals, icon: l?.icon ?? f?.icon, amount: r.amount,
                                                    price: price.flatMap { $0 > 0 ? $0 : nil },
                                                    verified: l != nil || f?.verified == true, frozen: r.frozen))
            }
            return (items, false)
        } catch {
            return ([], true)
        }
    }

    /// The Hyperliquid account of a wallet, read now. nil when Hyperliquid couldn't be reached.
    @MainActor static func perpAccount(for w: WalletAccount) async -> Hyperliquid.Account? {
        let hl = HyperliquidStore.shared
        if hl.wallet?.id == w.id {
            let ok = await hl.poll()
            return ok ? hl.account : nil
        }
        return try? await Hyperliquid.account(w.record.evmAddress)
    }

    // MARK: get_positions

    /// get_positions: what the selected wallet holds beyond its balances. Solana tokens with their cost, Aave deposits,
    /// and Hyperliquid positions and orders with the ids cancel_order takes. A source that didn't answer is named in
    /// `unreachable`, so an empty list is never passed off as "nothing held".
    @MainActor static func getPositions(_ a: [String: Any]) async throws -> ToolOutcome {
        var kind = ToolsV3.text(a, "kind").lowercased()
        if kind.isEmpty { kind = "all" }
        guard ["all", "spot", "earn", "perps"].contains(kind) else { throw ToolError("kind is all, spot, earn or perps") }
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        var out: [String: Any] = ["wallet": w.name]
        var unreachable: [String] = [], notes: [String] = []
        if kind == "all" || kind == "spot" {
            let (items, failed) = await spotHoldings(w)
            if failed { unreachable.append("solana") }
            let walletID = w.id
            let listed = ToolsV3.spotRows(items) { mint in SpotBook.shared.basis(mint: mint, walletID: walletID) }
            out["spot"] = listed.rows
            if listed.left > 0 { notes.append("\(listed.left) smaller or unpriced Solana tokens are left out; Trade, Positions lists them all.") }
        }
        if kind == "all" || kind == "earn" {
            let (positions, failed) = await WalletsViewModel.shared.service.aavePositions(wallets: [w.record])
            out["earn"] = ToolsV3.earnRows(positions)
            for c in failed where !unreachable.contains(c.id) { unreachable.append(c.id) }
        }
        if kind == "all" || kind == "perps" {
            // Hyperliquid: the account Trade uses, the same one the trade, close, stop and cancel tools act on.
            let hl = HyperliquidStore.shared
            let ok = await hl.poll()
            out["perps"] = ToolsV3.perps(ok ? hl.account : nil)
            if !ok || (hl.account == nil && hl.hasWallet) { unreachable.append("hyperliquid") }
            if let t = hl.wallet, t.id != w.id { notes.append("The Hyperliquid rows are for \(t.name), the wallet Trade uses.") }
        }
        if !unreachable.isEmpty { out["unreachable"] = unreachable }
        if !notes.isEmpty { out["note"] = notes.joined(separator: " ") }
        return json(out)
    }

    // MARK: get_portfolio

    /// get_portfolio: what the selected wallet is worth in dollars, by place. Nothing is counted twice: SOL and the
    /// stablecoins the wallet lists are "Wallet", every other Solana token is "Spot tokens".
    @MainActor static func getPortfolio() async throws -> ToolOutcome {
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        let vm = WalletsViewModel.shared
        await vm.refresh()
        var parts: [ToolsV3.Part] = []
        var unreachable: [String] = vm.unreachable.filter { !$0.isTestnet }.map(\.id)
        var unpriced: [String] = []
        for h in vm.holdings(wallet: w.id, chain: nil) where !h.chain.isTestnet {
            if h.priced { parts.append(ToolsV3.Part(place: "Wallet", what: ToolsV3.holdingName(h.symbol, h.chain), usd: h.usd)) }
            else if !unpriced.contains(h.symbol) { unpriced.append(h.symbol) }
        }
        let counted = Set(Chain.solana.tokens.map(\.address) + [Jupiter.usdcMint, Jupiter.solMint])
        let (spot, spotFailed) = await spotHoldings(w)
        if spotFailed, !unreachable.contains("solana") { unreachable.append("solana") }
        for h in spot where !counted.contains(h.id) {
            if let v = h.value, v >= 0.01 { parts.append(ToolsV3.Part(place: "Spot tokens", what: h.symbol, usd: v)) }
        }
        // Aave deposits are stablecoins (the ones Hermit can deposit): a dollar each.
        let (aave, aaveFailed) = await vm.service.aavePositions(wallets: [w.record])
        for p in aave {
            if let v = Double(p.text), v > 0 { parts.append(ToolsV3.Part(place: "Aave", what: "\(p.token.symbol) on \(p.chain.name)", usd: v)) }
        }
        for c in aaveFailed where !unreachable.contains(c.id) { unreachable.append(c.id) }
        if let account = await perpAccount(for: w) {
            if account.accountValue > 0 { parts.append(ToolsV3.Part(place: "Hyperliquid", what: "Account value", usd: account.accountValue)) }
        } else {
            unreachable.append("hyperliquid")
        }
        let note = unpriced.isEmpty ? nil : "No price for \(unpriced.sorted().joined(separator: ", ")), so it isn't counted."
        return json(ToolsV3.portfolio(wallet: w.name, parts: parts, unreachable: unreachable, note: note))
    }

    // MARK: get_activity

    /// get_activity: the Activity page's rows for the selected wallet, newest first.
    @MainActor static func getActivity(_ a: [String: Any]) async throws -> ToolOutcome {
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        let asked = ToolsV3.number(a, "limit") ?? 10
        let limit = asked.isFinite ? Int(min(max(asked, 1), 25)) : 10
        let feed = ActivityFeed.shared
        await feed.refresh()
        let walletID = w.id
        let mine = feed.items.filter { $0.walletID.isEmpty || $0.walletID == walletID }
        return json(ToolsV3.activity(mine, limit: limit))
    }

    // MARK: open_app

    /// open_app: a site in Hermit's browser, by its name in Explore or by a web address. It opens a page and nothing
    /// else: a site connects to the wallet only on the connect sheet the user approves. While an automation runs in the
    /// background nothing opens over the user's screen: the chat gets a button instead, and the result says so.
    @MainActor static func openApp(_ a: [String: Any]) throws -> ToolOutcome {
        let name = ToolsV3.text(a, "name"), address = ToolsV3.text(a, "url")
        var url: URL?
        var dapp: ExploreDapp?
        if !address.isEmpty {
            guard let u = webURL(address) else { return json(["error": "Only http and https addresses can be opened."]) }
            url = u
        } else if !name.isEmpty {
            if let site = ExploreData.sites.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                url = URL(string: "https://" + site.value)
                dapp = ExploreData.dapps.first { $0.name == site.key }
            } else if let close = ExploreData.closeMatch(name, in: ExploreData.dapps), let u = close.url {
                url = u; dapp = close
            } else if name.contains("."), let u = webURL(name) {
                // "uniswap.org" given as a name is an address.
                url = u
            }
            guard url != nil else {
                return json(["status": "not_found", "note": "No dApp called \(name) in Explore. Ask the user for the web address."])
            }
        } else {
            throw ToolError("Needs a name or a url")
        }
        guard let target = url else { throw ToolError("Needs a name or a url") }
        if dapp == nil, let host = target.host(), let known = DappBrowser.directoryName(for: host) {
            dapp = ExploreData.dapps.first { $0.name == known }
        }
        let title = dapp?.name ?? target.host() ?? "the site"
        let button = Action("Open \(title)", primary: true, symbol: "safari", open: "app:" + target.absoluteString)
        if let model = ToolHost.shared.model, !model.backgroundRunActive {
            DappBrowser.shared.open(target, dapp: dapp, model: model)
            var o = json(["status": "opened", "opened": target.absoluteString,
                          "note": "Opened in Hermit's browser. Nothing connects to the wallet until the user approves it."])
            o.action = button
            return o
        }
        var o = json(["status": "button_shown", "url": target.absoluteString,
                      "note": "Not opened yet: the user taps the button to open it in Hermit's browser. Nothing connects to the wallet until the user approves it."])
        o.action = button
        return o
    }

    /// An http or https address ("uniswap.org" becomes https). nil for anything else: javascript:, data:, file:, a bare
    /// word, text with spaces.
    @MainActor static func webURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = t.lowercased()
        // A scheme other than http(s), with or without "//" ("javascript:alert(1)", "data:text/html,…").
        if low.range(of: #"^[a-z][a-z0-9+.\-]*:"#, options: .regularExpression) != nil, !low.hasPrefix("http://"), !low.hasPrefix("https://"),
           low.range(of: #"^[a-z0-9.\-]+:\d+(/|$)"#, options: .regularExpression) == nil { return nil }
        return DappBrowserSession.normalize(t)
    }
}
