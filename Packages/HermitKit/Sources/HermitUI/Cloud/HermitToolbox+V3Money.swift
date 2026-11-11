import Foundation
import HermitCore
import HermitWallet

// The v3 money tools: buy and sell a Solana token through Jupiter, close a Hyperliquid position, and put a take
// profit or a stop loss on one. Each only prepares: it returns a button whose tap opens the usual approval sheet, and
// the move happens there, signed after Face ID or Touch ID. All four are in ToolGuard.moneyTools.
//
// Buying and selling follow the same steps as the Spot screen (TradeBuy.buyOnSolana and sellOnSolana): Jupiter's quote,
// the spending policy, the price-impact limits, the same review lines, the same test run and signing, the same
// records afterwards (daily limit, Activity, the cost book). What differs is where the answer goes: back to the model
// as a result instead of a toast, and any percent or amount for a sale, not only 25, 50 and 100.

extension HermitToolbox {
    // MARK: prepare_buy

    /// prepare_buy: a Solana token for USDC or SOL. `symbol` is a ticker (a token on Jupiter's verified list) or a mint
    /// (ToolGuard has checked it is the user's own or from a search of this chat): a mint may be unverified, and then
    /// Jupiter's audit decides. Too little liquidity or an unverified token its creator can freeze is refused; anything
    /// else unverified goes to the review with its warnings.
    @MainActor static func prepareBuy(_ a: [String: Any], label: String) async throws -> ToolOutcome {
        let asked = JupiterTokens.plain(ToolsV3.text(a, "symbol"))
        guard !asked.isEmpty, let usd = ToolsV3.number(a, "amount_usd"), usd.isFinite, usd > 0 else { throw ToolError("Needs symbol and a positive amount_usd") }
        let vm = WalletsViewModel.shared
        guard let w = agentWallet, !w.record.solanaAddress.isEmpty else { throw ToolError("No wallet on \(Device.here) to buy with") }
        if ["SOL", "USDC"].contains(asked.uppercased()) || asked == Jupiter.solMint || asked == Jupiter.usdcMint {
            throw ToolError("\(asked.count > 8 ? "That token" : asked.uppercased()) isn't bought here. Swap into it instead.")
        }

        // Which token.
        let token: Jupiter.Token
        let check: TokenCheck?
        if JupiterTokens.looksLikeMint(asked) {
            let found: [JupiterTokens.Found]
            do { found = try await JupiterTokens.search(asked) } catch {
                throw ToolError("Token search is unavailable right now, so Hermit can't check that mint. Try again in a moment.")
            }
            guard let f = found.first(where: { $0.id == asked }) else { throw ToolError("Jupiter doesn't know a token with that mint.") }
            guard let c = f.check ?? f.row?.check else { throw ToolError("Hermit couldn't check \(f.symbol), so it won't buy it.") }
            if let why = c.refusal { return json(ToolsV3.blocked([why])) }
            token = Jupiter.Token(mint: f.id, symbol: f.symbol, name: f.name, decimals: f.decimals, verified: f.verified)
            check = c
        } else {
            let store = JupiterTokens.shared
            if store.rows.isEmpty { await store.refresh(force: true) }
            guard !store.rows.isEmpty else { throw ToolError("Jupiter's token list is unavailable right now. Try again in a moment.") }
            switch ToolsV3.pickVerified(asked, rows: store.rows) {
            case .none:
                return json(ToolsV3.blocked([Jupiter.Error.notVerified(asked.uppercased()).errorDescription ?? "There's no verified \(asked.uppercased()) token on Solana."]))
            case .clash(let rows):
                return json(ToolsV3.buyChoice(asked.uppercased(), rows))
            case .token(let r):
                token = r.token
                check = nil
            }
        }

        // What pays: what the user said, else USDC when it covers the amount, else SOL.
        if !vm.loaded { await vm.refresh() }
        let usdcHeld = vm.balance(of: "USDC", wallet: w.id, chain: .solana), solHeld = vm.balance(of: "SOL", wallet: w.id, chain: .solana)
        let payWith = ToolsV3.text(a, "pay_with").uppercased()
        guard payWith.isEmpty || payWith == "USDC" || payWith == "SOL" else { throw ToolError("pay_with is USDC or SOL") }
        let solPrice = TradeBuy.solPrice()
        let solNeeded = solPrice.map { usd / $0 }
        let canUSDC = usdcHeld >= usd && solHeld >= TradeBuy.solForFees
        let canSOL = solNeeded.map { $0 <= solHeld - TradeBuy.solReserve } ?? false
        let insufficient: [String: Any] = ["status": "insufficient", "prepared": false,
                                           "holding": "\(Units.approx(usdcHeld)) USDC and \(Units.approx(solHeld)) SOL on Solana",
                                           "note": "The user holds less than that. Tell them."]
        let needsFeeSOL = ToolsV3.blocked(["Add a little SOL on Solana first. It pays the network fee."])
        let payUSDC: Bool
        switch payWith {
        case "USDC":
            guard usdcHeld >= usd else { return json(insufficient) }
            guard solHeld >= TradeBuy.solForFees else { return json(needsFeeSOL) }
            payUSDC = true
        case "SOL":
            guard solPrice != nil else { throw ToolError("Couldn't get SOL's price, so Hermit can't check your daily limit. Try again in a moment.") }
            guard canSOL else { return json(insufficient) }
            payUSDC = false
        default:
            if canUSDC { payUSDC = true }
            else if canSOL { payUSDC = false }
            else if usdcHeld >= usd { return json(needsFeeSOL) }
            else { return json(insufficient) }
        }
        let pay: Jupiter.Token = payUSDC ? Jupiter.usdc : Jupiter.sol
        guard let base = TradeAmount.baseUnits(payUSDC ? usd : (solNeeded ?? 0), decimals: pay.decimals) else { throw ToolError("That amount is too small to buy with") }
        // The daily limit and the assistant's cap count the dollars leaving the wallet.
        let usdValue = usd

        // Jupiter's quote, the policy (as the assistant), the impact limits.
        let q: Jupiter.Quote
        do { q = try await Jupiter.quote(from: pay, to: token, amount: base) } catch Jupiter.Error.bad(_) {
            return json(["error": "No route to buy that token right now."])
        }
        let verdict = vm.service.policy.evaluate(usd: usdValue, payee: nil, origin: .agent)
        if verdict.decision == .block { return json(ToolsV3.blocked(verdict.blocks)) }
        let impact = q.shownImpactPercent
        if impact > TradeBuy.maxImpact {
            return json(ToolsV3.blocked(["Price impact is \(String(format: "%.1f", impact))%, so Hermit won't send it. Try a smaller amount."]))
        }
        let impactWarning = impact > TradeBuy.warnImpact ? ["Price impact is \(String(format: "%.1f", impact))%. You get noticeably less than the market price."] : []
        // An unverified token: the strongest line first on the sheet, with the whole mint to check against.
        let strong: [String] = token.verified ? [] : ["\(token.symbol) is NOT on Jupiter's verified list. Anyone can make a token with this name. Check its full mint is the one you mean: \(token.mint)"]
        let audit: [String] = check?.warnings.filter { !$0.hasPrefix("Not on Jupiter's verified list") } ?? []

        let svc = vm.service, limit = vm.service.spendLimit, wid = w.record.id, walletKey = w.id, sym = token.symbol
        let owner = w.record.solanaAddress, mintID = token.mint, decimals = token.decimals, quoted = q.outAmount, paySym = pay.symbol
        let route = "Jupiter" + (q.route.isEmpty ? "" : " via " + q.route.prefix(2).joined(separator: ", "))
        let lines: [[String]] = [["You pay", "\(q.inFormatted) \(pay.symbol) on Solana"], ["You get, about", "\(q.outFormatted) \(token.symbol)"],
                                 ["Price impact", String(format: "%.2f%%", impact)], ["Slippage", "up to \(Double(q.slippageBps) / 100)%"],
                                 ["Route", route], ["Token", token.name + (token.verified ? ", verified on Jupiter" : ", not verified")],
                                 ["Mint", ToolsV3.shortMint(token.mint)], ["Asked for by", "\(label), from your message"]]
        let got = Double(q.outFormatted) ?? 0, paidShown = Double(q.inFormatted) ?? 0
        let what = "Bought about \(MoneyFmt.amount(got)) \(sym) with \(MoneyFmt.amount(paidShown)) \(pay.symbol)"
        let approval = Approval(kind: "Buy", title: "Buy \(token.symbol)", lines: lines,
                                checks: (token.verified ? ["Token is on Jupiter's verified list"] : [])
                                    + ["Hermit tests Jupiter's transaction on Solana before it's signed",
                                       "Signed on \(Device.here) with your wallet's key"] + verdict.passed,
                                success: "Bought \(token.symbol)", warnings: strong + audit + verdict.warnings + impactWarning) {
            // The balance before, so what actually arrived can be measured (for the cost book) once it's confirmed.
            let before = await SolanaHoldings.balance(owner: owner, mint: mintID)
            let sig: String
            do { sig = try await svc.executeJupiter(q, walletID: wid) } catch WalletError.pending(let h, let explorer) {
                // Sent but not confirmed in time: it may still land, so it counts toward the daily limit and is listed
                // as pending before the error tells the user not to buy again.
                limit.record(usd: Decimal(usdValue))
                await MainActor.run {
                    ActivityLedger.shared.record(ActivityItem(id: h, kind: .swap, chainID: "solana", walletID: walletKey, what: what, detail: "Jupiter",
                                                              amount: got, symbol: sym, date: Date(), tx: h, status: "Pending",
                                                              link: Chain.solana.explorerURL(tx: h)))
                }
                throw WalletError.pending(hash: h, explorer: explorer)
            }
            limit.record(usd: Decimal(usdValue))
            await MainActor.run {
                ActivityLedger.shared.record(ActivityItem(id: sig, kind: .swap, chainID: "solana", walletID: walletKey, what: what, detail: "Jupiter",
                                                          amount: got, symbol: sym, date: Date(), tx: sig, status: "Confirmed",
                                                          link: Chain.solana.explorerURL(tx: sig)))
            }
            // Into the cost book with what arrived (the quote's amount if it can't be read). Off the sheet's path, so
            // the review reports back at once.
            Task {
                let received = await SolanaHoldings.received(owner: owner, mint: mintID, before: before) ?? UInt128(quoted)
                let n = Double(Units.format(received, decimals: decimals)) ?? got
                await MainActor.run {
                    SolanaHoldings.shared.finished(
                        SpotTrade(walletID: walletKey, mint: mintID, symbol: sym, tokens: String(received), decimals: decimals,
                                  usd: usdValue, sell: false, date: Date(), tx: sig),
                        done: SolanaHoldings.Done(mint: mintID, symbol: sym, got: n, gotSymbol: sym, sell: false,
                                                  detail: "≈ \(MoneyFmt.usd(usdValue, digits: 2)) in \(paySym)"))
                }
            }
            return sig
        }

        var out: [String: Any] = ["status": "review_opened", "kind": "buy", "executed": false, "symbol": token.symbol,
                                  "you_pay": "\(ToolsV3.amount(paidShown)) \(pay.symbol) on Solana", "you_get": "about \(ToolsV3.amount(got)) \(token.symbol)",
                                  "price_impact_pct": ToolsV3.r2(impact), "slippage_pct": Double(q.slippageBps) / 100, "route": route,
                                  "note": "Nothing has moved. The Buy review is open with this Jupiter quote; the user approves it with \(Device.bio) or cancels."]
        if !token.verified { out["verified"] = false }
        let warnings = (check?.warnings ?? []) + verdict.warnings + impactWarning
        if !warnings.isEmpty { out["warnings"] = warnings }
        if vm.wallets.count > 1 { out["wallet"] = w.name }
        var o = json(out)
        o.action = Action("Review buy", approval: approval)
        return o
    }

    // MARK: prepare_sell

    /// prepare_sell: any share (1 to 100 percent) or any amount of a Solana token the selected wallet holds, for USDC or
    /// SOL. Unverified tokens can be sold; a frozen balance can't. A sale lowers risk, so it is checked against the
    /// daily limit like the user's own sale and not against the assistant's per-move cap. It is still a review.
    @MainActor static func prepareSell(_ a: [String: Any], label: String) async throws -> ToolOutcome {
        let vm = WalletsViewModel.shared
        guard let w = agentWallet, !w.record.solanaAddress.isEmpty else { throw ToolError("No wallet on \(Device.here) to sell with") }
        let asked = ToolsV3.text(a, "token")
        // SOL and USDC stay with the swap tool (ToolsV3.sellRefusal says why).
        if let no = ToolsV3.sellRefusal(asked) { throw ToolError(no) }
        let receive = ToolsV3.text(a, "receive").uppercased()
        guard receive.isEmpty || receive == "USDC" || receive == "SOL" else { throw ToolError("receive is USDC or SOL") }
        let (items, failed) = await spotHoldings(w)
        if failed && items.isEmpty { throw ToolError("Couldn't read your Solana tokens right now. Try again in a moment.") }

        let h: SolanaHoldings.Holding, base: UInt64, part: String
        switch ToolsV3.sellPlan(token: asked, percent: ToolsV3.has(a, "percent") ? (ToolsV3.number(a, "percent") ?? .nan) : nil,
                                amountText: ToolsV3.decimalText(a, "amount"), hasAmount: ToolsV3.has(a, "amount"), holdings: items) {
        case .error(let e): throw ToolError(e)
        case .notHeld(let name):
            return json(["status": "not_held", "prepared": false, "note": "The user holds no \(name) on Solana. Tell them."])
        case .choose(let hs):
            return json(ToolsV3.sellChoice(hs))
        case .frozen(let f):
            return json(ToolsV3.blocked(["Your \(f.symbol) balance is frozen by the token's authority, so it can't be sold."]))
        case .insufficient(let f):
            return json(["status": "insufficient", "prepared": false, "holding": "\(Units.approx(f.tokens)) \(f.symbol)",
                         "note": "The user holds less than that. Tell them."])
        case .sell(let holding, let units, let share):
            h = holding; base = units; part = share
        }

        // USDC itself sells for SOL. The fee, and rent for a new USDC account, come out of SOL.
        let out: Jupiter.Token = ToolsV3.sellOutput(mint: h.id, receive: receive)
        if !vm.loaded { await vm.refresh() }
        guard vm.balance(of: "SOL", wallet: w.id, chain: .solana) >= TradeBuy.solReserve else {
            return json(ToolsV3.blocked(["Keep about \(TradeAmount.text(TradeBuy.solReserve, maxFraction: 2)) SOL on Solana for fees. Add a little first."]))
        }
        let token = h.token
        let q: Jupiter.Quote
        do { q = try await Jupiter.quote(from: token, to: out, amount: base) } catch Jupiter.Error.bad(_) {
            return json(["error": "No route to sell that token right now."])
        }
        let gets = Double(q.outFormatted) ?? 0, sold = Double(q.inFormatted) ?? 0
        // The daily limit needs a dollar value: USDC as is, SOL at its price.
        let priced: Double? = out.mint == Jupiter.usdcMint ? gets : TradeBuy.solPrice().map { gets * $0 }
        guard let usdValue = priced else { throw ToolError("Couldn't get SOL's price, so Hermit can't check your daily limit. Try again in a moment.") }
        // A dollar stablecoin sold for SOL adds risk instead of lowering it, so that one is held to the assistant's
        // per-move cap like a swap. Every other sale is checked against the daily limit only.
        let soldIsStable = JupiterTokens.shared.rows.first { $0.id == h.id }?.isStable ?? false
        let verdict = vm.service.policy.evaluate(usd: usdValue, payee: nil, origin: ToolsV3.sellOrigin(outMint: out.mint, soldIsStable: soldIsStable))
        if verdict.decision == .block { return json(ToolsV3.blocked(verdict.blocks)) }
        let impact = q.shownImpactPercent
        if impact > TradeBuy.maxImpact {
            return json(ToolsV3.blocked(["Price impact is \(String(format: "%.1f", impact))%, so Hermit won't send it. Try selling less."]))
        }
        // The sheet warns from 5% like the Spot screen; the model is told from 3%, so it can say so earlier.
        let sheetImpact = impact > TradeBuy.warnImpact ? ["Price impact is \(String(format: "%.1f", impact))%. You get noticeably less than the market price."] : []
        let toldImpact = impact >= 3 ? ["Price impact is \(String(format: "%.1f", impact))%, so you get less than the market price."] : []
        let unverified: [String] = token.verified ? [] : ["\(token.symbol) isn't on Jupiter's verified list. Mint \(token.mint)."]

        let svc = vm.service, limit = vm.service.spendLimit, wid = w.record.id, walletKey = w.id, sym = token.symbol, outSym = out.symbol
        let mintID = token.mint, decimals = token.decimals
        let route = "Jupiter" + (q.route.isEmpty ? "" : " via " + q.route.prefix(2).joined(separator: ", "))
        let lines: [[String]] = [["You sell", "\(q.inFormatted) \(sym)" + (part.isEmpty ? "" : " (\(part))")], ["You get, about", "\(q.outFormatted) \(outSym) on Solana"],
                                 ["Price impact", String(format: "%.2f%%", impact)], ["Slippage", "up to \(Double(q.slippageBps) / 100)%"],
                                 ["Route", route], ["Token", token.name + (token.verified ? ", verified on Jupiter" : ", not verified")],
                                 ["Mint", ToolsV3.shortMint(token.mint)], ["Asked for by", "\(label), from your message"]]
        let what = "Sold \(MoneyFmt.amount(sold)) \(sym) for about \(MoneyFmt.amount(gets)) \(outSym)"
        let approval = Approval(kind: "Sell", title: "Sell \(sym)", lines: lines,
                                checks: (token.verified ? ["Token is on Jupiter's verified list"] : [])
                                    + ["Hermit tests Jupiter's transaction on Solana before it's signed",
                                       "Signed on \(Device.here) with your wallet's key"] + verdict.passed,
                                success: "Sold \(sym)", warnings: unverified + verdict.warnings + sheetImpact) {
            let sig: String
            do { sig = try await svc.executeJupiter(q, walletID: wid) } catch WalletError.pending(let hash, let explorer) {
                // Sent but not confirmed in time: listed as pending, and it counts toward the daily limit, like a buy.
                limit.record(usd: Decimal(usdValue))
                await MainActor.run {
                    ActivityLedger.shared.record(ActivityItem(id: hash, kind: .swap, chainID: "solana", walletID: walletKey, what: what, detail: "Jupiter",
                                                              amount: gets, symbol: outSym, date: Date(), tx: hash, status: "Pending",
                                                              link: Chain.solana.explorerURL(tx: hash)))
                }
                throw WalletError.pending(hash: hash, explorer: explorer)
            }
            limit.record(usd: Decimal(usdValue))
            await MainActor.run {
                ActivityLedger.shared.record(ActivityItem(id: sig, kind: .swap, chainID: "solana", walletID: walletKey, what: what, detail: "Jupiter",
                                                          amount: gets, symbol: outSym, date: Date(), tx: sig, status: "Confirmed",
                                                          link: Chain.solana.explorerURL(tx: sig)))
                // The input is exact, so the book takes away exactly what was sold.
                SolanaHoldings.shared.finished(
                    SpotTrade(walletID: walletKey, mint: mintID, symbol: sym, tokens: String(base), decimals: decimals,
                              usd: usdValue, sell: true, date: Date(), tx: sig),
                    done: SolanaHoldings.Done(mint: mintID, symbol: sym, got: gets, gotSymbol: outSym, sell: true,
                                              detail: "Sold \(MoneyFmt.amount(sold)) \(sym)"))
            }
            return sig
        }

        var result: [String: Any] = ["status": "review_opened", "kind": "sell", "executed": false, "symbol": sym,
                                     "you_sell": "\(ToolsV3.amount(sold)) \(sym)" + (part.isEmpty ? "" : " (\(part))"),
                                     "you_get": "about \(ToolsV3.amount(gets)) \(outSym) on Solana",
                                     "price_impact_pct": ToolsV3.r2(impact), "slippage_pct": Double(q.slippageBps) / 100, "route": route,
                                     "note": "Nothing has moved. The Sell review is open with this Jupiter quote; the user approves it with \(Device.bio) or cancels."]
        let warnings = toldImpact + verdict.warnings
        if !warnings.isEmpty { result["policy"] = "warn"; result["warnings"] = warnings }
        if vm.wallets.count > 1 { result["wallet"] = w.name }
        var o = json(result)
        o.action = Action("Review sale", approval: approval)
        return o
    }

    // MARK: prepare_close

    /// prepare_close: all of an open Hyperliquid position, or a percent of it, at market and reduce only. The position
    /// and the price are read fresh, as PerpActions.close does for the Close buttons; this builds the same order and the
    /// same review for chat. Closing lowers risk, so no spending cap applies. It is still a review.
    @MainActor static func prepareClose(_ a: [String: Any], label: String) async throws -> ToolOutcome {
        let coinIn = ToolsV3.text(a, "coin")
        guard !coinIn.isEmpty else { throw ToolError("Needs coin") }
        let percent = ToolsV3.has(a, "percent") ? (ToolsV3.number(a, "percent") ?? .nan) : 100
        guard percent > 0, percent <= 100 else { throw ToolError("percent must be between 1 and 100") }
        let hl = HyperliquidStore.shared
        guard hl.hasWallet, let trader = hl.trader() else { throw ToolError("No wallet on \(Device.here) to trade with") }
        guard await hl.poll(), let account = hl.account else { throw ToolError("Couldn't read the Hyperliquid account") }
        // The same ticker open on two venues: never pick one for the user.
        let clash = ToolsV3.positionClash(coinIn, in: account.positions)
        if !clash.isEmpty { throw ToolError("The user has more than one \(PerpFmt.sym(coinIn).uppercased()) position (\(clash.joined(separator: ", "))). Ask which one, and pass its full name as coin.") }
        guard let cur = ToolsV3.position(coinIn, in: account.positions) else {
            return json(["status": "no_position", "prepared": false,
                         "note": "The user has no open \(PerpFmt.sym(coinIn).uppercased()) position on Hyperliquid. Tell them."])
        }
        let sym = cur.sym
        guard let asset = await hl.asset(cur.coin) else { throw ToolError("\(sym) isn't tradable on Hyperliquid right now.") }
        // A fresh mark, else the one Hyperliquid just valued the position at.
        let live = (try? await Self.market(cur.coin, maxAge: 0))?.mark ?? 0
        let mid: Double = live > 0 ? live : (cur.markPx ?? 0)
        guard mid > 0 else { throw ToolError("No price for \(sym) right now. Try again in a moment.") }
        let full = percent >= 100
        let size = full ? cur.coins : Hyperliquid.roundSize(cur.coins * percent / 100, szDecimals: asset.szDecimals)
        let share = Hyperliquid.wire(percent)
        guard size > 0 else { throw ToolError("\(share)% is smaller than the smallest \(sym) order. Close more of it.") }
        if !full && size * mid < 10 {
            throw ToolError("\(share)% is about $\(String(format: "%.2f", size * mid)), and Hyperliquid's smallest order is $10. Close more of it.")
        }
        let isBuy = cur.size < 0
        let limit = Hyperliquid.marketPrice(mid: mid, isBuy: isBuy, asset: asset)
        let order = Hyperliquid.Order(asset: asset, isBuy: isBuy, price: limit, size: size, reduceOnly: true, tif: .ioc)
        let side = cur.isLong ? "long" : "short"
        let amountText = "\(Hyperliquid.wire(size)) \(sym)"
        let partPnl = cur.pnl * size / cur.coins
        var lines: [[String]] = [
            ["Position", "\(sym) \(side) \(cur.leverage)x on \(PerpFmt.venue(cur.coin))"],
            ["Close", full ? "All of it, \(amountText)" : "\(share)%, \(amountText)"],
            ["Worth about", "$" + String(format: "%.2f", size * mid)],
            [full ? "Unrealized P&L" : "P&L on this part", PerpFmt.pnl(partPnl)],
            ["Order", "Market, reduce only"],
            ["Worst price", "$" + Hyperliquid.wire(limit)],
        ]
        if !full { lines.append(["Left open", "\(Hyperliquid.wire(max(0, cur.coins - size))) \(sym)"]) }
        lines.append(["Asked for by", "\(label), from your message"])
        let approval = Approval(kind: "Hyperliquid order", title: full ? "Close \(sym) \(side)" : "Close \(share)% of \(sym) \(side)",
                                lines: lines, checks: ["Reduce only: it can't open a new position", "Signed on \(Device.here) with your wallet's key"],
                                success: full ? "\(sym) closed" : "Closed \(share)% of \(sym)") {
            let summary = try await trader.place(order, leverage: nil).summary
            await MainActor.run { HyperliquidStore.shared.refreshAfterTrade() }
            return summary
        }
        var o = json(["status": "review_opened", "kind": "close", "executed": false, "order": "Market, reduce only",
                      "closing": full ? "all of the \(sym) \(side), \(amountText)" : "\(share)% of the \(sym) \(side), \(amountText)",
                      "unrealised_pnl": ToolsV3.r2(partPnl), "note": "Waiting for the user to approve with \(Device.bio)."])
        o.action = Action(full ? "Review close \(sym)" : "Review close \(share)% of \(sym)", approval: approval)
        return o
    }

    // MARK: set_tp_sl

    /// set_tp_sl: a take profit and/or a stop loss on a position that is already open. Reduce-only market triggers for
    /// the whole position (HyperliquidTrader.protect); a trigger of the same kind that is already there is replaced in
    /// the same approval. A price on the wrong side of the market would fire at once, so it is refused with the price.
    /// Protection lowers risk, so no spending cap applies. It is still a review, signed after Face ID or Touch ID.
    @MainActor static func setProtection(_ a: [String: Any], label: String) async throws -> ToolOutcome {
        let coinIn = ToolsV3.text(a, "coin")
        guard !coinIn.isEmpty else { throw ToolError("Needs coin") }
        let askedTP = ToolsV3.has(a, "take_profit") ? ToolsV3.number(a, "take_profit") : nil
        let askedSL = ToolsV3.has(a, "stop_loss") ? ToolsV3.number(a, "stop_loss") : nil
        if (ToolsV3.has(a, "take_profit") && askedTP == nil) || (ToolsV3.has(a, "stop_loss") && askedSL == nil) { throw ToolError("take_profit and stop_loss are prices in USD") }
        guard askedTP != nil || askedSL != nil else { throw ToolError("Needs take_profit, stop_loss or both") }
        let hl = HyperliquidStore.shared
        guard hl.hasWallet, let trader = hl.trader() else { throw ToolError("No wallet on \(Device.here) to trade with") }
        guard await hl.poll(), let account = hl.account else { throw ToolError("Couldn't read the Hyperliquid account") }
        // The same ticker open on two venues: never pick one for the user.
        let clash = ToolsV3.positionClash(coinIn, in: account.positions)
        if !clash.isEmpty { throw ToolError("The user has more than one \(PerpFmt.sym(coinIn).uppercased()) position (\(clash.joined(separator: ", "))). Ask which one, and pass its full name as coin.") }
        guard let cur = ToolsV3.position(coinIn, in: account.positions) else {
            return json(["status": "no_position", "prepared": false,
                         "note": "The user has no open \(PerpFmt.sym(coinIn).uppercased()) position on Hyperliquid. Tell them."])
        }
        let sym = cur.sym, long = cur.isLong
        guard let asset = await hl.asset(cur.coin) else { throw ToolError("\(sym) isn't tradable on Hyperliquid right now.") }
        let live = (try? await Self.market(cur.coin, maxAge: 0))?.mark ?? 0
        let mark: Double = live > 0 ? live : (cur.markPx ?? 0)
        guard mark > 0 else { throw ToolError("No price for \(sym) right now. Try again in a moment.") }
        // Hyperliquid holds a trigger at 5 significant figures (Hyperliquid.triggerWire rounds it the same way). The
        // side check, the review and the signed order all use that price, so the sheet shows what is really placed.
        let takeProfit: Double? = askedTP.map { ToolsV3.triggerPrice($0, szDecimals: asset.szDecimals) }
        let stopLoss: Double? = askedSL.map { ToolsV3.triggerPrice($0, szDecimals: asset.szDecimals) }
        // A per-token price given for a market priced per 1,000 tokens (kPEPE).
        if let token = thousandOf(cur.coin), [takeProfit, stopLoss].contains(where: { ($0 ?? mark) < mark / 100 }) {
            return json(["error": "\(cur.coin) prices are per 1,000 \(token): the mark is \(Hyperliquid.wire(mark)). Give the take profit and stop loss in that unit.", "prepared": false])
        }
        if let why = ToolsV3.wrongSide(long: long, takeProfit: takeProfit, stopLoss: stopLoss, mark: mark) {
            return json(["error": why, "prepared": false])
        }
        let old = ToolsV3.replaced(coin: cur.coin, takeProfit: takeProfit != nil, stopLoss: stopLoss != nil, orders: account.orders)
        let replaces = ToolsV3.replacedText(old)
        let oldIDs = old.map(\.oid)

        var lines: [[String]] = [["Position", "\(sym) \(long ? "long" : "short") \(cur.leverage)x, \(Hyperliquid.wire(cur.coins)) \(sym)"],
                                 ["Price now", "$" + Hyperliquid.wire(ToolsV3.sig(mark, 5))]]
        if let tp = takeProfit { lines.append(["Take profit", ToolsV3.triggerText(tp)]) }
        if let sl = stopLoss { lines.append(["Stop loss", ToolsV3.triggerText(sl)]) }
        lines.append(["Order", "Trigger, market, reduce only"])
        lines.append(["Covers", "The whole position, whatever its size is then"])
        if let replaces { lines.append(["Replaces", ToolsV3.capFirst(replaces)]) }
        lines.append(["Asked for by", "\(label), from your message"])
        let kinds: [String] = (takeProfit == nil ? [] : ["take profit"]) + (stopLoss == nil ? [] : ["stop loss"])
        let approval = Approval(kind: "Hyperliquid order", title: "Set \(ToolsV3.both(kinds)) on \(sym) \(long ? "long" : "short")",
                                lines: lines, checks: ["Reduce only: it can only close this position", "Signed on \(Device.here) with your wallet's key"],
                                success: "\(ToolsV3.capFirst(ToolsV3.both(kinds))) set on \(sym)",
                                warnings: ["A trigger fires as a market order, so the fill can be worse than the trigger price in a fast market."]) {
            let summary = try await trader.protect(asset: asset, isLong: long, takeProfit: takeProfit, stopLoss: stopLoss, replacing: oldIDs)
            await MainActor.run { HyperliquidStore.shared.refreshAfterTrade() }
            return summary
        }
        // The prices go back exactly as the model passed them: they are what the review shows.
        var out: [String: Any] = ["status": "review_opened", "kind": "tp_sl", "executed": false, "order": "Trigger, market, reduce only",
                                  "position": ToolsV3.positionText(cur), "note": "Waiting for the user to approve with \(Device.bio)."]
        if let v = a["take_profit"], takeProfit != nil { out["take_profit"] = v }
        if let v = a["stop_loss"], stopLoss != nil { out["stop_loss"] = v }
        if let replaces { out["replaces"] = replaces }
        var o = json(out)
        o.action = Action("Review \(ToolsV3.both(kinds)) on \(sym)", approval: approval)
        return o
    }
}
