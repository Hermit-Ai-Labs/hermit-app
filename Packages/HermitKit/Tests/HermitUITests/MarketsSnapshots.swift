#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import HermitUI
import HermitCore

/// Trade, Earn and Explore at Mac and iPhone width. Snapshots can't reach the network, so each screen is drawn twice:
/// as it looks while loading, then filled with the fixture below (test-only numbers, never shipped in the app).
/// The names start with testPages so `macbuild <wt> shots trade,earn,explore` picks them up.
@MainActor
final class MarketsSnapshots: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        HermitFonts.register()
        SnapshotMode.active = true
    }

    private var dir: URL {
        let d = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func wanted(_ route: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["SNAPSHOT_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { $0 == route }
    }

    private func shoot<V: View>(_ view: V, _ name: String, _ size: CGSize) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top).background(Color.white)
            .foregroundStyle(Theme.text).environment(\.colorScheme, .light))
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.contentView = host
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        win.orderOut(nil)
    }

    /// Page tabs at both widths.
    private func pages<V: View>(_ route: String, _ tabs: [String], _ suffix: String, _ make: @escaping () -> V) throws {
        for t in tabs {
            let m = AppModel(); m.tabRequest = t
            try shoot(make().environment(m), "tab-\(route)-\(t)\(suffix)", CGSize(width: 1072, height: 1500))
            let p = AppModel(); p.tabRequest = t
            try shoot(make().environment(p), "phone-\(route)-\(t)\(suffix)", CGSize(width: 390, height: 1700))
        }
    }

    /// A market screen on its own, padded like a page.
    private func part<V: View>(_ v: V, _ name: String) throws {
        try shoot(v.padding(32).environment(AppModel()), "part-\(name)", CGSize(width: 1072, height: 1100))
        try shoot(v.padding(16).environment(AppModel()), "phone-part-\(name)", CGSize(width: 390, height: 1500))
    }

    func testPagesMarkets() throws {
        let trade = wanted("trade"), earn = wanted("earn"), explore = wanted("explore")
        guard trade || earn || explore else { return }
        // Loading: what you see before the first response.
        if trade {
            try pages("trade", ["positions", "markets", "strategies"], "") { TradePage() }
            try part(TradeSpot(), "spot")
        }
        if earn { try pages("earn", ["positions", "defi", "arb", "airdrops", "reverse"], "") { EarnPage() } }

        // Filled with the fixture.
        Fixture.fill()
        if trade {
            try pages("trade", ["markets"], "-data") { TradePage() }
            try part(TradeSpot(), "spot-data")
            try part(TradeMemes(), "memes-data")
            try part(TradePredictions(), "predict-data")
        }
        if earn { try pages("earn", ["defi", "arb"], "-data") { EarnPage() } }
        if explore { try pages("explore", ["new", "trending", "all"], "-data") { ExplorePage() } }
    }
}

/// Test-only numbers so the filled layouts can be checked offline. Shapes match the live APIs; values are arbitrary.
@MainActor
private enum Fixture {
    static func fill() {
        let f = MarketFeed.shared
        let perps: [TradeData.Perp] = [
            .init(coin: "BTC", px: 81654.5, prev: 80703, funding: 0.0000125, oi: 43557, vol: 2.68e9, maxLev: 40),
            .init(coin: "ETH", px: 3120.4, prev: 3075.2, funding: 0.0000094, oi: 512000, vol: 1.21e9, maxLev: 25),
            .init(coin: "SOL", px: 187.21, prev: 190.05, funding: -0.0000031, oi: 2.9e6, vol: 4.1e8, maxLev: 20),
            .init(coin: "HYPE", px: 93.437, prev: 88.9, funding: 0.0000271, oi: 1.1e7, vol: 6.2e8, maxLev: 10),
            .init(coin: "xyz:TSLA", px: 406.5, prev: 401.1, funding: 0.0000062, oi: 9456, vol: 3.6e8, maxLev: 10),
            .init(coin: "xyz:GOLD", px: 4012.1, prev: 3998.4, funding: 0.0000010, oi: 2100, vol: 1.1e8, maxLev: 20),
            .init(coin: "DOGE", px: 0.18342, prev: 0.18001, funding: 0.0000412, oi: 1.9e8, vol: 9.1e7, maxLev: 10),
        ]
        f.perps = Dictionary(uniqueKeysWithValues: perps.map { ($0.coin, $0) })
        f.perpState = .ready
        let tick: [String: TradeData.Ticker] = [
            "BTC": .init(px: 81689.96, ch: 1.35, vol: 1.24e9, high: 81788, low: 79710), "ETH": .init(px: 3121.1, ch: 1.9, vol: 8.2e8, high: 3140, low: 3051),
            "SOL": .init(px: 187.3, ch: -1.5, vol: 3.1e8, high: 191, low: 185), "BNB": .init(px: 1102.4, ch: 0.4, vol: 2.2e8, high: 1110, low: 1090),
            "HYPE": .init(px: 93.45, ch: 5.1, vol: 1.6e8, high: 94.2, low: 88.1), "XRP": .init(px: 2.4123, ch: -0.8, vol: 2.9e8, high: 2.45, low: 2.39),
            "PEPE": .init(px: 0.00001912, ch: 7.2, vol: 4.1e8, high: 0.0000195, low: 0.0000176), "WIF": .init(px: 1.4213, ch: -3.2, vol: 1.2e8, high: 1.5, low: 1.39),
            "PENGU": .init(px: 0.03341, ch: 12.4, vol: 2.4e8, high: 0.034, low: 0.0295), "BONK": .init(px: 0.00002281, ch: 2.2, vol: 6.1e7, high: 0.000023, low: 0.000022),
            "DOGE": .init(px: 0.1834, ch: 1.9, vol: 6.6e8, high: 0.186, low: 0.179), "SHIB": .init(px: 0.00001321, ch: 0.6, vol: 9.2e7, high: 0.0000134, low: 0.000013),
        ]
        f.tickers = tick
        // Drawn at 100 and scaled, since Candle.series floors prices at 0.0001.
        f.minis = tick.mapValues { t in
            Candle.series(seed: Int(t.vol) % 997, count: 24, start: 100, vol: 0.01).map { Candle(o: $0.o * t.px / 100, h: $0.h * t.px / 100, l: $0.l * t.px / 100, c: $0.c * t.px / 100) }
        }
        f.tickerState = .ready
        f.predictions = [
            .init(id: "1", q: "Will the Democratic Party control the House after the 2026 Midterm elections?", slug: "", outcomes: ["Yes", "No"], prices: [0.93, 0.07], vol24: 1.88e6, ends: Date().addingTimeInterval(6 * 86400)),
            .init(id: "2", q: "Erste Bank Open: Cameron Norrie vs Daniil Medvedev", slug: "", outcomes: ["Cameron Norrie", "Daniil Medvedev"], prices: [0.31, 0.69], vol24: 1.6e6, ends: Date().addingTimeInterval(7 * 86400)),
            .init(id: "3", q: "Bitcoin above $85,000 on November 7?", slug: "", outcomes: ["Yes", "No"], prices: [0.42, 0.58], vol24: 9.4e5, ends: Date().addingTimeInterval(9 * 86400)),
        ]
        f.predState = .ready

        let y = YieldsFeed.shared
        y.pools = [
            .init(pool: "a", chain: "Ethereum", project: "lido", symbol: "STETH", tvlUsd: 2.27e10, apy: 2.24, apyBase: 2.24, apyReward: nil, apyMean30d: 2.26, stablecoin: false, ilRisk: "no", exposure: "single", poolMeta: nil),
            .init(pool: "b", chain: "Ethereum", project: "sky-lending", symbol: "SUSDS", tvlUsd: 4.69e9, apy: 3.8, apyBase: 3.8, apyReward: nil, apyMean30d: 3.9, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: nil),
            .init(pool: "c", chain: "Ethereum", project: "maple", symbol: "USDC", tvlUsd: 2.56e9, apy: 5.11, apyBase: 5.11, apyReward: nil, apyMean30d: 5.2, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: "Syrup USDC"),
            .init(pool: "d", chain: "Ethereum", project: "ethena-usde", symbol: "SUSDE", tvlUsd: 1.19e9, apy: 5.06, apyBase: 5.06, apyReward: nil, apyMean30d: 5.4, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: "7 days unstaking"),
            .init(pool: "e", chain: "Solana", project: "jito-liquid-staking", symbol: "JITOSOL", tvlUsd: 1.06e9, apy: 4.93, apyBase: 4.93, apyReward: nil, apyMean30d: 4.9, stablecoin: false, ilRisk: "no", exposure: "single", poolMeta: nil),
            .init(pool: "f", chain: "Arbitrum", project: "usd-ai", symbol: "SUSDAI", tvlUsd: 5.56e8, apy: 6.24, apyBase: 6.24, apyReward: nil, apyMean30d: 6.5, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: "30d unlock"),
            .init(pool: "g", chain: "Base", project: "morpho-blue", symbol: "SPARKUSDC", tvlUsd: 4.95e8, apy: 5.55, apyBase: 4.9, apyReward: 0.65, apyMean30d: 5.3, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: nil),
            .init(pool: "h", chain: "Solana", project: "jupiter-lend", symbol: "USDC", tvlUsd: 4.77e8, apy: 6.07, apyBase: 5.2, apyReward: 0.87, apyMean30d: 6.1, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: "Earn"),
            .init(pool: "i", chain: "BSC", project: "venus-core-pool", symbol: "USDT", tvlUsd: 3.1e8, apy: 3.42, apyBase: 3.1, apyReward: 0.32, apyMean30d: 3.6, stablecoin: true, ilRisk: "no", exposure: "single", poolMeta: nil),
        ]
        y.state = .ready

        let e = ExploreStore.shared
        e.tvl = ["parent#hyperliquid": .init(tvl: 8.6e9, change7d: 4.2), "parent#aave": .init(tvl: 1.74e10, change7d: -1.1),
                 "parent#pendle": .init(tvl: 1.06e9, change7d: 2.3), "parent#ethena": .init(tvl: 5.0e9, change7d: -3.9),
                 "lido": .init(tvl: 2.26e10, change7d: 0.8), "parent#morpho": .init(tvl: 1.13e10, change7d: 6.1),
                 "jupiter-lend": .init(tvl: 9.9e8, change7d: 9.4), "usd-ai": .init(tvl: 2.7e8, change7d: 12.5), "parent#kinetiq": .init(tvl: 1.0e9, change7d: 3.3)]
        e.state = .ready
    }
}
#endif
