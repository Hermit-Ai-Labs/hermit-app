import XCTest
import HermitCore
@testable import HermitWallet
#if canImport(WebKit)
import WebKit
#endif

/// Hermit's browser wallet (EIP-1193). Vectors: personal_sign and the EIP-712 "Ether Mail" example signed with the
/// public test phrase by eth-account 0.14 (an independent implementation). Nothing here broadcasts: every
/// eth_sendTransaction test cancels at the approval sheet, and the wallets are fresh, empty or the public test phrase.
@MainActor
final class DappProviderTests: XCTestCase {
    nonisolated static let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let testAddress = "0x9858effd232b4033e47d90003d41ec34ecaeda94"
    static let personalVector = "0xffbf7f38fdccffe780e16cbbb6fcdcab83cb676de258256138afe28a5810845b6ad2522015fe499448d8166dabd9a5c2cd8feab7ca6b7ee2a27e0380d0a598b81b"
    static let typedVector = "0x5b9ee7ebad3acd6ca243732900203a8a9e59b871345cb9b229a1936e11f5ad8967c46a0d05027ccd880bcc49e18877a53b8e4813558a1fd165ebb875c4a447c21c"
    static let mail = #"{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Person":[{"name":"name","type":"string"},{"name":"wallet","type":"address"}],"Mail":[{"name":"from","type":"Person"},{"name":"to","type":"Person"},{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Ether Mail","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},"message":{"from":{"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},"to":{"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},"contents":"Hello, Bob!"}}"#

    var defaults: UserDefaults!
    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "hermit.dapp.tests.\(UUID().uuidString)")!
    }

    func service(phrase: String? = abandon) throws -> WalletService {
        let s = WalletService(vault: KeyVault(store: MemoryStore()), addressBook: AddressBook(defaults: defaults),
                              spendLimit: SpendLimit(defaults: defaults), sendLog: SendLog(defaults: defaults))
        if let phrase { try s.importWallet(phrase: phrase, name: "Test") } else { try s.createWallet(name: "Empty") }
        return s
    }

    final class Presenter: DappPresenter {
        var approve: [Bool] = []
        var shown: [Approval] = []
        var notices: [String] = []
        func present(_ a: Approval) async {
            shown.append(a)
            // Only signatures and connects are ever approved in tests; transactions always cancel.
            if !approve.isEmpty, approve.removeFirst(), !a.kind.hasPrefix("Transaction") { _ = try? await a.perform?() }
        }
        func notice(_ text: String) { notices.append(text) }
    }

    let site = DappOrigin(scheme: "https", host: "app.uniswap.org", port: nil)

    // MARK: Signing vectors

    func testPersonalSignVector() async throws {
        let s = try service()
        let sig = try await s.dappPersonalSign(walletID: s.wallets[0].id, message: Array("Hello from Hermit".utf8), reason: "test")
        XCTAssertEqual(sig, Self.personalVector)
    }

    func testTypedDataVector() async throws {
        let s = try service()
        let sig = try await s.dappSignTypedData(walletID: s.wallets[0].id, typedData: try EIP712(json: Data(Self.mail.utf8)), reason: "test")
        XCTAssertEqual(sig, Self.typedVector)
    }

    // MARK: Decoding

    func testDecodeUnlimitedApprove() async throws {
        let usdc = EVMAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")!
        let spender = EVMAddress("0x000000000022D473030F116dDEE9F6B43aC78BA3")!
        let data = DappDecoder.approveSel + ERC20.word(spender) + [UInt8](repeating: 0xff, count: 32)
        let r = DappTransactionRequest(from: EVMAddress(Self.testAddress)!, to: usdc, value: 0, data: data, gas: nil)
        let i = await DappDecoder.transaction(r, chain: .base, client: EVMClient(url: Chain.base.rpc), prices: [:])
        XCTAssertEqual(i.title, "Approve unlimited USDC")
        XCTAssertTrue(i.lines.contains(["Allowance", "Unlimited"]))
        XCTAssertTrue(i.warnings.first?.hasPrefix("Unlimited approval") == true)
        XCTAssertFalse(i.movesFunds)

        let exact = DappDecoder.approveSel + ERC20.word(spender) + ERC20.word(UInt128(25_000_000))
        let j = await DappDecoder.transaction(DappTransactionRequest(from: r.from, to: usdc, value: 0, data: exact, gas: nil),
                                              chain: .base, client: EVMClient(url: Chain.base.rpc), prices: [:])
        XCTAssertEqual(j.title, "Approve 25 USDC")
    }

    func testDecodeTransferAndNative() async throws {
        let usdc = EVMAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")!
        let to = EVMAddress("0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB")!
        let r = DappTransactionRequest(from: EVMAddress(Self.testAddress)!, to: usdc, value: 0,
                                       data: ERC20.transfer(to: to, amount: 12_500_000), gas: nil)
        let i = await DappDecoder.transaction(r, chain: .base, client: EVMClient(url: Chain.base.rpc), prices: [:])
        XCTAssertEqual(i.title, "Send 12.5 USDC")
        XCTAssertEqual(i.payee, to); XCTAssertEqual(i.outflowUSD, Decimal(string: "12.5")); XCTAssertTrue(i.movesFunds)

        let n = DappTransactionRequest(from: r.from, to: to, value: 500_000_000_000_000_000, data: [], gas: nil)
        let k = await DappDecoder.transaction(n, chain: .base, client: EVMClient(url: Chain.base.rpc), prices: ["ETH": 3000])
        XCTAssertEqual(k.title, "Send 0.5 ETH"); XCTAssertEqual(k.outflowUSD, 1500)
    }

    /// An undecoded contract call (a router swap with no ETH attached): the eth_simulateV1 answer becomes "You send" and
    /// "You get" lines and the amount the spending policy counts. Shape as publicnode returned it on 2026-11-10.
    func testSimulatedTransfersOnUndecodedCall() async throws {
        let me = EVMAddress(Self.testAddress)!, router = EVMAddress("0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD")!
        let usdc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", eth = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        func transfer(_ token: String, _ from: EVMAddress, _ to: EVMAddress, _ amount: UInt128) -> JSON {
            .object(["address": .string(token),
                     "topics": .array([.string(EVMClient.transferTopic), .string(ERC20.word(from).hex0x), .string(ERC20.word(to).hex0x)]),
                     "data": .string(ERC20.word(amount).hex0x)])
        }
        func answer(_ logs: [JSON], status: String = "0x1") -> JSON {
            .array([.object(["calls": .array([.object(["status": .string(status), "logs": .array(logs)])])])])
        }
        // 25 USDC out, 0.01 ETH back, plus a transfer between two other addresses that isn't ours.
        let sim = try EVMClient.parseSimulatedTransfers(answer([transfer(usdc, me, router, 25_000_000), transfer(eth, router, me, 10_000_000_000_000_000),
                                                                transfer(usdc, router, router, 7)]), wallet: me)
        XCTAssertEqual(sim.changes, [EVMBalanceChange(token: nil, sent: 0, received: 10_000_000_000_000_000),
                                     EVMBalanceChange(token: EVMAddress(usdc)!, sent: 25_000_000, received: 0)])
        XCTAssertThrowsError(try EVMClient.parseSimulatedTransfers(answer([], status: "0x0"), wallet: me))
        XCTAssertThrowsError(try EVMClient.parseSimulatedTransfers(.array([]), wallet: me))

        let r = DappTransactionRequest(from: me, to: router, value: 0, data: [0x12, 0x34, 0x56, 0x78] + ERC20.word(UInt128(1)), gas: nil)
        let client = EVMClient(url: Chain.base.rpc)
        var i = await DappDecoder.transaction(r, chain: .base, client: client, prices: ["ETH": 3000])
        XCTAssertFalse(i.decoded); XCTAssertFalse(i.movesFunds)
        await DappDecoder.applySimulation(&i, sim, request: r, chain: .base, client: client, prices: ["ETH": 3000])
        XCTAssertTrue(i.lines.contains(["You send", "25 USDC"]), "\(i.lines)")
        XCTAssertTrue(i.lines.contains(["You get", "0.01 ETH"]), "\(i.lines)")
        XCTAssertTrue(i.movesFunds); XCTAssertEqual(i.outflowUSD, 25); XCTAssertNil(i.payee)

        // No simulation (the network lacks eth_simulateV1): still counted as moving funds, of unknown value.
        var j = await DappDecoder.transaction(r, chain: .base, client: client, prices: [:])
        await DappDecoder.applySimulation(&j, nil, request: r, chain: .base, client: client, prices: [:])
        XCTAssertTrue(j.movesFunds); XCTAssertNil(j.outflowUSD)
        XCTAssertTrue(j.warnings.contains { $0.hasPrefix("Hermit can't decode this call, so") }, "\(j.warnings)")
    }

    func testDecodePermit2TypedData() async throws {
        let json = #"{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"PermitSingle":[{"name":"details","type":"PermitDetails"},{"name":"spender","type":"address"},{"name":"sigDeadline","type":"uint256"}],"PermitDetails":[{"name":"token","type":"address"},{"name":"amount","type":"uint160"},{"name":"expiration","type":"uint48"},{"name":"nonce","type":"uint48"}]},"primaryType":"PermitSingle","domain":{"name":"Permit2","chainId":"8453","verifyingContract":"0x000000000022D473030F116dDEE9F6B43aC78BA3"},"message":{"details":{"token":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","amount":"1461501637330902918203684832716283019655932542975","expiration":"1765000000","nonce":"0"},"spender":"0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD","sigDeadline":"1763000000"}}"#
        let t = try EIP712(json: Data(json.utf8))
        let i = await DappDecoder.typedData(t, chain: .base, client: EVMClient(url: Chain.base.rpc))
        XCTAssertTrue(i.title.hasPrefix("Permit2"), i.title)
        XCTAssertTrue(i.lines.contains { $0[0] == "Allowance" && $0[1].hasPrefix("Unlimited") }, "\(i.lines)")
        XCTAssertTrue(i.warnings.first?.hasPrefix("Unlimited Permit2") == true)
    }

    func testMessageAndSignIn() {
        let ok = DappDecoder.message(Array("app.uniswap.org wants you to sign in with your Ethereum account:\n0x9858…".utf8), host: "app.uniswap.org")
        XCTAssertEqual(ok.title, "Sign in to app.uniswap.org"); XCTAssertTrue(ok.warnings.isEmpty)
        let bad = DappDecoder.message(Array("app.uniswap.org wants you to sign in with your Ethereum account:\n0x9858…".utf8), host: "uniswap-claim.xyz")
        XCTAssertTrue(bad.warnings.first?.contains("Phishing") == true)
        let hash = DappDecoder.message([UInt8](repeating: 0xab, count: 32), host: "x.org")
        XCTAssertTrue(hash.warnings.first?.contains("32-byte hash") == true)
    }

    func testSiteChecks() {
        let known = ["app.uniswap.org", "app.aave.com", "jup.ag", "pump.fun"]
        XCTAssertTrue(DappSiteCheck.isListed("app.uniswap.org", known: known))
        XCTAssertTrue(DappSiteCheck.isListed("uniswap.org", known: known))
        XCTAssertTrue(DappSiteCheck.warnings(host: "app.uniswap.org", known: known).isEmpty)
        XCTAssertTrue(DappSiteCheck.warnings(host: "app.uniswep.org", known: known).first?.contains("looks like uniswap.org") == true)
        XCTAssertTrue(DappSiteCheck.warnings(host: "app.unlswap.org", known: known).first?.contains("looks like uniswap.org") == true)
        XCTAssertTrue(DappSiteCheck.warnings(host: "app.aave.com.claim-rewards.io", known: known).first?.contains("contains aave.com") == true)
        XCTAssertTrue(DappSiteCheck.warnings(host: "xn--uniswp-zxa.org", known: known).first?.contains("punycode") == true)
        XCTAssertTrue(DappSiteCheck.warnings(host: "example.com", known: known).isEmpty)
    }

    // MARK: Provider (no web view)

    func provider(_ s: WalletService, _ p: Presenter) -> DappProvider {
        let d = DappProvider(service: s, sites: DappPermissions(defaults: defaults))
        d.presenter = p; d.knownHosts = ["app.uniswap.org"]; d.prices = { [:] }
        return d
    }

    func call(_ d: DappProvider, _ m: String, _ p: JSON = [], _ o: DappOrigin? = nil) async -> Result<JSON, DappRPCError> {
        await d.handle(method: m, params: p, origin: o ?? site)
    }

    func testConnectFlowAndSigning() async throws {
        let s = try service(), p = Presenter(), d = provider(s, p)
        let v1 = try await call(d, "eth_chainId").get()
        XCTAssertEqual(v1, "0x1")
        let v2 = try await call(d, "eth_accounts").get()
        XCTAssertEqual(v2, .array([]))
        let v3 = await call(d, "personal_sign", ["0x68656c6c6f", .string(Self.testAddress)])
        XCTAssertEqual(v3, .failure(.unauthorized))

        p.approve = [false]
        let v4 = await call(d, "eth_requestAccounts")
        XCTAssertEqual(v4, .failure(.rejected))
        XCTAssertEqual(p.shown.last?.title, "Connect to app.uniswap.org")
        XCTAssertTrue(p.shown.last?.lines.contains(["Site", "app.uniswap.org"]) == true)
        let v5 = try await call(d, "eth_accounts").get()
        XCTAssertEqual(v5, .array([]))

        p.approve = [true]
        let v6 = try await call(d, "eth_requestAccounts").get()
        XCTAssertEqual(v6, .array([.string(Self.testAddress)]))
        let v7 = try await call(d, "eth_accounts").get()
        XCTAssertEqual(v7, .array([.string(Self.testAddress)]))
        // Another origin sees nothing.
        let other = DappOrigin(scheme: "https", host: "app.aave.com", port: nil)
        let v8 = try await call(d, "eth_accounts", [], other).get()
        XCTAssertEqual(v8, .array([]))

        // personal_sign: cancelled, then approved. Hex and the [address, message] order both work.
        let hello = "0x" + Array("Hello from Hermit".utf8).hex
        p.approve = [false]
        let v9 = await call(d, "personal_sign", [.string(hello), .string(Self.testAddress)])
        XCTAssertEqual(v9, .failure(.rejected))
        p.approve = [true]
        let v10 = try await call(d, "personal_sign", [.string(hello), .string(Self.testAddress)]).get()
        XCTAssertEqual(v10, .string(Self.personalVector))
        p.approve = [true]
        let v11 = try await call(d, "personal_sign", [.string(Self.testAddress), .string(hello)]).get()
        XCTAssertEqual(v11, .string(Self.personalVector))
        let wrong = await call(d, "personal_sign", [.string(hello), "0x000000000000000000000000000000000000dEaD"])
        XCTAssertEqual(wrong, .failure(DappRPCError(4100, "The site asked for an account that isn't connected.")))

        // Typed data: the Ether Mail domain is chain 1, which the site is on.
        p.approve = [true]
        let v12 = try await call(d, "eth_signTypedData_v4", [.string(Self.testAddress), .string(Self.mail)]).get()
        XCTAssertEqual(v12, .string(Self.typedVector))
        XCTAssertEqual(p.shown.last?.title, "Sign for Ether Mail")

        // Switch to Base: typed data for chain 1 is now refused before any sheet.
        let shown = p.shown.count
        let v13 = try await call(d, "wallet_switchEthereumChain", [["chainId": "0x2105"]]).get()
        XCTAssertEqual(v13, .null)
        let v14 = try await call(d, "eth_chainId").get()
        XCTAssertEqual(v14, "0x2105")
        let r = await call(d, "eth_signTypedData_v4", [.string(Self.testAddress), .string(Self.mail)])
        XCTAssertEqual((try? r.get()), nil); if case .failure(let e) = r { XCTAssertEqual(e.code, -32602) }
        XCTAssertEqual(p.shown.count, shown)
        // The connection remembers Base.
        XCTAssertEqual(DappProvider(service: s, sites: d.sites).chain(for: site), .base)

        // Unknown chain, blind signing, deploys.
        if case .failure(let e) = await call(d, "wallet_switchEthereumChain", [["chainId": "0x999999"]]) { XCTAssertEqual(e.code, 4902) } else { XCTFail() }
        if case .failure(let e) = await call(d, "eth_sign", [.string(Self.testAddress), "0x00"]) { XCTAssertEqual(e.code, 4200) } else { XCTFail() }
        if case .failure(let e) = await call(d, "eth_sendTransaction", [["from": .string(Self.testAddress), "data": "0x6000"]]) { XCTAssertEqual(e.code, 4200) } else { XCTFail() }
        if case .failure(let e) = await call(d, "eth_sendRawTransaction", ["0x02"]) { XCTAssertEqual(e.code, 4200) } else { XCTFail() }

        // http origins get nothing.
        let v15 = await call(d, "eth_accounts", [], DappOrigin(scheme: "http", host: "app.uniswap.org", port: nil))
        XCTAssertEqual(v15, .failure(.unauthorized))

        // Disconnect (Settings) clears the accounts.
        d.sites.disconnect(site.description)
        let v16 = try await call(d, "eth_accounts").get()
        XCTAssertEqual(v16, .array([]))
    }

    /// A connection belongs to one exact origin: another host, a subdomain, another port or plain http can't sign with it,
    /// and none of them reaches a sheet.
    func testPermissionIsBoundToItsOrigin() async throws {
        let s = try service(), p = Presenter(), d = provider(s, p)
        p.approve = [true]
        _ = try await call(d, "eth_requestAccounts").get()
        let hello = "0x" + Array("Hello from Hermit".utf8).hex
        let shown = p.shown.count
        let others = [DappOrigin(scheme: "https", host: "app.aave.com", port: nil),
                      DappOrigin(scheme: "https", host: "evil.app.uniswap.org", port: nil),
                      DappOrigin(scheme: "https", host: "app.uniswap.org", port: 8443)]
        for o in others {
            let accounts = try await call(d, "eth_accounts", [], o).get()
            XCTAssertEqual(accounts, .array([]), o.description)
            let sign = await call(d, "personal_sign", [.string(hello), .string(Self.testAddress)], o)
            XCTAssertEqual(sign, .failure(.unauthorized), o.description)
            let typed = await call(d, "eth_signTypedData_v4", [.string(Self.testAddress), .string(Self.mail)], o)
            XCTAssertEqual(typed, .failure(.unauthorized), o.description)
            let send = await call(d, "eth_sendTransaction", [["from": .string(Self.testAddress), "to": .string(Self.testAddress), "value": "0x1"]], o)
            XCTAssertEqual(send, .failure(.unauthorized), o.description)
            let sol = await call(d, "sol_signMessage", [["message": "aGk="]], o)
            XCTAssertEqual(sol, .failure(.unauthorized), o.description)
        }
        let http = await call(d, "personal_sign", [.string(hello), .string(Self.testAddress)], DappOrigin(scheme: "http", host: "app.uniswap.org", port: nil))
        XCTAssertEqual(http, .failure(.unauthorized))
        XCTAssertEqual(p.shown.count, shown)
        // The origin that connected still can.
        let mine = try await call(d, "eth_accounts").get()
        XCTAssertEqual(mine, .array([.string(Self.testAddress)]))
    }

    /// Live (HERMIT_LIVE=1): read-only RPC passthrough, and a transaction from a fresh empty wallet on Base Sepolia,
    /// simulated, decoded and shown, then cancelled. The wallet has no ETH, so nothing could be sent anyway.
    func testLiveReadsAndCancelledTransaction() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMIT_LIVE"] == "1", "set HERMIT_LIVE=1")
        let s = try service(phrase: nil), p = Presenter(), d = provider(s, p)
        p.approve = [true]
        guard case .array(let a) = try await call(d, "eth_requestAccounts").get(), let me = a.first?.string else { return XCTFail() }
        XCTAssertNotEqual(me, Self.testAddress)
        _ = try await call(d, "wallet_switchEthereumChain", [["chainId": "0x14a34"]]).get()   // Base Sepolia
        let block = try await call(d, "eth_blockNumber").get()
        XCTAssertTrue(block.string?.hasPrefix("0x") == true, "\(block)")
        let v17 = try await call(d, "eth_getBalance", [.string(me), "latest"]).get()
        XCTAssertEqual(v17, "0x0")

        // approve(Permit2, max) on Base Sepolia USDC.
        let usdc = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
        let data = "0x095ea7b3" + ERC20.word(EVMAddress("0x000000000022D473030F116dDEE9F6B43aC78BA3")!).hex + String(repeating: "f", count: 64)
        p.approve = [true]   // the presenter never approves transactions; this proves it cancels anyway
        let r = await call(d, "eth_sendTransaction", [["from": .string(me), "to": .string(usdc), "data": .string(data)]])
        XCTAssertEqual(r, .failure(.rejected))
        let sheet = try XCTUnwrap(p.shown.last)
        XCTAssertEqual(sheet.title, "Approve unlimited USDC")
        XCTAssertTrue(sheet.lines.contains(["Network", "Base Sepolia (testnet)"]))
        XCTAssertTrue(sheet.warnings.contains { $0.hasPrefix("Not enough ETH") }, "\(sheet.warnings)")
        XCTAssertTrue(sheet.warnings.contains { $0.hasPrefix("Unlimited approval") }, "\(sheet.warnings)")
        XCTAssertTrue(sheet.checks.contains("Simulated on Base Sepolia: it doesn't fail"), "\(sheet.checks)")
    }

    // MARK: The injected provider in a real WKWebView

    #if canImport(WebKit) && os(macOS)
    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
    }

    func page(_ html: String, base: String, provider d: DappProvider) async -> (WKWebView, DappWebBridge, Loaded) {
        let config = WKWebViewConfiguration()
        let bridge = DappWebBridge(provider: d)
        bridge.install(on: config)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        bridge.webView = wv
        let nav = Loaded()
        wv.navigationDelegate = nav
        await withCheckedContinuation { c in nav.done = c; wv.loadHTMLString(html, baseURL: URL(string: base)!) }
        return (wv, bridge, nav)
    }

    func js(_ wv: WKWebView, _ body: String) async throws -> Any? {
        try await wv.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// `{ok: result}` or `{code, message}` for one request made by the page through window.ethereum.
    func request(_ wv: WKWebView, _ method: String, _ params: String = "[]") async throws -> [String: Any] {
        try await js(wv, "try { return { ok: await window.ethereum.request({ method: '\(method)', params: \(params) }) } } catch (e) { return { code: e.code, message: e.message } }") as? [String: Any] ?? [:]
    }

    func testInjectedProviderInWebView() async throws {
        let s = try service(), p = Presenter(), d = provider(s, p)
        let html = """
        <html><body><script>
        window.__events = []; window.__announced = [];
        window.addEventListener('eip6963:announceProvider', e => window.__announced.push(e.detail.info));
        window.dispatchEvent(new Event('eip6963:requestProvider'));
        window.ethereum && window.ethereum.on('chainChanged', c => window.__events.push(['chainChanged', c]));
        window.ethereum && window.ethereum.on('accountsChanged', a => window.__events.push(['accountsChanged', a]));
        </script>
        <iframe id="f" srcdoc="<script>parent.__iframeEthereum = typeof window.ethereum; try { window.webkit.messageHandlers.hermitEthereum.postMessage({method:'eth_chainId',params:'[]'}).then(r => parent.__iframeReply = r, e => parent.__iframeReply = 'threw'); } catch (e) { parent.__iframeReply = 'no handler'; }</script>"></iframe>
        </body></html>
        """
        let (wv, bridge, nav) = await page(html, base: "https://app.uniswap.org/", provider: d)
        _ = (bridge, nav)
        try await Task.sleep(for: .milliseconds(300))

        let v18 = try await js(wv, "return window.ethereum.isHermit") as? Bool
        XCTAssertEqual(v18, true)
        let ann = try await js(wv, "return window.__announced.map(i => i.name + '|' + i.rdns + '|' + (i.icon.startsWith('data:image/png;base64,')))") as? [String]
        XCTAssertTrue(ann?.contains("Hermit|my.hermit|true") == true, "\(String(describing: ann))")
        let v19 = try await request(wv, "eth_chainId")["ok"] as? String
        XCTAssertEqual(v19, "0x1")
        let v20 = try await js(wv, "return window.ethereum.chainId") as? String
        XCTAssertEqual(v20, "0x1")
        let v21 = (try await request(wv, "eth_accounts")["ok"] as? [Any])?.count
        XCTAssertEqual(v21, 0)

        p.approve = [false]
        let v22 = try await request(wv, "eth_requestAccounts")["code"] as? Int
        XCTAssertEqual(v22, 4001)
        p.approve = [true]
        let v23 = try await request(wv, "eth_requestAccounts")["ok"] as? [String]
        XCTAssertEqual(v23, [Self.testAddress])
        let v24 = try await js(wv, "return window.ethereum.selectedAddress") as? String
        XCTAssertEqual(v24, Self.testAddress)

        let hello = "0x" + Array("Hello from Hermit".utf8).hex
        p.approve = [true]
        let v25 = try await request(wv, "personal_sign", "['\(hello)', '\(Self.testAddress)']")["ok"] as? String
        XCTAssertEqual(v25, Self.personalVector)
        p.approve = [true]
        let v26 = try await request(wv, "eth_signTypedData_v4", "['\(Self.testAddress)', \(Self.mail.debugDescription)]")["ok"] as? String
        XCTAssertEqual(v26, Self.typedVector)
        let v27 = try await request(wv, "eth_sign", "['\(Self.testAddress)', '0x00']")["code"] as? Int
        XCTAssertEqual(v27, 4200)
        let v28 = try await request(wv, "wallet_switchEthereumChain", "[{ chainId: '0x999999' }]")["code"] as? Int
        XCTAssertEqual(v28, 4902)
        let v29 = try await js(wv, "try { await window.ethereum.request({}) } catch (e) { return e.code }") as? Int
        XCTAssertEqual(v29, -32602)

        _ = try await request(wv, "wallet_switchEthereumChain", "[{ chainId: '0x2105' }]")
        try await Task.sleep(for: .milliseconds(200))
        let v30 = try await js(wv, "return window.ethereum.chainId") as? String
        XCTAssertEqual(v30, "0x2105")
        let events = try await js(wv, "return JSON.stringify(window.__events)") as? String ?? ""
        XCTAssertTrue(events.contains(#"["chainChanged","0x2105"]"#), events)
        XCTAssertTrue(events.contains(#"["accountsChanged",["\#(Self.testAddress)"]]"#), events)

        // Settings disconnects the site: the page hears accountsChanged([]) and gets no accounts.
        d.sites.disconnect("https://app.uniswap.org")
        try await Task.sleep(for: .milliseconds(200))
        let v31 = (try await js(wv, "return JSON.stringify(window.__events)") as? String ?? "").contains(#"["accountsChanged",[]]"#)
        XCTAssertTrue(v31)
        let v32 = (try await request(wv, "eth_accounts")["ok"] as? [Any])?.count
        XCTAssertEqual(v32, 0)

        // The embedded frame has no provider, and the handler refuses it even when called directly.
        let v33 = try await js(wv, "return window.__iframeEthereum") as? String
        XCTAssertEqual(v33, "undefined")
        let reply = try await js(wv, "return String(window.__iframeReply)") as? String ?? ""
        XCTAssertTrue(reply.contains("4100") || reply == "no handler", reply)
        XCTAssertFalse(reply.contains("result"), reply)
    }

    func testNoProviderOnHttpPages() async throws {
        let s = try service(), p = Presenter(), d = provider(s, p)
        let (wv, bridge, nav) = await page("<html><body>plain</body></html>", base: "http://app.uniswap.org/", provider: d)
        _ = (bridge, nav)
        let v34 = try await js(wv, "return typeof window.ethereum") as? String
        XCTAssertEqual(v34, "undefined")
        // Posting to the handler directly is refused too.
        let r = try await js(wv, "return await window.webkit.messageHandlers.hermitEthereum.postMessage({ method: 'eth_chainId', params: '[]' })") as? String ?? ""
        XCTAssertTrue(r.contains("4100"), r)
        XCTAssertTrue(p.shown.isEmpty)
    }

    /// Live (HERMIT_LIVE_DAPP=1, optionally HERMIT_DAPP_URL): loads a real app, opens its wallet list and checks that it
    /// lists "Hermit" (found through EIP-6963). Saves a PNG of the page to $SNAPSHOT_DIR (default /tmp).
    func testLiveDappListsHermit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HERMIT_LIVE_DAPP"] == "1", "set HERMIT_LIVE_DAPP=1")
        let target = ProcessInfo.processInfo.environment["HERMIT_DAPP_URL"] ?? "https://app.uniswap.org/swap"
        let s = try service(phrase: nil), p = Presenter(), d = provider(s, p)
        let config = WKWebViewConfiguration()
        let bridge = DappWebBridge(provider: d)
        bridge.install(on: config)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 860), configuration: config)
        bridge.webView = wv
        // Never shown: an offscreen borderless window so the page lays out and renders.
        let win = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1280, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        let nav = Loaded(); wv.navigationDelegate = nav
        await withCheckedContinuation { c in nav.done = c; wv.load(URLRequest(url: URL(string: target)!)) }
        try await Task.sleep(for: .seconds(8))
        // Click the visible button labelled exactly "Connect" (or "Connect wallet").
        let clicked = try await js(wv, """
            const b = [...document.querySelectorAll('button, [role=button]')].find(e => /^connect( wallet)?$/i.test((e.innerText || '').trim()) && e.offsetParent !== null);
            if (b) { b.click(); return b.innerText.trim(); } return null;
        """) as? String
        try await Task.sleep(for: .seconds(4))
        // A leaf element whose whole text is "Hermit": the wallet list's entry, not stray text.
        let listed = try await js(wv, "return [...document.querySelectorAll('*')].some(e => e.children.length === 0 && (e.textContent || '').trim() === 'Hermit' && e.offsetParent !== null)") as? Bool ?? false
        let text = listed ? "Hermit" : (try await js(wv, "return document.body.innerText") as? String ?? "")
        let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? "/tmp"
        let shot = try await wv.takeSnapshot(configuration: nil)
        if let tiff = shot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dapp-\(URL(string: target)!.host()!).png"))
        }
        let around = try await js(wv, "const e = [...document.querySelectorAll('*')].find(e => e.children.length === 0 && (e.textContent || '').trim() === 'Hermit'); let p = e; for (let i = 0; i < 6 && p && p.parentElement; i++) p = p.parentElement; return p ? p.innerText.replace(/\\n+/g, ' | ').slice(0, 300) : ''") as? String ?? ""
        print("dapp clicked:", clicked ?? "nothing", "lists Hermit:", listed, "around:", around)
        XCTAssertNotNil(clicked, "no Connect button found")
        XCTAssertTrue(listed, String(text.prefix(600)))
        XCTAssertTrue(p.shown.isEmpty, "opening the wallet list must not prompt")
        _ = win
    }
    #endif
}
