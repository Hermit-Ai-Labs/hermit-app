import Foundation
import HermitCore

/// An EIP-1193 error: 4001 rejected, 4100 unauthorized, 4200 unsupported, 4900 disconnected, 4902 unknown chain,
/// -32602 bad params, -32603 internal, -32002 a request is already waiting.
public struct DappRPCError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String) { self.code = code; self.message = message }

    public static let rejected = DappRPCError(4001, "User rejected the request.")
    public static let unauthorized = DappRPCError(4100, "Connect this site to Hermit first.")
    public static func unsupported(_ m: String) -> DappRPCError { DappRPCError(4200, "Hermit doesn't support \(m).") }
    public static func params(_ m: String) -> DappRPCError { DappRPCError(-32602, m) }
}

/// Shows approval sheets for the provider. The app's implementation sets `AppModel.approval` (the one approval sheet
/// every money move uses) and returns once the sheet has closed, approved or cancelled.
@MainActor public protocol DappPresenter: AnyObject {
    func present(_ approval: Approval) async
    func notice(_ text: String)
}

/// The wallet behind `window.ethereum` in Hermit's browser. Each call arrives with the origin WebKit reported for the
/// page's main frame (never one the page claims), and anything that signs goes through the approval sheet, where the
/// wallet unlocks the key with Face ID / Touch ID. Keys never leave `KeyVault.withKey`; the page only ever gets back
/// addresses, signatures and transaction hashes.
@MainActor public final class DappProvider {
    public let service: WalletService
    public let sites: DappPermissions
    public weak var presenter: DappPresenter?
    /// Hosts from the Explore directory, for the lookalike check and the "listed" line.
    public var knownHosts: [String] = []
    /// Sends an event (accountsChanged, chainChanged) to the page if it is still on `origin`. Payload is JSON.
    public var emit: ((DappOrigin, String, JSON) -> Void)?
    /// USD prices by symbol for the spending policy. Defaults to CoinGecko through `PriceFeed`.
    public var prices: @Sendable () async -> [String: Double] = { await PriceFeed.shared.quotes().mapValues(\.usd) }

    /// The network each origin is on during this session (connected sites also remember it).
    private var chains: [DappOrigin: UInt64] = [:]
    private var waiting: [DappOrigin: Int] = [:]
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    public static let defaultChain = Chain.ethereum

    public init(service: WalletService, sites: DappPermissions? = nil) {
        self.service = service; self.sites = sites ?? .shared
        observer = NotificationCenter.default.addObserver(forName: DappPermissions.disconnected, object: nil, queue: .main) { [weak self] n in
            guard let o = n.object as? String else { return }
            MainActor.assumeIsolated { self?.disconnected(o) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: State

    public func chain(for origin: DappOrigin) -> Chain {
        let id = chains[origin] ?? sites.site(origin)?.chainID ?? Self.defaultChain.chainId!
        return Chain.with(chainId: id).flatMap { $0.kind == .evm ? $0 : nil } ?? Self.defaultChain
    }

    /// The connected address for this origin, if its wallet still exists.
    public func account(for origin: DappOrigin) -> (wallet: WalletRecord, address: EVMAddress)? {
        guard let s = sites.site(origin), let w = service.wallets.first(where: { $0.id == s.walletID }),
              let a = EVMAddress(w.evmAddress), EVMAddress(s.address) == a else { return nil }
        return (w, a)
    }

    public static let evmChains: [Chain] = Chain.all.filter { $0.kind == .evm }

    /// Switches the origin to another EVM network Hermit supports and tells the page.
    public func switchChain(_ origin: DappOrigin, to c: Chain) {
        guard c.kind == .evm, let id = c.chainId else { return }
        let old = chain(for: origin)
        chains[origin] = id
        sites.setChain(origin, chainID: id)
        if old != c { emit?(origin, "chainChanged", .string(Self.hex(id))) }
    }

    /// Settings (or the browser menu) disconnected a site.
    func disconnected(_ origin: String) {
        guard let o = URL(string: origin).flatMap(DappOrigin.init(url:)) else { return }
        emit?(o, "accountsChanged", .array([]))
        emit?(o, "solana:accounts", .array([]))
    }

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    // MARK: Requests

    /// Methods passed straight to the network's RPC (reads only; nothing here can move funds or reveal keys).
    public static let readOnly: Set<String> = [
        "eth_blockNumber", "eth_call", "eth_estimateGas", "eth_gasPrice", "eth_getBalance", "eth_getBlockByHash",
        "eth_getBlockByNumber", "eth_getBlockTransactionCountByHash", "eth_getBlockTransactionCountByNumber", "eth_getCode",
        "eth_getLogs", "eth_getProof", "eth_getStorageAt", "eth_getTransactionByBlockHashAndIndex",
        "eth_getTransactionByBlockNumberAndIndex", "eth_getTransactionByHash", "eth_getTransactionCount",
        "eth_getTransactionReceipt", "eth_getUncleCountByBlockHash", "eth_getUncleCountByBlockNumber", "eth_feeHistory",
        "eth_maxPriorityFeePerGas", "eth_blobBaseFee", "eth_syncing", "eth_createAccessList", "net_listening",
    ]

    public func handle(method: String, params: JSON, origin: DappOrigin) async -> Result<JSON, DappRPCError> {
        guard origin.isSecure else { return .failure(.unauthorized) }
        do { return .success(try await route(method, params.array ?? (params.isNull ? [] : [params]), origin)) }
        catch let e as DappRPCError { return .failure(e) }
        catch let e as WalletError {
            if case .rpc(let code, let m) = e { return .failure(DappRPCError(code, m)) }
            if case .cancelled = e { return .failure(.rejected) }
            return .failure(DappRPCError(-32603, e.errorDescription ?? "Wallet error"))
        } catch {
            return .failure(DappRPCError(-32603, error.localizedDescription))
        }
    }

    private func route(_ method: String, _ p: [JSON], _ origin: DappOrigin) async throws -> JSON {
        if method.hasPrefix("sol_") { return try await solana(method, p.first ?? .object([:]), origin) }
        let c = chain(for: origin)
        switch method {
        case "eth_chainId": return .string(Self.hex(c.chainId!))
        case "net_version": return .string(String(c.chainId!))
        case "web3_clientVersion": return "Hermit"
        case "eth_accounts":
            return .array(account(for: origin).map { [.string($0.address.checksummed.lowercased())] } ?? [])
        case "eth_coinbase":
            return account(for: origin).map { .string($0.address.checksummed.lowercased()) } ?? .null
        case "eth_requestAccounts", "wallet_requestPermissions":
            let a = try await connect(origin)
            return method == "eth_requestAccounts" ? .array([.string(a)]) : .array([["parentCapability": "eth_accounts"]])
        case "wallet_getPermissions":
            return .array(account(for: origin) == nil ? [] : [["parentCapability": "eth_accounts"]])
        case "wallet_revokePermissions":
            sites.disconnect(origin.description)
            return .null
        case "wallet_switchEthereumChain", "wallet_addEthereumChain":
            guard let s = p.first?["chainId"]?.string, let id = UInt128(quantity: s).flatMap({ UInt64(exactly: $0) }) else {
                throw DappRPCError.params("Expected [{ chainId }]")
            }
            guard let target = Chain.with(chainId: id), target.kind == .evm else {
                throw DappRPCError(4902, "Hermit doesn't support chain \(id) yet.")
            }
            if target != c {
                switchChain(origin, to: target)
                presenter?.notice("\(origin.host) switched to \(target.name)")
            }
            return .null
        case "personal_sign":
            return .string(try await personalSign(p, origin))
        case "eth_signTypedData_v4":
            return .string(try await signTypedData(p, origin))
        case "eth_sendTransaction":
            return .string(try await sendTransaction(p, origin))
        case "eth_sign":
            throw DappRPCError.unsupported("eth_sign (it can sign a transaction blindly); the site should use personal_sign")
        case "eth_signTypedData", "eth_signTypedData_v1", "eth_signTypedData_v3":
            throw DappRPCError.unsupported("\(method); the site should use eth_signTypedData_v4")
        default:
            guard Self.readOnly.contains(method) else { throw DappRPCError.unsupported(method) }
            return try await service.evm(c).rpc.call(method, p)
        }
    }

    // MARK: Prompts

    /// One sheet at a time. A site may have at most three requests waiting.
    func ask(_ approval: Approval, _ origin: DappOrigin) async throws -> String {
        guard let presenter else { throw DappRPCError(4900, "Hermit isn't showing this page.") }
        guard waiting[origin, default: 0] < 3 else { throw DappRPCError(-32002, "Requests are already waiting for the user.") }
        waiting[origin, default: 0] += 1
        defer { waiting[origin, default: 1] -= 1 }
        if busy { await withCheckedContinuation { queue.append($0) } } else { busy = true }
        defer { if queue.isEmpty { busy = false } else { queue.removeFirst().resume() } }
        let box = ResultBox()
        var a = approval
        if let inner = approval.perform {
            a.perform = { let r = try await inner(); box.set(r); return r }
        }
        await presenter.present(a)
        if let v = box.value { return v }
        throw DappRPCError.rejected
    }

    /// Lines and checks every request shares: who asks, from where.
    func header(_ origin: DappOrigin, wallet: WalletRecord?, address: EVMAddress?, chain: Chain) -> (lines: [[String]], checks: [String], warnings: [String]) {
        var lines = [["Site", origin.host]]
        if let wallet, let address { lines.append(["Wallet", "\(wallet.name), \(DappDecoder.short(address))"]) }
        if let wallet, address == nil { lines.append(["Wallet", "\(wallet.name), \(SolanaDecoder.short(wallet.solanaAddress))"]) }
        lines.append(["Network", chain.name + (chain.isTestnet ? " (testnet)" : "")])
        var checks = ["Asked by \(origin.host), the page itself (HTTPS, not an embedded frame)"]
        if DappSiteCheck.isListed(origin.host, known: knownHosts) { checks.append("\(origin.host) is in Hermit's Explore directory") }
        return (lines, checks, DappSiteCheck.warnings(host: origin.host, known: knownHosts))
    }

    private func connect(_ origin: DappOrigin) async throws -> String {
        if let a = account(for: origin) { sites.touch(origin); return a.address.checksummed.lowercased() }
        guard let w = service.selected, let addr = EVMAddress(w.evmAddress) else {
            presenter?.notice("Create a wallet in Wallets first, then connect.")
            throw DappRPCError(4100, "No wallet in Hermit yet.")
        }
        let c = chain(for: origin)
        var h = header(origin, wallet: w, address: addr, chain: c)
        h.lines.append(["Shares", "This address and its balances"])
        let sites = self.sites, wid = w.id, cid = c.chainId!
        let a = Approval(kind: "Connect a site", title: "Connect to \(origin.host)", lines: h.lines,
                         checks: h.checks + ["Connecting can't move funds: every signature asks you again"],
                         success: "Connected to \(origin.host)", warnings: h.warnings,
                         perform: { @MainActor in
                             sites.connect(origin, walletID: wid, address: addr.checksummed, chainID: cid)
                             return addr.checksummed
                         })
        _ = try await ask(a, origin)
        let lower = addr.checksummed.lowercased()
        emit?(origin, "accountsChanged", .array([.string(lower)]))
        return lower
    }

    /// The connected account, and the address the site named must be it.
    private func signer(_ origin: DappOrigin, named: String?) throws -> (WalletRecord, EVMAddress) {
        guard let acc = account(for: origin) else { throw DappRPCError.unauthorized }
        if let named, EVMAddress(named) != acc.address { throw DappRPCError(4100, "The site asked for an account that isn't connected.") }
        sites.touch(origin)
        return (acc.wallet, acc.address)
    }

    private func personalSign(_ p: [JSON], _ origin: DappOrigin) async throws -> String {
        guard p.count >= 1, let first = p[0].string else { throw DappRPCError.params("Expected [message, address]") }
        // Some apps send [address, message]: take whichever one isn't the address.
        var raw = first, named = p.count > 1 ? p[1].string : nil
        if EVMAddress(first) != nil, let second = named, EVMAddress(second) == nil { raw = second; named = first }
        let (w, addr) = try signer(origin, named: named)
        let bytes: [UInt8] = raw.hasPrefix("0x") ? ([UInt8](hex: raw) ?? Array(raw.utf8)) : Array(raw.utf8)
        let c = chain(for: origin)
        var intent = DappDecoder.message(bytes, host: origin.host)
        let h = header(origin, wallet: w, address: addr, chain: c)
        intent.warnings = h.warnings + intent.warnings
        let svc = service, wid = w.id
        let reason = "Sign a message for \(origin.host)"
        let a = Approval(kind: "Signature request from \(origin.host)", title: intent.title, lines: h.lines + intent.lines,
                         checks: h.checks + ["A plain message: it can't send a transaction or approve tokens"],
                         success: "Signed for \(origin.host)", warnings: intent.warnings,
                         perform: { @MainActor in try await svc.dappPersonalSign(walletID: wid, message: bytes, reason: reason) })
        return try await ask(a, origin)
    }

    private func signTypedData(_ p: [JSON], _ origin: DappOrigin) async throws -> String {
        guard p.count >= 2 else { throw DappRPCError.params("Expected [address, typedData]") }
        let (w, addr) = try signer(origin, named: p[0].string)
        let json: Data
        if let s = p[1].string { json = Data(s.utf8) } else { json = try JSONEncoder().encode(p[1]) }
        let typed: EIP712
        do { typed = try EIP712(json: json) } catch { throw DappRPCError.params("Not valid EIP-712 typed data.") }
        let c = chain(for: origin)
        // The domain's chain must be the one the site is on, or a signature meant for one network could be replayed on another.
        if let v = typed.domain["chainId"], let s = v.string,
           let id = (s.hasPrefix("0x") ? UInt128(quantity: s) : UInt128(s)), id != UInt128(c.chainId!) {
            throw DappRPCError.params("The typed data is for chain \(id), but the site is on \(c.name) (\(c.chainId!)).")
        }
        do { _ = try typed.digest() } catch { throw DappRPCError.params("Hermit can't encode this typed data: \(error.localizedDescription)") }
        var intent = await DappDecoder.typedData(typed, chain: c, client: service.evm(c))
        let h = header(origin, wallet: w, address: addr, chain: c)
        intent.warnings = h.warnings + intent.warnings
        let svc = service, wid = w.id
        let reason = "Sign for \(origin.host)"
        let a = Approval(kind: "Signature request from \(origin.host)", title: intent.title, lines: h.lines + intent.lines,
                         checks: h.checks + ["Typed data matches \(c.name)"],
                         success: "Signed for \(origin.host)", warnings: intent.warnings,
                         perform: { @MainActor in try await svc.dappSignTypedData(walletID: wid, typedData: typed, reason: reason) })
        return try await ask(a, origin)
    }

    private func sendTransaction(_ p: [JSON], _ origin: DappOrigin) async throws -> String {
        guard let t = p.first, case .object = t else { throw DappRPCError.params("Expected [transaction]") }
        let (w, addr) = try signer(origin, named: t["from"]?.string)
        let c = chain(for: origin)
        if let s = t["chainId"]?.string, let id = UInt128(quantity: s), id != UInt128(c.chainId!) {
            throw DappRPCError.params("The transaction is for chain \(id), but the site is on \(c.name).")
        }
        guard let toS = t["to"]?.string, !toS.isEmpty else {
            throw DappRPCError.unsupported("deploying contracts from a web page")
        }
        guard let to = EVMAddress(toS) else { throw DappRPCError.params("Bad 'to' address.") }
        func q(_ k: String) throws -> UInt128 {
            guard let s = t[k]?.string else { return 0 }
            guard let v = UInt128(quantity: s) else { throw DappRPCError.params("Bad '\(k)'.") }
            return v
        }
        let value = try q("value")
        let dataS = t["data"]?.string ?? t["input"]?.string ?? "0x"
        guard let data = [UInt8](hex: dataS) else { throw DappRPCError.params("Bad 'data'.") }
        let gas = try q("gas")
        let req = DappTransactionRequest(from: addr, to: to, value: value, data: data, gas: gas > 0 ? UInt64(exactly: gas) : nil)

        let client = service.evm(c)
        let feed = prices, testnet = c.isTestnet
        async let pricesA: [String: Double] = testnet ? [:] : feed()
        async let preparedA = service.prepareDappTransaction(walletID: w.id, chain: c, req)
        let prices = await pricesA
        let intent = await DappDecoder.transaction(req, chain: c, client: client, prices: prices)
        let prepared = try await preparedA

        let h = header(origin, wallet: w, address: addr, chain: c)
        var lines = h.lines + intent.lines
        lines.append(["Network fee", "up to \(Units.format(prepared.networkFee, decimals: c.nativeDecimals, maxFraction: 8)) \(c.nativeSymbol)"])
        var checks = h.checks + ["Built transaction matches the site's request, checked again after signing"]
        var warnings = h.warnings + intent.warnings
        if prepared.simulated { checks.append("Simulated on \(c.name): it doesn't fail") }
        else { warnings.insert("Simulation failed: \(prepared.simulationDetail) It will probably fail and still cost a fee.", at: 0) }
        if prepared.feeCovered { checks.append("Enough \(c.nativeSymbol) for the network fee") }
        else {
            warnings.insert("Not enough \(c.nativeSymbol) on \(c.name) for this and its network fee (have \(Units.format(prepared.nativeBalance, decimals: c.nativeDecimals, maxFraction: 6))). The network will refuse it.", at: 0)
        }
        // The spending policy: daily limit and first-payment check on what leaves the wallet directly.
        var spent: Decimal? = nil
        if intent.movesFunds {
            let v = service.policy.evaluate(usd: intent.outflowUSD.map { NSDecimalNumber(decimal: $0).doubleValue },
                                            payee: intent.payee.map { ($0.checksummed, ChainKind.evm) }, origin: .user)
            if v.decision == .block {
                presenter?.notice(v.blocks.first ?? "Blocked by your spending policy")
                throw DappRPCError(4001, "Blocked by Hermit's spending policy: \(v.blocks.joined(separator: " "))")
            }
            checks += v.passed
            warnings += v.warnings
            spent = intent.outflowUSD
        }
        let svc = service
        let reason = "\(intent.title) on \(origin.host)"
        let a = Approval(kind: "Transaction from \(origin.host)", title: intent.title, lines: lines, checks: checks,
                         success: "Sent to \(c.name)", warnings: warnings,
                         perform: { @MainActor in try await svc.executeDappTransaction(prepared, reason: reason, spentUSD: spent) })
        return try await ask(a, origin)
    }
}

/// Holds what the approval sheet's perform produced, so a cancelled sheet can be told apart from an approved one.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    var value: String? { lock.withLock { v } }
    func set(_ s: String) { lock.withLock { v = s } }
}
