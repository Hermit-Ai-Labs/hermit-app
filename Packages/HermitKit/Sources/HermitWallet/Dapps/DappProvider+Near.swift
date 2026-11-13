import Foundation
import HermitCore

// The NEAR half of Hermit's browser wallet. The page script (DappWebBridge.nearScript) announces "Hermit" to HOT's
// near-connect ("near-wallet-injected") and mounts it at window.near.hermit (NEP-408); both call these near_* methods.
// Same rules as EVM and Solana: main frame, https, origin from WebKit, every signature through the approval sheet with
// Face ID / Touch ID. Mainnet only.

extension DappProvider {
    /// The connected NEAR account for this origin, if its wallet still has it.
    public func nearAccount(for origin: DappOrigin) -> (wallet: WalletRecord, account: String)? {
        guard let s = sites.site(origin), let a = s.near, let w = service.wallets.first(where: { $0.id == s.walletID }),
              w.nearAccount == a else { return nil }
        return (w, a)
    }

    /// {accountId, publicKey: "ed25519:…"}: an implicit account's key is its id.
    static func nearAccountJSON(_ account: String) -> JSON {
        let key = [UInt8](hex: account).map(NearAccount.publicKeyString) ?? ""
        return ["accountId": .string(account), "publicKey": .string(key)]
    }

    func near(_ method: String, _ p: JSON, _ origin: DappOrigin) async throws -> JSON {
        do {
            try NearDapp.checkNetwork(p["network"])
            switch method {
            case "near_accounts":
                return .array(nearAccount(for: origin).map { [Self.nearAccountJSON($0.account)] } ?? [])
            case "near_signIn":
                return try await nearSignIn(p, origin)
            case "near_signOut":
                sites.disconnectNear(origin)
                emit?(origin, "near:accounts", .array([]))
                return .null
            case "near_signAndSendTransactions":
                return try await nearTransactions(p, origin)
            case "near_signMessage":
                return try await nearSignMessage(p, origin)
            default:
                throw DappRPCError.unsupported(method)
            }
        } catch let e as DappRPCError where e == .rejected {
            // near-connect apps check for this exact text.
            throw DappRPCError(4001, "User rejected")
        }
    }

    /// The header lines for a NEAR request: site, wallet and account, network.
    private func nearHeader(_ origin: DappOrigin, _ w: WalletRecord, _ account: String) -> (lines: [[String]], checks: [String], warnings: [String]) {
        var h = header(origin, wallet: nil, address: nil, chain: .near)
        h.lines.insert(["Wallet", "\(w.name), \(NearDapp.shortAccount(account))"], at: 1)
        return h
    }

    private func nearSigner(_ origin: DappOrigin) throws -> (WalletRecord, String) {
        guard let a = nearAccount(for: origin) else { throw DappRPCError(4100, "Connect Hermit to this site first.") }
        sites.touch(origin)
        return (a.wallet, a.account)
    }

    /// The account must exist on chain to sign a transaction: an implicit account appears the first time it receives NEAR.
    private func nearState(_ account: String) async throws -> NearClient.AccountState {
        let state: NearClient.AccountState?
        do { state = try await service.nearAccountState(account) }
        catch { throw DappRPCError(-32603, "Couldn't read your NEAR account: \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        guard let state else {
            presenter?.notice("Your NEAR account needs a little NEAR first")
            throw DappRPCError(4100, "Your NEAR account needs a little NEAR first. Send about 0.01 NEAR to it in Hermit, then try again.")
        }
        return state
    }

    /// What a key can do on the account: .some(nil) when it isn't there, nil when it couldn't be read.
    private func keyPermission(_ account: String, _ key: String) async -> NearGuard.KeyPermission?? {
        do { return .some(try await service.nearClient.accessKeyPermission(account: account, publicKey: key)) } catch { return nil }
    }

    /// Runs the approval, and passes on why `perform` failed (a refused transaction) instead of "User rejected".
    private func askNear(_ a: Approval, _ origin: DappOrigin, _ errors: ErrorBox) async throws {
        do { _ = try await ask(a, origin) }
        catch let e as DappRPCError where e == .rejected {
            if let inner = errors.value {
                if case WalletError.cancelled = inner { throw e }
                throw DappRPCError(-32603, (inner as? LocalizedError)?.errorDescription ?? "\(inner)")
            }
            throw e
        }
    }

    // MARK: Connect / sign in

    /// signIn: shares the account. With addFunctionCallKey it also adds the site's function-call key to the account
    /// (one transaction, Face ID), so the site can sign gas-only calls to that one contract by itself.
    private func nearSignIn(_ p: JSON, _ origin: DappOrigin) async throws -> JSON {
        guard let w = service.selected else {
            presenter?.notice("Create a wallet in Wallets first, then connect.")
            throw DappRPCError(4100, "No wallet in Hermit yet.")
        }
        guard let account = w.nearAccount else {
            presenter?.notice("Add a NEAR account to this wallet in Wallets first.")
            throw DappRPCError(4100, "This Hermit wallet has no NEAR account yet.")
        }
        if let named = p["accountId"]?.string, named != account {
            throw DappRPCError(4100, "The site asked for \(named.prefix(64)), which isn't this wallet's NEAR account.")
        }
        let keyJSON = p["addFunctionCallKey"].flatMap { $0.isNull ? nil : $0 }
        let key = try keyJSON.map { try NearDapp.functionCallKey($0, account: account) }
        if key == nil, let a = nearAccount(for: origin), a.account == account {
            sites.touch(origin)
            return .array([Self.nearAccountJSON(account)])
        }

        var h = nearHeader(origin, w, account)
        h.lines.append(["Shares", "This account and its balances"])
        var checks = h.checks, warnings = h.warnings
        var needsTx = false
        if let key {
            guard service.allowMainnetSends else { throw DappRPCError(4100, "Mainnet transactions are off in this build.") }
            let state = try await nearState(account)
            let keyString = NearAccount.publicKeyString(key.publicKey)
            switch await keyPermission(account, keyString) {
            case .some(.some(.fullAccess)):
                throw DappRPCError(4100, "That key already has full access to your account. Remove it in a NEAR wallet you trust.")
            case .some(.some(.functionCall(let r, let m))) where r == key.contract && Set(m) == Set(key.methods):
                checks.append("The site's key is already on your account with these permissions: no transaction needed")
            case .some(.some(.functionCall)):
                throw DappRPCError(4100, "That key is already on your account with other permissions.")
            default:
                needsTx = true   // not on the account, or it couldn't be read (then AddKey simply fails if it exists)
            }
            h.lines.append(["Lets the site call", "\(key.methods.isEmpty ? "any method" : key.methods.joined(separator: ", ")) on \(key.contract)"])
            h.lines.append(["Gas allowance", key.allowance.map { "up to \(NearDapp.nearText($0))" } ?? "No limit"])
            h.lines.append(["Site's key", "ed25519:\(Base58.encode(key.publicKey).prefix(8))…"])
            if needsTx {
                let fee = UInt128(NearDapp.plainActionGas) * NearDapp.gasPriceCeiling
                h.lines.append(["Network fee", "up to \(NearDapp.nearText(fee))"])
                if state.available < fee { warnings.insert("Not enough NEAR for the network fee. The network will refuse it.", at: 0) }
            }
            checks.append("The key can only call \(key.contract) and can't attach NEAR, so it can't send your NEAR")
            if key.methods.isEmpty { warnings.append("The site can call any method on \(key.contract) without asking you.") }
            if let a = key.allowance, a > NearDapp.oneNear { warnings.append("The site's key may spend up to \(NearDapp.nearText(a)) of your NEAR on gas.") }
            if key.allowance == nil { warnings.append("The site's key has no gas allowance limit: it can spend your NEAR on gas until you remove it.") }
        } else {
            checks.append("Connecting can't move funds: every transaction asks you again")
        }

        let svc = service, sites = self.sites, wid = w.id, host = origin.host, sendKey = needsTx
        let errors = ErrorBox()
        let a = Approval(kind: "Connect a site", title: key == nil ? "Connect to \(host)" : "Sign in to \(host)", lines: h.lines,
                         checks: checks, success: key == nil ? "Connected to \(host)" : "Signed in to \(host)", warnings: warnings,
                         perform: { @MainActor in
                             do {
                                 var out = account
                                 if let key, sendKey {
                                     let tx = NearDapp.Tx(receiver: account, actions: [key.action])
                                     out = try await svc.dappNearSend(walletID: wid, account: account, transactions: [tx],
                                                                      reason: "Sign in to \(host)").first?["transaction"]?["hash"]?.string ?? account
                                 }
                                 sites.connectNear(origin, walletID: wid, account: account)
                                 return out
                             } catch { errors.set(error); throw error }
                         })
        try await askNear(a, origin, errors)
        emit?(origin, "near:accounts", .array([Self.nearAccountJSON(account)]))
        return .array([Self.nearAccountJSON(account)])
    }

    // MARK: Transactions

    /// signAndSendTransactions: checks every action, reviews them on one sheet, signs all with one Face ID, sends them in
    /// order (stopping at the first failure) and returns each FinalExecutionOutcome.
    private func nearTransactions(_ p: JSON, _ origin: DappOrigin) async throws -> JSON {
        let (w, account) = try nearSigner(origin)
        let txs = try NearDapp.transactions(p, account: account)
        guard service.allowMainnetSends else { throw DappRPCError(4100, "Mainnet transactions are off in this build.") }
        let state = try await nearState(account)

        var review = NearDapp.review(txs, account: account)
        // A key a site asks to delete must not be a full-access key (that could lock you out of this account).
        for t in txs { for case .deleteKey(let k) in t.actions {
            switch await keyPermission(account, NearAccount.publicKeyString(k)) {
            case .some(.some(.fullAccess)):
                throw DappRPCError(4200, "Hermit won't remove a full-access key for a site.")
            case .some(.none):
                review.warnings.append("The key to remove isn't on your account, so this will fail.")
            default: break
            }
        } }

        let h = nearHeader(origin, w, account)
        var checks = h.checks + ["Hermit signs exactly the actions listed here, as your account \(NearDapp.shortAccount(account))"]
        var warnings = h.warnings + review.warnings
        let fee = UInt128(review.gas) * NearDapp.gasPriceCeiling
        if state.available < review.deposit + fee {
            warnings.insert("Not enough NEAR for this and its network fee (have \(Units.format(state.available, decimals: 24, maxFraction: 5))). The network will refuse it.", at: 0)
        } else {
            checks.append("Enough NEAR for this and its network fee")
        }

        // The spending policy counts NEAR that leaves: transfers and deposits attached to calls.
        var price: Double? = nil
        if review.movesFunds {
            price = await prices()["NEAR"]
            let usd = NearDapp.usd(review.deposit, price: price)
            let v = service.policy.evaluate(usd: usd.map { NSDecimalNumber(decimal: $0).doubleValue },
                                            payee: review.payee.map { ($0, ChainKind.near) }, origin: .user)
            if v.decision == .block {
                presenter?.notice(v.blocks.first ?? "Blocked by your spending policy")
                throw DappRPCError(4001, "Blocked by Hermit's spending policy: \(v.blocks.joined(separator: " "))")
            }
            checks += v.passed.filter { !(review.payee == nil && $0 == "Pays out to your own address") }
            warnings += v.warnings
        }
        let perTx = txs.map { NearDapp.usd($0.actions.reduce(UInt128(0)) { $0 + $1.attached }, price: price) }

        let svc = service, wid = w.id, onSent = self.onSent, title = review.title, host = origin.host
        let reason = "\(review.title) on \(host)"
        let box = ResultBox(), errors = ErrorBox()
        let a = Approval(kind: "Transaction from \(host)", title: review.title, lines: h.lines + review.lines, checks: checks,
                         success: "Sent to NEAR", warnings: warnings,
                         perform: { @MainActor in
                             do {
                                 let outcomes = try await svc.dappNearSend(walletID: wid, account: account, transactions: txs, reason: reason) { i, hash in
                                     if let usd = perTx[i], usd > 0 { svc.spendLimit.record(usd: usd) }
                                     onSent?(DappSentTransaction(chain: .near, hash: hash, title: title, host: host, walletID: wid))
                                 }
                                 let text = String(data: try JSONEncoder().encode(JSON.array(outcomes)), encoding: .utf8) ?? "[]"
                                 box.set(text)
                                 return outcomes.last?["transaction"]?["hash"]?.string ?? ""
                             } catch { errors.set(error); throw error }
                         })
        try await askNear(a, origin, errors)
        guard let text = box.value, let out = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8)) else { throw DappRPCError.rejected }
        return out
    }

    // MARK: Messages

    /// NEP-413 signMessage: {message, recipient, nonce (32 bytes), callbackUrl?} → {accountId, publicKey, signature}.
    private func nearSignMessage(_ p: JSON, _ origin: DappOrigin) async throws -> JSON {
        let (w, account) = try nearSigner(origin)
        guard let message = p["message"]?.string else { throw DappRPCError.params("Expected a message string.") }
        guard message.utf8.count <= 64 * 1024 else { throw DappRPCError.params("That message is too long to review.") }
        guard let recipient = p["recipient"]?.string, !recipient.isEmpty, recipient.utf8.count <= 256 else {
            throw DappRPCError.params("Expected a recipient.")
        }
        let nonce = try NearDapp.nonce(p["nonce"])
        let callback = p["callbackUrl"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let payload = NearDapp.nep413Payload(message: message, nonce: nonce, recipient: recipient, callbackUrl: callback)

        let h = nearHeader(origin, w, account)
        var lines = h.lines.filter { $0[0] != "Network" }
        lines.append(["Message", message.count > 600 ? String(message.prefix(600)) + "…" : message])
        lines.append(["For", recipient])
        if let callback { lines.append(["Callback", String(callback.prefix(200))]) }
        var warnings = h.warnings
        let r = recipient.lowercased(), host = origin.host
        let sameSite = r == host || host.hasSuffix("." + r) || (r.contains(".") && DappSiteCheck.registrable(r) == DappSiteCheck.registrable(host))
        if !sameSite {
            warnings.append("This message is addressed to \(recipient.prefix(80)), but the page asking is \(host). Sign it only if you expected that.")
        }
        let svc = service, wid = w.id
        let box = ResultBox(), errors = ErrorBox()
        let a = Approval(kind: "Signature request from \(host)", title: "Sign a message", lines: lines,
                         checks: h.checks + ["A signed message (NEP-413), not a transaction: it can't move funds"],
                         success: "Signed for \(host)", warnings: warnings,
                         perform: { @MainActor in
                             do {
                                 let sig = try await svc.dappNearSignMessage(walletID: wid, account: account, payload: payload, reason: "Sign a message for \(host)")
                                 box.set(Data(sig).base64EncodedString())
                                 return Base58.encode(sig)
                             } catch { errors.set(error); throw error }
                         })
        try await askNear(a, origin, errors)
        guard let sig = box.value else { throw DappRPCError.rejected }
        var out = Self.nearAccountJSON(account)
        if case .object(var o) = out { o["signature"] = .string(sig); out = .object(o) }
        return out
    }
}

/// Holds the error an approval's perform threw, so the page hears why instead of "User rejected".
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var e: Error?
    var value: Error? { lock.withLock { e } }
    func set(_ error: Error) { lock.withLock { e = error } }
}
