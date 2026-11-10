import Foundation
import HermitCore

// The Solana half of Hermit's browser wallet: the Wallet Standard wallet "Hermit" and window.solana call these as
// sol_* methods. Same rules as EVM: main frame, https, origin from WebKit, every signature through the approval sheet.

extension DappProvider {
    /// The Solana chain a request names ("solana:mainnet" by default, "solana:devnet").
    static func solanaChain(_ id: String?) throws -> Chain {
        switch id ?? "solana:mainnet" {
        case "solana:mainnet", "solana:mainnet-beta": return .solana
        case "solana:devnet": return .solanaDevnet
        case let other: throw DappRPCError(4100, "Hermit doesn't support \(other).")
        }
    }

    /// The connected Solana account for this origin, if its wallet still exists.
    public func solanaAccount(for origin: DappOrigin) -> (wallet: WalletRecord, key: SolanaPublicKey)? {
        guard let s = sites.site(origin), let addr = s.solana, let w = service.wallets.first(where: { $0.id == s.walletID }),
              w.solanaAddress == addr, let k = SolanaPublicKey(addr) else { return nil }
        return (w, k)
    }

    static func accountJSON(_ k: SolanaPublicKey) -> JSON {
        ["address": .string(k.description), "publicKey": .string(Data(k.bytes).base64EncodedString())]
    }

    static func bytes(_ p: JSON, _ key: String) throws -> [UInt8] {
        guard let s = p[key]?.string, let d = Data(base64Encoded: s) else { throw DappRPCError.params("Expected base64 '\(key)'.") }
        return [UInt8](d)
    }

    func solana(_ method: String, _ p: JSON, _ origin: DappOrigin) async throws -> JSON {
        switch method {
        case "sol_accounts":
            return solanaAccount(for: origin).map { Self.accountJSON($0.key) } ?? .null
        case "sol_connect":
            if let a = solanaAccount(for: origin) { sites.touch(origin); return Self.accountJSON(a.key) }
            if p["silent"]?.bool == true { return .null }
            return Self.accountJSON(try await connectSolana(origin))
        case "sol_disconnect":
            sites.disconnectSolana(origin)
            return .null
        case "sol_signMessage":
            return ["signature": .string(Data(try await solanaSignMessage(try Self.bytes(p, "message"), origin)).base64EncodedString())]
        case "sol_signIn":
            return try await solanaSignIn(p["input"] ?? .object([:]), origin)
        case "sol_signTransaction":
            let signed = try await solanaTransaction(try Self.bytes(p, "transaction"), chain: p["chain"]?.string, send: false,
                                                     skipPreflight: false, origin)
            return ["signedTransaction": .string(signed)]
        case "sol_signAndSendTransaction":
            let sig = try await solanaTransaction(try Self.bytes(p, "transaction"), chain: p["chain"]?.string, send: true,
                                                  skipPreflight: p["options"]?["skipPreflight"]?.bool ?? false, origin)
            return ["signature": .string(sig), "signatureBytes": .string(Data(Base58.decode(sig) ?? []).base64EncodedString())]
        default:
            throw DappRPCError.unsupported(method)
        }
    }

    /// Plain words for the simulation errors people actually hit.
    static func solanaSimError(_ e: String, logs: [String]) -> String {
        if e.contains("InvalidAccountForFee") || e.contains("AccountNotFound") { return "this wallet has no SOL on this network to pay the fee." }
        if e.contains("BlockhashNotFound") { return "the site's transaction has expired; ask it to try again." }
        let s = WalletService.solanaError(e, logs: logs)
        return s.hasSuffix(".") ? s : s + "."
    }

    // MARK: Connect

    private func connectSolana(_ origin: DappOrigin) async throws -> SolanaPublicKey {
        guard let w = service.selected, let key = SolanaPublicKey(w.solanaAddress) else {
            presenter?.notice("Create a wallet in Wallets first, then connect.")
            throw DappRPCError(4100, "No wallet in Hermit yet.")
        }
        var h = header(origin, wallet: w, address: nil, chain: .solana)
        h.lines.removeAll { $0[0] == "Network" }
        h.lines.append(["Network", "Solana"])
        h.lines.append(["Shares", "This address and its balances"])
        let sites = self.sites, wid = w.id
        let a = Approval(kind: "Connect a site", title: "Connect to \(origin.host)", lines: h.lines,
                         checks: h.checks + ["Connecting can't move funds: every signature asks you again"],
                         success: "Connected to \(origin.host)", warnings: h.warnings,
                         perform: { @MainActor in
                             sites.connectSolana(origin, walletID: wid, address: key.description)
                             return key.description
                         })
        _ = try await ask(a, origin)
        emit?(origin, "solana:accounts", .array([Self.accountJSON(key)]))
        return key
    }

    private func solanaSigner(_ origin: DappOrigin) throws -> (WalletRecord, SolanaPublicKey) {
        guard let a = solanaAccount(for: origin) else { throw DappRPCError.unauthorized }
        sites.touch(origin)
        return (a.wallet, a.key)
    }

    // MARK: Messages

    /// A message that parses as a Solana transaction or message is refused: signing it would sign a transaction blind.
    static func looksLikeTransaction(_ b: [UInt8]) -> Bool {
        (try? SolanaWireTransaction.parse(b)) != nil || (try? SolanaWireMessage.parse(b)) != nil
    }

    private func solanaSignMessage(_ bytes: [UInt8], _ origin: DappOrigin) async throws -> [UInt8] {
        let (w, key) = try solanaSigner(origin)
        guard !Self.looksLikeTransaction(bytes) else {
            presenter?.notice("Hermit refused: the site asked to sign a transaction as a message")
            throw DappRPCError(4100, "This message is a Solana transaction. Hermit only signs transactions it can show you.")
        }
        var intent = DappDecoder.message(bytes, host: origin.host)
        if let text = String(bytes: bytes, encoding: .utf8), let r = text.range(of: " wants you to sign in with your Solana account:") {
            let domain = String(text[..<r.lowerBound]).components(separatedBy: "://").last?.lowercased() ?? ""
            let host = domain.split(separator: ":").first.map(String.init) ?? domain
            intent.title = "Sign in to \(host)"
            if host != origin.host {
                intent.warnings.append("This sign-in message is for \(host), but the page asking is \(origin.host). Phishing sites do this to steal a login.")
            }
        }
        let h = header(origin, wallet: w, address: nil, chain: .solana)
        let svc = service, wid = w.id, reason = "Sign a message for \(origin.host)"
        let box = ResultBox()
        let a = Approval(kind: "Signature request from \(origin.host)", title: intent.title,
                         lines: h.lines.filter { $0[0] != "Network" } + intent.lines,
                         checks: h.checks + ["A plain message, not a transaction: it can't move funds"],
                         success: "Signed for \(origin.host)", warnings: h.warnings + intent.warnings,
                         perform: { @MainActor in
                             let sig = try await svc.dappSolanaSignMessage(walletID: wid, bytes, reason: reason)
                             box.set(Data(sig).base64EncodedString())
                             return Base58.encode(sig)
                         })
        _ = try await ask(a, origin)
        _ = key
        guard let b64 = box.value, let d = Data(base64Encoded: b64) else { throw DappRPCError.rejected }
        return [UInt8](d)
    }

    /// solana:signIn (Sign-In with Solana): Hermit writes the message from the site's input, so the domain is always
    /// the page's own unless the site names another (then it warns). Connects the site too.
    private func solanaSignIn(_ input: JSON, _ origin: DappOrigin) async throws -> JSON {
        guard let w = service.selected, let key = SolanaPublicKey(w.solanaAddress) else { throw DappRPCError(4100, "No wallet in Hermit yet.") }
        if let a = input["address"]?.string, a != key.description { throw DappRPCError(4100, "The site asked for an account that isn't this wallet.") }
        let domain = input["domain"]?.string ?? origin.host
        let text = SolanaDecoder.signInMessage(domain: domain, address: key.description, input: input)
        let bytes = Array(text.utf8)
        var h = header(origin, wallet: w, address: nil, chain: .solana)
        h.lines.removeAll { $0[0] == "Network" }
        var warnings = h.warnings
        let host = domain.split(separator: ":").first.map(String.init)?.lowercased() ?? domain
        if host != origin.host {
            warnings.append("This sign-in message is for \(host), but the page asking is \(origin.host). Phishing sites do this to steal a login.")
        }
        let svc = service, sites = self.sites, wid = w.id, reason = "Sign in to \(origin.host)"
        let box = ResultBox()
        let a = Approval(kind: "Sign-in request from \(origin.host)", title: "Sign in to \(host)",
                         lines: h.lines + [["Message", text.count > 420 ? String(text.prefix(420)) + "…" : text]],
                         checks: h.checks + ["A plain message, not a transaction: it can't move funds"],
                         success: "Signed in to \(origin.host)", warnings: warnings,
                         perform: { @MainActor in
                             let sig = try await svc.dappSolanaSignMessage(walletID: wid, bytes, reason: reason)
                             sites.connectSolana(origin, walletID: wid, address: key.description)
                             box.set(Data(sig).base64EncodedString())
                             return Base58.encode(sig)
                         })
        _ = try await ask(a, origin)
        guard let sig = box.value else { throw DappRPCError.rejected }
        emit?(origin, "solana:accounts", .array([Self.accountJSON(key)]))
        return ["account": Self.accountJSON(key), "signedMessage": .string(Data(bytes).base64EncodedString()), "signature": .string(sig)]
    }

    // MARK: Transactions

    /// Parses, resolves lookup tables, simulates, decodes and reviews a transaction, then signs it (and sends it).
    /// Returns the signed transaction in base64, or the signature in base58 when sent.
    private func solanaTransaction(_ raw: [UInt8], chain id: String?, send: Bool, skipPreflight: Bool, _ origin: DappOrigin) async throws -> String {
        let (w, me) = try solanaSigner(origin)
        let c = try Self.solanaChain(id)
        if send, !c.isTestnet, !service.allowMainnetSends { throw DappRPCError(4100, "Mainnet transactions are off in this build.") }
        let tx: SolanaWireTransaction
        do { tx = try SolanaWireTransaction.parse(raw) }
        catch { throw DappRPCError.params((error as? LocalizedError)?.errorDescription ?? "Not a Solana transaction.") }
        let m = tx.message
        let slot: Int
        do { slot = try WalletService.signerSlot(m, wallet: me) }
        catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "Not for this wallet."
            presenter?.notice(msg)
            throw DappRPCError(4100, msg)
        }
        if send, !WalletService.otherSignaturesValid(tx, except: slot) {
            let msg = "This transaction needs another signature (fee payer \(SolanaDecoder.short(m.feePayer.description))) before it can be sent."
            presenter?.notice(msg)
            throw DappRPCError(4100, msg)
        }
        let client = service.sol(c)
        let tables: [SolanaPublicKey: [SolanaPublicKey]]
        do { tables = try await client.lookupTables(for: m) }
        catch { throw DappRPCError(-32603, "Couldn't load the transaction's lookup tables: \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        let keys: [SolanaPublicKey]
        do { keys = try SolanaLookupTable.resolve(m, tables: tables) }
        catch { throw DappRPCError.params((error as? LocalizedError)?.errorDescription ?? "Bad lookup table.") }

        let feed = prices, testnet = c.isTestnet
        async let pricesA: [String: Double] = testnet ? [:] : feed()
        let sim = try? await client.simulateDapp(tx)
        var tokenInfo: [Int: SolanaTokenBalance] = [:]
        for t in (sim?.postToken ?? []) + (sim?.preToken ?? []) { tokenInfo[t.accountIndex] = t }
        var review = SolanaDecoder.review(m, keys: keys, wallet: me, chain: c, tokenInfo: tokenInfo)

        let h = header(origin, wallet: w, address: nil, chain: c)
        var lines = h.lines + review.lines
        var checks = h.checks + ["Hermit signs the site's bytes exactly as decoded here, in your signer slot only"]
        var warnings = h.warnings
        if slot != 0 {
            lines.insert(["Fee payer", SolanaDecoder.short(m.feePayer.description)], at: h.lines.count)
            warnings.append("Someone else pays the fee: \(SolanaDecoder.short(m.feePayer.description)) is the fee payer, and your wallet signs as an extra signer.")
        }
        let format: String = switch m.version {
        case .legacy: "Legacy"
        case .v0: m.lookups.isEmpty ? "v0" : "v0, \(m.lookups.count) lookup table\(m.lookups.count == 1 ? "" : "s")"
        case .v1: "v1"
        }
        lines.append(["Format", format])

        var changes: [SolanaBalanceChange] = []
        if let sim {
            if let e = sim.error {
                warnings.insert("Simulation failed: \(Self.solanaSimError(e, logs: sim.logs)) It will probably fail and may still cost a fee.", at: 0)
            } else {
                checks.append("Simulated on \(c.name): it succeeds")
            }
            if sim.error != nil {
                // A failed simulation changes nothing, which says nothing about what success would do.
            } else if sim.hasBalances {
                changes = SolanaDecoder.changes(sim, keys: keys, wallet: me, chain: c)
                if changes.isEmpty { lines.append(["Your balances", "No change"]) }
                for ch in changes { lines.append([ch.delta < 0 ? "You pay" : "You get", ch.text]) }
            } else {
                warnings.append("This network didn't report balance changes, so Hermit can't show what you send or receive.")
            }
            let fee = sim.fee ?? (5_000 * UInt64(m.numRequiredSignatures) + review.priorityFeeLamports)
            lines.append(["Network fee", "\(Units.format(UInt128(fee), decimals: 9, maxFraction: 9)) SOL" + (slot != 0 ? " (paid by the fee payer)" : "")])
        } else {
            warnings.insert("Hermit couldn't simulate this transaction, so it can't show its balance changes.", at: 0)
            lines.append(["Network fee", "about \(Units.format(UInt128(5_000 * UInt64(m.numRequiredSignatures) + review.priorityFeeLamports), decimals: 9, maxFraction: 9)) SOL"])
        }
        // Token-2022 mints this wallet's balances touch: transfer fees, hooks, permanent delegates.
        let balances = (sim?.preToken ?? []) + (sim?.postToken ?? [])
        let t22 = Set(balances.filter { $0.programId == SolanaPrograms.token2022 && $0.owner == me.description }.map(\.mint))
        if !t22.isEmpty, let data = try? await client.accountsData(Array(t22)) {
            for (mint, d) in data.sorted(by: { $0.key < $1.key }) {
                warnings += SolanaDecoder.mintExtensionWarnings(d, symbol: SolanaDecoder.symbol(mint, chain: c).0)
            }
        }
        warnings += review.warnings

        // Spending policy on the net outflow (from simulation; from the decoded transfers when there is none). The
        // network fee alone doesn't count as a payment.
        let quotes = await pricesA
        let feeLamports = Int128(sim?.fee ?? (5_000 * UInt64(m.numRequiredSignatures) + review.priorityFeeLamports))
        let spentChanges = changes.compactMap { ch -> SolanaBalanceChange? in
            guard ch.mint == nil, slot == 0 else { return ch }
            let net = ch.delta + feeLamports   // SOL change without the fee this wallet pays
            return net == 0 ? nil : SolanaBalanceChange(symbol: ch.symbol, mint: nil, decimals: 9, delta: net)
        }
        var outflow: Decimal? = sim?.hasBalances == true && sim?.error == nil
            ? SolanaDecoder.outflowUSD(spentChanges, chain: c, solPrice: quotes["SOL"]) : review.directOutflowUSD(chain: c, solPrice: quotes["SOL"])
        if c.isTestnet { outflow = 0 }
        let leaves = spentChanges.contains { $0.delta < 0 } || review.movesFunds
        var spent: Decimal? = nil
        if leaves {
            let v = service.policy.evaluate(usd: outflow.map { NSDecimalNumber(decimal: $0).doubleValue },
                                            payee: review.payee.map { ($0, ChainKind.solana) }, origin: .user)
            if v.decision == .block {
                presenter?.notice(v.blocks.first ?? "Blocked by your spending policy")
                throw DappRPCError(4001, "Blocked by Hermit's spending policy: \(v.blocks.joined(separator: " "))")
            }
            // With no single payee, evaluate() says it pays out to your own address; that isn't known here, so drop it.
            checks += v.passed.filter { !(review.payee == nil && $0 == "Pays out to your own address") }
            warnings += v.warnings
            spent = outflow
        }
        review.changes = changes
        let svc = service, wid = w.id
        let reason = "\(review.title) on \(origin.host)"
        let box = ResultBox()
        let a = Approval(kind: "Transaction from \(origin.host)", title: review.title, lines: lines, checks: checks,
                         success: send ? "Sent to \(c.name)" : "Signed for \(origin.host)", warnings: warnings,
                         perform: { @MainActor in
                             let signed = try await svc.dappSolanaSign(walletID: wid, tx, reason: reason)
                             guard signed.message.bytes == tx.message.bytes else { throw WalletError.blocked("Signed transaction failed its self-check.") }
                             if !send {
                                 let b64 = Data(signed.serialized).base64EncodedString()
                                 box.set(b64); return Base58.encode(signed.signatures[slot])
                             }
                             let sig = try await client.sendRaw(signed, skipPreflight: skipPreflight)
                             guard sig == signed.id else { throw WalletError.badResponse("the node returned a different signature") }
                             if let spent, spent > 0, !c.isTestnet { svc.spendLimit.record(usd: spent) }
                             box.set(sig)
                             Task { @MainActor in
                                 _ = try? await client.waitForConfirmation(sig)
                                 await svc.refreshBalances(chains: [c])
                             }
                             return sig
                         })
        _ = try await ask(a, origin)
        guard let out = box.value else { throw DappRPCError.rejected }
        return out
    }
}
