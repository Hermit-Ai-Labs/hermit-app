import XCTest
import CryptoKit
import HermitCore
@testable import HermitWallet
#if canImport(WebKit)
import WebKit
#endif

/// NEAR in Hermit's browser (HOT near-connect injected wallet + NEP-408 window.near.hermit). The byte vectors were
/// written by near-api-js (@near-js/transactions 1.x encodeTransaction) and, for NEP-413, by borsh-js with the
/// wallet-selector payload schema, signed with @noble/curves ed25519 from seed 00 01 … 1f. Nothing here broadcasts.
@MainActor
final class NearDappTests: XCTestCase {
    // MARK: Vectors (near-api-js)

    static let seed = [UInt8](0..<32)
    static let account = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
    static let siteKey = "ed25519:J2xccRtuG43drESLYznHhLhQkLTdfepcKYbiQ9BsJVaf"
    static let header = "40000000303361313037626666336365313062653164373064643138653734626330393936376534643633303962613530643566316464633836363431323535333162380003a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b80500000000000000"
    static let block = [UInt8](repeating: 3, count: 32)

    func tx(_ receiver: String, _ actions: [NearAction]) -> String {
        NearTransaction(signer: Self.account, publicKey: [UInt8](hex: Self.account)!, nonce: 5, receiver: receiver, blockHash: Self.block, actions: actions).serialized.hex
    }
    func action(_ j: JSON, receiver: String = account) throws -> NearAction { try NearDapp.action(j, account: Self.account, receiver: receiver) }
    func refused(_ body: () throws -> Any, code: Int = 4200, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try body(); XCTFail("expected a refusal", file: file, line: line) }
        catch let e as DappRPCError { XCTAssertEqual(e.code, code, e.message, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testFunctionCallKeyBytesMatchNearApiJs() throws {
        let limited = try action(["type": "AddKey", "params": ["publicKey": .string(Self.siteKey), "accessKey": ["nonce": 0,
                                  "permission": ["receiverId": "nearhunt.near", "allowance": "250000000000000000000000", "methodNames": []]]]])
        XCTAssertEqual(tx(Self.account, [limited]), Self.header + "40000000303361313037626666336365313062653164373064643138653734626330393936376534643633303962613530643566316464633836363431323535333162380303030303030303030303030303030303030303030303030303030303030303010000000500fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f61800000000000000000001000040683bb3f386f0340000000000000d0000006e65617268756e742e6e65617200000000")
        // No allowance: Option::None, as near-api-js writes it.
        let unlimited = try action(["type": "AddKey", "params": ["publicKey": .string(Self.siteKey), "accessKey": [
                                    "permission": ["receiverId": "nearhunt.near", "methodNames": ["vote", "comment"]]]]])
        XCTAssertEqual(unlimited, .addFunctionCallKey(publicKey: try NearDapp.publicKey(.string(Self.siteKey)), allowance: nil, receiver: "nearhunt.near", methods: ["vote", "comment"]))
        XCTAssertEqual(tx(Self.account, [unlimited]), Self.header + "40000000303361313037626666336365313062653164373064643138653734626330393936376534643633303962613530643566316464633836363431323535333162380303030303030303030303030303030303030303030303030303030303030303010000000500fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618000000000000000000000d0000006e65617268756e742e6e6561720200000004000000766f746507000000636f6d6d656e74")
        let del = try action(["type": "DeleteKey", "params": ["publicKey": .string(Self.siteKey)]])
        XCTAssertEqual(tx(Self.account, [del]), Self.header + "40000000303361313037626666336365313062653164373064643138653734626330393936376534643633303962613530643566316464633836363431323535333162380303030303030303030303030303030303030303030303030303030303030303010000000600fd1724385aa0c75b64fb78cd602fa1d991fdebf76b13c58ed702eac835e9f618")
        // The sign-in key from near-connect's addFunctionCallKey is the same action.
        let k = try NearDapp.functionCallKey(["contractId": "nearhunt.near", "publicKey": .string(Self.siteKey), "allowMethods": ["anyMethod": true],
                                              "gasAllowance": ["kind": "limited", "amount": "250000000000000000000000"]], account: Self.account)
        XCTAssertEqual(k.action, limited)
        let def = try NearDapp.functionCallKey(["contractId": "nearhunt.near", "publicKey": .string(Self.siteKey), "allowMethods": ["anyMethod": true]], account: Self.account)
        XCTAssertEqual(def.allowance, NearDapp.defaultAllowance)
        let open = try NearDapp.functionCallKey(["contractId": "nearhunt.near", "publicKey": .string(Self.siteKey), "allowMethods": ["anyMethod": false, "methodNames": ["vote"]],
                                                 "gasAllowance": ["kind": "unlimited"]], account: Self.account)
        XCTAssertEqual(open.allowance, nil); XCTAssertEqual(open.methods, ["vote"])
        // anyMethod false with no names would quietly mean "any method": refused.
        refused({ try NearDapp.functionCallKey(["contractId": "nearhunt.near", "publicKey": .string(Self.siteKey), "allowMethods": ["anyMethod": false]], account: Self.account) }, code: -32602)
    }

    func testFunctionCallArgsAndTransfer() throws {
        let args = #"{"project_id":42,"up":true}"#
        let expected = Self.header + "0d0000006e65617268756e742e6e6561720303030303030303030303030303030303030303030303030303030303030303020000000204000000766f74651b0000007b2270726f6a6563745f6964223a34322c227570223a747275657d00e057eb481b0000000040b2bac9e0191e0200000000000003000000a1edccce1bc2d3000000000000"
        let transfer: JSON = ["type": "Transfer", "params": ["deposit": "1000000000000000000000000"]]
        // The page script's form: the exact JSON text the page serialized.
        for a in [JSON.object(["$hermitJSON": .string(args)]),
                  .object(["$hermitBytes": .string(Data(args.utf8).base64EncodedString())]),
                  .string(Data(args.utf8).base64EncodedString()),
                  .array(Array(args.utf8).map { .number(Double($0)) }),
                  ["project_id": 42, "up": true]] {
            let call = try action(["type": "FunctionCall", "params": ["methodName": "vote", "args": a, "gas": "30000000000000", "deposit": "10000000000000000000000"]], receiver: "nearhunt.near")
            XCTAssertEqual(tx("nearhunt.near", [call, try action(transfer, receiver: "nearhunt.near")]), expected, "\(a)")
        }
        // Numbers for gas, and missing args/deposit.
        XCTAssertEqual(try action(["type": "FunctionCall", "params": ["methodName": "ping", "gas": 5_000_000_000_000]], receiver: "x.near"),
                       .functionCall(method: "ping", args: [], gas: 5_000_000_000_000, deposit: 0))
        refused({ try self.action(["type": "FunctionCall", "params": ["methodName": "x", "args": "not base64!"]], receiver: "x.near") }, code: -32602)
        refused({ try self.action(["type": "FunctionCall", "params": ["methodName": "x", "gas": "300000000000001"]], receiver: "x.near") }, code: -32602)
        refused({ try self.action(["type": "Transfer", "params": ["deposit": "-1"]], receiver: "x.near") }, code: -32602)
        refused({ try self.action(["type": "Transfer", "params": ["deposit": "1e24"]], receiver: "x.near") }, code: -32602)
    }

    func testRefusals() throws {
        let fullAccess: [JSON] = ["FullAccess", ["fullAccess": [:]], ["FullAccess": .null]]
        for perm in fullAccess {
            refused { try self.action(["type": "AddKey", "params": ["publicKey": .string(Self.siteKey), "accessKey": ["nonce": 0, "permission": perm]]]) }
        }
        refused { try self.action(["type": "AddKey", "params": ["publicKey": .string(Self.siteKey), "accessKey": ["permission": [:]]]]) }
        refused { try self.action(["type": "AddKey", "params": ["publicKey": .string(Self.siteKey), "gasKeyInfo": ["balance": "1"],
                                                                "accessKey": ["permission": ["receiverId": "a.near", "methodNames": []]]]]) }
        for t in ["DeleteAccount", "DeployContract", "DeployGlobalContract", "UseGlobalContract", "Stake", "CreateAccount", "SignedDelegate", "TransferToGasKey", "Mystery"] {
            refused { try self.action(["type": .string(t), "params": ["beneficiaryId": "evil.near"]]) }
        }
        // Hermit's own key: never removed, never re-added.
        let own: JSON = .string(NearAccount.publicKeyString([UInt8](hex: Self.account)!))
        refused { try self.action(["type": "DeleteKey", "params": ["publicKey": own]]) }
        refused { try self.action(["type": "AddKey", "params": ["publicKey": own, "accessKey": ["permission": ["receiverId": "a.near"]]]]) }
        // Keys only on your own account; other key types refused.
        refused({ try self.action(["type": "DeleteKey", "params": ["publicKey": .string(Self.siteKey)]], receiver: "other.near") }, code: -32602)
        refused { try self.action(["type": "DeleteKey", "params": ["publicKey": "secp256k1:abc"]]) }
        // Testnet and other networks.
        XCTAssertNoThrow(try NearDapp.checkNetwork(nil))
        XCTAssertNoThrow(try NearDapp.checkNetwork("mainnet"))
        XCTAssertNoThrow(try NearDapp.checkNetwork(["networkId": "mainnet"]))
        refused { try NearDapp.checkNetwork("testnet") }
        refused { try NearDapp.checkNetwork(["networkId": "testnet"]) }
        // signerId must be the connected account; receivers must be valid.
        let call: JSON = ["type": "FunctionCall", "params": ["methodName": "vote", "args": [:], "gas": "30000000000000", "deposit": "0"]]
        refused({ try NearDapp.transactions(["transactions": [["signerId": "alice.near", "receiverId": "nearhunt.near", "actions": [call]]]], account: Self.account) }, code: 4100)
        refused({ try NearDapp.transactions(["transactions": [["receiverId": "Not Valid", "actions": [call]]]], account: Self.account) }, code: -32602)
        refused({ try NearDapp.transactions(["transactions": []], account: Self.account) }, code: -32602)
        let ok = try NearDapp.transactions(["transactions": [["signerId": .string(Self.account), "receiverId": "nearhunt.near", "actions": [call]]]], account: Self.account)
        XCTAssertEqual(ok, [NearDapp.Tx(receiver: "nearhunt.near", actions: [.functionCall(method: "vote", args: Array("{}".utf8), gas: 30 * NearAction.tgas, deposit: 0)])])
    }

    func testReviewWords() throws {
        let txs = try NearDapp.transactions(["transactions": [
            ["receiverId": "nearhunt.near", "actions": [["type": "FunctionCall", "params": ["methodName": "vote", "args": ["$hermitJSON": #"{"id":1}"#],
                                                                                              "gas": "30000000000000", "deposit": "100000000000000000000000"]]]],
            ["receiverId": "bob.near", "actions": [["type": "Transfer", "params": ["deposit": "2500000000000000000000000"]]]]]], account: Self.account)
        let r = NearDapp.review(txs, account: Self.account)
        XCTAssertEqual(r.title, "2 transactions")
        XCTAssertEqual(r.deposit, 2_600_000_000_000_000_000_000_000)
        XCTAssertNil(r.payee)   // a call attaches NEAR too
        XCTAssertTrue(r.lines.contains(["Calls", "vote on nearhunt.near"]), "\(r.lines)")
        XCTAssertTrue(r.lines.contains(["Arguments", #"{"id":1}"#]))
        XCTAssertTrue(r.lines.contains(["Gas", "30 Tgas"]))
        XCTAssertTrue(r.lines.contains(["Deposit", "0.1 NEAR"]))
        XCTAssertTrue(r.lines.contains(["Sends", "2.5 NEAR to bob.near"]))
        XCTAssertTrue(r.warnings.contains { $0.contains("attaches 0.1 NEAR to nearhunt.near") }, "\(r.warnings)")
        XCTAssertEqual(NearDapp.usd(r.deposit, price: 2), Decimal(string: "5.2"))
        XCTAssertNil(NearDapp.usd(r.deposit, price: nil))

        let send = NearDapp.review([NearDapp.Tx(receiver: "bob.near", actions: [.transfer(deposit: NearDapp.oneNear)])], account: Self.account)
        XCTAssertEqual(send.title, "Send 1 NEAR"); XCTAssertEqual(send.payee, "bob.near")
        let yocto = NearDapp.review([NearDapp.Tx(receiver: "usdt.tether-token.near", actions: [.ftTransfer(receiver: "bob.near", amount: 5)])], account: Self.account)
        XCTAssertEqual(yocto.title, "Call ft_transfer")
        XCTAssertTrue(yocto.warnings.contains { $0.contains("1 yoctoNEAR") }, "\(yocto.warnings)")
    }

    // MARK: NEP-413

    func testNep413PayloadMatchesReference() throws {
        let nonce = [UInt8](repeating: 7, count: 32)
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.seed).publicKey
        XCTAssertEqual([UInt8](pub.rawRepresentation).hex, Self.account)
        for (cb, payload, hash, sig) in [
            (nil as String?, "9d010080130000005369676e20696e20746f206e65617268756e7407070707070707070707070707070707070707070707070707070707070707070c0000006e65617268756e742e78797a00",
             "6f81ec9ef6c51944f124adde35588912bde9aef14e7a199bbdc67fae3ebdc6a7", "vGTlzlj6YLlXeB7IvCAPuAU/LZ4/kl3AHoa9fzRu+/9WCrKEZepjl3byy80Inx7/cLhVGdSG0MX8yYbCAvx0Cw=="),
            ("https://nearhunt.xyz/cb", "9d010080130000005369676e20696e20746f206e65617268756e7407070707070707070707070707070707070707070707070707070707070707070c0000006e65617268756e742e78797a011700000068747470733a2f2f6e65617268756e742e78797a2f6362",
             "de850f236a8e0859f666b52f422d9917bafc521663b6d16245ca9b73cb356ad9", "rYEhllFX0D25AXpVDaurzXvQVmJ0sCMtjuZXyX15qkHkihZaxzr5p+9d7d7HWTT70Q39H9ImeXZqm+dKdEMWCQ=="),
        ] {
            let p = NearDapp.nep413Payload(message: "Sign in to nearhunt", nonce: nonce, recipient: "nearhunt.xyz", callbackUrl: cb)
            XCTAssertEqual(p.hex, payload)
            XCTAssertEqual(Hash.sha256(p).hex, hash)
            // The reference signature (deterministic ed25519) verifies over our hash with the same key.
            XCTAssertTrue(pub.isValidSignature(Data(base64Encoded: sig)!, for: Data(Hash.sha256(p))))
        }
        XCTAssertEqual(try NearDapp.nonce(["$hermitBytes": .string(Data(nonce).base64EncodedString())]), nonce)
        XCTAssertEqual(try NearDapp.nonce(.string(Data(nonce).base64EncodedString())), nonce)
        XCTAssertEqual(try NearDapp.nonce(.array(nonce.map { .number(Double($0)) })), nonce)
        refused({ try NearDapp.nonce(.string(Data(nonce.prefix(31)).base64EncodedString())) }, code: -32602)
    }

    // MARK: Provider

    final class Presenter: DappPresenter {
        var approve: [Bool] = []
        var shown: [Approval] = []
        var notices: [String] = []
        func present(_ a: Approval) async {
            shown.append(a)
            // Never approve anything that would broadcast.
            if !approve.isEmpty, approve.removeFirst(), !a.success.hasPrefix("Sent"), !a.title.hasPrefix("Sign in") { _ = try? await a.perform?() }
        }
        func notice(_ text: String) { notices.append(text) }
    }

    var defaults: UserDefaults!
    override func setUp() async throws { defaults = UserDefaults(suiteName: "hermit.near.tests.\(UUID().uuidString)")! }

    func setup() throws -> (WalletService, Presenter, DappProvider) {
        let s = WalletService(vault: KeyVault(store: MemoryStore()), addressBook: AddressBook(defaults: defaults),
                              spendLimit: SpendLimit(defaults: defaults), sendLog: SendLog(defaults: defaults))
        try s.importWallet(phrase: SolanaDappTests.abandon, name: "Test")
        let p = Presenter(), d = DappProvider(service: s, sites: DappPermissions(defaults: defaults))
        d.presenter = p; d.knownHosts = ["nearhunt.xyz"]; d.prices = { ["NEAR": 2] }
        return (s, p, d)
    }
    let hunt = DappOrigin(scheme: "https", host: "nearhunt.xyz", port: nil)
    func call(_ d: DappProvider, _ m: String, _ p: JSON = [:]) async -> Result<JSON, DappRPCError> {
        await d.handle(method: m, params: [p], origin: hunt)
    }

    func testProviderConnectSignMessageAndRefusals() async throws {
        let (s, p, d) = try setup()
        let account = try XCTUnwrap(s.wallets[0].nearAccount)
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap([UInt8](hex: account)))
        let none = await call(d, "near_accounts", ["network": "mainnet"])
        XCTAssertEqual(none, .success([]))
        if case .failure(let e) = await call(d, "near_signMessage", ["message": "hi", "recipient": "nearhunt.xyz", "nonce": .string(Data(count: 32).base64EncodedString())]) {
            XCTAssertEqual(e.code, 4100)
        } else { XCTFail() }
        if case .failure(let e) = await call(d, "near_signIn", ["network": "testnet"]) { XCTAssertEqual(e.code, 4200) } else { XCTFail() }
        XCTAssertTrue(p.shown.isEmpty)

        p.approve = [false]
        let no = await call(d, "near_signIn", ["network": "mainnet"])
        XCTAssertEqual(no, .failure(DappRPCError(4001, "User rejected")))
        p.approve = [true]
        let accounts = try await call(d, "near_signIn", ["network": "mainnet"]).get()
        XCTAssertEqual(accounts, [["accountId": .string(account), "publicKey": .string(NearAccount.publicKeyString(pub.rawRepresentation.bytes))]])
        XCTAssertEqual(p.shown.last?.title, "Connect to nearhunt.xyz")
        XCTAssertTrue(p.shown.last?.lines.contains(["Network", "NEAR"]) == true, "\(p.shown.last?.lines ?? [])")
        XCTAssertEqual(d.sites.site(hunt)?.near, account)
        XCTAssertNil(d.account(for: hunt)); XCTAssertNil(d.solanaAccount(for: hunt))
        let listed = try await call(d, "near_accounts").get()
        XCTAssertEqual(listed, accounts)
        // Connected already: no second sheet.
        let shown = p.shown.count
        let again = try await call(d, "near_signIn").get()
        XCTAssertEqual(again, accounts)
        XCTAssertEqual(p.shown.count, shown)

        // NEP-413 message: reviewed, then signed over sha256(payload) with the account's key.
        let nonce = [UInt8](repeating: 7, count: 32)
        p.approve = [true]
        let signed = try await call(d, "near_signMessage", ["message": "Sign in to nearhunt", "recipient": "nearhunt.xyz",
                                                            "nonce": ["$hermitBytes": .string(Data(nonce).base64EncodedString())], "network": "mainnet"]).get()
        XCTAssertEqual(signed["accountId"]?.string, account)
        let sig = try XCTUnwrap(signed["signature"]?.string.flatMap { Data(base64Encoded: $0) })
        let digest = Hash.sha256(NearDapp.nep413Payload(message: "Sign in to nearhunt", nonce: nonce, recipient: "nearhunt.xyz", callbackUrl: nil))
        XCTAssertTrue(pub.isValidSignature(sig, for: Data(digest)))
        let sheet = try XCTUnwrap(p.shown.last)
        XCTAssertEqual(sheet.title, "Sign a message")
        XCTAssertTrue(sheet.lines.contains(["Message", "Sign in to nearhunt"]))
        XCTAssertTrue(sheet.warnings.allSatisfy { !$0.contains("addressed to") }, "\(sheet.warnings)")
        // A message for another recipient warns.
        p.approve = [false]
        _ = await call(d, "near_signMessage", ["message": "x", "recipient": "evil.example", "nonce": .string(Data(nonce).base64EncodedString())])
        XCTAssertTrue(p.shown.last?.warnings.contains { $0.contains("addressed to evil.example") } == true)

        // Refused before any sheet (and before any network read).
        let before = p.shown.count
        let fullKey: JSON = ["transactions": [["receiverId": .string(account), "actions": [["type": "AddKey", "params": ["publicKey": .string(Self.siteKey), "accessKey": ["nonce": 0, "permission": "FullAccess"]]]]]]]
        if case .failure(let e) = await call(d, "near_signAndSendTransactions", fullKey) { XCTAssertEqual(e.code, 4200); XCTAssertTrue(e.message.contains("full-access"), e.message) } else { XCTFail() }
        let delAcct: JSON = ["transactions": [["receiverId": .string(account), "actions": [["type": "DeleteAccount", "params": ["beneficiaryId": "evil.near"]]]]]]
        if case .failure(let e) = await call(d, "near_signAndSendTransactions", delAcct) { XCTAssertEqual(e.code, 4200) } else { XCTFail() }
        let vote: JSON = ["type": "FunctionCall", "params": ["methodName": "vote", "args": [:], "gas": "30000000000000", "deposit": "0"]]
        if case .failure(let e) = await call(d, "near_signAndSendTransactions", ["network": "testnet", "transactions": [["receiverId": "nearhunt.near", "actions": [vote]]]]) {
            XCTAssertEqual(e.code, 4200)
        } else { XCTFail() }
        if case .failure(let e) = await call(d, "near_signAndSendTransactions", ["transactions": [["signerId": "alice.near", "receiverId": "nearhunt.near", "actions": [vote]]]]) {
            XCTAssertEqual(e.code, 4100)
        } else { XCTFail() }
        XCTAssertEqual(p.shown.count, before)

        // signOut drops the NEAR connection; with nothing else connected the site is gone.
        let out = await call(d, "near_signOut", ["network": "mainnet"])
        XCTAssertEqual(out, .success(.null))
        XCTAssertNil(d.sites.site(hunt))
        let gone = await call(d, "near_accounts")
        XCTAssertEqual(gone, .success([]))
    }

    func testPermissionsKeepOtherChains() throws {
        let sites = DappPermissions(defaults: defaults), id = UUID()
        sites.connectSolana(hunt, walletID: id, address: "So1")
        sites.connectNear(hunt, walletID: id, account: Self.account)
        XCTAssertEqual(sites.site(hunt)?.solana, "So1"); XCTAssertEqual(sites.site(hunt)?.near, Self.account)
        sites.disconnectSolana(hunt)
        XCTAssertEqual(sites.site(hunt)?.near, Self.account)
        sites.disconnectNear(hunt)
        XCTAssertNil(sites.site(hunt))
        // Another wallet replaces the old wallet's connections.
        sites.connectNear(hunt, walletID: id, account: Self.account)
        sites.connectSolana(hunt, walletID: UUID(), address: "So2")
        XCTAssertNil(sites.site(hunt)?.near)
        // Lists saved before NEAR still load.
        let old = #"[{"origin":"https://a.xyz","walletID":"\#(id.uuidString)","address":"","chainID":1,"solana":"So1","connected":0,"lastUsed":0}]"#
        defaults.set(Data(old.utf8), forKey: "hermit.dapps.sites")
        XCTAssertEqual(DappPermissions(defaults: defaults).sites.first?.solana, "So1")
    }

    // MARK: In a real WKWebView

    #if canImport(WebKit) && os(macOS)
    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
    }

    func testNearWalletInWebView() async throws {
        let (s, p, d) = try setup()
        let account = try XCTUnwrap(s.wallets[0].nearAccount)
        let config = WKWebViewConfiguration()
        let bridge = DappWebBridge(provider: d)
        bridge.install(on: config)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        bridge.webView = wv
        let nav = Loaded(); wv.navigationDelegate = nav
        // A near-connect page: it listens for injected wallets, then says it is ready (as NearConnector does).
        let html = """
        <html><body><script>
        window.__wallets = [];
        window.addEventListener('near-wallet-injected', e => window.__wallets.unshift(e.detail));
        window.dispatchEvent(new Event('near-selector-ready'));
        </script></body></html>
        """
        await withCheckedContinuation { c in nav.done = c; wv.loadHTMLString(html, baseURL: URL(string: "https://nearhunt.xyz/")!) }
        func js(_ b: String) async throws -> Any? { try await wv.callAsyncJavaScript(b, arguments: [:], in: nil, contentWorld: .page) }
        let info = try await js("""
            const w = window.__wallets[0], m = w.manifest, n = window.near.hermit;
            return JSON.stringify({ n: window.__wallets.length, id: m.id, name: m.name, type: m.type, icon: m.icon.startsWith('data:image/svg+xml;base64,'),
              fck: m.features.signInWithFunctionCallKey, testnet: m.features.testnet, fns: Object.keys(w).filter(k => typeof w[k] === 'function').sort(),
              nep408: n.id, connected: n.connected, net: n.network.networkId, accounts: await w.getAccounts({ network: 'mainnet' }) });
        """) as? String ?? ""
        XCTAssertEqual(info, #"{"n":1,"id":"hermit-wallet","name":"Hermit","type":"injected","icon":true,"fck":true,"testnet":false,"fns":["getAccounts","signAndSendTransaction","signAndSendTransactions","signDelegateActions","signIn","signInAndSignMessage","signMessage","signOut"],"nep408":"hermit","connected":false,"net":"mainnet","accounts":[]}"#)
        p.approve = [false]
        let rejected = try await js("try { await window.__wallets[0].signIn({ network: 'mainnet' }); return 'ok' } catch (e) { return e.message }") as? String
        XCTAssertEqual(rejected, "User rejected")
        p.approve = [true]
        let signedIn = try await js("""
            let changes = 0; window.near.hermit.on('accountsChanged', () => changes++);
            const a = await window.__wallets[0].signIn({ network: 'mainnet' });
            return a[0].accountId + '|' + a[0].publicKey.startsWith('ed25519:') + '|' + window.near.hermit.connected + '|' + changes + '|' + window.near.hermit.accounts[0].publicKey.data.length;
        """) as? String
        XCTAssertEqual(signedIn, "\(account)|true|true|1|32")
        // bigint gas and a FullAccess near-api-js-style AddKey: normalized by the page script, refused natively.
        let refusedText = try await js("""
            try { await window.near.hermit.signAndSendTransaction({ receiverId: '\(account)', actions: [{ addKey: { publicKey: { toString: () => 'x' }, accessKey: { nonce: 0n, permission: { fullAccess: {} } } } }] }); return 'signed?' }
            catch (e) { return e.message }
        """) as? String
        XCTAssertTrue(refusedText?.contains("full-access") == true, refusedText ?? "nil")
        p.approve = [true]
        let sig = try await js("""
            const r = await window.__wallets[0].signMessage({ message: 'hello', recipient: 'nearhunt.xyz', nonce: new Uint8Array(32).fill(1), network: 'mainnet' });
            return r.accountId + '|' + atob(r.signature).length;
        """) as? String
        XCTAssertEqual(sig, "\(account)|64")
        // Disconnect from Settings reaches the page.
        d.sites.disconnect("https://nearhunt.xyz")
        try await Task.sleep(for: .milliseconds(200))
        let after = try await js("return String(window.near.hermit.connected)") as? String
        XCTAssertEqual(after, "false")
        _ = (bridge, nav)
    }
    #endif
}
