import XCTest
@testable import HermitUI
import HermitCore
import HermitWallet

/// The v3 tools with made-up values in place of the network, the wallet and the screen: every result has the keys of
/// hermit-lab/train/spec/hermit_tools_v3.meta.json, every refusal is a refusal (never a claimed success), and nothing
/// here can move anything. No network, nothing written to disk.
@MainActor
final class ToolsV3Tests: XCTestCase {
    let alice = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
    let other = "0x52908400098527886E0F7030069857D2E4169EE7"
    let solAddress = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
    let wifMint = "EKpQGSJtjMFqKZ9KQanSqYXRcF8fBopzLHYxdM65zcjm"
    let pumpA = "pumpCmXqMfrsAkQ5r49WcJnRayYRqmXz6ae8H7H9Dfn"
    let pumpB = "7Gk2xQ9dRvTnWb4mLpYc8sHfJ3uZaE5oNiB1KtVwXyDe"

    func object(_ o: ToolOutcome) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(o.content.utf8)) as? [String: Any])
    }
    func keys(_ d: [String: Any]) -> [String] { d.keys.sorted() }

    /// 2026-11-11 07:30 UTC, a Wednesday, on a UTC calendar.
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    var now: Date { date(2026, 11, 11, 7, 30) }

    // MARK: open_page

    func testOpenPage() throws {
        let o = ToolsV3.openPage(["page": "earn", "tab": "positions"])
        let v = try object(o)
        XCTAssertEqual(keys(v), ["note", "page", "screen", "status", "tab"])
        XCTAssertEqual(v["status"] as? String, "button_shown")
        XCTAssertEqual(v["note"] as? String, "The user taps it to open Earn.")
        XCTAssertEqual(v["tab"] as? String, "positions")
        XCTAssertEqual(o.action?.open, "page:earn:positions")
        XCTAssertNil(o.action?.approval, "a button, never a review")

        let plain = ToolsV3.openPage(["page": "trade"])
        XCTAssertEqual(keys(try object(plain)), ["note", "page", "screen", "status"])
        XCTAssertEqual(plain.action?.title, "Open Trade")
        XCTAssertEqual(plain.action?.open, "page:trade")
        XCTAssertEqual(try object(ToolsV3.openPage(["page": "home"]))["note"] as? String, "The user taps it to open Home.")

        // A tab the page doesn't have: an error that lists the real ones, and no button.
        let bad = ToolsV3.openPage(["page": "earn", "tab": "staking"])
        XCTAssertEqual(try object(bad)["error"] as? String, "Earn has no tab called staking. Tabs: save, positions, explore.")
        XCTAssertNil(bad.action)
        XCTAssertNil(ToolsV3.openPage(["page": "calendar", "tab": "week"]).action)

        // Settings, Safety may be opened: the user changes limits there themselves.
        XCTAssertEqual(ToolsV3.openPage(["page": "settings", "tab": "safety"]).action?.open, "page:settings:safety")
    }

    func testOpenPageNeverShowsAKey() throws {
        for args in [["page": "wallets", "tab": "recovery phrase"], ["page": "wallets", "tab": "security"], ["page": "seed"], ["page": "admin"],
                     ["page": "settings", "tab": "export keys"], ["page": "private-key"], ["page": ""]] {
            let o = ToolsV3.openPage(args)
            XCTAssertEqual(try object(o)["error"] as? String, "That page can't be opened from chat.", "\(args)")
            XCTAssertNil(o.action, "\(args)")
        }
        // The button's link is checked against the same list when it is tapped.
        XCTAssertEqual(ToolsV3.pageTarget("earn", tab: "positions")?.route, .earn)
        XCTAssertEqual(ToolsV3.pageTarget("earn", tab: "positions")?.tab, "positions")
        XCTAssertNil(ToolsV3.pageTarget("wallets", tab: "security"))
        XCTAssertNil(ToolsV3.pageTarget("earn", tab: "nope"))
        // Every page of the schema's list is a real page of the app.
        for p in ToolsV3.pages { XCTAssertNotNil(Route(rawValue: p), p) }
        XCTAssertEqual(ToolsV3.pages.count, 12)
    }

    // MARK: get_address

    func testOwnAddresses() {
        let own: [(kind: ChainKind, address: String)] = [(kind: .evm, address: alice), (kind: .solana, address: solAddress), (kind: .near, address: "alice.near")]
        let all = ToolsV3.ownAddresses(own, wallet: "Main", only: nil)
        XCTAssertEqual(keys(all), ["addresses", "note"])
        let rows = all["addresses"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(keys(rows[0]), ["address", "family", "networks", "wallet"])
        XCTAssertEqual(rows.map { $0["family"] as? String }, ["evm", "solana", "near"])
        XCTAssertEqual(Array((rows[0]["networks"] as? [String] ?? []).prefix(6)), ["ethereum", "base", "arbitrum", "bnb", "polygon", "monad"])
        XCTAssertEqual(rows[1]["networks"] as? [String], ["solana"])
        XCTAssertEqual(all["note"] as? String, "Only send tokens on these networks to these addresses. The QR code is in Add funds.")
        // One chain: only that family.
        let one = ToolsV3.ownAddresses(own, wallet: "Main", only: .solana)
        XCTAssertEqual((one["addresses"] as? [[String: Any]])?.count, 1)
        // A wallet with no NEAR account, asked for NEAR: an error, not an empty list.
        XCTAssertNotNil(ToolsV3.ownAddresses(Array(own.prefix(2)), wallet: "Main", only: .near)["error"])
    }

    func testContactLookup() {
        let list = [ToolsV3.Contact(name: "Alice Smith", address: alice), ToolsV3.Contact(name: "Alice Chen", address: other),
                    ToolsV3.Contact(name: "Bob", address: solAddress)]
        XCTAssertEqual(ToolsV3.findContact("alice smith", in: list), .one(list[0]))
        XCTAssertEqual(ToolsV3.findContact("Alice", in: list), .several([list[0], list[1]]))
        XCTAssertEqual(ToolsV3.findContact("bob", in: list), .one(list[2]))
        XCTAssertEqual(ToolsV3.findContact("carol", in: list), ToolsV3.ContactMatch.none)
        // The whole name wins over a longer one, and the same address saved twice is one contact.
        let exact = list + [ToolsV3.Contact(name: "Alice", address: alice), ToolsV3.Contact(name: "alice", address: alice.lowercased())]
        XCTAssertEqual(ToolsV3.findContact("alice", in: exact), .one(exact[3]))

        let found = ToolsV3.contactResult("Bob", in: list, only: nil)
        XCTAssertEqual(keys(found), ["contacts"])
        let row = (found["contacts"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(keys(row), ["address", "family", "name", "networks"])
        XCTAssertEqual(row["address"] as? String, solAddress, "the full address, to copy character for character")
        XCTAssertEqual(row["family"] as? String, "solana")

        let missing = ToolsV3.contactResult("Carol", in: list, only: nil)
        XCTAssertEqual(keys(missing), ["note", "status"])
        XCTAssertEqual(missing["status"] as? String, "not_found")
        XCTAssertEqual(missing["note"] as? String, "No saved contact called Carol. Ask the user for the address.")

        let choice = ToolsV3.contactResult("Alice", in: list, only: nil)
        XCTAssertEqual(keys(choice), ["note", "options", "question", "status"])
        XCTAssertEqual(choice["status"] as? String, "needs_choice")
        XCTAssertEqual(choice["options"] as? [String], ["Alice Smith", "Alice Chen"])
        XCTAssertEqual(choice["question"] as? String, "Which Alice? Alice Smith or Alice Chen.")
        XCTAssertNil(choice["contacts"], "no address is handed out while the name is unclear")

        // A contact of another family than the chain asked for is not handed over as if it fitted.
        XCTAssertEqual(ToolsV3.contactResult("Bob", in: list, only: .evm)["status"] as? String, "not_found")
    }

    // MARK: add_contact

    func testContactPlan() {
        XCTAssertEqual(ToolsV3.contactPlan(name: " Alice ", address: alice, network: nil, payees: []), .ok(name: "Alice", address: alice, kind: .evm))
        XCTAssertEqual(ToolsV3.contactPlan(name: "Alice", address: alice, network: "base", payees: []), .ok(name: "Alice", address: alice, kind: .evm))
        XCTAssertEqual(ToolsV3.contactPlan(name: "Mom", address: "Mom.near", network: nil, payees: []), .ok(name: "Mom", address: "mom.near", kind: .near))
        XCTAssertEqual(ToolsV3.contactPlan(name: "Alice", address: "0x1234", network: nil, payees: []), .error("That doesn't look like a valid address."))
        XCTAssertEqual(ToolsV3.contactPlan(name: "Alice", address: "not an address", network: nil, payees: []), .error("That doesn't look like a valid address."))
        XCTAssertEqual(ToolsV3.contactPlan(name: "Alice", address: alice, network: "solana", payees: []),
                       .error("That is an EVM address, so it can't be used on Solana."))
        // Saved already (EVM addresses compare without case), or the name is taken by another address.
        let saved = [ToolsV3.Contact(name: "Alice", address: alice.lowercased())]
        XCTAssertEqual(ToolsV3.contactPlan(name: "Ali", address: alice, network: nil, payees: saved), .exists("Alice"))
        XCTAssertEqual(ToolsV3.contactPlan(name: "alice", address: other, network: nil, payees: saved), .nameTaken("alice"))
        XCTAssertEqual(ToolsV3.contactPlan(name: "", address: alice, network: nil, payees: []), .error("Needs a name and an address"))
    }

    // MARK: search_tokens

    func row(_ mint: String, _ symbol: String, _ name: String, price: Double, liquidity: Double, check: TokenCheck? = nil) -> JupiterTokens.Row {
        JupiterTokens.Row(id: mint, symbol: symbol, name: name, decimals: 6, icon: nil, price: price, change24h: -3.2, liquidity: liquidity,
                          volume24h: 96_000_000, tags: [], check: check)
    }
    func found(_ mint: String, _ symbol: String, _ name: String, price: Double?, liquidity: Double, verified: Bool, audit: [String: Any] = [:]) -> JupiterTokens.Found {
        let check = TokenCheck(["isVerified": verified, "audit": audit], liquidity: liquidity)
        return JupiterTokens.Found(id: mint, symbol: symbol, name: name, decimals: 6, icon: nil, verified: verified,
                                   row: price.map { row(mint, symbol, name, price: $0, liquidity: liquidity, check: check) }, check: check)
    }
    let safeAudit: [String: Any] = ["mintAuthorityDisabled": true, "freezeAuthorityDisabled": true]

    func testSearchTokens() {
        let wif = found(wifMint, "WIF", "dogwifhat", price: 1.82, liquidity: 18_400_000, verified: true, audit: safeAudit)
        let risky = found(pumpB, "WIFG", "WIF Gold", price: 0.00031, liquidity: 3_900, verified: false,
                          audit: ["mintAuthorityDisabled": false, "freezeAuthorityDisabled": false, "topHoldersPercentage": 62.0])
        let out = ToolsV3.searchResult([risky, wif], query: "wif")
        XCTAssertEqual(keys(out), ["tokens"])
        let rows = out["tokens"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["symbol"] as? String }, ["WIF", "WIFG"], "best liquidity first")
        XCTAssertEqual(keys(rows[0]), ["change_24h_pct", "liquidity_usd", "mint", "name", "price", "symbol", "tags", "verified", "volume_24h_usd"])
        XCTAssertEqual(rows[0]["verified"] as? Bool, true)
        XCTAssertEqual(rows[0]["tags"] as? [String], [])
        XCTAssertEqual(rows[0]["price"] as? Double ?? 0, 1.82, accuracy: 1e-9)
        XCTAssertEqual(rows[0]["liquidity_usd"] as? Double, 18_400_000)
        XCTAssertNil(rows[0]["refusal"])
        // The risky one: its tags in the tool's own words, and why Hermit won't buy it.
        XCTAssertEqual(keys(rows[1]), ["change_24h_pct", "liquidity_usd", "mint", "name", "price", "refusal", "symbol", "tags", "verified", "volume_24h_usd"])
        XCTAssertEqual(rows[1]["verified"] as? Bool, false)
        XCTAssertEqual(rows[1]["tags"] as? [String], ["Unverified", "Freeze on", "Mint on", "Low liquidity", "Top holders 62%"])
        XCTAssertTrue((rows[1]["refusal"] as? String ?? "").contains("won't buy it"))
        XCTAssertEqual(rows[1]["price"] as? Double ?? 0, 0.00031, accuracy: 1e-12)

        // A token with no price: null price and change, never an invented number.
        let unpriced = found(pumpA, "PUMP", "Pump", price: nil, liquidity: 80_000, verified: true, audit: safeAudit)
        let u = ToolsV3.tokenRow(unpriced)
        XCTAssertTrue(u["price"] is NSNull)
        XCTAssertTrue(u["change_24h_pct"] is NSNull)

        // At most five, and the exact ticker is never pushed out by bigger tokens that only resemble it.
        let fillers = (0..<7).map { i in found("Mint\(i)", "WIFX\(i)", "Filler \(i)", price: 1, liquidity: 50_000_000 + Double(i), verified: true, audit: safeAudit) }
        let capped = ToolsV3.searchResult(fillers + [wif], query: "wif")["tokens"] as? [[String: Any]] ?? []
        XCTAssertEqual(capped.count, 5)
        XCTAssertTrue(capped.contains { $0["mint"] as? String == wifMint })

        let none = ToolsV3.searchResult([], query: "zzzz")
        XCTAssertEqual(keys(none), ["note", "tokens"])
        XCTAssertEqual((none["tokens"] as? [Any])?.count, 0)
        XCTAssertEqual(none["note"] as? String, "No Solana token matched. Check the spelling or paste the mint.")
    }

    // MARK: prepare_buy

    func testBuyPicksTheVerifiedTokenOrAsks() {
        let rows = [row(wifMint, "WIF", "dogwifhat", price: 1.82, liquidity: 18_400_000),
                    row("ED5nyyWEzpPPiWimP8vYm7sD7TD3LAt3Q3gRTWHzPJBY", "MOODENG", "Moo Deng", price: 0.21, liquidity: 9_100_000),
                    row(pumpB, "MOODENG", "Moo Deng 2", price: 0.034, liquidity: 6_200_000)]
        if case .token(let r) = ToolsV3.pickVerified("$wif", rows: rows) { XCTAssertEqual(r.id, wifMint) } else { XCTFail("WIF is on the list") }
        if case .none = ToolsV3.pickVerified("XYZ", rows: rows) {} else { XCTFail("XYZ isn't on the list") }
        guard case .clash(let two) = ToolsV3.pickVerified("moodeng", rows: rows) else { return XCTFail("two tokens share the ticker") }
        let choice = ToolsV3.buyChoice("MOODENG", two)
        XCTAssertEqual(keys(choice), ["note", "options", "prepared", "question", "status"])
        XCTAssertEqual(choice["status"] as? String, "needs_choice")
        XCTAssertEqual(choice["prepared"] as? Bool, false)
        XCTAssertEqual(choice["question"] as? String, "Two tokens are called MOODENG. Pick the one you mean on Spot or Memes, or paste its mint.")
        let options = choice["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.map { keys($0) }, [["liquidity_usd", "mint", "symbol"], ["liquidity_usd", "mint", "symbol"]])
        XCTAssertEqual(options.first?["liquidity_usd"] as? Double, 9_100_000)
        // A runner-up with under half the liquidity is no clash.
        let clear = [rows[1], row(pumpB, "MOODENG", "Small", price: 1, liquidity: 1_000_000)]
        if case .token(let r) = ToolsV3.pickVerified("MOODENG", rows: clear) { XCTAssertEqual(r.name, "Moo Deng") } else { XCTFail("the big one wins") }
    }

    // MARK: prepare_sell

    func holding(_ mint: String, _ symbol: String, units: UInt128, price: Double? = 1.82, frozen: Bool = false) -> SolanaHoldings.Holding {
        SolanaHoldings.Holding(id: mint, symbol: symbol, name: symbol, decimals: 6, icon: nil, amount: units, price: price, verified: true, frozen: frozen)
    }

    /// The plan in a word, for the tests.
    func said(_ p: ToolsV3.SellPlan) -> String {
        switch p {
        case .error(let e): return "error: \(e)"
        case .notHeld(let n): return "not_held \(n)"
        case .choose(let hs): return "choose \(hs.count)"
        case .frozen(let h): return "frozen \(h.symbol)"
        case .insufficient(let h): return "insufficient \(h.symbol)"
        case .sell(let h, let base, let part): return "sell \(base) \(h.symbol) [\(part)]"
        }
    }

    func testSellPlan() {
        let wif = holding(wifMint, "WIF", units: 6_020_000)
        func plan(_ token: String, percent: Double? = nil, amount: String? = nil, of hs: [SolanaHoldings.Holding]? = nil) -> String {
            said(ToolsV3.sellPlan(token: token, percent: percent, amountText: amount, hasAmount: amount != nil, holdings: hs ?? [wif]))
        }
        // Any percent from 1 to 100, in exact base units, rounded down.
        XCTAssertEqual(plan("WIF", percent: 50), "sell 3010000 WIF [50% of your WIF]")
        XCTAssertEqual(plan("wif", percent: 100), "sell 6020000 WIF [all of your WIF]")
        XCTAssertEqual(plan("$WIF", percent: 12.5), "sell 752500 WIF [12.5% of your WIF]")
        XCTAssertEqual(plan("WIF", percent: 33), "sell 1986600 WIF [33% of your WIF]")
        // Or an amount in token units.
        XCTAssertEqual(plan("WIF", amount: "3"), "sell 3000000 WIF []")
        XCTAssertEqual(plan("WIF", amount: "6.02"), "sell 6020000 WIF [all of your WIF]")
        XCTAssertEqual(plan("WIF", amount: "7"), "insufficient WIF")
        XCTAssertTrue(plan("WIF", amount: "0.00000001").hasPrefix("error:"), "more decimals than the token has")
        // By mint.
        XCTAssertEqual(plan(wifMint, percent: 25), "sell 1505000 WIF [25% of your WIF]")
        // Never both, never neither, never out of range.
        XCTAssertEqual(plan("WIF", percent: 50, amount: "3"), "error: Give percent or amount, not both.")
        XCTAssertTrue(plan("WIF").hasPrefix("error: Needs percent"))
        XCTAssertTrue(plan("WIF", percent: 0).hasPrefix("error:"))
        XCTAssertTrue(plan("WIF", percent: 101).hasPrefix("error:"))
        XCTAssertTrue(plan("WIF", percent: .nan).hasPrefix("error:"))
        // Not held, frozen, and two tokens under one ticker.
        XCTAssertEqual(plan("BONK", percent: 100), "not_held BONK")
        XCTAssertEqual(plan("WIF", percent: 100, of: [holding(wifMint, "WIF", units: 0)]), "not_held WIF")
        XCTAssertEqual(plan("PUMP", percent: 100, of: [holding(pumpA, "PUMP", units: 120_000_000, frozen: true)]), "frozen PUMP")
        let two = [holding(pumpA, "PUMP", units: 120_000_000), holding(pumpB, "PUMP", units: 4_000_000)]
        XCTAssertEqual(plan("PUMP", percent: 100, of: two), "choose 2")
        XCTAssertEqual(plan(pumpB, percent: 100, of: two), "sell 4000000 PUMP [all of your PUMP]", "the mint settles it")

        let choice = ToolsV3.sellChoice(two)
        XCTAssertEqual(keys(choice), ["note", "options", "prepared", "question", "status"])
        XCTAssertEqual(choice["status"] as? String, "needs_choice")
        XCTAssertEqual(choice["question"] as? String, "You hold two tokens called PUMP: 120 (pump…9Dfn) and 4 (7Gk2…XyDe). Which one?")
        let options = choice["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.map { keys($0) }, [["amount", "mint", "symbol"], ["amount", "mint", "symbol"]])
        XCTAssertEqual(options.first?["amount"] as? String, "120")
    }

    // MARK: get_positions

    func testSpotRows() {
        let wif = holding(wifMint, "WIF", units: 6_020_000)
        let full = ToolsV3.spotRow(wif, basis: SpotBook.Basis(tokens: 6.02, cost: 6.02 * 1.74))
        XCTAssertEqual(keys(full), ["amount", "avg_cost", "frozen", "mint", "pnl_pct", "symbol", "usd"])
        XCTAssertEqual(full["amount"] as? String, "6.02")
        XCTAssertEqual(full["usd"] as? Double ?? 0, 10.96, accuracy: 1e-9)
        XCTAssertEqual(full["avg_cost"] as? Double ?? 0, 1.74, accuracy: 1e-9)
        XCTAssertEqual(full["pnl_pct"] as? Double ?? 0, 4.6, accuracy: 1e-9)
        XCTAssertEqual(full["frozen"] as? Bool, false)
        // Not bought in Hermit: no cost, no P&L. Never a made-up number.
        let outside = ToolsV3.spotRow(holding(pumpA, "PUMP", units: 120_000_000, price: 0.03, frozen: true), basis: nil)
        XCTAssertTrue(outside["avg_cost"] is NSNull)
        XCTAssertTrue(outside["pnl_pct"] is NSNull)
        XCTAssertEqual(outside["frozen"] as? Bool, true)
        XCTAssertEqual(outside["usd"] as? Double ?? 0, 3.6, accuracy: 1e-9)
        // Half of it came from outside: Hermit's own average cost, but no P&L for the whole.
        let half = ToolsV3.spotRow(wif, basis: SpotBook.Basis(tokens: 3, cost: 3 * 1.74))
        XCTAssertEqual(half["avg_cost"] as? Double ?? 0, 1.74, accuracy: 1e-9)
        XCTAssertTrue(half["pnl_pct"] is NSNull)
        // No price: null value.
        XCTAssertTrue(ToolsV3.spotRow(holding(pumpB, "X", units: 5, price: nil), basis: nil)["usd"] is NSNull)

        // The list: most valuable first, dust left out, a cap with a count of what's left.
        let many = (0..<20).map { i in holding("Mint\(i)", "T\(i)", units: UInt128(1_000_000 * (i + 1)), price: 1) } + [holding("Dust", "DUST", units: 1, price: 1)]
        let listed = ToolsV3.spotRows(many, limit: 12) { _ in nil }
        XCTAssertEqual(listed.rows.count, 12)
        XCTAssertEqual(listed.rows.first?["symbol"] as? String, "T19")
        XCTAssertEqual(listed.left, 9)
    }

    func testEarnAndPerpRows() throws {
        let usdc = try XCTUnwrap(Chain.base.token("USDC"))
        let earn = ToolsV3.earnRows([AavePosition(walletID: UUID(), chain: .base, token: usdc, amount: 52_310_000, supplyAPY: 0.0421),
                                     AavePosition(walletID: UUID(), chain: .base, token: usdc, amount: 1_000_000, supplyAPY: nil)])
        XCTAssertEqual(keys(earn[0]), ["amount", "apy_pct", "chain", "symbol"])
        XCTAssertEqual(earn[0]["amount"] as? String, "52.31")
        XCTAssertEqual(earn[0]["apy_pct"] as? Double ?? 0, 4.21, accuracy: 1e-9)
        XCTAssertEqual(earn[0]["chain"] as? String, "base")
        XCTAssertTrue(earn[1]["apy_pct"] is NSNull)

        let out = ToolsV3.perps(account)
        XCTAssertEqual(keys(out), ["open_orders", "positions"])
        let positions = out["positions"] as? [[String: Any]] ?? []
        XCTAssertEqual(keys(positions[0]), ["coin", "entry", "leverage", "liquidation", "side", "size", "unrealised_pnl"])
        XCTAssertEqual(positions[0]["side"] as? String, "long")
        let orders = out["open_orders"] as? [[String: Any]] ?? []
        XCTAssertEqual(orders.map { $0["kind"] as? String }, ["limit", "stop_loss", "take_profit", "limit"])
        XCTAssertEqual(keys(orders[0]), ["coin", "id", "kind", "price", "side", "size"])
        XCTAssertEqual(orders[0]["id"] as? String, "8123", "the id is text: it is what cancel_order takes back")
        // A whole-position stop: the price it triggers at (not its slippage cap) and the position's size.
        XCTAssertEqual(keys(orders[1]), ["coin", "id", "kind", "price", "side", "size", "whole_position"])
        XCTAssertEqual(orders[1]["price"] as? Double, 128)
        XCTAssertEqual(orders[1]["size"] as? Double, 10)
        XCTAssertEqual(orders[1]["whole_position"] as? Bool, true)
        // Nothing read: empty lists, and the caller names Hyperliquid as unreachable.
        let empty = ToolsV3.perps(nil)
        XCTAssertEqual((empty["positions"] as? [Any])?.count, 0)
        XCTAssertEqual((empty["open_orders"] as? [Any])?.count, 0)
    }

    // MARK: cancel_order and set_tp_sl

    var solLong: Hyperliquid.Position { .make(coin: "SOL", size: 10, entry: 140.1, pnl: 22.6, leverage: 5, liquidation: 118.4) }
    var ethLimit: Hyperliquid.OpenOrder { .make(coin: "ETH", oid: 8123, isBuy: true, price: 3100, size: 0.5) }
    var solStop: Hyperliquid.OpenOrder {
        .make(coin: "SOL", oid: 8140, isBuy: false, price: 115.2, size: 0, reduceOnly: true, orderType: "Stop Market", isTrigger: true, triggerPx: 128,
              triggerCondition: "Price below 128", isPositionTpsl: true)
    }
    var solTP: Hyperliquid.OpenOrder {
        .make(coin: "SOL", oid: 8141, isBuy: false, price: 153, size: 0, reduceOnly: true, orderType: "Take Profit Market", isTrigger: true, triggerPx: 170,
              triggerCondition: "Price above 170", isPositionTpsl: true)
    }
    var btcLimit: Hyperliquid.OpenOrder { .make(coin: "BTC", oid: 8200, isBuy: false, price: 120_000, size: 0.01) }
    var account: Hyperliquid.Account { .make(accountValue: 250.5, positions: [solLong], orders: [ethLimit, solStop, solTP, btcLimit]) }

    func cancel(_ coin: String, kind: String? = nil, id: String? = nil) -> String {
        switch ToolsV3.cancelPlan(coin: coin, kind: kind, orderID: id, orders: account.orders, positions: account.positions) {
        case .error(let e): return "error: \(e)"
        case .nothing(let note): return "nothing: \(note)"
        case .choose(let sym, let orders): return "choose \(sym) \(orders.map(\.oid))"
        case .cancel(let orders, let text, let warning): return "cancel \(orders.map(\.oid)) \(text)" + (warning.map { " ! \($0)" } ?? "")
        }
    }

    func testCancelPlan() {
        XCTAssertEqual(cancel("ETH"), "cancel [8123] ETH buy limit, 0.5 ETH at $3,100")
        XCTAssertEqual(cancel("eth-perp", kind: "order"), "cancel [8123] ETH buy limit, 0.5 ETH at $3,100")
        // Cancelling the only stop loss leaves the position unprotected, and the card says so.
        XCTAssertEqual(cancel("SOL", kind: "stop_loss"), "cancel [8140] SOL stop loss at $128 ! Without it the SOL long has no stop loss.")
        XCTAssertEqual(cancel("SOL", kind: "take_profit"), "cancel [8141] SOL take profit at $170")
        // Several orders and no kind: a question, never a guess.
        XCTAssertEqual(cancel("SOL"), "choose SOL [8140, 8141]")
        // An id from get_positions settles it, when it is an order of the coin (and the kind) the call names.
        XCTAssertEqual(cancel("SOL", id: "8141"), "cancel [8141] SOL take profit at $170")
        XCTAssertEqual(cancel("SOL", kind: "take_profit", id: "8141"), "cancel [8141] SOL take profit at $170")
        // An id of another coin's order, or of another kind (the stop loss when the take profit was meant): no card.
        XCTAssertTrue(cancel("ETH", id: "8140").hasPrefix("error: Order 8140 is SOL stop loss at $128, not ETH."))
        XCTAssertTrue(cancel("SOL", kind: "take_profit", id: "8140").hasPrefix("error: Order 8140 is SOL stop loss at $128, not a take profit."))
        XCTAssertTrue(cancel("ETH", kind: "stop_loss", id: "8123").hasPrefix("error: Order 8123 is ETH buy limit, 0.5 ETH at $3,100, not a stop loss."))
        XCTAssertEqual(cancel("SOL", id: "999"), "nothing: The user has no open order with id 999. Tell them.")
        // "all" is every plain limit order and never a take profit or a stop loss.
        XCTAssertEqual(cancel("all"), "cancel [8123, 8200] 2 open limit orders (ETH, BTC)")
        XCTAssertTrue(cancel("all", kind: "stop_loss").hasPrefix("error:"))
        XCTAssertEqual(cancel("DOGE"), "nothing: The user has no open DOGE orders. Tell them.")
        XCTAssertEqual(cancel("ETH", kind: "stop_loss"), "nothing: The user has no open ETH stop loss. Tell them.")
        XCTAssertTrue(cancel("SOL", kind: "everything").hasPrefix("error:"))

        let choice = ToolsV3.cancelChoice(sym: "SOL", orders: [solStop, solTP])
        XCTAssertEqual(keys(choice), ["note", "options", "prepared", "question", "status"])
        XCTAssertEqual(choice["status"] as? String, "needs_choice")
        XCTAssertEqual(choice["options"] as? [String], ["stop_loss at $128", "take_profit at $170"])
        XCTAssertEqual(choice["question"] as? String, "Which SOL order? A stop loss at $128 or a take profit at $170.")
        // Two of the same kind: each option carries its id.
        let twoLimits = ToolsV3.cancelChoice(sym: "ETH", orders: [ethLimit, .make(coin: "ETH", oid: 8124, isBuy: true, price: 3000, size: 1)])
        XCTAssertEqual(twoLimits["options"] as? [String], ["limit buy 0.5 at $3,100 (id 8123)", "limit buy 1 at $3,000 (id 8124)"])
        // A second stop still protects: no warning.
        let twoStops = [solStop, Hyperliquid.OpenOrder.make(coin: "SOL", oid: 8150, isBuy: false, price: 108, size: 5, reduceOnly: true, orderType: "Stop Market",
                                                            isTrigger: true, triggerPx: 120)]
        if case .cancel(_, _, let warning) = ToolsV3.cancelPlan(coin: "SOL", kind: nil, orderID: "8140", orders: twoStops, positions: [solLong]) {
            XCTAssertNil(warning)
        } else { XCTFail("the id names one order") }
    }

    func testCoinNames() {
        XCTAssertTrue(ToolsV3.sameCoin("sol", "SOL"))
        XCTAssertTrue(ToolsV3.sameCoin("SOL-PERP", "SOL"))
        XCTAssertTrue(ToolsV3.sameCoin("NVDA", "xyz:NVDA"))
        XCTAssertTrue(ToolsV3.sameCoin("xyz:nvda", "xyz:NVDA"))
        XCTAssertTrue(ToolsV3.sameCoin("PEPE", "kPEPE"))
        XCTAssertFalse(ToolsV3.sameCoin("SO", "SOL"))
        XCTAssertFalse(ToolsV3.sameCoin("", "SOL"))
        XCTAssertEqual(ToolsV3.position("sol", in: [solLong])?.coin, "SOL")
        XCTAssertNil(ToolsV3.position("ETH", in: [solLong]))
        XCTAssertNil(ToolsV3.position("SOL", in: [.make(coin: "SOL", size: 0, entry: 140)]), "a closed position is no position")
        // The same ticker open on two venues: the full name picks one, a bare ticker is a question back.
        let nvda: [Hyperliquid.Position] = [.make(coin: "xyz:NVDA", size: 1, entry: 180), .make(coin: "flx:NVDA", size: 2, entry: 181)]
        XCTAssertEqual(ToolsV3.positionClash("NVDA", in: nvda), ["xyz:NVDA", "flx:NVDA"])
        XCTAssertEqual(ToolsV3.position("flx:nvda", in: nvda)?.coin, "flx:NVDA")
        XCTAssertTrue(ToolsV3.positionClash("flx:NVDA", in: nvda).isEmpty)
        XCTAssertTrue(ToolsV3.positionClash("SOL", in: [solLong]).isEmpty)
    }

    func testStopsMustSitOnTheRightSide() {
        // A long: stop below the price, take profit above. The sentence carries the price.
        XCTAssertNil(ToolsV3.wrongSide(long: true, takeProfit: 170, stopLoss: 128, mark: 142.37))
        XCTAssertEqual(ToolsV3.wrongSide(long: true, takeProfit: nil, stopLoss: 150, mark: 142.37),
                       "A stop loss for a long must be below the current price (142.37).")
        XCTAssertEqual(ToolsV3.wrongSide(long: true, takeProfit: 130, stopLoss: nil, mark: 142.37),
                       "A take profit for a long must be above the current price (142.37).")
        // A short: the other way round.
        XCTAssertNil(ToolsV3.wrongSide(long: false, takeProfit: 120, stopLoss: 150, mark: 142.37))
        XCTAssertEqual(ToolsV3.wrongSide(long: false, takeProfit: nil, stopLoss: 130, mark: 142.37),
                       "A stop loss for a short must be above the current price (142.37).")
        XCTAssertEqual(ToolsV3.wrongSide(long: false, takeProfit: 150, stopLoss: nil, mark: 142.37),
                       "A take profit for a short must be below the current price (142.37).")
        XCTAssertNotNil(ToolsV3.wrongSide(long: true, takeProfit: nil, stopLoss: 0, mark: 142.37))
        XCTAssertNotNil(ToolsV3.wrongSide(long: true, takeProfit: nil, stopLoss: -5, mark: 142.37))

        // A new stop takes the place of the old one, and the result says which.
        let old = ToolsV3.replaced(coin: "SOL", takeProfit: false, stopLoss: true, orders: account.orders)
        XCTAssertEqual(old.map(\.oid), [8140])
        XCTAssertEqual(ToolsV3.replacedText(old), "stop loss at $128")
        XCTAssertEqual(ToolsV3.replacedText(ToolsV3.replaced(coin: "SOL", takeProfit: true, stopLoss: true, orders: account.orders)),
                       "stop loss at $128 and take profit at $170")
        XCTAssertNil(ToolsV3.replacedText(ToolsV3.replaced(coin: "ETH", takeProfit: true, stopLoss: true, orders: account.orders)), "a limit order is never replaced")
        XCTAssertEqual(ToolsV3.positionText(solLong), "SOL long, 10 SOL")
    }

    // MARK: create_automation

    func testAutomationPlan() {
        XCTAssertEqual(ToolsV3.automationPlan(name: "Morning SOL check", prompt: "Tell me the SOL price and my open positions.", schedule: "every morning at 8", existing: 0),
                       .ok(name: "Morning SOL check", trigger: "Every day 08:00", schedule: "Every day at 08:00", prompt: "Tell me the SOL price and my open positions."))
        XCTAssertEqual(ToolsV3.automationPlan(name: "BTC watch", prompt: "Tell me the BTC price and the 24h change.", schedule: "every 5 minutes", existing: 3),
                       .ok(name: "BTC watch", trigger: "Every 5 minutes", schedule: "Every 5 minutes", prompt: "Tell me the BTC price and the 24h change."))
        XCTAssertEqual(ToolsV3.automationPlan(name: "Week", prompt: "Review my week.", schedule: "every Friday at 18:00", existing: 0),
                       .ok(name: "Week", trigger: "Every Friday 18:00", schedule: "Every Friday at 18:00", prompt: "Review my week."))
        XCTAssertEqual(ToolsV3.scheduleText("Every hour"), "Every hour")
        // A schedule Hermit can't plan is an error with examples, not an automation that never runs.
        XCTAssertEqual(ToolsV3.automationPlan(name: "A", prompt: "Check ETH.", schedule: "every 2 hours", existing: 0), .error(ToolsV3.badSchedule))
        XCTAssertEqual(ToolsV3.automationPlan(name: "A", prompt: "Check ETH.", schedule: "whenever it feels right", existing: 0), .error(ToolsV3.badSchedule))
        XCTAssertTrue(ToolsV3.badSchedule.hasPrefix("I couldn't read that schedule."))
        // The shortest repeat from chat is every 5 minutes, and ten automations is the most.
        XCTAssertEqual(ToolsV3.automationPlan(name: "A", prompt: "Check ETH.", schedule: "every minute", existing: 0), .blocked("The shortest repeat is every 5 minutes."))
        XCTAssertEqual(ToolsV3.automationPlan(name: "A", prompt: "Check ETH.", schedule: "every 2 minutes", existing: 0), .blocked("The shortest repeat is every 5 minutes."))
        XCTAssertEqual(ToolsV3.automationPlan(name: "A", prompt: "Check ETH.", schedule: "every morning at 8", existing: 10),
                       .blocked("You already have 10 automations. Delete one in Automations first."))
        XCTAssertEqual(ToolsV3.automationPlan(name: "", prompt: "Check ETH.", schedule: "every morning at 8", existing: 0), .error("Needs name, prompt and schedule"))
        XCTAssertEqual(ToolsV3.blocked(["x"])["status"] as? String, "blocked")
    }

    // MARK: schedule_payment

    func testParseWhen() {
        func when(_ s: String, at: Date? = nil) -> String? { ToolsV3.parseWhen(s, now: at ?? now, calendar: utc).map { ToolsV3.stamp($0, calendar: utc) } }
        XCTAssertEqual(when("Dec 1 9:00"), "2026-12-01 09:00")
        XCTAssertEqual(when("Dec 1"), "2026-12-01 09:00", "09:00 when no time is given")
        XCTAssertEqual(when("December 1st, 2026 at 6pm"), "2026-12-01 18:00")
        XCTAssertEqual(when("1 Dec 2026 14:30"), "2026-12-01 14:30")
        XCTAssertEqual(when("2026-12-01"), "2026-12-01 09:00")
        XCTAssertEqual(when("2026-12-01 14:30"), "2026-12-01 14:30")
        XCTAssertEqual(when("2026-12-01T14:30:00Z"), "2026-12-01 14:30")
        XCTAssertEqual(when("tomorrow 18:00"), "2026-11-12 18:00")
        XCTAssertEqual(when("tomorrow"), "2026-11-12 09:00")
        XCTAssertEqual(when("today"), "2026-11-11 09:00")
        XCTAssertEqual(when("today", at: date(2026, 11, 11, 15, 10)), "2026-11-11 16:00", "09:00 has passed: the next full hour")
        XCTAssertEqual(when("tonight"), "2026-11-11 20:00")
        XCTAssertEqual(when("next friday"), "2026-11-13 09:00")
        XCTAssertEqual(when("friday 10:00"), "2026-11-13 10:00")
        XCTAssertEqual(when("wednesday"), "2026-11-18 09:00", "today is Wednesday: the next one")
        XCTAssertEqual(when("in 3 days"), "2026-11-14 09:00")
        XCTAssertEqual(when("in 3 days at 18:00"), "2026-11-14 18:00")
        XCTAssertEqual(when("in 2 weeks"), "2026-11-25 09:00")
        XCTAssertEqual(when("in 1 month"), "2026-12-11 09:00")
        XCTAssertEqual(when("next month"), "2026-12-11 09:00")
        XCTAssertEqual(when("the 15th"), "2026-11-15 09:00")
        XCTAssertEqual(when("the 5th"), "2026-12-05 09:00", "this month's has passed")
        XCTAssertEqual(when("Nov 1"), "2027-11-01 09:00", "a month and day with no year is the next one to come")
        // An explicit date in the past comes back as it is, for the caller to refuse.
        XCTAssertEqual(when("2020-01-01"), "2020-01-01 09:00")
        XCTAssertNil(when("soon"))
        XCTAssertNil(when(""))
        XCTAssertNil(when("Feb 30"))
        XCTAssertNil(when("25:99"))
    }

    func testPaymentPlan() {
        let a = Payee(name: "Alice", addr: alice)
        let evm: [ChainKind: [Chain]] = [.evm: [.base, .arbitrum], .solana: [.solana]]
        func plan(_ payee: String, amount: String? = "200", symbol: String = "USDC", when: String = "Dec 1 9:00", chain: String? = nil, repeats: String? = "monthly",
                  payees: [Payee]? = nil, held: [String: Double] = ["base": 120.5]) -> ToolsV3.PaymentPlan {
            ToolsV3.paymentPlan(payee: payee, amountText: amount, symbol: symbol, when: when, chain: chain, repeats: repeats, payees: payees ?? [a],
                                candidates: evm, held: held, now: now, calendar: utc)
        }
        // A saved contact, held on one network: that network, and a payment that is only a reminder.
        guard case .ok(let p, let network, let shown) = plan("alice") else { return XCTFail("a saved contact and a clear date") }
        XCTAssertEqual(shown, "Alice")
        XCTAssertEqual(network.id, "base")
        XCTAssertEqual(p.payee, "Alice")
        XCTAssertEqual(p.addr, alice)
        XCTAssertEqual(p.payeeID, a.id)
        XCTAssertEqual(p.amount, 200)
        XCTAssertEqual(p.sendAmount, "200", "the amount as the model passed it")
        XCTAssertEqual(p.token, "USDC")
        XCTAssertEqual(p.repeats, .monthly)
        XCTAssertEqual(p.chain, "base")
        XCTAssertEqual(ToolsV3.stamp(p.next, calendar: utc), "2026-12-01 09:00")
        XCTAssertFalse(p.paused)

        // A typed address: shown shortened, in full on the card and in the payment.
        guard case .ok(let typed, _, let shortened) = plan(other, repeats: nil) else { return XCTFail("a typed address") }
        XCTAssertEqual(shortened, "0x5290… 9EE7")
        XCTAssertEqual(typed.addr, other)
        XCTAssertEqual(typed.repeats, .once)
        XCTAssertNil(typed.payeeID)

        // Held on two networks and none named: a question with what is where.
        guard case .chooseChain(let sym, let options) = plan("Alice", held: ["base": 120.5, "arbitrum": 40]) else { return XCTFail("two networks hold it") }
        let question = ToolsV3.chainChoice(symbol: sym, options: options)
        XCTAssertEqual(Set(question.keys), ["note", "options", "prepared", "question", "status"])
        XCTAssertEqual(question["status"] as? String, "needs_chain")
        XCTAssertEqual(question["options"] as? [String], ["base", "arbitrum"])
        XCTAssertEqual(question["question"] as? String, "Which network should the payment use? You hold USDC on Base and Arbitrum (Base: 120.5, Arbitrum: 40).")
        // Named: that one. One that can't carry it: an error.
        if case .ok(_, let n, _) = plan("Alice", chain: "arbitrum", held: ["base": 120.5, "arbitrum": 40]) { XCTAssertEqual(n.id, "arbitrum") } else { XCTFail("the named network") }
        if case .error = plan("Alice", chain: "solana") {} else { XCTFail("USDC to a 0x address doesn't go out on Solana") }

        // Who: unknown, or more than one.
        if case .payeeNotFound(let name) = plan("Bob") { XCTAssertEqual(name, "Bob") } else { XCTFail("Bob isn't saved") }
        // Only what ToolGuard checks as an address is paid as one. A NEAR account the guard reads as a name ("bob.tg") is
        // looked up among the contacts, never scheduled as an address the user didn't type.
        XCTAssertFalse(ToolGuard.namesAddress("bob.tg"))
        if case .payeeNotFound(let name) = plan("bob.tg", symbol: "NEAR") { XCTAssertEqual(name, "bob.tg") } else { XCTFail("bob.tg is not a saved name") }
        XCTAssertTrue(ToolGuard.namesAddress("Bob.NEAR"))
        let two = [Payee(name: "Alice Smith", addr: alice), Payee(name: "Alice Chen", addr: other)]
        if case .chooseContact(let name, let labels) = plan("Alice", payees: two) {
            XCTAssertEqual(name, "Alice")
            XCTAssertEqual(labels, ["Alice Smith", "Alice Chen"])
        } else { XCTFail("two Alices") }

        // When: the past and the unreadable are errors, each with its own words.
        if case .error(let e) = plan("Alice", when: "2020-01-01") { XCTAssertEqual(e, "That date is in the past.") } else { XCTFail("the past") }
        if case .error(let e) = plan("Alice", when: "soon") { XCTAssertTrue(e.hasPrefix("I couldn't read that date.")) } else { XCTFail("unreadable") }
        // What: a real amount, a token Payments knows, a repeat it has.
        if case .error = plan("Alice", amount: nil) {} else { XCTFail("no amount") }
        if case .error = plan("Alice", symbol: "DOGE") {} else { XCTFail("not a token Payments sends") }
        if case .error = plan("Alice", repeats: "daily") {} else { XCTFail("no daily repeat") }
    }

    // MARK: get_portfolio and get_activity

    func testPortfolio() {
        let parts = [ToolsV3.Part(place: "Wallet", what: "USDC on Base", usd: 120.5), ToolsV3.Part(place: "Wallet", what: "SOL", usd: 116.74),
                     ToolsV3.Part(place: "Wallet", what: "USDC on Arbitrum", usd: 40), ToolsV3.Part(place: "Spot tokens", what: "WIF", usd: 10.96),
                     ToolsV3.Part(place: "Aave", what: "USDC on Base", usd: 52.31), ToolsV3.Part(place: "Hyperliquid", what: "Account value", usd: 250.5)]
        let out = ToolsV3.portfolio(wallet: "Main", parts: parts, unreachable: [])
        XCTAssertEqual(keys(out), ["by_place", "top", "total_usd", "wallet"])
        let places = out["by_place"] as? [[String: Any]] ?? []
        XCTAssertEqual(places.map { $0["place"] as? String }, ["Wallet", "Spot tokens", "Aave", "Hyperliquid"])
        XCTAssertEqual(places.first?["usd"] as? Double ?? 0, 277.24, accuracy: 1e-9)
        XCTAssertEqual(out["total_usd"] as? Double ?? 0, 591.01, accuracy: 1e-9)
        // The total is the sum of the places.
        XCTAssertEqual(places.reduce(0) { $0 + ($1["usd"] as? Double ?? 0) }, out["total_usd"] as? Double ?? 0, accuracy: 0.005)
        let top = out["top"] as? [[String: Any]] ?? []
        XCTAssertEqual(top.map { $0["what"] as? String }, ["Account value", "USDC on Base", "SOL"])
        XCTAssertEqual(keys(top[0]), ["place", "usd", "what"])

        let empty = ToolsV3.portfolio(wallet: "Main", parts: [], unreachable: [])
        XCTAssertEqual((empty["by_place"] as? [Any])?.count, 0)
        XCTAssertEqual(empty["total_usd"] as? Double, 0)
        // A network that didn't answer is named, so the total isn't passed off as complete.
        let short = ToolsV3.portfolio(wallet: "Main", parts: [parts[0]], unreachable: ["bnb"])
        XCTAssertEqual(keys(short), ["by_place", "top", "total_usd", "unreachable", "wallet"])
        XCTAssertEqual(short["unreachable"] as? [String], ["bnb"])
        XCTAssertEqual(ToolsV3.holdingName("SOL", .solana), "SOL")
        XCTAssertEqual(ToolsV3.holdingName("ETH", .base), "ETH on Base")
    }

    func testActivity() {
        func item(_ id: String, _ what: String, _ status: String, _ minute: Int) -> ActivityItem {
            ActivityItem(id: id, kind: .sent, chainID: "base", walletID: "w", what: what, detail: "", amount: nil, symbol: "USDC",
                         date: date(2026, 11, 10, 14, minute), tx: nil, status: status, link: nil)
        }
        let items = [item("a", "Sent 0.5 USDC to 0x12…ab", "Confirmed", 32), item("b", "Swap 1 USDC on Solana to USDC on Base", "Waiting for your deposit", 41),
                     item("c", "Bought 4.82 WIF with 10 USDC", "Failed", 5)]
        let out = ToolsV3.activity(items, limit: 10, calendar: utc)
        XCTAssertEqual(keys(out), ["activity", "in_progress", "note"])
        let rows = out["activity"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.map { $0["status"] as? String }, ["in_progress", "confirmed", "failed"], "newest first")
        XCTAssertEqual(keys(rows[0]), ["status", "time", "what"])
        XCTAssertEqual(rows[0]["time"] as? String, "2026-11-10 14:41")
        XCTAssertEqual(out["in_progress"] as? Int, 1)
        XCTAssertEqual(out["note"] as? String, "Reviews the user has not approved yet do not appear here.")
        XCTAssertEqual((ToolsV3.activity(items, limit: 1, calendar: utc)["activity"] as? [Any])?.count, 1)
        let none = ToolsV3.activity([], limit: 10, calendar: utc)
        XCTAssertEqual(none["note"] as? String, "No activity yet. Reviews the user has not approved yet do not appear here.")
        XCTAssertEqual(none["in_progress"] as? Int, 0)
        // Only "Confirmed" (or a delivered swap) reads as confirmed: everything unclear is still in progress.
        XCTAssertEqual(ToolsV3.activityStatus("Delivered"), "confirmed")
        XCTAssertEqual(ToolsV3.activityStatus("Refunded"), "failed")
        XCTAssertEqual(ToolsV3.activityStatus("Pending"), "in_progress")
        XCTAssertEqual(ToolsV3.activityStatus("Solvers are filling the swap on NEAR Intents"), "in_progress")
    }

    // MARK: Through the toolbox

    /// The tools that need no wallet and no network answer through the toolbox's own entry, with honest results.
    func testToolboxRunsTheOfflineTools() async throws {
        // Snapshot mode keeps the stores off the disk, like the other logic tests.
        let was = SnapshotMode.active
        SnapshotMode.active = true
        defer { SnapshotMode.active = was }
        let box = HermitToolbox.onDevice
        let page = await box.run("open_page", arguments: #"{"page": "earn", "tab": "positions"}"#)
        XCTAssertEqual(try object(page)["status"] as? String, "button_shown")
        XCTAssertEqual(page.action?.open, "page:earn:positions")
        let secret = await box.run("open_page", arguments: #"{"page": "wallets", "tab": "recovery phrase"}"#)
        XCTAssertEqual(try object(secret)["error"] as? String, "That page can't be opened from chat.")

        // add_contact: a card, nothing saved, and the result says so.
        let draft = await box.run("add_contact", arguments: #"{"name": "Zed Test", "address": "\#(alice)"}"#)
        let v = try object(draft)
        XCTAssertEqual(keys(v), ["address", "executed", "kind", "name", "network", "note", "status"])
        XCTAssertEqual(v["status"] as? String, "card_opened")
        XCTAssertEqual(v["executed"] as? Bool, false)
        XCTAssertEqual(v["address"] as? String, alice)
        XCTAssertEqual(v["network"] as? String, "EVM")
        XCTAssertEqual(v["note"] as? String, "Waiting for the user to tap Save. The card shows the full address; nothing is sent.")
        guard case .confirm(let card)? = draft.card else { return XCTFail("a confirm card") }
        XCTAssertEqual(card.confirm, "Save")
        XCTAssertTrue(card.rows.contains(["Address", alice]), "the card shows the address in full")
        XCTAssertNil(draft.action, "a card, not a review")
        XCTAssertEqual(ToolCards.shared.state(card.id), .waiting)
        XCTAssertNil(PaymentsStore.shared.payee(named: "Zed Test"), "nothing is saved by the tool call")
        ToolCards.shared.dismiss(card.id)
        XCTAssertNil(ToolCards.shared.state(card.id))
        XCTAssertNil(PaymentsStore.shared.payee(named: "Zed Test"))
        let bad = await box.run("add_contact", arguments: #"{"name": "Zed Test", "address": "0x12"}"#)
        XCTAssertEqual(try object(bad)["error"] as? String, "That doesn't look like a valid address.")
        XCTAssertNil(bad.card)

        // create_automation: a card with the schedule as it will run and the exact prompt; or an honest no.
        let auto = await box.run("create_automation", arguments: #"{"name": "Morning SOL check", "prompt": "Tell me the SOL price.", "schedule": "every morning at 8"}"#)
        let av = try object(auto)
        XCTAssertEqual(keys(av), ["executed", "kind", "name", "note", "prompt", "schedule", "status"])
        XCTAssertEqual(av["schedule"] as? String, "Every day at 08:00")
        XCTAssertEqual(av["status"] as? String, "card_opened")
        XCTAssertEqual(av["note"] as? String, "Waiting for the user to tap Create. Nothing is scheduled yet.")
        guard case .confirm(let autoCard)? = auto.card else { return XCTFail("a confirm card") }
        XCTAssertTrue(autoCard.rows.contains(["Asks Hermit", "Tell me the SOL price."]))
        ToolCards.shared.dismiss(autoCard.id)
        let fast = await box.run("create_automation", arguments: #"{"name": "Fast", "prompt": "Tell me the SOL price.", "schedule": "every minute"}"#)
        XCTAssertEqual(try object(fast)["status"] as? String, "blocked")
        XCTAssertNil(fast.card)
        let unreadable = await box.run("create_automation", arguments: #"{"name": "Odd", "prompt": "Tell me the SOL price.", "schedule": "every 2 hours"}"#)
        XCTAssertEqual(try object(unreadable)["prepared"] as? Bool, false)
        XCTAssertNotNil(try object(unreadable)["error"])

        // open_app refuses anything that isn't a web address, and says when it doesn't know a name.
        let script = await box.run("open_app", arguments: #"{"url": "javascript:alert(1)"}"#)
        XCTAssertEqual(try object(script)["error"] as? String, "Only http and https addresses can be opened.")
        XCTAssertNil(script.action)
        let unknown = await box.run("open_app", arguments: #"{"name": "Zzzzqqq"}"#)
        XCTAssertEqual(try object(unknown)["status"] as? String, "not_found")
        XCTAssertNil(HermitToolbox.webURL("data:text/html,hi"))
        XCTAssertNil(HermitToolbox.webURL("file:///etc/passwd"))
        XCTAssertEqual(HermitToolbox.webURL("uniswap.org")?.absoluteString, "https://uniswap.org")

        // A name that isn't a tool is still an error, not a crash.
        let nope = await box.run("approve_everything", arguments: "{}")
        XCTAssertEqual(try object(nope)["error"] as? String, "Unknown tool approve_everything")
    }
}
