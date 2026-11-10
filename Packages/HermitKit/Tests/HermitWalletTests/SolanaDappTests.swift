import XCTest
import CryptoKit
import HermitCore
@testable import HermitWallet
#if canImport(WebKit)
import WebKit
#endif

/// Solana in Hermit's browser. Fixtures (Fixtures/solana, fetched 2026-11-10 from mainnet with the app's public RPC):
/// three Jupiter v0 transactions with their address lookup tables and RPC loadedAddresses, three v1 transactions
/// (SIMD-0385), and one simulateTransaction answer. `expect` in each was written by solders 0.29, an independent decoder.
/// Real signatures on real transactions prove the message bytes are cut exactly. Nothing here broadcasts.
@MainActor
final class SolanaDappTests: XCTestCase {
    nonisolated static let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func fixture(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solana"))
        return try JSONDecoder().decode(JSON.self, from: Data(contentsOf: url))
    }
    func b64(_ j: JSON?) -> [UInt8] { j?.string.flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) } ?? [] }
    func keys(_ j: JSON?) -> [String] { (j?.array ?? []).compactMap(\.string) }

    func verify(_ sig: [UInt8], _ key: SolanaPublicKey, _ msg: [UInt8]) -> Bool {
        (try? Curve25519.Signing.PublicKey(rawRepresentation: key.bytes))?.isValidSignature(sig, for: msg) ?? false
    }

    // MARK: Wire format

    func testJupiterV0WithLookupTables() throws {
        let f = try fixture("jupiter-v0")
        var tables: [SolanaPublicKey: [SolanaPublicKey]] = [:]
        if case .object(let o)? = f["tables"] {
            for (k, v) in o { tables[SolanaPublicKey(k)!] = try SolanaLookupTable.addresses(b64(v)) }
        }
        let txs = try XCTUnwrap(f["txs"]?.array)
        XCTAssertEqual(txs.count, 3)
        for t in txs {
            let raw = b64(t["tx"]), e = t["expect"]!
            let tx = try SolanaWireTransaction.parse(raw)
            XCTAssertEqual(tx.message.version, .v0)
            XCTAssertEqual(tx.serialized, raw)
            XCTAssertEqual([tx.message.numRequiredSignatures, tx.message.numReadonlySigned, tx.message.numReadonlyUnsigned],
                           e["header"]?.array?.compactMap(\.int))
            XCTAssertEqual(tx.message.staticKeys.map(\.description), keys(e["static"]))
            XCTAssertEqual(Base58.encode(tx.message.recentBlockhash), e["blockhash"]?.string)
            XCTAssertFalse(tx.message.lookups.isEmpty)
            // Lookup tables resolve to exactly what the RPC says the transaction loaded.
            let all = try SolanaLookupTable.resolve(tx.message, tables: tables).map(\.description)
            XCTAssertEqual(all, keys(e["static"]) + keys(t["loaded"]?["writable"]) + keys(t["loaded"]?["readonly"]))
            XCTAssertEqual(tx.message.instructions.map { all[$0.programIndex] }, keys(e["programs"]))
            XCTAssertEqual(tx.message.instructions.map(\.accounts), e["ixAccounts"]?.array?.map { $0.array?.compactMap(\.int) ?? [] })
            XCTAssertEqual(tx.message.instructions.map { Data($0.data).base64EncodedString() }, keys(e["ixData"]))
            // The fee payer's real signature verifies over our message bytes.
            XCTAssertEqual(tx.id, keys(e["signatures"]).first)
            XCTAssertTrue(verify(tx.signatures[0], tx.message.feePayer, tx.message.bytes))
            // Writability: loaded writable accounts are writable, loaded read-only aren't.
            let nw = t["loaded"]?["writable"]?.array?.count ?? 0, ns = tx.message.staticKeys.count
            if nw > 0 { XCTAssertTrue(tx.message.isWritable(ns)); XCTAssertFalse(tx.message.isWritable(ns + nw)) }
            // It names Jupiter.
            let r = SolanaDecoder.review(tx.message, keys: all.map { SolanaPublicKey($0)! }, wallet: tx.message.feePayer, chain: .solana)
            XCTAssertTrue(r.lines.contains(["App", "Jupiter"]), "\(r.lines)")
            XCTAssertTrue(r.title.hasPrefix("Jupiter"), r.title)
        }
    }

    func testMainnetV1() throws {
        let txs = try XCTUnwrap(try fixture("mainnet-v1")["txs"]?.array)
        for t in txs {
            let raw = b64(t["tx"]), e = t["expect"]!
            let tx = try SolanaWireTransaction.parse(raw)
            XCTAssertEqual(tx.message.version, .v1)
            XCTAssertEqual(raw.first, 0x81)
            XCTAssertEqual(tx.serialized, raw)
            XCTAssertEqual(tx.message.staticKeys.map(\.description), keys(e["static"]))
            XCTAssertEqual(tx.message.instructions.map { tx.message.staticKeys[$0.programIndex].description }, keys(e["programs"]))
            XCTAssertEqual(tx.message.instructions.map { Data($0.data).base64EncodedString() }, keys(e["ixData"]))
            XCTAssertEqual(tx.id, keys(e["signatures"]).first)
            for (i, k) in tx.message.signers.enumerated() { XCTAssertTrue(verify(tx.signatures[i], k, tx.message.bytes)) }
            let cfg = try XCTUnwrap(tx.message.config)
            let mask = raw[4]
            XCTAssertEqual(cfg.priorityFeeLamports != nil, mask & 3 == 3)
            XCTAssertEqual(cfg.computeUnitLimit != nil, mask & 4 != 0)
            XCTAssertEqual(cfg.heapSize != nil, mask & 16 != 0)
        }
    }

    func testRejectsWhatItCantRead() throws {
        let raw = b64(try fixture("mainnet-v1")["txs"]?[0]?["tx"])
        var v2 = raw; v2[0] = 0x82
        XCTAssertThrowsError(try SolanaWireTransaction.parse(v2)) { XCTAssertEqual($0 as? SolanaWireError, .unsupportedVersion(2)) }
        XCTAssertThrowsError(try SolanaWireTransaction.parse(raw + [0]))
        XCTAssertThrowsError(try SolanaWireTransaction.parse(Array(raw.dropLast())))
        var badMask = raw; badMask[4] = 0x20
        XCTAssertThrowsError(try SolanaWireTransaction.parse(badMask))
        // A v1 message inside a legacy envelope isn't a thing.
        let v0 = b64(try fixture("jupiter-v0")["txs"]?[0]?["tx"])
        var odd = v0; odd[65] = 0x81
        XCTAssertThrowsError(try SolanaWireTransaction.parse(odd)) { XCTAssertEqual($0 as? SolanaWireError, .unsupportedVersion(1)) }
        XCTAssertThrowsError(try SolanaWireTransaction.parse([]))
    }

    // MARK: Review

    let me = SolanaPublicKey("Bq1pvmrs49ks4DTy7ts5HDGoALaGhC81upSyZ9YttMLu")!
    let other = SolanaPublicKey("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM")!
    let usdc = SolanaPublicKey("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")!

    func legacy(_ ixs: [SolanaInstruction], payer: SolanaPublicKey? = nil) throws -> SolanaWireTransaction {
        try SolanaWireTransaction.parse(SolanaTransaction(message: SolanaMessage(payer: payer ?? me, instructions: ixs,
                                                                                   recentBlockhash: [UInt8](repeating: 7, count: 32))).serialized)
    }

    func testReviewDecodesCommonPrograms() throws {
        let src = SolanaPublicKey.associatedTokenAccount(owner: me, mint: usdc), dst = SolanaPublicKey.associatedTokenAccount(owner: other, mint: usdc)
        let unknown = SolanaPublicKey(bytes: [UInt8](repeating: 9, count: 32))
        let approve = SolanaInstruction(program: .tokenProgram, accounts: [.init(src, signer: false, writable: true), .init(other, signer: false, writable: false),
                                                                           .init(me, signer: true, writable: false)], data: [4] + UInt64.max.littleEndianBytes(width: 8))
        let close = SolanaInstruction(program: .tokenProgram, accounts: [.init(src, signer: false, writable: true), .init(other, signer: false, writable: true),
                                                                         .init(me, signer: true, writable: false)], data: [9])
        let tx = try legacy([.setComputeUnitLimit(200_000), .setComputeUnitPrice(50_000),
                             .createAssociatedTokenAccountIdempotent(payer: me, owner: other, mint: usdc),
                             .transferChecked(source: src, mint: usdc, destination: dst, owner: me, amount: 12_500_000, decimals: 6),
                             approve, close, .transfer(from: me, to: other, lamports: 1_500_000_000),
                             SolanaInstruction(program: unknown, accounts: [], data: [1, 2, 3])])
        XCTAssertEqual(tx.message.version, .legacy)
        let r = SolanaDecoder.review(tx.message, keys: tx.message.staticKeys, wallet: me, chain: .solana)
        XCTAssertEqual(r.priorityFeeLamports, 10_000)
        // Without simulation the recipient's token account is shown (its owner comes from simulation).
        XCTAssertTrue(r.lines.contains(["Send", "12.5 USDC to \(SolanaDecoder.short(dst.description))"]), "\(r.lines)")
        let withOwner = SolanaDecoder.review(tx.message, keys: tx.message.staticKeys, wallet: me, chain: .solana,
                                             tokenInfo: [tx.message.staticKeys.firstIndex(of: dst)!: SolanaTokenBalance(accountIndex: 0, mint: usdc.description, owner: other.description, programId: SolanaPrograms.token, amount: 0, decimals: 6)])
        XCTAssertTrue(withOwner.lines.contains(["Send", "12.5 USDC to 9WzD…AWWM"]), "\(withOwner.lines)")
        XCTAssertTrue(r.lines.contains(["Send", "1.5 SOL to 9WzD…AWWM"]), "\(r.lines)")
        XCTAssertTrue(r.lines.contains(["Token account", "create for 9WzD…AWWM, USDC"]), "\(r.lines)")
        XCTAssertTrue(r.lines.contains(["Program", "\(SolanaDecoder.short(unknown.description)) (unknown)"]), "\(r.lines)")
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("Unlimited delegate") }, "\(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("This closes one of your token accounts") }, "\(r.warnings)")
        XCTAssertTrue(r.warnings.contains { $0.hasPrefix("Hermit doesn't know this program") }, "\(r.warnings)")
        XCTAssertTrue(r.movesFunds); XCTAssertEqual(r.payee, dst.description); XCTAssertEqual(withOwner.payee, other.description)
        XCTAssertEqual(r.title, "Send 12.5 USDC")
        // Without simulation the policy prices the direct transfers: 12.5 USDC + 1.5 SOL at $100.
        XCTAssertEqual(r.directOutflowUSD(chain: .solana, solPrice: 100), Decimal(string: "162.5"))
        XCTAssertEqual(r.directOutflowUSD(chain: .solanaDevnet, solPrice: 100), 0)
    }

    func testBalanceChangesAndOutflow() throws {
        // The recorded simulation of the first Jupiter fixture: it sells a token for SOL (numbers checked in Python).
        let f = try fixture("jupiter-v0"), t = f["txs"]![0]!
        let all = (keys(t["expect"]?["static"]) + keys(t["loaded"]?["writable"]) + keys(t["loaded"]?["readonly"])).map { SolanaPublicKey($0)! }
        let sim = SolanaSimResult(json: try fixture("jupiter-v0-sim"))
        XCTAssertNil(sim.error); XCTAssertTrue(sim.hasBalances); XCTAssertEqual(sim.fee, 5000)
        let got = SolanaDecoder.changes(sim, keys: all, wallet: all[0], chain: .solana)
        XCTAssertEqual(got, [SolanaBalanceChange(symbol: "SOL", mint: nil, decimals: 9, delta: 4_607_468),
                             SolanaBalanceChange(symbol: "token H1kX…gpUf",
                                                 mint: "H1kXUqEPkQNNeNjGNN5tuHf3nsQK2vB1jUA9c4RggpUf", decimals: 9, delta: -180_166_588_062)])
        XCTAssertNil(SolanaDecoder.outflowUSD(got, chain: .solana, solPrice: 150))   // an unpriced token leaves
        // A swap: 25 USDC out, 0.1 SOL in.
        let swap: JSON = ["err": .null, "preBalances": [1_000_000_000, 0], "postBalances": [1_099_995_000, 0], "fee": 5000,
                          "preTokenBalances": [["accountIndex": 1, "mint": .string(usdc.description), "owner": .string(me.description),
                                                "programId": .string(SolanaPrograms.token), "uiTokenAmount": ["amount": "30000000", "decimals": 6]]],
                          "postTokenBalances": [["accountIndex": 1, "mint": .string(usdc.description), "owner": .string(me.description),
                                                 "programId": .string(SolanaPrograms.token), "uiTokenAmount": ["amount": "5000000", "decimals": 6]]]]
        let ch = SolanaDecoder.changes(SolanaSimResult(json: swap), keys: [me, other], wallet: me, chain: .solana)
        XCTAssertEqual(ch.map(\.text), ["+0.099995 SOL", "−25 USDC"])
        XCTAssertEqual(SolanaDecoder.outflowUSD(ch, chain: .solana, solPrice: 150), 25)
        XCTAssertNil(SolanaDecoder.outflowUSD([SolanaBalanceChange(symbol: "token X", mint: "X", decimals: 6, delta: -1)], chain: .solana, solPrice: 150))
    }

    func testToken2022ExtensionWarnings() {
        var mint = [UInt8](repeating: 0, count: 166); mint[165] = 1
        var fee = [UInt8](repeating: 0, count: 108); fee[106] = 150 // 1.5%
        mint += [1, 0, 108, 0] + fee
        mint += [12, 0, 32, 0] + other.bytes
        var hook = [UInt8](repeating: 0, count: 64); hook.replaceSubrange(32..<64, with: other.bytes)
        mint += [14, 0, 64, 0] + hook
        let w = SolanaDecoder.mintExtensionWarnings(mint, symbol: "XYZ")
        XCTAssertEqual(w.count, 3, "\(w)")
        XCTAssertTrue(w[0].contains("1.5% transfer fee")); XCTAssertTrue(w[1].contains("permanent delegate")); XCTAssertTrue(w[2].contains("transfer hook"))
    }

    func testSignerRulesAndMessages() throws {
        let notMine = try legacy([.transfer(from: other, to: other, lamports: 1)], payer: other)
        XCTAssertThrowsError(try WalletService.signerSlot(notMine.message, wallet: me))
        // Wallet present only as a read-only account: not a signer.
        let readOnly = try legacy([SolanaInstruction(program: .systemProgram, accounts: [.init(me, signer: false, writable: false)], data: [9, 9])], payer: other)
        XCTAssertThrowsError(try WalletService.signerSlot(readOnly.message, wallet: me))
        // Wallet as second signer: slot 1.
        let cosign = try legacy([.transfer(from: me, to: other, lamports: 5)], payer: other)
        XCTAssertEqual(try WalletService.signerSlot(cosign.message, wallet: me), 1)
        XCTAssertFalse(WalletService.otherSignaturesValid(cosign, except: 1))
        // A message that is really a transaction is refused.
        XCTAssertTrue(DappProvider.looksLikeTransaction(cosign.message.bytes))
        XCTAssertTrue(DappProvider.looksLikeTransaction(cosign.serialized))
        XCTAssertFalse(DappProvider.looksLikeTransaction(Array("Hello from Hermit".utf8)))
        // Sign-In with Solana text, in the wallet-standard format.
        let text = SolanaDecoder.signInMessage(domain: "jup.ag", address: me.description,
                                               input: ["statement": "Sign in to Jupiter", "uri": "https://jup.ag", "version": "1", "nonce": "abc123",
                                                       "issuedAt": "2026-11-10T09:00:00Z", "resources": ["https://jup.ag/terms"]])
        XCTAssertEqual(text, "jup.ag wants you to sign in with your Solana account:\n\(me)\n\nSign in to Jupiter\n\nURI: https://jup.ag\nVersion: 1\nNonce: abc123\nIssued At: 2026-11-10T09:00:00Z\nResources:\n- https://jup.ag/terms")
    }

    // MARK: Provider

    final class Presenter: DappPresenter {
        var approve: [Bool] = []
        var shown: [Approval] = []
        var notices: [String] = []
        func present(_ a: Approval) async {
            shown.append(a)
            // Never approve anything that would broadcast.
            if !approve.isEmpty, approve.removeFirst(), !a.success.hasPrefix("Sent") { _ = try? await a.perform?() }
        }
        func notice(_ text: String) { notices.append(text) }
    }

    var defaults: UserDefaults!
    override func setUp() async throws { defaults = UserDefaults(suiteName: "hermit.sol.tests.\(UUID().uuidString)")! }

    func setup(phrase: String? = abandon) throws -> (WalletService, Presenter, DappProvider) {
        let s = WalletService(vault: KeyVault(store: MemoryStore()), addressBook: AddressBook(defaults: defaults),
                              spendLimit: SpendLimit(defaults: defaults), sendLog: SendLog(defaults: defaults))
        if let phrase { try s.importWallet(phrase: phrase, name: "Test") } else { try s.createWallet(name: "Empty") }
        let p = Presenter(), d = DappProvider(service: s, sites: DappPermissions(defaults: defaults))
        d.presenter = p; d.knownHosts = ["jup.ag"]; d.prices = { ["SOL": 150] }
        return (s, p, d)
    }
    let jup = DappOrigin(scheme: "https", host: "jup.ag", port: nil)
    func call(_ d: DappProvider, _ m: String, _ p: JSON = [:]) async -> Result<JSON, DappRPCError> {
        await d.handle(method: m, params: [p], origin: jup)
    }

    /// Signatures made through the provider, written to $HERMIT_SOL_SIGS for an independent check (PyNaCl).
    func testProviderConnectSignMessageAndTransaction() async throws {
        let (s, p, d) = try setup()
        let key = SolanaPublicKey(s.wallets[0].solanaAddress)!
        let silent = await call(d, "sol_connect", ["silent": true])
        XCTAssertEqual(silent, .success(.null)); XCTAssertTrue(p.shown.isEmpty)
        let early = await call(d, "sol_signMessage", ["message": "aGk="])
        XCTAssertEqual(early, .failure(.unauthorized))
        p.approve = [false]
        let refused = await call(d, "sol_connect")
        XCTAssertEqual(refused, .failure(.rejected))
        p.approve = [true]
        let acct = try await call(d, "sol_connect").get()
        XCTAssertEqual(acct["address"]?.string, key.description)
        XCTAssertEqual(d.sites.site(jup)?.solana, key.description)
        XCTAssertEqual(d.account(for: jup) == nil, true)   // Solana-only: no EVM accounts for this site

        let msg = Array("Hello from Hermit on Solana".utf8)
        p.approve = [true]
        let sigB64 = try await call(d, "sol_signMessage", ["message": .string(Data(msg).base64EncodedString())]).get()["signature"]?.string
        let sig = [UInt8](Data(base64Encoded: try XCTUnwrap(sigB64))!)
        XCTAssertTrue(verify(sig, key, msg))
        XCTAssertEqual(p.shown.last?.title, "Sign a message")

        // A transaction as a message: refused before any sheet.
        let tx = try legacy([.transfer(from: key, to: other, lamports: 1_000)], payer: key)
        let shown = p.shown.count
        if case .failure(let e) = await call(d, "sol_signMessage", ["message": .string(Data(tx.message.bytes).base64EncodedString())]) { XCTAssertEqual(e.code, 4100) } else { XCTFail() }
        XCTAssertEqual(p.shown.count, shown)

        // signTransaction on devnet: decoded, then signed in the fee payer slot only.
        p.approve = [true]
        let signedB64 = try await call(d, "sol_signTransaction", ["transaction": .string(Data(tx.serialized).base64EncodedString()), "chain": "solana:devnet"]).get()["signedTransaction"]?.string
        let signed = try SolanaWireTransaction.parse([UInt8](Data(base64Encoded: try XCTUnwrap(signedB64))!))
        XCTAssertEqual(signed.message.bytes, tx.message.bytes)
        XCTAssertTrue(verify(signed.signatures[0], key, signed.message.bytes))
        let sheet = try XCTUnwrap(p.shown.last)
        XCTAssertEqual(sheet.title, "Send 0.000001 SOL")
        XCTAssertTrue(sheet.lines.contains(["Site", "jup.ag"]))
        XCTAssertTrue(sheet.lines.contains(["Network", "Solana Devnet (testnet)"]), "\(sheet.lines)")
        XCTAssertTrue(sheet.lines.contains(["Format", "Legacy"]))

        // A transaction for another wallet, an unknown chain, a wrong account.
        let foreign = try legacy([.transfer(from: other, to: other, lamports: 1)], payer: other)
        if case .failure(let e) = await call(d, "sol_signTransaction", ["transaction": .string(Data(foreign.serialized).base64EncodedString())]) { XCTAssertEqual(e.code, 4100) } else { XCTFail() }
        if case .failure(let e) = await call(d, "sol_signTransaction", ["transaction": .string(Data(tx.serialized).base64EncodedString()), "chain": "solana:testnet"]) { XCTAssertEqual(e.code, 4100) } else { XCTFail() }
        if case .failure(let e) = await call(d, "sol_signTransaction", ["transaction": "AAAA"]) { XCTAssertEqual(e.code, -32602) } else { XCTFail() }

        // Sign-In with Solana: the message names the page's domain.
        p.approve = [true]
        let si = try await call(d, "sol_signIn", ["input": ["statement": "Sign in", "nonce": "n1"]]).get()
        let siMsg = [UInt8](Data(base64Encoded: si["signedMessage"]!.string!)!), siSig = [UInt8](Data(base64Encoded: si["signature"]!.string!)!)
        XCTAssertTrue(String(decoding: siMsg, as: UTF8.self).hasPrefix("jup.ag wants you to sign in with your Solana account:\n\(key)"))
        XCTAssertTrue(verify(siSig, key, siMsg))

        if let path = ProcessInfo.processInfo.environment["HERMIT_SOL_SIGS"] {
            let out: JSON = ["publicKey": .string(key.description), "items": [
                ["message": .string(Data(msg).base64EncodedString()), "signature": .string(Data(sig).base64EncodedString())],
                ["message": .string(Data(signed.message.bytes).base64EncodedString()), "signature": .string(Data(signed.signatures[0]).base64EncodedString())],
                ["message": .string(Data(siMsg).base64EncodedString()), "signature": .string(Data(siSig).base64EncodedString())],
                ["transaction": .string(Data(signed.serialized).base64EncodedString())]]]
            try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: path))
        }

        // Disconnect from the page keeps nothing.
        _ = await call(d, "sol_disconnect")
        XCTAssertNil(d.sites.site(jup))
    }

    /// Live (HERMIT_LIVE=1): a fresh empty wallet signs-and-sends 0.001 SOL to itself on devnet with a real blockhash.
    /// The review simulates it on devnet and the sheet is cancelled, so nothing is signed or sent.
    func testLiveCancelledSignAndSendOnDevnet() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMIT_LIVE"] == "1", "set HERMIT_LIVE=1")
        let (s, p, d) = try setup(phrase: nil)
        let key = SolanaPublicKey(s.wallets[0].solanaAddress)!
        p.approve = [true]
        _ = try await call(d, "sol_connect").get()
        let (bh, _) = try await SolanaClient(url: Chain.solanaDevnet.rpc).latestBlockhash()
        let tx = SolanaTransaction(message: SolanaMessage(payer: key, instructions: [.setComputeUnitPrice(1_000), .transfer(from: key, to: other, lamports: 1_000_000)],
                                                          recentBlockhash: bh))
        p.approve = [true]   // the presenter refuses to perform anything that sends
        let r = await call(d, "sol_signAndSendTransaction", ["transaction": .string(tx.base64), "chain": "solana:devnet"])
        XCTAssertEqual(r, .failure(.rejected))
        let sheet = try XCTUnwrap(p.shown.last)
        print("devnet sheet:", sheet.title, sheet.lines, sheet.warnings, sheet.checks)
        XCTAssertEqual(sheet.title, "Send 0.001 SOL")
        XCTAssertEqual(sheet.success, "Sent to Solana Devnet")
        XCTAssertTrue(sheet.warnings.first?.hasPrefix("Simulation failed") == true, "\(sheet.warnings)")   // the wallet has no SOL
        XCTAssertTrue(sheet.lines.contains { $0[0] == "Network fee" }, "\(sheet.lines)")
    }

    // MARK: In a real WKWebView

    #if canImport(WebKit) && os(macOS)
    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
    }

    func testWalletStandardInWebView() async throws {
        let (s, p, d) = try setup()
        let key = SolanaPublicKey(s.wallets[0].solanaAddress)!
        let config = WKWebViewConfiguration()
        let bridge = DappWebBridge(provider: d)
        bridge.install(on: config)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        bridge.webView = wv
        let nav = Loaded(); wv.navigationDelegate = nav
        // An app that loads after the wallet: it announces app-ready and the wallet registers itself.
        let html = """
        <html><body><script>
        window.__wallets = [];
        window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: { register: w => { window.__wallets.push(w); return () => {}; } } }));
        </script></body></html>
        """
        await withCheckedContinuation { c in nav.done = c; wv.loadHTMLString(html, baseURL: URL(string: "https://jup.ag/")!) }
        func js(_ b: String) async throws -> Any? { try await wv.callAsyncJavaScript(b, arguments: [:], in: nil, contentWorld: .page) }
        let info = try await js("""
            const w = window.__wallets[0];
            return JSON.stringify({ n: window.__wallets.length, name: w.name, chains: w.chains, icon: w.icon.startsWith('data:image/png;base64,'),
              features: Object.keys(w.features).sort(), versions: w.features['solana:signTransaction'].supportedTransactionVersions,
              legacy: window.solana.isHermit === true && window.hermit === window.solana });
        """) as? String ?? ""
        XCTAssertEqual(info, #"{"n":1,"name":"Hermit","chains":["solana:mainnet","solana:devnet"],"icon":true,"features":["solana:signAndSendTransaction","solana:signIn","solana:signMessage","solana:signTransaction","standard:connect","standard:disconnect","standard:events"],"versions":["legacy",0,1],"legacy":true}"#)
        p.approve = [false]
        let rejected = try await js("try { await window.__wallets[0].features['standard:connect'].connect(); return 'ok' } catch (e) { return e.code }") as? Int
        XCTAssertEqual(rejected, 4001)
        p.approve = [true]
        let address = try await js("""
            const w = window.__wallets[0]; let changes = 0; w.features['standard:events'].on('change', () => changes++);
            const r = await w.features['standard:connect'].connect();
            return r.accounts[0].address + '|' + r.accounts[0].publicKey.length + '|' + w.accounts.length + '|' + changes + '|' + window.solana.publicKey.toBase58();
        """) as? String
        XCTAssertEqual(address, "\(key)|32|1|1|\(key)")
        p.approve = [true]
        let sigLen = try await js("""
            const w = window.__wallets[0];
            const [out] = await w.features['solana:signMessage'].signMessage({ account: w.accounts[0], message: new TextEncoder().encode('hi from the page') });
            return out.signature.length;
        """) as? Int
        XCTAssertEqual(sigLen, 64)
        XCTAssertEqual(p.shown.last?.lines.first, ["Site", "jup.ag"])
        // Disconnect from Settings reaches the page.
        d.sites.disconnect("https://jup.ag")
        try await Task.sleep(for: .milliseconds(200))
        let after = try await js("return window.__wallets[0].accounts.length + '|' + window.solana.isConnected") as? String
        XCTAssertEqual(after, "0|false")
        _ = (bridge, nav)
    }

    /// Live (HERMIT_LIVE_DAPP=1): jup.ag's wallet list shows Hermit.
    func testLiveJupiterListsHermit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMIT_LIVE_DAPP"] == "1", "set HERMIT_LIVE_DAPP=1")
        let target = ProcessInfo.processInfo.environment["HERMIT_SOL_DAPP_URL"] ?? "https://jup.ag/"
        let (_, p, d) = try setup(phrase: nil)
        let config = WKWebViewConfiguration()
        let bridge = DappWebBridge(provider: d)
        bridge.install(on: config)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 860), configuration: config)
        bridge.webView = wv
        let win = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1280, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        let nav = Loaded(); wv.navigationDelegate = nav
        await withCheckedContinuation { c in nav.done = c; wv.load(URLRequest(url: URL(string: target)!)) }
        func js(_ b: String) async throws -> Any? { try await wv.callAsyncJavaScript(b, arguments: [:], in: nil, contentWorld: .page) }
        try await Task.sleep(for: .seconds(10))
        let clicked = try await js("""
            const b = [...document.querySelectorAll('button, [role=button]')].find(e => /^(connect|connect wallet|sign in|log in)$/i.test((e.innerText || '').trim()) && e.offsetParent !== null);
            if (b) { b.click(); return b.innerText.trim(); } return null;
        """) as? String
        try await Task.sleep(for: .seconds(5))
        let around = try await js("""
            const e = [...document.querySelectorAll('*')].find(e => e.children.length === 0 && (e.textContent || '').trim() === 'Hermit' && e.offsetParent !== null);
            if (!e) return ''; let p = e; for (let i = 0; i < 6 && p.parentElement; i++) p = p.parentElement; return p.innerText.replace(/\\n+/g, ' | ').slice(0, 400);
        """) as? String ?? ""
        print("jup clicked:", clicked ?? "nothing", "| around Hermit:", around)
        XCTAssertNotNil(clicked, "no Connect button")
        XCTAssertFalse(around.isEmpty, "Hermit not listed")
        XCTAssertTrue(p.shown.isEmpty, "opening the wallet list must not prompt")
        _ = (win, bridge, nav)
    }
    #endif
}
