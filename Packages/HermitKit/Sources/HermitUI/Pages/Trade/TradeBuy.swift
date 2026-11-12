import SwiftUI
import HermitWallet
import HermitCore

/// How a coin on the Spot or Memes list can actually be bought from Hermit, with the wallet you have:
///   intents  Hermit's own swap through NEAR Intents, paid in USDC from your wallet, delivered to your own address.
///   site     the app inside Hermit's browser (Jupiter, Uniswap, Hyperliquid) with the wallet connected; the same
///            review and approval as everything else.
///   none     not possible yet, and why (Hermit has no wallet for that coin's chain).
enum TradeBuy {
    enum Route {
        case intents(to: Chain, symbol: String)
        /// Bought on Solana inside Hermit through Jupiter's API: only a token Jupiter marks verified, checked at tap time.
        case solana(String)
        case site(URL, dapp: String, label: String)
        case none(String)
    }

    static func route(for sym: String) -> Route {
        switch sym {
        case "ETH": if let c = Chain.with(id: "base") { return .intents(to: c, symbol: "ETH") }
        case "SOL": if let c = Chain.with(id: "solana") { return .intents(to: c, symbol: "SOL") }
        case "BNB": if let c = Chain.with(id: "bnb") { return .intents(to: c, symbol: "BNB") }
        case "HYPE": return .site(URL(string: "https://app.hyperliquid.xyz/trade/HYPE")!, dapp: "Hyperliquid", label: "Buy on Hyperliquid")
        case "BTC": return .site(URL(string: "https://app.hyperliquid.xyz/trade/UBTC")!, dapp: "Hyperliquid", label: "Buy on Hyperliquid")
        case "XRP": return .solana("XRP")
        case "PEPE": return .site(URL(string: "https://app.uniswap.org/swap?chain=mainnet&inputCurrency=NATIVE&outputCurrency=0x6982508145454Ce325dDbE47a25d4ec3d2311933")!, dapp: "Uniswap", label: "Buy on Uniswap")
        case "SHIB": return .site(URL(string: "https://app.uniswap.org/swap?chain=mainnet&inputCurrency=NATIVE&outputCurrency=0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE")!, dapp: "Uniswap", label: "Buy on Uniswap")
        case "WIF", "BONK", "PENGU", "DOGE": return .solana(sym)
        default: break
        }
        return .none("\(sym) can't be bought from Hermit yet")
    }

    /// Opens the right thing: the swap review for an Intents buy (USDC from wherever you hold it), or the app.
    @MainActor static func start(_ sym: String, usd: Double, model: AppModel) {
        switch route(for: sym) {
        case .intents(let to, let symbol):
            let vm = WalletsViewModel.shared
            guard let w = vm.wallets.first else { model.fundGoal = .wallet; return }
            // Pay from the USDC you hold: the first cheap network that covers the amount, else the biggest holding.
            let order = ["base", "arbitrum", "solana", "polygon", "bnb", "ethereum"]
            let usdc = vm.holdings(wallet: w.id, chain: nil).filter { $0.symbol == "USDC" && !$0.chain.isTestnet && $0.amount > 0 }
                .sorted { (order.firstIndex(of: $0.chain.id) ?? 99) < (order.firstIndex(of: $1.chain.id) ?? 99) }
            guard let from = usdc.first(where: { $0.amount >= usd }) ?? usdc.max(by: { $0.amount < $1.amount }), from.amount >= 1 else {
                model.toast("You need at least 1 USDC in the wallet first"); model.fundGoal = .wallet; return
            }
            // Never more than that network holds; cents rounded down so it stays under the balance.
            let amount = (min(max(1, usd), from.amount) * 100).rounded(.down) / 100
            let verdict = vm.service.policy.evaluate(usd: amount, payee: nil, origin: .user)
            vm.pendingSwap = SwapIntent(from: from.chain, fromSymbol: "USDC", to: .chain(to), toSymbol: symbol,
                                        amount: TradeAmount.text(amount, maxFraction: 2), origin: .user, verdict: verdict)
            model.open(.wallets, tab: "agent-swap")
        case .solana(let symbol):
            Task { await buyOnSolana(symbol, usd: usd, model: model) }
        case .site(let u, let dapp, _):
            DappBrowser.shared.open(u, dapp: ExploreData.dapps.first { $0.name == dapp }, model: model)
        case .none(let why):
            model.toast(why, kind: .error)
        }
    }

    /// SOL kept back when paying with SOL: the network fee plus rent for a new token account (about 0.002 SOL).
    static let solReserve = 0.01
    /// Paying with USDC still needs a little SOL on Solana for the fee and the rent.
    static let solForFees = 0.005
    /// Price impact, in percent, that gets a warning on the review sheet, and the most Hermit will send at all.
    static let warnImpact = 5.0, maxImpact = 15.0

    /// SOL's dollar price: the wallet's price feed, else Jupiter's list. Nil when neither has one yet.
    @MainActor static func solPrice() -> Double? {
        if let p = WalletsViewModel.shared.price("SOL"), p > 0 { return p }
        // The list may be a saved copy up to a day old: its price only counts while it's under an hour old.
        guard let u = JupiterTokens.shared.updated, Date().timeIntervalSince(u) < 3600,
              let p = JupiterTokens.shared.rows.first(where: { $0.id == Jupiter.solMint })?.price, p > 0 else { return nil }
        return p
    }

    /// The verified token for a symbol, from Jupiter's list (only tokens with real liquidity). Several tokens can carry the
    /// same symbol; when the runner-up has at least half the liquidity of the top one, Hermit won't guess.
    @MainActor static func verifiedToken(_ symbol: String) async throws -> Jupiter.Token {
        let store = JupiterTokens.shared
        if store.rows.isEmpty { await store.refresh(force: true) }
        let want = symbol.uppercased()
        let matches = store.rows.filter { $0.symbol.uppercased() == want }.sorted { $0.liquidity > $1.liquidity }
        guard let best = matches.first else { throw Jupiter.Error.notVerified(symbol) }
        if matches.count > 1, matches[1].liquidity >= best.liquidity * 0.5 {
            throw WalletError.blocked("More than one verified token is called \(symbol) on Solana. Pick the one you mean on Spot or Memes, or paste its mint.")
        }
        return best.token
    }

    /// Jupiter inside Hermit: verified token, live quote, the usual review sheet, signed here. `symbol` form: looks the
    /// token up and pays with USDC when there is enough, else SOL.
    @MainActor static func buyOnSolana(_ symbol: String, usd: Double, model: AppModel) async {
        model.toast("Getting a quote from Jupiter…", kind: .progress)
        do {
            let token = try await verifiedToken(symbol)
            let vm = WalletsViewModel.shared
            guard let w = vm.wallets.first else { model.fundGoal = .wallet; return }
            let usdcHeld = vm.balance(of: "USDC", wallet: w.id, chain: .solana)
            let solHeld = vm.balance(of: "SOL", wallet: w.id, chain: .solana)
            let price = solPrice() ?? 0
            if usdcHeld >= max(1, usd) { buyOnSolana(token: token, payUSDC: true, amount: max(1, usd), model: model) }
            else if price > 0, solHeld > solReserve { buyOnSolana(token: token, payUSDC: false, amount: min(usd / price, solHeld - solReserve), model: model) }
            else { throw WalletError.blocked("Not enough USDC or SOL on Solana to buy with. Add some first.") }
        } catch {
            model.toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
        }
    }

    /// Quote, policy, review, then Hermit signs and sends. `amount` is in the paying token (USDC or SOL). `exact` is the
    /// amount as typed, when there is one: it becomes base units exactly instead of going through a Double.
    /// `check` is what Jupiter's search said about a token that isn't on the verified list: an unverified token needs it,
    /// and its `refusal` (too little liquidity, a freeze authority) stops the buy before any review opens.
    @MainActor static func buyOnSolana(token: Jupiter.Token, payUSDC: Bool, amount: Double, exact: String? = nil, check: TokenCheck? = nil,
                                       model: AppModel) {
        if let why = check?.refusal { model.toast(why, kind: .error); return }
        if !token.verified && check == nil {
            model.toast("Hermit couldn't check \(token.symbol), so it won't buy it. Search for it again.", kind: .error); return
        }
        let vm = WalletsViewModel.shared
        guard let w = vm.wallets.first, !w.record.solanaAddress.isEmpty else { model.fundGoal = .wallet; return }
        let pay: Jupiter.Token = payUSDC ? Jupiter.usdc : Jupiter.sol
        let parsed: UInt64?
        if let exact { parsed = TradeAmount.baseUnits(text: exact, decimals: pay.decimals) } else { parsed = TradeAmount.baseUnits(amount, decimals: pay.decimals) }
        guard let base = parsed else {
            model.toast(exact == nil ? "Enter an amount to pay" : "Check the amount: up to \(pay.decimals) decimals for \(pay.symbol)")
            return
        }
        let paid = Double(base) / pow(10, Double(pay.decimals))
        let solHeld = vm.balance(of: "SOL", wallet: w.id, chain: .solana)
        if payUSDC {
            guard paid <= vm.balance(of: "USDC", wallet: w.id, chain: .solana) else { model.toast("Not enough USDC on Solana"); return }
            guard solHeld >= solForFees else {
                model.toast("Add a little SOL on Solana first. It pays the network fee."); model.fundGoal = .token(.solana, "SOL"); return
            }
        } else if paid > solHeld - solReserve {
            model.toast("Keep about \(TradeAmount.text(solReserve, maxFraction: 2)) SOL for fees. Try a smaller amount."); return
        }
        // The daily limit needs a dollar value. With no SOL price, stop rather than check it as $0.
        let priced: Double? = payUSDC ? paid : solPrice().map { paid * $0 }
        guard let usdValue = priced else { model.toast("Couldn't get SOL's price, so Hermit can't check your daily limit. Try again in a moment."); return }
        Task {
            do {
                let q = try await Jupiter.quote(from: pay, to: token, amount: base)
                let verdict = vm.service.policy.evaluate(usd: usdValue, payee: nil, origin: .user)
                if verdict.decision == .block { model.toast(verdict.blocks.first ?? "Blocked by your spending policy", kind: .error); return }
                let impact = q.shownImpactPercent
                if impact > maxImpact {
                    model.toast("Price impact is \(String(format: "%.1f", impact))%, so Hermit won't send it. Try a smaller amount."); return
                }
                let impactWarning = impact > warnImpact ? ["Price impact is \(String(format: "%.1f", impact))%. You get noticeably less than the market price."] : []
                // An unverified token: the strongest line first, with the whole mint to check against (the line above
                // it shows the mint shortened), then what its audit says.
                let strong: [String] = token.verified ? [] : ["\(token.symbol) is NOT on Jupiter's verified list. Anyone can make a token with this name. Check its full mint is the one you mean: \(token.mint)"]
                let audit: [String] = check?.warnings.filter { !$0.hasPrefix("Not on Jupiter's verified list") } ?? []
                let unverified = strong + audit
                // The limit is read here, on the main actor: the review's closure runs off it.
                let svc = vm.service, limit = vm.service.spendLimit, wid = w.record.id, walletKey = w.id, sym = token.symbol
                let owner = w.record.solanaAddress, mintID = token.mint, decimals = token.decimals, quoted = q.outAmount, paySym = pay.symbol
                let mint = token.mint.count > 12 ? "\(token.mint.prefix(4))…\(token.mint.suffix(4))" : token.mint
                let lines: [[String]] = [["You pay", "\(q.inFormatted) \(pay.symbol) on Solana"], ["You get, about", "\(q.outFormatted) \(token.symbol)"],
                                         ["Price impact", String(format: "%.2f%%", impact)], ["Slippage", "up to \(Double(q.slippageBps) / 100)%"],
                                         ["Route", "Jupiter" + (q.route.isEmpty ? "" : " via " + q.route.prefix(2).joined(separator: ", "))],
                                         ["Token", token.name + (token.verified ? ", verified on Jupiter" : ", not verified")], ["Mint", mint]]
                let got = Double(q.outFormatted) ?? 0, paidShown = Double(q.inFormatted) ?? 0
                let what = "Bought about \(MoneyFmt.amount(got)) \(sym) with \(MoneyFmt.amount(paidShown)) \(pay.symbol)"
                let approval = Approval(kind: "Buy", title: "Buy \(token.symbol)", lines: lines,
                                        checks: (token.verified ? ["Token is on Jupiter's verified list"] : [])
                                            + ["Hermit tests Jupiter's transaction on Solana before it's signed",
                                               "Signed on \(Device.here) with your wallet's key"] + verdict.passed,
                                        success: "Bought \(token.symbol)", warnings: unverified + verdict.warnings + impactWarning) {
                    // The balance before, so what actually arrived can be measured (for the cost book) once it's confirmed.
                    let before = await SolanaHoldings.balance(owner: owner, mint: mintID)
                    let sig: String
                    do { sig = try await svc.executeJupiter(q, walletID: wid) } catch WalletError.pending(let h, let explorer) {
                        // Sent but not confirmed in time: it may still land, so it counts toward the daily limit and is
                        // listed as pending before the error tells the user not to buy again.
                        limit.record(usd: Decimal(usdValue))
                        await MainActor.run {
                            ActivityLedger.shared.record(ActivityItem(id: h, kind: .swap, chainID: "solana", walletID: walletKey, what: what, detail: "Jupiter",
                                                                      amount: got, symbol: sym, date: Date(), tx: h, status: "Pending",
                                                                      link: Chain.solana.explorerURL(tx: h)))
                        }
                        throw WalletError.pending(hash: h, explorer: explorer)
                    }
                    // Confirmed on chain: it counts toward the daily limit and goes into Activity under its own signature.
                    limit.record(usd: Decimal(usdValue))
                    await MainActor.run {
                        ActivityLedger.shared.record(ActivityItem(id: sig, kind: .swap, chainID: "solana", walletID: walletKey, what: what, detail: "Jupiter",
                                                                  amount: got, symbol: sym, date: Date(), tx: sig, status: "Confirmed",
                                                                  link: Chain.solana.explorerURL(tx: sig)))
                    }
                    // Into the cost book with what arrived (the quote's amount if it can't be read), then the success
                    // moment. Off the sheet's path, so the review reports back at once.
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
                model.approval = approval
            } catch {
                model.toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            }
        }
    }

    /// Sells `percent` (25, 50 or 100) of a Solana token the wallet holds, for USDC or SOL (USDC itself sells for SOL),
    /// through the same path as buying: Jupiter's quote, the spending policy, the review, a test run of Jupiter's
    /// transaction, then Hermit signs and sends. The amount is exact base units of what the wallet holds, rounded down;
    /// 100% is all of it. The wallet keeps `solReserve` (0.01 SOL) for the fee and a new token account's rent.
    @MainActor static func sellOnSolana(_ held: SolanaHoldings.Holding, percent: Int, toUSDC: Bool = true, model: AppModel) {
        let vm = WalletsViewModel.shared
        guard let w = vm.wallets.first, !w.record.solanaAddress.isEmpty else { model.fundGoal = .wallet; return }
        // The latest reading, if there is one (the button may be from a screen a refresh ago).
        let h = SolanaHoldings.shared.holding(held.id) ?? held
        guard [25, 50, 100].contains(percent) else { return }
        guard !h.frozen else { model.toast("The token's issuer froze this account, so it can't be sold.", kind: .error); return }
        guard h.id != Jupiter.solMint else { model.toast("That's wrapped SOL. It counts as SOL in your wallet.", kind: .info); return }
        let share = percent == 100 ? h.amount : h.amount * UInt128(percent) / 100
        guard share > 0 else { model.toast("That's too little \(h.symbol) to sell", kind: .info); return }
        guard let base = UInt64(exactly: share) else { model.toast("That's more \(h.symbol) than one swap can sell. Try 25%.", kind: .error); return }
        let out: Jupiter.Token = toUSDC && h.id != Jupiter.usdcMint ? Jupiter.usdc : Jupiter.sol
        // The fee, and rent for a new USDC account, come out of SOL: keep solReserve (0.01 SOL) in hand.
        guard vm.balance(of: "SOL", wallet: w.id, chain: .solana) >= solReserve else {
            model.toast("Keep about \(TradeAmount.text(solReserve, maxFraction: 2)) SOL on Solana for fees. Add a little first.")
            model.fundGoal = .token(.solana, "SOL"); return
        }
        let token = h.token
        model.toast("Getting a quote from Jupiter…", kind: .progress)
        Task {
            do {
                let q = try await Jupiter.quote(from: token, to: out, amount: base)
                let gets = Double(q.outFormatted) ?? 0, sold = Double(q.inFormatted) ?? 0
                // The daily limit needs a dollar value: USDC as is, SOL at its price. With no SOL price, stop.
                let priced: Double? = out.mint == Jupiter.usdcMint ? gets : solPrice().map { gets * $0 }
                guard let usdValue = priced else {
                    model.toast("Couldn't get SOL's price, so Hermit can't check your daily limit. Try again in a moment."); return
                }
                let verdict = vm.service.policy.evaluate(usd: usdValue, payee: nil, origin: .user)
                if verdict.decision == .block { model.toast(verdict.blocks.first ?? "Blocked by your spending policy", kind: .error); return }
                let impact = q.shownImpactPercent
                if impact > maxImpact {
                    model.toast("Price impact is \(String(format: "%.1f", impact))%, so Hermit won't send it. Try selling less."); return
                }
                let impactWarning = impact > warnImpact ? ["Price impact is \(String(format: "%.1f", impact))%. You get noticeably less than the market price."] : []
                let unverified: [String] = token.verified ? [] : ["\(token.symbol) isn't on Jupiter's verified list. Mint \(token.mint)."]
                let svc = vm.service, limit = vm.service.spendLimit, wid = w.record.id, walletKey = w.id, sym = token.symbol, outSym = out.symbol
                let mintID = token.mint, decimals = token.decimals, sharePart = percent == 100 ? "all of it" : "\(percent)%"
                let mint = token.mint.count > 12 ? "\(token.mint.prefix(4))…\(token.mint.suffix(4))" : token.mint
                let lines: [[String]] = [["You sell", "\(q.inFormatted) \(sym) (\(sharePart))"], ["You get, about", "\(q.outFormatted) \(outSym) on Solana"],
                                         ["Price impact", String(format: "%.2f%%", impact)], ["Slippage", "up to \(Double(q.slippageBps) / 100)%"],
                                         ["Route", "Jupiter" + (q.route.isEmpty ? "" : " via " + q.route.prefix(2).joined(separator: ", "))],
                                         ["Token", token.name + (token.verified ? ", verified on Jupiter" : ", not verified")], ["Mint", mint]]
                let what = "Sold \(MoneyFmt.amount(sold)) \(sym) for about \(MoneyFmt.amount(gets)) \(outSym)"
                let approval = Approval(kind: "Sell", title: "Sell \(sym)", lines: lines,
                                        checks: (token.verified ? ["Token is on Jupiter's verified list"] : [])
                                            + ["Hermit tests Jupiter's transaction on Solana before it's signed",
                                               "Signed on \(Device.here) with your wallet's key"] + verdict.passed,
                                        success: "Sold \(sym)", warnings: unverified + verdict.warnings + impactWarning) {
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
                model.approval = approval
            } catch {
                model.toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: .error)
            }
        }
    }
}

extension Jupiter.Quote {
    /// Jupiter sends price impact as a fraction ("0.5704" is 57%). This is it in percent, for the screen and the checks.
    var shownImpactPercent: Double { priceImpactPct * 100 }
}

/// The Buy button for a Spot or Memes row, in whichever form the coin allows.
struct TradeBuyButton: View {
    let sym: String
    var usd: Double = 10
    @Environment(AppModel.self) private var model
    var body: some View {
        switch TradeBuy.route(for: sym) {
        case .intents(let to, _):
            Button("Buy \(sym) with USDC") { TradeBuy.start(sym, usd: usd, model: model) }.buttonStyle(TradeSmallButton(kind: .primary))
                .help("Through NEAR Intents, into your wallet on \(to.name)")
        case .solana:
            Button("Buy \(sym) on Solana") { TradeBuy.start(sym, usd: usd, model: model) }.buttonStyle(TradeSmallButton(kind: .primary))
                .help("Through Jupiter's API, signed here; only Jupiter-verified tokens")
        case .site(_, _, let label):
            Button(label) { TradeBuy.start(sym, usd: usd, model: model) }.buttonStyle(TradeSmallButton(kind: .primary))
        case .none(let why):
            Text(why).font(.system(size: 12)).foregroundStyle(Theme.hint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
