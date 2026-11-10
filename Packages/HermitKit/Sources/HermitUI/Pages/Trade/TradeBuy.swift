import SwiftUI
import HermitWallet

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
            // Pay from the USDC you hold: the cheap networks first.
            let order = ["base", "arbitrum", "solana", "polygon", "bnb", "ethereum"]
            let usdc = vm.holdings(wallet: w.id, chain: nil).filter { $0.symbol == "USDC" && !$0.chain.isTestnet && $0.amount > 0 }
                .sorted { (order.firstIndex(of: $0.chain.id) ?? 99) < (order.firstIndex(of: $1.chain.id) ?? 99) }
            guard let from = usdc.first else { model.toast("You need some USDC in the wallet first"); model.fundGoal = .wallet; return }
            let amount = max(1, min(usd, from.amount))
            let verdict = vm.service.policy.evaluate(usd: amount, payee: nil, origin: .user)
            vm.pendingSwap = SwapIntent(from: from.chain, fromSymbol: "USDC", to: .chain(to), toSymbol: symbol,
                                        amount: amount.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)), origin: .user, verdict: verdict)
            model.open(.wallets, tab: "agent-swap")
        case .solana(let symbol):
            Task { await buyOnSolana(symbol, usd: usd, model: model) }
        case .site(let u, let dapp, _):
            DappBrowser.shared.open(u, dapp: ExploreData.dapps.first { $0.name == dapp }, model: model)
        case .none(let why):
            model.toast(why)
        }
    }

    /// Jupiter inside Hermit: verified token, live quote, the usual review sheet, signed here. `symbol` form: looks the
    /// token up and pays with USDC when there is enough, else SOL.
    @MainActor static func buyOnSolana(_ symbol: String, usd: Double, model: AppModel) async {
        model.toast("Getting a quote from Jupiter…")
        do {
            guard let token = try await Jupiter.verifiedToken(symbol: symbol) else { throw Jupiter.Error.notVerified(symbol) }
            let vm = WalletsViewModel.shared
            guard let w = vm.wallets.first else { model.fundGoal = .wallet; return }
            let usdcHeld = vm.balance(of: "USDC", wallet: w.id, chain: .solana)
            let solPrice = vm.price("SOL") ?? 0
            if usdcHeld >= max(1, usd) { buyOnSolana(token: token, payUSDC: true, amount: max(1, min(usd, usdcHeld)), model: model) }
            else if solPrice > 0 { buyOnSolana(token: token, payUSDC: false, amount: min(usd / solPrice, max(0, vm.balance(of: "SOL", wallet: w.id, chain: .solana) - 0.004)), model: model) }
            else { throw WalletError.blocked("Not enough USDC or SOL on Solana to buy with. Add some first.") }
        } catch {
            model.toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Quote, policy, review, then Hermit signs and sends. `amount` is in the paying token (USDC or SOL).
    @MainActor static func buyOnSolana(token: Jupiter.Token, payUSDC: Bool, amount: Double, model: AppModel) {
        let vm = WalletsViewModel.shared
        guard let w = vm.wallets.first, !w.record.solanaAddress.isEmpty else { model.fundGoal = .wallet; return }
        let pay: Jupiter.Token = payUSDC ? .usdc : .sol
        guard amount > 0 else { return }
        let base = UInt64((amount * pow(10, Double(pay.decimals))).rounded())
        let usdValue = payUSDC ? amount : amount * (vm.price("SOL") ?? 0)
        Task {
            do {
                let q = try await Jupiter.quote(from: pay, to: token, amount: base)
                let verdict = vm.service.policy.evaluate(usd: usdValue, payee: nil, origin: .user)
                if verdict.decision == .block { model.toast(verdict.blocks.first ?? "Blocked by your spending policy"); return }
                let svc = vm.service, wid = w.record.id
                let lines: [[String]] = [["You pay", "\(q.inFormatted) \(pay.symbol) on Solana"], ["You get, about", "\(q.outFormatted) \(token.symbol)"],
                                         ["Price impact", String(format: "%.2f%%", q.priceImpactPct)], ["Slippage", "up to \(Double(q.slippageBps) / 100)%"],
                                         ["Route", "Jupiter" + (q.route.isEmpty ? "" : " via " + q.route.prefix(2).joined(separator: ", "))], ["Token", token.name + ", verified on Jupiter"]]
                let approval = Approval(kind: "Buy", title: "Buy \(token.symbol)", lines: lines,
                                        checks: ["Token is on Jupiter's verified list", "Signed on \(Device.here) with your wallet's key"] + verdict.warnings,
                                        success: "Bought \(token.symbol)") {
                    try await svc.executeJupiter(q, walletID: wid)
                }
                let got = Double(q.outFormatted) ?? 0, paid = Double(q.inFormatted) ?? 0
                BuyRecord.pending = ActivityItem(id: "buy-\(Int(Date().timeIntervalSince1970))-\(token.symbol)", kind: .swap, chainID: "solana", walletID: w.id,
                                                 what: "Bought \(MoneyFmt.amount(got)) \(token.symbol) with \(MoneyFmt.amount(paid)) \(pay.symbol)", detail: "Jupiter",
                                                 amount: got, symbol: token.symbol, date: Date(), tx: nil, status: "Confirmed", link: nil)
                model.approval = approval
            } catch {
                model.toast((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

/// The Activity row for a Solana buy, written once the review is approved (AppModel.approved).
@MainActor enum BuyRecord { static var pending: ActivityItem? }
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
            Text(why).font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
