import SwiftUI
import HermitCore

/// Full history with filters; each row opens its receipt.
struct HistorySheet: View {
    let vm: WalletsViewModel
    let walletID: String?
    @State private var filter = "All"
    @State private var chain: WalletChain?
    @State private var detail: ActivityItem?
    static let filters = ["All", "Sent", "Received", "Trades", "APIs", "Earn"]

    private func keep(_ a: ActivityItem) -> Bool {
        switch filter {
        case "Sent": a.usd < 0 && (a.category == "Payment" || a.category == "Transfer")
        case "Received": a.usd > 0
        case "Trades": a.category == "Trade"
        case "APIs": a.category == "API"
        case "Earn": a.category == "Earn"
        default: true
        }
    }

    var body: some View {
        if let detail {
            ActivityDetailSheet(item: detail, vm: vm) { withAnimation(.smooth) { self.detail = nil } }
        } else {
            let items = vm.activity(wallet: walletID, chain: chain).filter(keep)
            SheetChrome(title: "History", subtitle: walletID.flatMap { vm.wallet($0)?.name } ?? "All wallets", width: 540) {
                HStack(alignment: .top) {
                    WrapRow { ForEach(Self.filters, id: \.self) { f in SelectChip(title: f, on: filter == f) { filter = f } } }
                    ChainFilter(chain: $chain)
                }
                if items.isEmpty { EmptyNote(text: "Nothing here yet").frame(maxWidth: .infinity) }
                RowList(items: items) { a in
                    ActivityRow(item: a, wallet: walletID == nil ? vm.wallet(a.walletID)?.name : nil) { withAnimation(.smooth) { detail = a } }
                }
            }
            .animation(.smooth(duration: 0.22), value: filter)
            .animation(.smooth(duration: 0.22), value: chain)
        }
    }
}

/// One transaction's receipt.
struct ActivityDetailSheet: View {
    @Environment(AppModel.self) private var model
    let item: ActivityItem
    let vm: WalletsViewModel
    var onBack: (() -> Void)? = nil

    var body: some View {
        SheetChrome(title: item.what, onBack: onBack) {
            HStack(spacing: 12) {
                Text(item.usd == 0 ? "$0" : MoneyFmt.signed(item.usd)).font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(item.usd > 0 ? Theme.green : Theme.text)
                Spacer()
                PillTag(text: "Confirmed", color: Theme.green, dot: true)
            }
            DetailLines(lines: [("Type", item.category), ("Network", item.chain.name), ("Wallet", vm.wallet(item.walletID)?.name ?? ""),
                                ("Route", item.via), ("When", item.when), ("Tx", item.tx)], monoKeys: ["Tx"])
        } foot: {
            Button("Copy hash") { Clip.copy(item.tx); model.toast("Transaction hash copied") }.buttonStyle(WideButton(kind: .plain))
            Button("View on explorer") { model.toast("Opened in \(item.chain == .solana ? "Solscan" : item.chain == .bnb ? "BscScan" : item.chain.name + " explorer")") }
                .buttonStyle(WideButton())
        }
    }
}

/// A token: value, candles, where it sits (wallet and network), and Send / Swap / Bridge / Earn.
struct TokenSheet: View {
    let group: TokenGroup
    let vm: WalletsViewModel
    let onAction: (String) -> Void
    @State private var range = "1D"

    var body: some View {
        let up = group.change >= 0
        SheetChrome(title: group.symbol, subtitle: group.name, width: 540) {
            HStack(spacing: 12) {
                TokenLogo(symbol: group.symbol, chain: group.chains.count == 1 ? group.chains[0] : nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MoneyFmt.usd(group.usd)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Text("\(MoneyFmt.pct(group.change)) today, \(MoneyFmt.amount(group.amount)) \(group.symbol)")
                        .font(.system(size: 12.5)).foregroundStyle(up ? Theme.green : Theme.red)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Price").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Text(group.price < 0.01 ? "$" + group.price.formatted(.number.precision(.significantDigits(3))) : MoneyFmt.usd(group.price, digits: 2))
                        .font(.system(size: 13.5)).monospacedDigit()
                }
            }
            VStack(alignment: .trailing, spacing: 8) {
                Candles(data: Candle.series(seed: group.symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) } + range.count * 7,
                                            count: 48, start: max(group.price, 0.0001) * 0.92, vol: group.symbol.hasPrefix("USD") ? 0.002 : 0.035,
                                            drift: group.symbol.hasPrefix("USD") ? 0 : (up ? 0.06 : -0.06)))
                    .frame(height: 170)
                Segmented(options: [("1H", "1H"), ("1D", "1D"), ("1W", "1W"), ("1M", "1M")], selection: $range)
            }
            HStack(spacing: 0) {
                ForEach([("Send", "arrow.up.right", "send"), ("Swap", "arrow.left.arrow.right", "swap"),
                         ("Bridge", "point.3.connected.trianglepath.dotted", "bridge"), ("Earn", "leaf", "earn")], id: \.2) { a in
                    RoundAction(title: a.0, symbol: a.1) { onAction(a.2) }.frame(maxWidth: .infinity)
                }
            }
            SectionLabel("Where it is")
            RowList(items: group.parts.sorted { $0.usd > $1.usd }) { h in
                HStack(spacing: 10) {
                    LogoMark(h.chain.logo, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.wallet(h.walletID)?.name ?? h.walletID).font(.system(size: 13.5, weight: .medium))
                        Text(h.chain.name).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(MoneyFmt.usd(h.usd)).font(.system(size: 13.5)).monospacedDigit()
                        Text("\(MoneyFmt.amount(h.amount)) \(h.symbol)").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: Gas

/// Two ways to refill gas: swap a token already on that chain, or send gas from another of your wallets.
struct GasTopUpSheet: View {
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    let chain: WalletChain
    @State private var usd: Double = 10
    @State private var swap = true
    @State private var token = "USDC"
    @State private var fromID = "trading"

    private var tank: GasTank { vm.gas.first { $0.chain == chain } ?? GasTank(chain: chain, amount: 0, usd: 0, txs: 0, level: 0) }
    private var perUsd: Double { max(Double(tank.txs) / max(tank.usd, 0.1), 20) }
    private var sources: [WalletAccount] { vm.wallets.filter { $0.address(on: chain) != nil } }

    var body: some View {
        let amt = usd / vm.price(chain.gasToken)
        SheetChrome(title: "Top up \(chain.name) gas") {
            gasHeader(tank)
            HStack(spacing: 8) {
                ForEach([5.0, 10, 25], id: \.self) { v in
                    AmountTile(title: "$\(Int(v))", sub: "\(Int(v * perUsd).formatted(.number.locale(Locale(identifier: "en_US")))) txs", on: usd == v) { usd = v }
                }
            }
            HStack(spacing: 8) {
                SelectRow(title: "Swap from balance", subtitle: "Use a token on \(chain.name)", on: swap, action: { swap = true }) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 13))
                }
                SelectRow(title: "From another wallet", subtitle: "Send \(chain.gasToken) across", on: !swap, action: { swap = false }) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 13))
                }
            }
            if swap {
                ForEach(["USDC", "USDT"], id: \.self) { t in
                    let bal = vm.balance(of: t, wallet: "main", chain: chain) + vm.balance(of: t, wallet: "trading", chain: chain) + (t == "USDT" ? 310 : 0)
                    SelectRow(title: t, subtitle: "\(MoneyFmt.usd(bal)) on \(chain.name)", on: token == t, action: { token = t }) {
                        TokenLogo(symbol: t, chain: chain, size: 28)
                    } trailing: {
                        Text("\(Int(usd)) \(t) to \(MoneyFmt.amount(amt)) \(chain.gasToken)").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
            } else {
                ForEach(sources) { w in
                    let direct = vm.balance(of: chain.gasToken, wallet: w.id, chain: chain) * vm.price(chain.gasToken) >= usd
                    SelectRow(title: w.name, subtitle: "\(MoneyFmt.usd(vm.total(w.id))), \(direct ? "direct" : "bridged in 30s")", on: fromID == w.id, action: { fromID = w.id }) {
                        SymbolTile(symbol: w.symbol, size: 28)
                    }
                }
            }
        } foot: {
            Button("Review") { review(amt) }.buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
        }
    }

    private func review(_ amt: Double) {
        let (c, u, t, f) = (chain, usd, token, fromID)
        let adds = Int(u * perUsd)
        let a: Approval
        if swap {
            a = Approval(kind: "Gas top-up", title: "Swap \(Int(u)) \(t) to \(c.gasToken)",
                         lines: [["Pay", "\(Int(u)) \(t) on \(c.name)"], ["Get", "About \(MoneyFmt.amount(amt)) \(c.gasToken)"],
                                 ["Route", c == .solana ? "Jupiter" : c == .bnb ? "PancakeSwap" : c == .monad ? "Kuru" : "Uniswap"],
                                 ["Fee", "$0.02"], ["Adds", "About \(adds) transactions"]],
                         checks: WalletSeed.checks(["Swap stays in your wallet"]), success: "\(c.name) gas topped up")
        } else {
            let w = vm.wallet(f)
            a = Approval(kind: "Gas top-up", title: "Send gas from \(w?.name ?? "wallet")",
                         lines: [["From", "\(w?.name ?? "") (\(w?.kind ?? ""))"], ["To", "\(c.name) gas"], ["Amount", "About \(MoneyFmt.amount(amt)) \(c.gasToken) ($\(Int(u)))"],
                                 ["Route", "Gas.zip"], ["Arrives", "About 30s"]],
                         checks: WalletSeed.checks(["Destination is your own wallet"]), success: "\(c.name) gas topped up")
        }
        ask(a) { vm.refillGas(c, usd: u, payWith: swap ? t : nil, fromWallet: swap ? "main" : f) }
    }
}

/// Take gas back out: swap it to USDC in place, or send it to another of your wallets.
struct GasWithdrawSheet: View {
    @Environment(\.askApproval) private var ask
    let vm: WalletsViewModel
    let chain: WalletChain
    @State private var pct: Double = 50
    @State private var to = "usdc"

    private var tank: GasTank { vm.gas.first { $0.chain == chain } ?? GasTank(chain: chain, amount: 0, usd: 0, txs: 0, level: 0) }

    var body: some View {
        let usd = (tank.usd * pct / 100 * 100).rounded() / 100
        let amt = usd / vm.price(chain.gasToken)
        SheetChrome(title: "Withdraw \(chain.name) gas") {
            gasHeader(tank)
            HStack(spacing: 8) {
                ForEach([25.0, 50, 100], id: \.self) { v in
                    AmountTile(title: v == 100 ? "Max" : "\(Int(v))%", sub: MoneyFmt.usd(tank.usd * v / 100, digits: 2), on: pct == v) { pct = v }
                }
            }
            SelectRow(title: "Swap to USDC", subtitle: "Lands in Main on \(chain.name)", on: to == "usdc", action: { to = "usdc" }) {
                TokenLogo(symbol: "USDC", chain: chain, size: 28)
            }
            ForEach(vm.wallets.filter { $0.id != "main" && $0.address(on: chain) != nil }) { w in
                SelectRow(title: "Send to \(w.name)", subtitle: w.kind, on: to == w.id, action: { to = w.id }) { SymbolTile(symbol: w.symbol, size: 28) }
            }
        } foot: {
            Button("Review") {
                let (c, dest) = (chain, vm.wallet(to))
                let left = Int((tank.usd - usd) * Double(tank.txs) / max(tank.usd, 0.1))
                var checks = ["Destination is your own wallet"]
                if pct == 100 { checks.append("Auto top-up refills it if pending orders need gas") }
                ask(Approval(kind: "Gas withdrawal",
                             title: dest == nil ? "Swap \(MoneyFmt.amount(amt)) \(c.gasToken) to USDC" : "Send \(MoneyFmt.amount(amt)) \(c.gasToken) to \(dest!.name)",
                             lines: [["From", "\(c.name) gas"], ["Amount", "\(MoneyFmt.amount(amt)) \(c.gasToken) ($\(usd))"],
                                     ["To", dest == nil ? "About \(MoneyFmt.usd(usd, digits: 2)) USDC in Main" : "\(dest!.name) (\(dest!.kind))"],
                                     ["Leaves", "About \(left) transactions"]],
                             checks: WalletSeed.checks(checks), success: "\(c.name) gas withdrawn")) {
                    vm.drainGas(c, usd: usd, toUSDC: dest == nil)
                }
            }
            .buttonStyle(WideButton()).disabled(usd <= 0).keyboardShortcut(.defaultAction)
        }
    }
}

@ViewBuilder
private func gasHeader(_ g: GasTank) -> some View {
    HStack(spacing: 12) {
        LogoMark(g.chain.logo, size: 38)
        VStack(alignment: .leading, spacing: 2) {
            Text("\(MoneyFmt.amount(g.amount)) \(g.chain.gasToken)").font(.system(size: 15, weight: .medium)).monospacedDigit()
            Text("About \(g.txs.formatted(.number.locale(Locale(identifier: "en_US")))) transactions left, \(MoneyFmt.usd(g.usd, digits: g.usd < 10 ? 2 : 0))")
                .font(.system(size: 12.5)).foregroundStyle(g.low ? Theme.red : Theme.muted)
        }
    }
}

/// Amount choice tile: big value, small note.
struct AmountTile: View {
    let title: String
    let sub: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: { withAnimation(.snappy(duration: 0.2)) { action() } }) {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(on ? Theme.subtle : Theme.bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Theme.text : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: Add wallet

/// Add a wallet. Local: create (next account from your recovery phrase), import a phrase, or connect a Ledger.
/// Privy: sign in with email, Google, Apple or a passkey, then confirm.
struct AddWalletSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vm: WalletsViewModel
    let custody: WalletAccount.Custody
    let onCreated: (WalletAccount) -> Void

    enum Step: Equatable { case pick, create, importPhrase, hardware, privyConfirm(String, String), working(String), done }
    @State private var step: Step = .pick
    @State private var name = ""
    @State private var phrase = ""
    @State private var created: WalletAccount?
    @State private var error: String?

    private var words: [String] { phrase.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) }

    var body: some View {
        Group {
            switch step {
            case .pick: pick
            case .create: create
            case .importPhrase: importView
            case .hardware: hardware
            case .privyConfirm(let m, let d): privyConfirm(m, d)
            case .working(let t): working(t)
            case .done: done
            }
        }
        .animation(.smooth(duration: 0.25), value: step)
    }

    private func back() { withAnimation(.smooth) { step = .pick; error = nil } }

    private var pick: some View {
        SheetChrome(title: custody == .privy ? "Create Privy wallet" : "Add local wallet") {
            Text(custody == .privy ? "Keyless. Sign in to create and recover it, no seed phrase." : "Keys are created and stored on this device, in the Secure Enclave.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            if custody == .local {
                option("plus", "Create a local wallet", "Next account from your recovery phrase") { step = .create; name = "Wallet \(vm.wallets.count + 1)" }
                option("key.horizontal", "Import with recovery phrase", "12 or 24 words, entered on device only") { step = .importPhrase; name = "Imported" }
                option("externaldrive", "Connect a hardware wallet", "Ledger or Trezor") { step = .hardware; connectLedger() }
            } else {
                option("envelope", "Continue with email", "ryan@hermit.app") { step = .privyConfirm("email", "ryan@hermit.app") }
                optionLogo("gmail", "Continue with Google", "One-tap sign in") { step = .privyConfirm("Google", "ryan@hermit.app") }
                option("apple.logo", "Continue with Apple", "Face ID") { step = .privyConfirm("Apple", "Apple ID, Face ID") }
                option("person.badge.key", "Use a passkey", "No password, no seed phrase") { step = .privyConfirm("passkey", "Passkey in iCloud Keychain") }
            }
            HStack(spacing: 6) {
                Text("Works on").font(.system(size: 12)).foregroundStyle(Theme.faint)
                ChainStack(chains: WalletChain.all, size: 16)
            }
        }
    }

    private func option(_ symbol: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        SelectRow(title: title, subtitle: sub, action: { withAnimation(.smooth) { action() } }) { SymbolTile(symbol: symbol, size: 34) } trailing: {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
        }
    }
    private func optionLogo(_ logo: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        SelectRow(title: title, subtitle: sub, action: { withAnimation(.smooth) { action() } }) { LogoMark(logo, size: 34) } trailing: {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
        }
    }

    private var create: some View {
        SheetChrome(title: "Create a local wallet", onBack: back) {
            FormField(label: "Name") { BoxedTextField(placeholder: "e.g. Savings", text: $name) }
            DetailLines(lines: [("Keys", "Secure Enclave, this device"), ("From", "Your recovery phrase, new account"),
                                ("Addresses", "One EVM, one Solana"), ("Unlock", "Face ID or Touch ID")])
            NoteBox(symbol: "checkmark.shield", text: "Same recovery phrase as your other local wallets, so one backup restores them all.")
        } foot: {
            Button("Create wallet") {
                let n = name.trimmingCharacters(in: .whitespaces)
                run("Creating keys") { try await vm.provider.createLocalWallet(name: n.isEmpty ? "New wallet" : n).0 }
            }
            .buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
        }
    }

    private var importView: some View {
        let n = words.count
        let ok = n == 12 || n == 24
        return SheetChrome(title: "Import recovery phrase", onBack: back) {
            FormField(label: "Recovery phrase", trailing: "\(n) words") {
                TextEditor(text: $phrase)
                    .font(.system(size: 13.5, design: .monospaced)).scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .frame(height: 96).padding(8)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            FormField(label: "Name") { BoxedTextField(placeholder: "Imported", text: $name) }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            NoteBox(symbol: "lock.shield", text: "Your words never leave this device. Hermit derives an EVM address and a Solana address from them.")
        } foot: {
            Button("Import") {
                let (w, nm) = (words, name)
                run("Deriving addresses") { try await vm.provider.importWallet(phrase: w, name: nm.isEmpty ? "Imported" : nm) }
            }
            .buttonStyle(WideButton()).disabled(!ok).keyboardShortcut(.defaultAction)
        }
    }

    private var hardware: some View {
        SheetChrome(title: "Connect a hardware wallet", onBack: back) {
            VStack(spacing: 14) {
                Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.text)
                    .frame(width: 64, height: 64).background(Theme.hover, in: RoundedRectangle(cornerRadius: 18))
                    .symbolEffect(.pulse, options: .repeating)
                Text("Looking for your Ledger").font(.system(size: 15, weight: .medium))
                Text("Plug it in or turn on Bluetooth, unlock it, and open the Ethereum app.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    private func connectLedger() {
        Task {
            if let w = try? await vm.provider.connectHardwareWallet(), step == .hardware { finish(w) }
        }
    }

    private func privyConfirm(_ method: String, _ detail: String) -> some View {
        SheetChrome(title: "Create Privy wallet", onBack: back) {
            VStack(spacing: 12) {
                Image(systemName: "touchid").font(.system(size: 24)).foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                Text("Confirm with \(method == "email" ? "your email" : method)").font(.system(size: 15.5, weight: .semibold))
                Text("Privy creates a wallet only you can sign for. Hermit never sees the key.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.top, 4)
            DetailLines(lines: [("Recovery", detail), ("Chains", "EVM and Solana"), ("Agent spending", "Within your limits")])
        } foot: {
            Button { run("Creating wallet") { try await vm.provider.createKeylessWallet(method: method.capitalized) } } label: {
                Label("Create wallet", systemImage: "touchid")
            }
            .buttonStyle(WideButton(kind: .accent)).keyboardShortcut(.defaultAction)
        }
    }

    private func working(_ text: String) -> some View {
        SheetChrome(title: custody == .privy ? "Create Privy wallet" : "Add local wallet") {
            VStack(spacing: 12) {
                ProgressView()
                Text("\(text)…").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        }
    }

    private var done: some View {
        SheetChrome(title: "Wallet ready") {
            VStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Theme.green, in: Circle())
                    .transition(.scale.combined(with: .opacity))
                Text(created?.name ?? "Wallet").font(.system(size: 16, weight: .semibold))
                Text(created?.source ?? "").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            if let w = created {
                DetailLines(lines: [w.evmAddress.map { ("EVM", shortAddr($0)) }, w.solanaAddress.map { ("Solana", shortAddr($0)) }].compactMap { $0 },
                            monoKeys: ["EVM", "Solana"])
                HStack(spacing: 6) {
                    Text("Ready on").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    ChainStack(chains: w.chains, size: 16)
                }
            }
        } foot: {
            Button("Done") { dismiss() }.buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> WalletAccount) {
        withAnimation(.smooth) { step = .working(label) }
        Task {
            do {
                let w = try await work()
                finish(w)
            } catch {
                self.error = error.localizedDescription
                withAnimation(.smooth) { step = custody == .privy ? .pick : .importPhrase }
            }
        }
    }

    private func finish(_ w: WalletAccount) {
        vm.add(w)
        created = w
        onCreated(w)
        model.toast("\(w.name) added")
        withAnimation(.bouncy) { step = .done }
    }
}
