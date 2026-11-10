#if canImport(WebKit)
import Foundation
import WebKit

/// Connects a WKWebView to a `DappProvider`: injects `window.ethereum` (EIP-1193) and announces it as "Hermit"
/// (EIP-6963), registers "Hermit" as a Wallet Standard wallet for Solana (plus window.solana / window.hermit), in the
/// main frame of https pages only, and answers their requests.
///
/// The origin of every request is the one WebKit reports for the frame that sent it (`WKFrameInfo.securityOrigin`),
/// never anything the page says. Requests from embedded frames, from http pages, or sent while the page is navigating
/// to another origin are refused. Nothing secret crosses into JavaScript: replies carry addresses, chain ids,
/// signatures and transaction hashes only.
@MainActor public final class DappWebBridge: NSObject, WKScriptMessageHandlerWithReply {
    public static let handlerName = "hermitEthereum"
    public let provider: DappProvider
    public weak var webView: WKWebView?

    public init(provider: DappProvider) {
        self.provider = provider
        super.init()
        provider.emit = { [weak self] origin, name, payload in self?.send(name, payload, to: origin) }
    }

    /// Adds the provider script and the message handler. Call before the web view is created with `config`.
    public func install(on config: WKWebViewConfiguration) {
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: Self.providerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        ucc.addUserScript(WKUserScript(source: Self.solanaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
    }

    /// Breaks the user content controller's strong hold on this bridge.
    public func uninstall(from config: WKWebViewConfiguration) {
        config.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        config.userContentController.removeAllUserScripts()
    }

    /// Checks where a message came from. Returns the origin, or why it was refused.
    static func origin(of frame: WKFrameInfo, pageURL: URL?) -> Result<DappOrigin, DappRPCError> {
        guard frame.isMainFrame else { return .failure(DappRPCError(4100, "Hermit only answers the page itself, not embedded frames.")) }
        let so = frame.securityOrigin
        guard so.protocol == "https", !so.host.isEmpty else { return .failure(DappRPCError(4100, "Hermit only connects to https pages.")) }
        let origin = DappOrigin(scheme: so.protocol, host: so.host, port: so.port)
        // The page must still be on that origin: a request racing a navigation to another site is dropped.
        guard let url = pageURL, DappOrigin(url: url) == origin else { return .failure(DappRPCError(4900, "The page changed. Try again.")) }
        return .success(origin)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                      replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let origin: DappOrigin
        switch Self.origin(of: message.frameInfo, pageURL: message.webView?.url) {
        case .success(let o): origin = o
        case .failure(let e): replyHandler(Self.encode(.failure(e)), nil); return
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String, !method.isEmpty else {
            replyHandler(Self.encode(.failure(.params("Expected { method, params }"))), nil); return
        }
        let params: JSON
        if let s = body["params"] as? String, let d = s.data(using: .utf8), let j = try? JSONDecoder().decode(JSON.self, from: d) { params = j }
        else { params = .array([]) }
        Task { @MainActor in
            let r = await provider.handle(method: method, params: params, origin: origin)
            replyHandler(Self.encode(r), nil)
        }
    }

    /// {"result": …} or {"error": {"code", "message"}}, as a JSON string the page parses.
    static func encode(_ r: Result<JSON, DappRPCError>) -> String {
        let obj: JSON
        switch r {
        case .success(let v): obj = ["result": v]
        case .failure(let e): obj = ["error": ["code": .number(Double(e.code)), "message": .string(e.message)]]
        }
        return (try? JSONEncoder().encode(obj)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"error":{"code":-32603,"message":"encoding"}}"#
    }

    /// An EIP-1193 event to the page, only if it is still on `origin`.
    func send(_ name: String, _ payload: JSON, to origin: DappOrigin) {
        guard let wv = webView, let url = wv.url, DappOrigin(url: url) == origin,
              let p = try? JSONEncoder().encode(payload), let ps = String(data: p, encoding: .utf8),
              let lit = try? JSONEncoder().encode([name, ps]), let args = String(data: lit, encoding: .utf8) else { return }
        let fn = name.hasPrefix("solana:") ? "__hermitSolanaEvent" : "__hermitEthereumEvent"
        wv.evaluateJavaScript("window.\(fn) && window.\(fn).apply(null, \(args))", in: nil, in: .page) { _ in }
    }

    static let icon = "data:image/png;base64,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"

    /// The provider. Runs at document start in the main frame; does nothing on http pages or inside frames.
    public static let providerScript = #"""
    (function () {
      'use strict';
      if (window.top !== window || location.protocol !== 'https:') return;
      if (window.ethereum && window.ethereum.isHermit) return;
      var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hermitEthereum;
      if (!mh) return;
      var post = mh.postMessage.bind(mh);
      var listeners = {};
      var state = { chainId: null, accounts: [] };
      function rpcError(code, message, data) { var e = new Error(message); e.code = code; if (data !== undefined) e.data = data; return e; }
      function emit(name, payload) {
        (listeners[name] || []).slice().forEach(function (fn) { try { fn(payload); } catch (e) { setTimeout(function () { throw e; }); } });
      }
      function call(method, params) {
        var json;
        try { json = JSON.stringify(params === undefined ? [] : params); } catch (e) { return Promise.reject(rpcError(-32602, 'Params must be JSON')); }
        return post({ method: method, params: json }).then(function (raw) {
          var r = JSON.parse(raw);
          if (r.error) throw rpcError(r.error.code, r.error.message, r.error.data);
          if (method === 'eth_chainId' && typeof r.result === 'string') state.chainId = r.result;
          if ((method === 'eth_accounts' || method === 'eth_requestAccounts') && Array.isArray(r.result)) state.accounts = r.result;
          return r.result;
        });
      }
      var provider = {
        isHermit: true,
        isMetaMask: false,
        get chainId() { return state.chainId; },
        get networkVersion() { return state.chainId ? String(parseInt(state.chainId, 16)) : null; },
        get selectedAddress() { return state.accounts[0] || null; },
        isConnected: function () { return true; },
        request: function (args) {
          if (!args || typeof args !== 'object' || typeof args.method !== 'string' || !args.method) {
            return Promise.reject(rpcError(-32602, 'Expected { method, params }'));
          }
          return call(args.method, args.params);
        },
        on: function (n, fn) { (listeners[n] = listeners[n] || []).push(fn); return provider; },
        once: function (n, fn) { function w(p) { provider.removeListener(n, w); fn(p); } return provider.on(n, w); },
        removeListener: function (n, fn) { var l = listeners[n]; if (l) { var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); } return provider; },
        removeAllListeners: function (n) { if (n) delete listeners[n]; else listeners = {}; return provider; },
        listenerCount: function (n) { return (listeners[n] || []).length; },
        enable: function () { return call('eth_requestAccounts', []); },
        send: function (a, b) {
          if (typeof a === 'string') return call(a, b);
          if (typeof b === 'function') return provider.sendAsync(a, b);
          throw rpcError(4200, 'Synchronous send is not supported');
        },
        sendAsync: function (payload, cb) {
          call(payload.method, payload.params).then(function (res) {
            cb(null, { id: payload.id, jsonrpc: '2.0', result: res });
          }, function (err) {
            cb(err, { id: payload.id, jsonrpc: '2.0', error: { code: err.code, message: err.message } });
          });
        }
      };
      provider.addListener = provider.on;
      provider.off = provider.removeListener;
      Object.defineProperty(window, '__hermitEthereumEvent', {
        value: function (name, raw) {
          var p = JSON.parse(raw);
          if (name === 'chainChanged') state.chainId = p;
          if (name === 'accountsChanged') state.accounts = p;
          emit(name, p);
        }, writable: false, configurable: false, enumerable: false
      });
      Object.defineProperty(window, 'ethereum', { value: provider, writable: true, configurable: true, enumerable: true });
      var info = Object.freeze({
        uuid: (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : '6c1d2a9e-4a1b-4e57-9a43-0f1b7f6f9e21',
        name: 'Hermit', icon: '\#(icon)', rdns: 'my.hermit'
      });
      var detail = Object.freeze({ info: info, provider: provider });
      function announce() { window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: detail })); }
      window.addEventListener('eip6963:requestProvider', announce);
      announce();
      window.dispatchEvent(new Event('ethereum#initialized'));
      call('eth_chainId', []).then(function (c) { emit('connect', { chainId: c }); }, function () {});
      call('eth_accounts', []).catch(function () {});
    })();
    """#
    /// The Solana wallet: a Wallet Standard wallet named "Hermit" (registered with the wallet-standard events, so
    /// @solana/wallet-adapter, @solana/kit-plugin-wallet and wallet-standard apps list it), plus a legacy
    /// window.solana / window.hermit with isHermit. Main frame of https pages only.
    public static let solanaScript = #"""
    (function () {
      'use strict';
      if (window.top !== window || location.protocol !== 'https:') return;
      if (window.hermit && window.hermit.isHermit) return;
      var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hermitEthereum;
      if (!mh) return;
      var post = mh.postMessage.bind(mh);
      function rpcError(code, message) { var e = new Error(message); e.code = code; return e; }
      function call(method, params) {
        return post({ method: method, params: JSON.stringify([params || {}]) }).then(function (raw) {
          var r = JSON.parse(raw);
          if (r.error) throw rpcError(r.error.code, r.error.message);
          return r.result;
        });
      }
      function b64(bytes) { var s = ''; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]); return btoa(s); }
      function unb64(s) { var b = atob(s), out = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) out[i] = b.charCodeAt(i); return out; }
      function seq(inputs, fn) {
        return inputs.reduce(function (p, input) {
          return p.then(function (out) { return Promise.resolve().then(function () { return fn(input); }).then(function (r) { return out.concat([r]); }); });
        }, Promise.resolve([]));
      }
      var CHAINS = ['solana:mainnet', 'solana:devnet'];
      var FEATURES = ['solana:signAndSendTransaction', 'solana:signTransaction', 'solana:signMessage', 'solana:signIn'];
      var VERSIONS = ['legacy', 0, 1];
      var accounts = [];
      var listeners = {};
      var legacyListeners = {};
      function makeAccount(a) {
        return Object.freeze({ address: a.address, publicKey: unb64(a.publicKey), chains: CHAINS.slice(), features: FEATURES.slice(), label: 'Hermit' });
      }
      function legacyKey(a) {
        var bytes = a.publicKey;
        return { toBase58: function () { return a.address; }, toString: function () { return a.address; }, toJSON: function () { return a.address; },
                 toBytes: function () { return bytes.slice(); }, toBuffer: function () { return bytes.slice(); },
                 equals: function (o) { return !!o && (typeof o.toBase58 === 'function' ? o.toBase58() : String(o)) === a.address; } };
      }
      function emitLegacy(name, payload) {
        (legacyListeners[name] || []).slice().forEach(function (fn) { try { fn(payload); } catch (e) { setTimeout(function () { throw e; }); } });
      }
      function setAccounts(list) {
        var before = accounts[0] ? accounts[0].address : null;
        accounts = list.map(makeAccount);
        var after = accounts[0] ? accounts[0].address : null;
        legacy.publicKey = accounts[0] ? legacyKey(accounts[0]) : null;
        legacy.isConnected = !!accounts[0];
        if (before === after) return;
        (listeners.change || []).slice().forEach(function (fn) { try { fn({ accounts: accounts.slice() }); } catch (e) {} });
        if (!after) emitLegacy('disconnect');
        else if (!before) emitLegacy('connect', legacy.publicKey);
        else emitLegacy('accountChanged', legacy.publicKey);
      }
      function requireAccount(input) {
        if (!accounts[0]) throw rpcError(4100, 'Connect Hermit first.');
        if (input && input.account && input.account.address !== accounts[0].address) throw rpcError(4100, 'That account is not connected to this site.');
      }
      function chainOf(input) { return (input && input.chain) || 'solana:mainnet'; }
      var wallet = {
        version: '1.0.0',
        name: 'Hermit',
        icon: '\#(icon)',
        chains: CHAINS.slice(),
        get accounts() { return accounts.slice(); },
        features: {
          'standard:connect': { version: '1.0.0', connect: function (input) {
            return call('sol_connect', { silent: !!(input && input.silent) }).then(function (r) { if (r) setAccounts([r]); return { accounts: accounts.slice() }; });
          } },
          'standard:disconnect': { version: '1.0.0', disconnect: function () { return call('sol_disconnect').then(function () { setAccounts([]); }); } },
          'standard:events': { version: '1.0.0', on: function (event, fn) {
            (listeners[event] = listeners[event] || []).push(fn);
            return function () { var l = listeners[event] || []; var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); };
          } },
          'solana:signMessage': { version: '1.1.0', signMessage: function () {
            return seq([].slice.call(arguments), function (input) {
              requireAccount(input);
              return call('sol_signMessage', { message: b64(input.message) }).then(function (r) {
                return { signedMessage: input.message, signature: unb64(r.signature), signatureType: 'ed25519' };
              });
            });
          } },
          'solana:signIn': { version: '1.0.0', signIn: function () {
            var inputs = [].slice.call(arguments); if (!inputs.length) inputs = [{}];
            return seq(inputs, function (input) {
              return call('sol_signIn', { input: input || {} }).then(function (r) {
                setAccounts([r.account]);
                return { account: accounts[0], signedMessage: unb64(r.signedMessage), signature: unb64(r.signature), signatureType: 'ed25519' };
              });
            });
          } },
          'solana:signTransaction': { version: '1.0.0', supportedTransactionVersions: VERSIONS, signTransaction: function () {
            return seq([].slice.call(arguments), function (input) {
              requireAccount(input);
              return call('sol_signTransaction', { transaction: b64(input.transaction), chain: chainOf(input) }).then(function (r) {
                return { signedTransaction: unb64(r.signedTransaction) };
              });
            });
          } },
          'solana:signAndSendTransaction': { version: '1.0.0', supportedTransactionVersions: VERSIONS, signAndSendTransaction: function () {
            return seq([].slice.call(arguments), function (input) {
              requireAccount(input);
              return call('sol_signAndSendTransaction', { transaction: b64(input.transaction), chain: chainOf(input), options: input.options || {} })
                .then(function (r) { return { signature: unb64(r.signatureBytes) }; });
            });
          } }
        }
      };
      // Legacy apps: window.solana / window.hermit with web3.js transaction objects.
      function serialize(tx) {
        if (tx instanceof Uint8Array) return tx;
        return new Uint8Array(tx.serialize({ requireAllSignatures: false, verifySignatures: false }));
      }
      function rebuild(tx, bytes) {
        if (tx instanceof Uint8Array) return bytes;
        var C = tx.constructor;
        return typeof C.deserialize === 'function' ? C.deserialize(bytes) : C.from(bytes);
      }
      var legacy = {
        isHermit: true,
        isPhantom: false,
        publicKey: null,
        isConnected: false,
        connect: function (opts) {
          return call('sol_connect', { silent: !!(opts && opts.onlyIfTrusted) }).then(function (r) {
            if (!r) throw rpcError(4001, 'User rejected the request.');
            setAccounts([r]); return { publicKey: legacy.publicKey };
          });
        },
        disconnect: function () { return call('sol_disconnect').then(function () { setAccounts([]); }); },
        signMessage: function (message) {
          return Promise.resolve().then(function () { requireAccount(); return call('sol_signMessage', { message: b64(message) }); })
            .then(function (r) { return { signature: unb64(r.signature), publicKey: legacy.publicKey }; });
        },
        signTransaction: function (tx) {
          return Promise.resolve().then(function () { requireAccount(); return call('sol_signTransaction', { transaction: b64(serialize(tx)), chain: 'solana:mainnet' }); })
            .then(function (r) { return rebuild(tx, unb64(r.signedTransaction)); });
        },
        signAllTransactions: function (txs) { return seq(txs, legacy.signTransaction); },
        signAndSendTransaction: function (tx, options) {
          return Promise.resolve().then(function () { requireAccount(); return call('sol_signAndSendTransaction', { transaction: b64(serialize(tx)), chain: 'solana:mainnet', options: options || {} }); })
            .then(function (r) { return { signature: r.signature, publicKey: legacy.publicKey }; });
        },
        on: function (n, fn) { (legacyListeners[n] = legacyListeners[n] || []).push(fn); return legacy; },
        off: function (n, fn) { var l = legacyListeners[n]; if (l) { var i = l.indexOf(fn); if (i >= 0) l.splice(i, 1); } return legacy; }
      };
      legacy.removeListener = legacy.off;
      Object.defineProperty(window, 'hermit', { value: legacy, writable: false, configurable: false, enumerable: true });
      if (!window.solana) Object.defineProperty(window, 'solana', { value: legacy, writable: true, configurable: true, enumerable: true });
      Object.defineProperty(window, '__hermitSolanaEvent', {
        value: function (name, raw) { if (name === 'solana:accounts') setAccounts(JSON.parse(raw)); },
        writable: false, configurable: false, enumerable: false
      });
      // Wallet Standard registration (the same two events @wallet-standard/wallet's registerWallet uses).
      class RegisterWalletEvent extends Event {
        constructor(callback) { super('wallet-standard:register-wallet', { bubbles: false, cancelable: false, composed: false }); this._detail = callback; }
        get detail() { return this._detail; }
        get type() { return 'wallet-standard:register-wallet'; }
      }
      var callback = function (api) { api.register(wallet); };
      try { window.dispatchEvent(new RegisterWalletEvent(callback)); } catch (e) { console.error('Hermit wallet-standard register failed', e); }
      try { window.addEventListener('wallet-standard:app-ready', function (e) { callback(e.detail); }); } catch (e) {}
      call('sol_accounts').then(function (a) { if (a) setAccounts([a]); }, function () {});
    })();
    """#
}
#endif
