import SwiftUI
import Observation
import WebKit
import HermitCore
import HermitWallet

/// Hermit's in-app browser for the Explore directory. One page at a time, shown in place of the Explore page, so the
/// app's approval sheet (RootView) can come up over it. The page keeps running while you visit other tabs.
@MainActor @Observable
final class DappBrowser: DappPresenter {
    static let shared = DappBrowser()
    private(set) var session: DappBrowserSession?
    @ObservationIgnored weak var model: AppModel?

    /// Opens `url` (from Explore, the address bar or the assistant). `dapp` is the directory entry, if any.
    func open(_ url: URL, dapp: ExploreDapp? = nil, model: AppModel) {
        self.model = model
        session?.close()
        session = DappBrowserSession(url: url, dapp: dapp, browser: self)
        model.open(.explore)
    }

    func close() {
        session?.close()
        withAnimation(.smooth(duration: 0.25)) { session = nil }
    }

    // MARK: DappPresenter

    /// Puts the request on the shared approval sheet and waits until that sheet has closed.
    func present(_ approval: Approval) async {
        guard let model else { return }
        // Another sheet (a send, a swap) is up: wait for it, never replace it.
        while model.approval != nil { try? await Task.sleep(for: .milliseconds(200)) }
        model.approval = approval
        while model.approval?.id == approval.id { try? await Task.sleep(for: .milliseconds(150)) }
    }

    func notice(_ text: String) { model?.toast(text) }

    #if DEBUG
    /// Simulator screenshots (scripts/phone-shots.sh): `-hermitDapp <url>` opens the browser once on launch, and
    /// `-hermitDappAsk connect|connected|sign|tx|sol-connect|sol-list|sol-tx` makes the page ask for a connection or a signature, so the real approval sheet
    /// shows over it. Nobody taps Approve in a screenshot run. Never compiled into Release.
    private static var debugUsed = false
    func debugLaunch(_ model: AppModel) {
        guard !Self.debugUsed, let s = UserDefaults.standard.string(forKey: "hermitDapp"), let u = URL(string: s) else { return }
        Self.debugUsed = true
        open(u, dapp: ExploreData.dapps.first { $0.url?.host() == u.host() }, model: model)
        guard let ask = UserDefaults.standard.string(forKey: "hermitDappAsk"), let session, let o = session.origin,
              let w = WalletsViewModel.shared.service.selected else { return }
        if ["sign", "connected", "tx"].contains(ask) { DappPermissions.shared.connect(o, walletID: w.id, address: w.evmAddress, chainID: 1) }
        // Uniswap connects Hermit on both EVM and Solana from one pick.
        if ask == "sol-tx" || ask == "connected" { DappPermissions.shared.connectSolana(o, walletID: w.id, address: w.solanaAddress) }
        Task { @MainActor [weak session] in
            // Pages with long-running analytics may never report "finished": ask after a fixed wait instead.
            try? await Task.sleep(for: .seconds(9))
            guard let session else { return }
            var script: String
            switch ask {
            case "sign":
                script = "window.ethereum.request({ method: 'eth_accounts' }).then(a => window.ethereum.request({ method: 'personal_sign', params: ['0x' + Array.from(new TextEncoder().encode(location.host + ' wants you to sign in with your Ethereum account:\\n' + a[0] + '\\n\\nURI: https://' + location.host + '\\nVersion: 1\\nChain ID: 1\\nNonce: hermitdemo1\\nIssued At: 2026-11-10T09:00:00Z')).map(b => b.toString(16).padStart(2, '0')).join(''), a[0]] }))"
            case "sol-connect":
                script = "window.hermit.connect()"
            case "connected", "sol-list":
                // The page's own Connect button, then (EVM) Hermit in its wallet list; the site was connected above,
                // so no sheet comes up and the page shows the account. sol-list stops at the list.
                let pick = ask == "connected" ? "true" : "false"
                script = """
                (async () => { const sleep = t => new Promise(r => setTimeout(r, t));
                  const vis = e => e.getClientRects().length > 0;
                  const press = e => { for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
                    const r = e.getBoundingClientRect(), o = { bubbles: true, cancelable: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, pointerType: 'mouse', isPrimary: true };
                    e.dispatchEvent(t.startsWith('pointer') ? new PointerEvent(t, o) : new MouseEvent(t, o)); } };
                  const find = re => [...document.querySelectorAll('*')].filter(e => re.test((e.innerText || '').trim()) && vis(e)).pop();
                  for (let i = 0; i < 6; i++) {
                    const b = find(/^connect( wallet)?$/i); if (b) press(b);
                    await sleep(1500);
                    if (!\(pick)) return;
                    const h = find(/^Hermit$/); if (h) { press(h); return; }
                  } })()
                """
            case "tx":
                // approve(Permit2, unlimited) on Ethereum USDC: the transaction review with its warnings. Nobody approves it.
                script = "window.ethereum.request({ method: 'eth_accounts' }).then(a => window.ethereum.request({ method: 'eth_sendTransaction', params: [{ from: a[0], to: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', data: '0x095ea7b3000000000000000000000000000000000022d473030f116ddee9f6b43ac78ba3' + 'f'.repeat(64) }] }))"
            case "sol-tx":
                // A real mainnet transfer of 0.01 SOL to a public address, shown for review only: nobody approves in a screenshot run.
                guard let me = SolanaPublicKey(w.solanaAddress), let to = SolanaPublicKey("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"),
                      let latest = try? await SolanaClient(url: Chain.solana.rpc).latestBlockhash() else { return }
                let tx = SolanaTransaction(message: SolanaMessage(payer: me, instructions: [.setComputeUnitLimit(1_000), .setComputeUnitPrice(100_000),
                                                                                           .transfer(from: me, to: to, lamports: 10_000_000)], recentBlockhash: latest.hash))
                script = "window.hermit.signAndSendTransaction(Uint8Array.from(atob('\(tx.base64)'), c => c.charCodeAt(0)))"
            default:
                script = "window.ethereum.request({ method: 'eth_requestAccounts' })"
            }
            session.webView.evaluateJavaScript(script, in: nil, in: .page) { _ in }
        }
    }
    #endif

    /// Directory hosts, for the lookalike check.
    static var knownHosts: [String] { ExploreData.sites.values.map { String($0.split(separator: "/").first ?? "") } }
}

/// One open page: the web view, its navigation state and the provider bound to it.
@MainActor @Observable
final class DappBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let provider: DappProvider
    @ObservationIgnored private let bridge: DappWebBridge
    @ObservationIgnored private let config: WKWebViewConfiguration
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    let dapp: ExploreDapp?

    private(set) var url: URL?
    private(set) var title = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loading = false
    private(set) var progress = 0.0
    /// Set when a page fails to load (no network, bad address).
    private(set) var failure: String?

    init(url: URL, dapp: ExploreDapp?, browser: DappBrowser) {
        self.dapp = dapp
        let wallet = WalletsViewModel.shared.service
        provider = DappProvider(service: wallet)
        provider.presenter = browser
        provider.knownHosts = DappBrowser.knownHosts
        bridge = DappWebBridge(provider: provider)
        config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = "Hermit"
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        bridge.install(on: config)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        bridge.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG && os(macOS)
        webView.isInspectable = true
        #endif
        observe()
        self.url = url
        webView.load(URLRequest(url: url))
    }

    func close() {
        webView.stopLoading()
        kvo.removeAll()
        bridge.uninstall(from: config)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func observe() {
        func on<V>(_ kp: KeyPath<WKWebView, V>, _ set: @escaping @MainActor (DappBrowserSession, V) -> Void) {
            kvo.append(webView.observe(kp, options: [.initial, .new]) { [weak self] wv, change in
                MainActor.assumeIsolated { if let self { set(self, wv[keyPath: kp]) } }
            })
        }
        on(\.url) { s, v in if let v { s.url = v } }
        on(\.title) { s, v in s.title = v ?? "" }
        on(\.canGoBack) { s, v in s.canGoBack = v }
        on(\.canGoForward) { s, v in s.canGoForward = v }
        on(\.isLoading) { s, v in withAnimation(.smooth(duration: 0.2)) { s.loading = v } }
        on(\.estimatedProgress) { s, v in s.progress = v }
    }

    // MARK: What the address bar shows

    var origin: DappOrigin? { url.flatMap(DappOrigin.init(url:)) }
    var host: String { url?.host() ?? "" }
    var secure: Bool { url?.scheme == "https" }
    /// Lookalike / punycode / IP warnings for the current host.
    var warnings: [String] { host.isEmpty ? [] : DappSiteCheck.warnings(host: host, known: DappBrowser.knownHosts) }
    var listed: Bool { !host.isEmpty && DappSiteCheck.isListed(host, known: DappBrowser.knownHosts) }
    /// The wallet connected to this page's origin, if any (reads the shared list, so Settings changes show at once).
    var connected: DappPermissions.Site? {
        guard let o = origin, provider.account(for: o) != nil || provider.solanaAccount(for: o) != nil else { return nil }
        return DappPermissions.shared.site(o)
    }
    /// The EVM network, when an EVM wallet is connected; Solana when only Solana is.
    var chain: Chain? {
        guard let o = origin else { return nil }
        return provider.account(for: o) != nil ? provider.chain(for: o) : provider.solanaAccount(for: o) != nil ? .solana : nil
    }
    var evmConnected: Bool { origin.map { provider.account(for: $0) != nil } ?? false }

    func load(_ text: String) {
        guard let u = Self.normalize(text) else { DappBrowser.shared.notice("That isn't a web address"); return }
        failure = nil
        webView.load(URLRequest(url: u))
    }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { failure = nil; if loading { webView.stopLoading() } else { webView.reload() } }

    func disconnect() {
        guard let o = origin else { return }
        DappPermissions.shared.disconnect(o.description)
        DappBrowser.shared.notice("Disconnected \(o.host)")
    }

    func switchChain(_ c: Chain) {
        guard let o = origin else { return }
        provider.switchChain(o, to: c)
    }

    /// "uniswap.org" → https://uniswap.org. Only http(s) with a real host.
    static func normalize(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let h = u.host(), h.contains(".") || h == "localhost" else { return nil }
        return u
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        if ["https", "http", "about", "blob", "data"].contains(scheme) {
            // Top-level data: and blob: pages could pose as another site's address; frames may use them.
            if main, scheme == "data" || scheme == "blob" { decisionHandler(.cancel); return }
            decisionHandler(.allow); return
        }
        // wc:, metamask:, mailto: and other app links don't open from here.
        if main, !scheme.isEmpty { DappBrowser.shared.notice("Hermit doesn't open \(scheme): links") }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { failure = nil }
    private func fail(_ error: Error) {
        let e = error as NSError
        guard !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled) else { return }
        failure = e.localizedDescription
    }

    // MARK: WKUIDelegate

    /// target=_blank and window.open load in this same page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let u = navigationAction.request.url, ["https", "http"].contains(u.scheme?.lowercased() ?? "") {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// alert(): shown as a toast with the page's host, so it can't pose as Hermit.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        DappBrowser.shared.notice("\(frame.securityOrigin.host): \(message.prefix(140))")
        completionHandler()
    }

    /// confirm(): Hermit doesn't show page dialogs, so it answers Cancel.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(false)
    }
}
