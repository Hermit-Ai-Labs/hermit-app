import Foundation
import HermitCore
import HermitWallet

/// The money tools beyond the trained set: batch sends, Aave deposits and withdrawals, and the network choice a send
/// makes when the user didn't name one. Like the others they only prepare; the user approves with Face ID.
extension HermitToolbox {
    enum ChainPick { case chain(Chain), ask(ToolOutcome) }

    /// The wallet chat's money tools act for: the one selected in Wallets, which get_balances and prepare_swap read too,
    /// else the first.
    @MainActor static var agentWallet: WalletAccount? {
        let vm = WalletsViewModel.shared
        return vm.service.selected.flatMap { s in vm.wallets.first { $0.record.id == s.id } } ?? vm.wallets.first
    }

    /// The chain a money tool runs on. A chain the user named wins; otherwise the only candidate, or the only one where
    /// the user holds the token; otherwise a question back to the user, listing where they hold it.
    @MainActor static func pickChain(_ given: String?, symbol: String, candidates: [Chain], doing: String) async throws -> ChainPick {
        let vm = WalletsViewModel.shared
        if !vm.loaded { await vm.refresh() }
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        func holding(_ c: Chain) -> Holding? { vm.holdings(wallet: w.id, chain: c).first { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame } }
        if let g = given?.trimmingCharacters(in: .whitespaces), !g.isEmpty {
            guard let c = findChain(g) else { throw ToolError("Unknown chain \(g)") }
            // A named network where the user holds none of the token, while they hold it on exactly one other: ask, never
            // switch silently (the model tends to say "Ethereum" when nobody did). Not when that network's balance is unknown.
            if holding(c) == nil, candidates.contains(c), !vm.unreachable.contains(c) {
                let elsewhere = candidates.filter { $0 != c && holding($0) != nil }
                if elsewhere.count == 1, let o = elsewhere.first {
                    let sym = symbol.uppercased()
                    return .ask(json(["status": "needs_chain", "prepared": false, "question": "You hold \(sym) on \(o.name), not \(c.name). Use \(o.name)?",
                                      "options": [o.id, c.id],
                                      "note": "Nothing was prepared. Ask the user, in one short question. They hold no \(sym) on \(c.name), so a \(doing) there would fail."]))
                }
            }
            return .chain(c)
        }
        guard !candidates.isEmpty else { throw ToolError("\(symbol.uppercased()) can't be used for that on any network Hermit supports") }
        if candidates.count == 1 { return .chain(candidates[0]) }
        let held: [(Chain, Holding)] = candidates.compactMap { c in holding(c).map { (c, $0) } }
        if held.count == 1 { return .chain(held[0].0) }
        let sym = symbol.uppercased()
        let question = held.isEmpty
            ? "You don't hold \(sym) on \(names(candidates)) yet. Which network should the \(doing) use?"
            : "Which network should the \(doing) use? You hold \(sym) on " + names(held.map(\.0)) + " ("
                + held.map { "\($0.0.name): \(Units.approx($0.1.exact))" }.joined(separator: ", ") + ")."
        return .ask(json(["status": "needs_chain", "prepared": false, "question": question, "options": (held.isEmpty ? candidates : held.map(\.0)).map(\.id),
                          "note": "Nothing was prepared. Ask the user which network, in one short question."]))
    }

    static func names(_ cs: [Chain]) -> String {
        let n = cs.map(\.name)
        return n.count <= 1 ? (n.first ?? "") : n.dropLast().joined(separator: ", ") + " or " + n.last!
    }

    /// Networks a send of `symbol` to `to` could mean: the address format picks the family, the token must exist there.
    static func sendChains(symbol: String, to: String) -> [Chain] {
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ChainKind?
        if t.hasPrefix("0x") || t.hasPrefix("0X") || t.lowercased().hasSuffix(".eth") { kind = .evm }
        else if t.lowercased().hasSuffix(".near") || t.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil { kind = .near }
        else if SolanaPublicKey(t) != nil { kind = .solana }
        else { kind = nil }
        return Chain.mainnets.filter { c in (kind == nil || c.kind == kind) && hasToken(symbol, on: c) }
    }

    static func hasToken(_ symbol: String, on c: Chain) -> Bool {
        c.nativeSymbol.caseInsensitiveCompare(symbol) == .orderedSame || c.token(symbol) != nil
    }

    // MARK: Batch send

    /// prepare_multisend: checks every recipient and opens the Batch send review (one Face ID for all of it).
    /// `origin` is .agent when the model asked; .user when the app read the user's own attached list.
    /// `fromPicture`: the chat holds text read from a picture, so rows without an EIP-55 checksum are refused.
    @MainActor static func prepareMultisend(_ a: [String: Any], origin: ActionOrigin, source: String? = nil, fromPicture: Bool = false) async throws -> ToolOutcome {
        guard let symbol = (a["symbol"] as? String)?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty else { throw ToolError("Needs symbol and recipients") }
        let rows: [(address: String, amount: String)] = ((a["recipients"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map { r in
            ((r["address"] as? String) ?? "", (r["amount"] as? NSNumber)?.stringValue ?? (r["amount"] as? String) ?? "")
        }
        guard !rows.isEmpty else { throw ToolError("Needs at least one recipient with an address and an amount") }
        let vm = WalletsViewModel.shared
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        let candidates = Chain.mainnets.filter { WalletService.batchSupported($0) && hasToken(symbol, on: $0) }
        let chain: Chain
        switch try await pickChain(a["chain"] as? String, symbol: symbol, candidates: candidates, doing: "batch send") {
        case .chain(let c): chain = c
        case .ask(let out): return out
        }
        // Whitelist only covers the assistant's batches as it covers its single sends: one payee it stops stops the list.
        for r in rows {
            if let block = vm.whitelistBlock(r.address.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return json(["status": "blocked", "prepared": false, "reasons": [block], "note": "Nothing was prepared. Tell the user why."])
            }
        }
        let plan: BatchPlan
        do {
            plan = try await vm.service.planBatch(walletID: w.record.id, chain: chain, symbol: symbol, recipients: rows, origin: origin, source: source, fromPicture: fromPicture)
        } catch {
            return json(["status": "blocked", "prepared": false, "reasons": [message(error)],
                         "note": "Nothing was prepared. Tell the user why."])
        }
        let leftOut = plan.invalid.prefix(6).map { "row \($0.line): \($0.problem ?? "invalid")" }
        var out: [String: Any] = ["kind": "multisend", "executed": false, "network": chain.name, "recipients": plan.valid.count,
                                  "total": "\(plan.total) \(plan.symbol)", "fees_up_to": plan.feeText]
        if vm.wallets.count > 1 { out["wallet"] = w.name }
        if !leftOut.isEmpty { out["left_out"] = leftOut; out["left_out_count"] = plan.invalid.count }
        guard plan.blocks.isEmpty else {
            out["status"] = "blocked"; out["reasons"] = plan.blocks
            out["note"] = "Nothing was prepared. Tell the user why."
            return json(out)
        }
        BatchStore.shared.add(plan)
        out["status"] = "review_opened"
        if !plan.warnings.isEmpty { out["warnings"] = plan.warnings }
        out["note"] = "Nothing has moved. The Batch send review lists every recipient; the user approves all of it with one \(Device.bio), or cancels."
        var o = json(out)
        o.action = Action("Review batch send", primary: true, symbol: "list.bullet.rectangle", open: "batch:\(plan.id)")
        return o
    }

    // MARK: Aave

    /// Networks where Hermit can deposit `symbol` into Aave v3.
    static func aaveChains(_ symbol: String) -> [Chain] {
        Chain.mainnets.filter { c in AaveV3.tokens(on: c).contains { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame } }
    }

    /// prepare_deposit: checks the request against the spending policy and the balance, then the Deposit review opens
    /// prefilled (EarnDepositSheet: allowance, approve + supply, each simulated and signed with Face ID).
    @MainActor static func prepareDeposit(_ a: [String: Any]) async throws -> ToolOutcome {
        let project = ((a["project"] as? String) ?? (a["pool"] as? String) ?? "aave-v3").lowercased()
        guard project.isEmpty || project.contains("aave") else {
            return json(["status": "unsupported", "prepared": false,
                         "note": "Hermit can only deposit into Aave v3 (Ethereum, Base, Arbitrum) from chat for now. Other pools are in Earn, DeFi, with Ask."])
        }
        guard let symbol = (a["symbol"] as? String)?.uppercased(), !symbol.isEmpty,
              let amount = (a["amount"] as? NSNumber)?.doubleValue ?? (a["amount"] as? String).flatMap(Double.init), amount > 0 else {
            throw ToolError("Needs symbol and a positive amount")
        }
        let chain: Chain
        switch try await pickChain(a["chain"] as? String, symbol: symbol, candidates: aaveChains(symbol), doing: "deposit") {
        case .chain(let c): chain = c
        case .ask(let out): return out
        }
        guard let token = AaveV3.tokens(on: chain).first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) else {
            return json(["status": "unsupported", "prepared": false, "note": "Hermit can't deposit \(symbol) into Aave on \(chain.name). It can: "
                         + Chain.mainnets.flatMap { c in AaveV3.tokens(on: c).map { "\($0.symbol) on \(c.name)" } }.joined(separator: ", ") + "."])
        }
        let vm = WalletsViewModel.shared
        guard let w = agentWallet else { throw ToolError("No wallet on \(Device.here) yet") }
        if !vm.loaded { await vm.refresh() }
        let held = vm.holding(token.symbol, wallet: w.id, chain: chain)?.amount ?? 0
        guard held >= amount else {
            return json(["status": "insufficient", "prepared": false, "holding": "\(Units.approx(held)) \(token.symbol) on \(chain.name)",
                         "note": "Nothing was prepared: the deposit needs \(Units.approx(amount)) \(token.symbol) on \(chain.name). Tell the user."])
        }
        let usd: Double? = TokenTable.stableSymbols.contains(token.symbol) ? amount : nil
        let verdict = vm.service.policy.evaluate(usd: usd, payee: nil, origin: .agent)
        if verdict.decision == .block {
            return json(["status": "blocked", "reasons": verdict.blocks, "note": "Nothing was prepared. Tell the user why."])
        }
        let pool = await EarnFlow.pool(chain: chain, symbol: token.symbol)
        var out: [String: Any] = ["status": "review_opened", "kind": "deposit", "executed": false, "pool": "Aave v3 on \(chain.name)",
                                  "amount": "\(Units.approx(amount)) \(token.symbol)",
                                  "note": "Waiting for the user to review the deposit and approve it with \(Device.bio)."]
        if let p = pool { out["apy_pct"] = (p.depositAPY * 100).rounded() / 100 }
        if vm.wallets.count > 1 { out["wallet"] = w.name }
        var o = json(out)
        o.action = Action("Review deposit", primary: true, symbol: "leaf", open: EarnFlow.depositLink(chain: chain, symbol: token.symbol, amount: amount))
        return o
    }

    /// prepare_withdraw: finds the user's Aave supply and prepares the withdrawal (all of it, or `amount`).
    @MainActor static func prepareWithdraw(_ a: [String: Any], label: String) async throws -> ToolOutcome {
        guard let symbol = (a["symbol"] as? String)?.uppercased(), !symbol.isEmpty else { throw ToolError("Needs symbol") }
        let amount = (a["amount"] as? NSNumber)?.doubleValue ?? (a["amount"] as? String).flatMap(Double.init)
        let vm = WalletsViewModel.shared
        guard !vm.wallets.isEmpty else { throw ToolError("No wallet on \(Device.here) yet") }
        let given = (a["chain"] as? String).flatMap { $0.isEmpty ? nil : findChain($0) }
        let (all, failed) = await vm.service.aavePositions(wallets: vm.wallets.map(\.record))
        let mine = all.filter { $0.token.symbol.caseInsensitiveCompare(symbol) == .orderedSame && (given == nil || $0.chain == given) }
        guard !mine.isEmpty else {
            var o: [String: Any] = ["status": "nothing_to_withdraw", "prepared": false,
                                    "note": "The user has no \(symbol) in Aave\(given.map { " on \($0.name)" } ?? ""). Tell them."]
            if !failed.isEmpty { o["unreachable"] = failed.map(\.id) }
            return json(o)
        }
        guard mine.count == 1 else {
            return json(["status": "needs_choice", "prepared": false,
                         "question": "Which deposit? " + mine.map { p in "\(p.text) \(p.token.symbol) on \(p.chain.name)" + (vm.wallets.count > 1 ? " (\(vm.wallet(p.walletID.uuidString)?.name ?? "wallet"))" : "") }.joined(separator: ", ") + ".",
                         "note": "Nothing was prepared. Ask the user which one."])
        }
        let p = mine[0]
        var value: UInt128? = nil
        if let amount {
            guard let v = try? Units.parse(String(format: "%.\(min(p.token.decimals, 6))f", amount), decimals: p.token.decimals), v > 0 else { throw ToolError("Not a valid amount") }
            guard v <= p.amount else {
                return json(["status": "insufficient", "prepared": false, "supplied": "\(p.text) \(p.token.symbol)",
                             "note": "Only \(p.text) \(p.token.symbol) is in Aave on \(p.chain.name). Tell the user."])
            }
            value = v
        }
        let approval = try withdrawApproval(p, amount: value, label: label)
        return ToolOutcome(content: prepared("withdraw"), action: Action("Review withdrawal", approval: approval))
    }

    /// The approval for an Aave withdrawal; Approve signs it on this device (Face ID) and waits for the block.
    @MainActor static func withdrawApproval(_ p: AavePosition, amount: UInt128?, label: String? = nil) throws -> Approval {
        let vm = WalletsViewModel.shared
        let call = try vm.service.aaveWithdrawCall(walletID: p.walletID, chain: p.chain, token: p.token, amount: amount)
        let text = amount.map { Units.format($0, decimals: p.token.decimals) } ?? p.text
        let svc = vm.service, wid = p.walletID, chain = p.chain
        var lines: [[String]] = [["From", "Aave v3, \(p.chain.name)"], ["Amount", amount == nil ? "All, about \(p.text) \(p.token.symbol)" : "\(text) \(p.token.symbol)"],
                                 ["To", vm.wallet(p.walletID.uuidString)?.name ?? "Your wallet"]]
        if let r = p.supplyAPY { lines.append(["Earning now", String(format: "%.2f%% APY", r * 100)]) }
        if let label { lines.append(["Asked for by", "\(label), from your message"]) }
        return Approval(kind: "Withdraw on \(p.chain.name)", title: "Withdraw \(amount == nil ? "all" : text) \(p.token.symbol) from Aave",
                        lines: lines, checks: ["Back to your own wallet", "Simulated before it's signed", "Signed on \(Device.here) with your wallet's key"],
                        success: "Withdrew \(p.token.symbol) from Aave") {
            let h = try await svc.executeCalls(walletID: wid, chain: chain, [call]).last ?? ""
            Task { @MainActor in await WalletsViewModel.shared.refresh() }
            return h
        }
    }
}
