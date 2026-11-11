import XCTest
@testable import HermitUI
import HermitWallet

/// Explore search and Enter, the Earn feed filter and the Aave pre-flight read. No network.
@MainActor
final class EarnExploreLogicTests: XCTestCase {
    func testEnterOpensOnlyATypoOfAName() {
        let list = ExploreData.dapps
        for q in ["apple", "metamask", "sell eth", "lens", "zerion", "guru", "mantle", "curve", "what is aave"] {
            XCTAssertTrue(ExploreData.search(q, in: list).isEmpty, q)
            XCTAssertNil(ExploreData.closeMatch(q, in: list), q)
        }
        XCTAssertEqual(ExploreData.closeMatch("uniswp", in: list)?.name, "Uniswap")
        XCTAssertEqual(ExploreData.closeMatch("morfo", in: list)?.name, "Morpho")
        XCTAssertEqual(ExploreData.closeMatch("polymrket", in: list)?.name, "Polymarket")
    }

    func testSearchMatchesWordStartsAndChain() {
        let names = { (q: String) -> Set<String> in Set(ExploreData.search(q, in: ExploreData.dapps).map(\.name)) }
        XCTAssertFalse(names("ai").contains("Plasma"))
        XCTAssertTrue(names("ai").contains("Virtuals"))
        XCTAssertFalse(names("base").contains("Coinbase Sales"))
        XCTAssertTrue(names("solana").isSuperset(of: ["Jupiter", "Kamino", "Pump.fun"]))
        XCTAssertEqual(names("near"), ["NEAR Intents", "Rhea Finance", "Meta Pool"])
    }

    func testParentChangeNeedsMembersToMatchTheTotal() throws {
        let json = """
        [{"slug":"a1","parentProtocol":"parent#a","tvl":100,"change_7d":10},
         {"slug":"a2","parentProtocol":"parent#a","tvl":50,"change_7d":null,"excludeTvlFromParent":true},
         {"slug":"b1","parentProtocol":"parent#b","tvl":130,"change_7d":0}]
        """
        let c = try ExploreAPI.parseChanges(Data(json.utf8), keys: ["parent#a", "parent#b"], totals: ["parent#a": 100, "parent#b": 100])
        XCTAssertEqual(c["parent#a"] ?? 0, 10, accuracy: 0.0001)
        XCTAssertNil(c["parent#b"])
        XCTAssertEqual(ExploreAPI.slug("parent#astherus"), "aster")
        XCTAssertEqual(ExploreAPI.slug("lido"), "lido")
    }

    func testFeedKeepsUmbrellaOutOfDepositAndAddsUSDT0() throws {
        let json = """
        {"data":[
         {"pool":"m","chain":"Ethereum","project":"aave-v3","symbol":"USDC","tvlUsd":160000000,"apy":4.18,"apyBase":4.18,"stablecoin":true,"exposure":"single","underlyingTokens":["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"]},
         {"pool":"u","chain":"Ethereum","project":"aave-v3","symbol":"USDC","tvlUsd":55000000,"apy":5.95,"apyBase":4.18,"apyReward":1.77,"stablecoin":true,"exposure":"single","poolMeta":"Umbrella"},
         {"pool":"b","chain":"Base","project":"aave-v3","symbol":"USDC","tvlUsd":15000000,"apy":7.37,"apyBase":5.57,"apyReward":1.79,"stablecoin":true,"exposure":"single","underlyingTokens":["0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"]},
         {"pool":"t","chain":"Arbitrum","project":"aave-v3","symbol":"USD₮0","tvlUsd":5000000,"apy":3.5,"apyBase":3.5,"stablecoin":false,"exposure":"single","underlyingTokens":["0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9"]},
         {"pool":"x","chain":"Arbitrum","project":"aave-v3","symbol":"USDC","tvlUsd":2000000,"apy":3,"apyBase":3,"stablecoin":true,"exposure":"single","underlyingTokens":["0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8"]}
        ]}
        """
        let pools = try EarnAPI.parse(Data(json.utf8))
        let byID = Dictionary(uniqueKeysWithValues: pools.map { ($0.pool, $0) })
        XCTAssertNotNil(byID["m"].flatMap { EarnRoute.aave($0) })
        XCTAssertNotNil(byID["u"])
        XCTAssertNil(byID["u"].flatMap { EarnRoute.aave($0) })
        XCTAssertEqual(byID["b"]?.depositAPY ?? 0, 5.57, accuracy: 0.0001)
        XCTAssertEqual(byID["t"]?.symbol, "USDT0")
        XCTAssertNotNil(byID["t"].flatMap { EarnRoute.aave($0) })
        XCTAssertNil(byID["x"])
    }

    func testReserveFlagsStopFrozenAndPaused() throws {
        var out = [UInt8](repeating: 0, count: 32 * 12)
        out[24] = 0x01            // active
        out[95] = 1               // a tiny rate
        out[32 * 8 + 31] = 1      // aToken
        XCTAssertNoThrow(try AaveReserveCheck.supplyAPY(reserveData: out, symbol: "USDC", chain: "Base"))
        out[24] = 0x03            // frozen
        XCTAssertThrowsError(try AaveReserveCheck.supplyAPY(reserveData: out, symbol: "USDC", chain: "Base"))
        out[24] = 0x11            // paused
        XCTAssertThrowsError(try AaveReserveCheck.supplyAPY(reserveData: out, symbol: "USDC", chain: "Base"))
        out[24] = 0x00            // not active
        XCTAssertThrowsError(try AaveReserveCheck.supplyAPY(reserveData: out, symbol: "USDC", chain: "Base"))
    }
}
