import XCTest
import CryptoKit
@testable import HermitWallet

/// Fixtures (Tests/HermitWalletTests/Fixtures): real dry quotes and the token list recorded from
/// https://1click.chaindefuser.com on 2026-11-08; status responses shaped by the OpenAPI schema (GetExecutionStatusResponse)
/// because a real status needs a real deposit; two non-dry quotes signed with a throwaway test key by the official
/// @defuse-protocol/one-click-sdk-typescript 0.1.26 hashing code (verifyQuoteSignature returned true for both).
/// Expected hashes were computed with that SDK's `quoteHash`.
final class NearIntentsTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func json(_ name: String) throws -> JSON { try JSONDecoder().decode(JSON.self, from: try fixture(name)) }

    /// A 1Click client that answers from fixtures and records what was asked.
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [String: (Data, Int)] = [:]
    }
    func client(_ r: Recorder, jwt: String? = nil) -> OneClick {
        OneClick(jwt: jwt) { req in
            r.requests.append(req)
            return r.answers[req.url!.path] ?? (Data(#"{"message":"not found"}"#.utf8), 404)
        }
    }

    // MARK: Signature

    func testSignatureMatchesSDKOnLiveQuotes() throws {
        // verifyQuoteSignature: true for these three.
        for (f, h) in [("quote-dry-base-usdc-to-near", "9AHui9mMPXENEx5uqBXB4Nb3LNMKb45hwkicQzqCsXBn"),
                       ("quote-dry-near-to-hyperliquid", "GHze8Ge5SnCZW47SWubZs1dw3dNjUfZh8CAL5dr8S2SW")] {
            let j = try json(f)
            XCTAssertEqual(QuoteSignature.hash(j), h, f)
            XCTAssertTrue(QuoteSignature.verify(j), f)
        }
        XCTAssertTrue(QuoteSignature.verify(try json("quote-dry-flex-arb-to-base")))
        // The SDK's hash, yet the SDK also rejects this one (BTC origin, INTENTS refund): we agree with it, not override it.
        let btc = try json("quote-dry-btc-refund-intents")
        XCTAssertEqual(QuoteSignature.hash(btc), "4BZr9KC3hBEP9YXadpWmWStNJAfSM1Eir4jCgB5C19pt")
        XCTAssertFalse(QuoteSignature.verify(btc))
    }

    func testSignatureNonDryAndTampering() throws {
        let test = "ed25519:GmaDrppBC7P5ARKV8g3djiwP89vz1jLK23V2GBjuAEGB"
        let signed = try json("quote-live-synthetic-signed")
        XCTAssertEqual(QuoteSignature.hash(signed), "EvzC7XnxVi7Us7JzjB9hRGBCvgRDt1dX2qfJURvJoDH9")
        XCTAssertTrue(QuoteSignature.verify(signed, publicKey: test))
        XCTAssertFalse(QuoteSignature.verify(signed))   // not 1Click's key
        // No quote.deadline: JS spread drops the request deadline as well.
        let nd = try json("quote-live-synthetic-nodeadline")
        XCTAssertEqual(QuoteSignature.hash(nd), "GwJzNNSZ42KebXjBZgjw1WpmAdE4kRDYiht3oHw8oawJ")
        XCTAssertTrue(QuoteSignature.verify(nd, publicKey: test))
        XCTAssertFalse(QuoteSignature.message(nd)!.contains("\"deadline\""))
        // Swap the deposit address: the signature must fail.
        var s = String(data: try fixture("quote-live-synthetic-signed"), encoding: .utf8)!
        s = s.replacingOccurrences(of: "0x76b4c56085ED136a8744D52bE956396624a730E8", with: "0x000000000000000000000000000000000000dEaD")
        XCTAssertFalse(QuoteSignature.verify(try JSONDecoder().decode(JSON.self, from: Data(s.utf8)), publicKey: test))
    }

    func testStableStringify() {
        let v: JSON = ["b": 1, "a": ["z": true, "y": .null], "c": "q\"\\\n\u{01}é", "d": .number(0.5)]
        XCTAssertEqual(QuoteSignature.stableStringify(v), #"{"a":{"y":null,"z":true},"b":1,"c":"q\"\\\n\u0001é","d":0.5}"#)
    }

    // MARK: Quotes, tokens, asset ids

    func testTokensAndAssetMapping() async throws {
        let r = Recorder(); r.answers["/v0/tokens"] = (try fixture("tokens"), 200)
        let list = try await client(r).tokens(force: true)
        XCTAssertEqual(list.count, 216)
        XCTAssertGreaterThanOrEqual(Set(list.map(\.blockchain)).count, 38)
        func id(_ s: String?, _ p: IntentsPlace) -> String? { IntentsAssets.token(s, at: p, in: list, hermitToken: p.chain.flatMap { c in s.flatMap(c.token) })?.assetId }
        XCTAssertEqual(id("USDC", .chain(.base)), "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near")
        XCTAssertEqual(id(nil, .chain(.base)), "nep141:base.omft.near")
        XCTAssertEqual(id(nil, .chain(.ethereum)), "nep141:eth.omft.near")
        XCTAssertEqual(id(nil, .chain(.arbitrum)), "nep141:arb.omft.near")
        XCTAssertEqual(id("USDC", .chain(.arbitrum)), "nep141:arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near")
        XCTAssertEqual(id(nil, .chain(.solana)), "nep141:sol.omft.near")
        XCTAssertEqual(id("USDC", .chain(.solana)), "nep141:sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near")
        XCTAssertEqual(id(nil, .chain(.bnb)), "nep245:v2_1.omni.hot.tg:56_11111111111111111111")
        XCTAssertEqual(id("USDT", .chain(.bnb)), "nep245:v2_1.omni.hot.tg:56_2CMMyVTGZkeyNZTSvS5sarzfir6g")
        XCTAssertEqual(id(nil, .chain(.polygon)), "nep245:v2_1.omni.hot.tg:137_11111111111111111111")
        XCTAssertEqual(id(nil, .chain(.near)), "nep141:wrap.near")
        XCTAssertEqual(id("USDC", .chain(.near)), "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1")
        XCTAssertEqual(id("USDT", .chain(.near)), "nep141:usdt.tether-token.near")
        XCTAssertEqual(id("BTC", .bitcoin), "nep141:btc.omft.near")
        XCTAssertEqual(id("USDC", .hyperliquid), IntentsAssets.hyperliquidUSDC)
        // Every Hermit mainnet has a 1Click code; NEAR, Bitcoin and Hyperliquid are places.
        XCTAssertTrue(IntentsPlace.all.contains(.chain(.near)) && IntentsPlace.all.contains(.bitcoin) && IntentsPlace.all.contains(.hyperliquid))
        XCTAssertNil(IntentsPlace.chain(.baseSepolia).blockchain)
        XCTAssertTrue(IntentsAssets.symbols(at: .chain(.near), in: list).starts(with: ["NEAR", "USDC", "USDT"]))
    }

    func testQuoteRequestAndParse() async throws {
        let r = Recorder(); r.answers["/v0/quote"] = (try fixture("quote-dry-base-usdc-to-near"), 200)
        let req = IntentsQuoteRequest(dry: true, originAsset: "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near",
                                      destinationAsset: "nep141:wrap.near", amount: 10_000_000,
                                      recipient: "98793cd91a3f870fb126f66285808c7e094afcfc4eda8a970f6648cdf0dbd6de",
                                      refundTo: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let q = try await client(r, jwt: "test-jwt").quote(req)
        let sent = try XCTUnwrap(r.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer test-jwt")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        XCTAssertEqual(body["dry"] as? Bool, true)
        XCTAssertEqual(body["amount"] as? String, "10000000")
        XCTAssertEqual(body["depositType"] as? String, "ORIGIN_CHAIN")
        XCTAssertEqual(body["recipientType"] as? String, "DESTINATION_CHAIN")
        XCTAssertNil(body["confidentiality"])
        XCTAssertEqual(q.amountIn, 10_000_000)
        XCTAssertEqual(q.amountOut, UInt128("2704574174131954765039327")!)
        XCTAssertEqual(q.amountOutFormatted, "2.704574174131954765039327")
        XCTAssertEqual(q.minAmountOut, UInt128("2677528432390635217388933")!)
        XCTAssertEqual(q.seconds, 35)
        XCTAssertEqual(q.appFeeBps, 20)                  // the unauthenticated 0.2%
        XCTAssertNil(q.depositAddress)                   // dry
        XCTAssertTrue(q.signatureValid)
        XCTAssertEqual(q.amountInUSD ?? 0, 9.99565, accuracy: 0.0001)
        // No JWT: no Authorization header at all.
        let r2 = Recorder(); r2.answers["/v0/quote"] = (try fixture("quote-dry-base-usdc-to-near"), 200)
        _ = try await client(r2).quote(req)
        XCTAssertNil(r2.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testErrorsInPlainWords() async throws {
        let r = Recorder()
        r.answers["/v0/quote"] = (Data(#"{"message":"User authentication is required for confidential intent quotes","statusCode":401}"#.utf8), 401)
        var req = IntentsQuoteRequest(dry: true, originAsset: "a", destinationAsset: "b", amount: 1, recipient: "x", refundTo: "y")
        req.confidentiality = .basic
        XCTAssertEqual(req.body["confidentiality"] as? String, "basic")
        do { _ = try await client(r).quote(req); XCTFail() } catch let e as OneClickError {
            XCTAssertEqual(e.status, 401); XCTAssertTrue(e.errorDescription!.contains("partner key"))
        }
    }

    func testStatusesAndSubmit() async throws {
        let s = IntentsSwapState(try json("status-success"))
        XCTAssertEqual(s.status, .success); XCTAssertTrue(s.status.isFinal); XCTAssertEqual(s.status.step, 3)
        XCTAssertEqual(s.amountOutFormatted, "2.704574174131954765039327")
        XCTAssertEqual(s.originTxs.first?.url?.absoluteString, "https://basescan.org/tx/0xabc1")
        XCTAssertEqual(s.destinationTxs.first?.hash, "9QmJt")
        let rf = IntentsSwapState(try json("status-refunded"))
        XCTAssertEqual(rf.status, .refunded); XCTAssertTrue(rf.status.isProblem && rf.status.isFinal)
        XCTAssertEqual(rf.refundedAmount, 4_000_000); XCTAssertEqual(rf.refundReason, "PARTIAL_DEPOSIT")
        XCTAssertEqual(rf.refundTo, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let inc = IntentsSwapState(try json("status-incomplete"))
        XCTAssertEqual(inc.status, .incompleteDeposit); XCTAssertFalse(inc.status.isFinal); XCTAssertEqual(inc.depositedFormatted, "4.0")
        // Every status the API documents parses and has words.
        for st in ["PENDING_DEPOSIT", "KNOWN_DEPOSIT_TX", "PROCESSING", "SUCCESS", "INCOMPLETE_DEPOSIT", "REFUNDED", "FAILED"] {
            let x = IntentsSwapState(["status": .string(st)])
            XCTAssertEqual(x.status.rawValue, st); XCTAssertFalse(x.status.headline.isEmpty)
        }
        XCTAssertEqual(IntentsStatus.allCases.count, 7)

        let r = Recorder()
        r.answers["/v0/status"] = (try fixture("status-success"), 200)
        r.answers["/v0/deposit/submit"] = (try fixture("status-success"), 200)
        let c = client(r)
        try await c.submitDeposit(txHash: "0xabc1", depositAddress: "0xdep", nearSender: nil)
        let st = try await c.status(depositAddress: "0xdep")
        XCTAssertEqual(st.status, .success)
        let sub = try JSONSerialization.jsonObject(with: r.requests[0].httpBody!) as? [String: String]
        XCTAssertEqual(sub, ["txHash": "0xabc1", "depositAddress": "0xdep"])
        XCTAssertEqual(r.requests[1].url?.query, "depositAddress=0xdep")
    }

    // MARK: Policy

    func testSpendPolicy() {
        let d = UserDefaults(suiteName: "policy-\(UUID())")!
        let book = AddressBook(defaults: d), limit = SpendLimit(defaults: d)
        let p = SpendPolicy(limit: limit, book: book, defaults: d)
        // The user, to their own address, inside the limit: allowed.
        XCTAssertEqual(p.evaluate(usd: 40, payee: nil, origin: .user).decision, .allow)
        // Over the $500 daily limit: blocked.
        limit.record(usd: 480)
        XCTAssertEqual(p.evaluate(usd: 40, payee: nil, origin: .user).decision, .block)
        // A new address: warned, not blocked.
        let fresh = p.evaluate(usd: 5, payee: ("0x000000000000000000000000000000000000dEaD", .evm), origin: .user)
        XCTAssertEqual(fresh.decision, .warn); XCTAssertTrue(fresh.warnings[0].contains("First payment"))
        // The assistant: capped per move, never to someone else's address, never unpriced.
        XCTAssertEqual(p.evaluate(usd: 5, payee: nil, origin: .agent).decision, .allow)
        XCTAssertEqual(p.evaluate(usd: 25, payee: nil, origin: .agent).decision, .block)   // only $20 left today
        let inj = p.evaluate(usd: 5, payee: ("0x000000000000000000000000000000000000dEaD", .evm), origin: .agent)
        XCTAssertEqual(inj.decision, .block); XCTAssertTrue(inj.blocks.contains { $0.contains("own addresses") })
        XCTAssertEqual(p.evaluate(usd: nil, payee: nil, origin: .agent).decision, .block)
        let d2 = UserDefaults(suiteName: "policy-\(UUID())")!
        let p2 = SpendPolicy(limit: SpendLimit(defaults: d2), book: AddressBook(defaults: d2), defaults: d2)
        XCTAssertEqual(p2.evaluate(usd: 150, payee: nil, origin: .agent).decision, .block)  // over the $100 assistant cap
        XCTAssertEqual(p2.evaluate(usd: 150, payee: nil, origin: .user).decision, .allow)
    }

    @MainActor func testAgentToolsParseChainsAndPrepareIsGuarded() async throws {
        XCTAssertEqual(WalletTools.place("bsc"), .chain(.bnb))
        XCTAssertEqual(WalletTools.place("NEAR"), .chain(.near))
        XCTAssertEqual(WalletTools.place("btc"), .bitcoin)
        XCTAssertEqual(WalletTools.place("hyperliquid"), .hyperliquid)
        XCTAssertNil(WalletTools.place("narnia"))
        let defs = try JSONSerialization.jsonObject(with: Data(WalletTools.definitionsJSON.utf8)) as? [[String: Any]]
        let names = defs?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names ?? []), WalletTools.names)
        let tools = WalletTools(service: WalletService(vault: KeyVault(store: MemoryStore())))
        let out = await tools.call("prepare_swap", argumentsJSON: #"{"from_symbol":"USDC","from_chain":"bitcoin","to_symbol":"ETH","to_chain":"base","amount":5}"#)
        XCTAssertTrue(out.contains("can only receive"), out)
    }

    /// Live: ONECLICK_LIVE=1 swift test --filter NearIntentsTests/testLiveDryQuote. Dry only: nothing is created or moved.
    func testLiveDryQuote() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ONECLICK_LIVE"] == "1", "set ONECLICK_LIVE=1 for the live dry quote")
        let c = OneClick()
        let list = try await c.tokens(force: true)
        XCTAssertGreaterThan(list.count, 100)
        let from = try XCTUnwrap(IntentsAssets.token("USDC", at: .chain(.base), in: list, hermitToken: Chain.base.token("USDC")))
        let to = try XCTUnwrap(IntentsAssets.token(nil, at: .chain(.near), in: list))
        let q = try await c.quote(IntentsQuoteRequest(dry: true, originAsset: from.assetId, destinationAsset: to.assetId, amount: 10_000_000,
                                                      recipient: "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412",
                                                      refundTo: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))
        XCTAssertGreaterThan(q.amountOut, 0)
        XCTAssertNil(q.depositAddress)
        XCTAssertTrue(q.signatureValid, "1Click signature")
        print("LIVE dry quote: 10 USDC on Base -> \(q.amountOutFormatted) NEAR, \(q.seconds)s, fee \(q.appFeeBps) bps")
    }
}

/// NEAR: key derivation and transactions against near-seed-phrase 0.2.1 and near-api-js 4 (independent implementations).
final class NearTests: XCTestCase {
    let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    // near-seed-phrase parseSeedPhrase(abandon…about), path m/44'/397'/0'.
    let pubB58 = "6j4b6zUaty6fD1awqcGCCU9JYGCWYUgdJhQrzfZhqE25"
    let implicit = "5510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee412"
    let blockHash = "4reLvkAWfqk5fsqio1KLudk46cqRz9erQdaHkWZKMJDZ"

    func testDerivation() throws {
        XCTAssertEqual(try KeyVault.nearAccount(phrase: abandon), implicit)
        XCTAssertEqual(NearAccount.publicKeyString([UInt8](hex: implicit)!), "ed25519:" + pubB58)
        // near-seed-phrase's secret key is seed || public key, base58.
        let sk = Base58.decode("F1kPR175szkGxEL52A9H6Z5ocS2BtaipprK2Hiob9DjGzHTkScrBb1yt44baXPZ3LxyHcsTPdBjHmn6zx147txH")!
        var seed = Mnemonic.seed(phrase: abandon)
        XCTAssertEqual(try HD.ed25519Seed(seed: seed, path: KeyVault.nearPath), Array(sk[0..<32]))
        seed.wipe()
    }

    func testAccountIds() {
        for ok in ["alice.near", "hermit-labs.near", "a1_b.c", implicit, "near"] { XCTAssertTrue(NearAccount.isValid(ok), ok) }
        for bad in ["A.near", "a", "alice..near", ".near", "alice.near.", "al ice.near", String(repeating: "a", count: 65), "-a.near"] {
            XCTAssertFalse(NearAccount.isValid(bad), bad)
        }
        XCTAssertTrue(NearAccount.isImplicit(implicit)); XCTAssertFalse(NearAccount.isImplicit("alice.near"))
    }

    func tx(_ receiver: String, _ actions: [NearAction]) -> NearTransaction {
        NearTransaction(signer: implicit, publicKey: [UInt8](hex: implicit)!, nonce: 123_456_789, receiver: receiver,
                        blockHash: Base58.decode(blockHash)!, actions: actions)
    }

    func testTransferMatchesNearApiJs() throws {
        let t = tx("bob.near", [.transfer(deposit: UInt128("1500000000000000000000000")!)])
        XCTAssertEqual(t.serialized.hex, "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b070000000008000000626f622e6e656172394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c0100000003000080716433b629a33d010000000000")
        XCTAssertEqual(t.hashString, "Dx1qLDXqinY5Mo5q9ZkG3Mzg7phWXpGU1szK3M1JTDCR")
        // near-api-js's signed transaction: our tx bytes + its signature, and that signature verifies with our key.
        let js = [UInt8](Data(base64Encoded: "QAAAADU1MTBlMmI0NGNhZTZlYjgwN2UzZTBlNDVkNTc5ZGRhMDU4YzI3NGFiY2JhMTVlNWNiODQ2MzZmNWQxZWU0MTIAVRDitEyubrgH4+DkXVed2gWMJ0q8uhXly4Rjb10e5BIVzVsHAAAAAAgAAABib2IubmVhcjlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAAAKFsNyvmBU9/q5DL0NsUkh0qkT1HOjc0yx3mISDOg75m16Um6Uf1dzDSl+Wogd6q3JlPvp1+FoZRPhOxDLnMNgw=")!)
        XCTAssertEqual(Array(js[0..<t.serialized.count]), t.serialized)
        XCTAssertEqual(js[t.serialized.count], 0)
        let theirs = SignedNearTransaction(transaction: t, signature: Array(js[(t.serialized.count + 1)...]))
        XCTAssertTrue(theirs.verify())
        // And ours: signed from the derived seed, verifies, same layout.
        var seed = Mnemonic.seed(phrase: abandon)
        let key = try HD.ed25519Seed(seed: seed, path: KeyVault.nearPath); seed.wipe()
        let mine = try t.sign(ed25519Seed: key)
        XCTAssertTrue(mine.verify())
        XCTAssertEqual(mine.serialized.count, js.count)
        XCTAssertThrowsError(try tx("bob.near", []).sign(ed25519Seed: [UInt8](repeating: 1, count: 32)))   // wrong key
    }

    func testFtTransferWithStorageMatchesNearApiJs() {
        let t = tx("17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1",
                   [.storageDeposit(for: "bob.near"), .ftTransfer(receiver: "bob.near", amount: 2_500_000)])
        XCTAssertEqual(t.serialized.hex, "4000000035353130653262343463616536656238303765336530653435643537396464613035386332373461626362613135653563623834363336663564316565343132005510e2b44cae6eb807e3e0e45d579dda058c274abcba15e5cb84636f5d1ee41215cd5b07000000004000000031373230383632386638346635643661643333663064613362626265623237666663623339386561633530316133316264366164323031316533363133336131394abeb35e707609de8f73b63d43bd1a376ffe67935caa68937dd29bc04e673c02000000020f00000073746f726167655f6465706f736974320000007b226163636f756e745f6964223a22626f622e6e656172222c22726567697374726174696f6e5f6f6e6c79223a747275657d00e057eb481b00000000485637193cc34300000000000000020b00000066745f7472616e736665722d0000007b2272656365697665725f6964223a22626f622e6e656172222c22616d6f756e74223a2232353030303030227d00e057eb481b000001000000000000000000000000000000")
        XCTAssertEqual(t.hashString, "2852HwiCVMHsVDhexEsSy2LCeXiy6MWgUpg39EGqPLuy")
    }

    func testAvailableBalanceLessStorage() {
        let s = NearClient.AccountState(amount: 10_000_000_000_000_000_000_000, locked: 0, storageUsage: 182)
        XCTAssertEqual(s.available, 10_000_000_000_000_000_000_000 - 1_820_000_000_000_000_000_000)
    }

    func testRecordDecodesWithoutNearAccount() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"W","created":0,"protection":"memoryOnly","wordCount":12,"evmAddress":"0x9858EfFD232B4033E47d90003D41EC34EcaEda94","solanaAddress":"x","backedUp":true}]"#
        let r = try JSONDecoder().decode([WalletRecord].self, from: Data(old.utf8))
        XCTAssertNil(r[0].nearAccount)
        XCTAssertEqual(r[0].address(on: .near), "")
    }

    func testNewWalletGetsNearAccount() throws {
        let v = KeyVault(store: MemoryStore())
        let w = try v.importPhrase(abandon, name: "T")
        XCTAssertEqual(w.nearAccount, implicit)
        XCTAssertEqual(w.address(on: .near), implicit)
    }
}
