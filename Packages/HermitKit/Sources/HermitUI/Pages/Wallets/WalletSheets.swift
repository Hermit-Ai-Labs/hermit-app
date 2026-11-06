import SwiftUI
import HermitCore
import HermitWallet

/// Sends made from this device, filterable by network; each row opens its receipt.
struct HistorySheet: View {
    let vm: WalletsViewModel
    let walletID: String?
    @State private var chain: Chain?
    @State private var detail: ActivityItem?

    var body: some View {
        if let detail {
            ActivityDetailSheet(item: detail, vm: vm) { withAnimation(.smooth) { self.detail = nil } }
        } else {
            let items = vm.activity(wallet: walletID, chain: chain)
            SheetChrome(title: "History", subtitle: walletID.flatMap { vm.wallet($0)?.name } ?? "All wallets", width: 540) {
                HStack {
                    Text("Sends from this device").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    Spacer()
                    ChainFilter(chain: $chain)
                }
                if items.isEmpty { EmptyNote(text: "Nothing sent from Hermit yet.").frame(maxWidth: .infinity) }
                RowList(items: items) { a in
                    ActivityRow(item: a, wallet: walletID == nil ? vm.wallet(a.walletID)?.name : nil) { withAnimation(.smooth) { detail = a } }
                }
                ExplorerLinks(vm: vm, walletID: walletID, chain: chain)
            }
            .animation(.smooth(duration: 0.22), value: chain)
        }
    }
}

/// One transaction's receipt, with the real hash and explorer link.
struct ActivityDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: ActivityItem
    let vm: WalletsViewModel
    var onBack: (() -> Void)? = nil

    var body: some View {
        SheetChrome(title: item.what, onBack: onBack) {
            HStack(spacing: 12) {
                Text(item.amountText).font(.system(size: 28, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Spacer()
                PillTag(text: "Confirmed", color: Theme.green, dot: true)
            }
            DetailLines(lines: [("Network", item.chain.name + (item.chain.isTestnet ? " (testnet)" : "")),
                                ("Wallet", vm.wallet(item.walletID)?.name ?? ""), ("To", shortAddr(item.entry.recipient)),
                                ("When", item.entry.date.formatted(date: .abbreviated, time: .shortened)), ("Tx", shortAddr(item.tx))],
                        monoKeys: ["Tx", "To"])
        } foot: {
            Button("Copy hash") { Clip.copy(item.tx); model.toast("Transaction hash copied") }.buttonStyle(WideButton(kind: .plain))
            Button("View on explorer") { if let u = item.explorer { openURL(u) } }
                .buttonStyle(WideButton()).disabled(item.explorer == nil)
        }
    }
}

/// A token: value, price, where it sits (wallet and network), and Send. Swap, Bridge and Earn aren't connected yet.
struct TokenSheet: View {
    let group: TokenGroup
    let vm: WalletsViewModel
    let onAction: (String) -> Void

    var body: some View {
        SheetChrome(title: group.symbol, subtitle: group.name + (group.testnet ? " (testnet)" : ""), width: 540) {
            HStack(spacing: 12) {
                TokenLogo(symbol: group.symbol, chain: group.chains.count == 1 ? group.chains[0] : nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.priced ? MoneyFmt.usd(group.usd, digits: 2) : "\(MoneyFmt.amount(group.amount)) \(group.symbol)")
                        .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Group {
                        if group.priced, let ch = group.change {
                            Text("\(MoneyFmt.pct(ch)) in 24h, \(MoneyFmt.amount(group.amount)) \(group.symbol)").foregroundStyle(ch >= 0 ? Theme.green : Theme.red)
                        } else {
                            Text(group.testnet ? "Testnet coins have no value" : "No price right now").foregroundStyle(Theme.muted)
                        }
                    }
                    .font(.system(size: 12.5))
                }
                Spacer()
                if let p = group.price {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Price").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        Text(p < 0.01 ? "$" + p.formatted(.number.precision(.significantDigits(3))) : MoneyFmt.usd(p, digits: 2))
                            .font(.system(size: 13.5)).monospacedDigit()
                    }
                }
            }
            HStack(spacing: 0) {
                RoundAction(title: "Send", symbol: "arrow.up.right") { onAction("send") }.frame(maxWidth: .infinity)
                ForEach([("Swap", "arrow.left.arrow.right"), ("Bridge", "point.3.connected.trianglepath.dotted"), ("Earn", "leaf")], id: \.0) { a in
                    RoundAction(title: a.0, symbol: a.1) {}.frame(maxWidth: .infinity).notYet("\(a.0) isn't available in the wallet yet")
                }
            }
            SectionLabel("Where it is")
            RowList(items: group.parts.sorted { $0.amount > $1.amount }) { h in
                HStack(spacing: 10) {
                    LogoMark(h.chain.logo, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.wallet(h.walletID)?.name ?? "Wallet").font(.system(size: 13.5, weight: .medium))
                        Text(h.chain.name).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(MoneyFmt.value(h)).font(.system(size: 13.5)).monospacedDigit()
                        Text("\(h.exact) \(h.symbol)").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                .padding(.vertical, 8)
            }
            Text("Prices from CoinGecko.").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
        }
    }
}

// MARK: Recovery phrase

/// The words in a numbered grid. Never copied to the clipboard.
struct PhraseGrid: View {
    let words: [String]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 11.5)).foregroundStyle(Theme.faint).monospacedDigit().frame(width: 18, alignment: .trailing)
                    Text(w).font(.system(size: 13.5, design: .monospaced))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            }
        }
        .privacySensitive()
    }
}

/// Shows a wallet's recovery phrase after Touch ID / Face ID, and lets the user mark it backed up.
struct RecoveryPhraseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vm: WalletsViewModel
    let walletID: String
    @State private var words: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let w = vm.wallet(walletID)
        SheetChrome(title: "Recovery phrase", subtitle: w?.name) {
            if words.isEmpty {
                NoteBox(symbol: "eye.slash", text: "Anyone who sees these words can take everything in this wallet. Make sure no one is watching your screen.", tint: Theme.amber)
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            } else {
                PhraseGrid(words: words)
                NoteBox(symbol: "pencil", text: "Write the words down in order and keep them offline. Hermit can't recover them for you.")
            }
        } foot: {
            if words.isEmpty {
                Button { reveal() } label: {
                    HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text("Reveal") }
                }
                .buttonStyle(WideButton()).disabled(busy).keyboardShortcut(.defaultAction)
            } else if w?.backedUp == false {
                Button("I wrote it down") { vm.markBackedUp(walletID); words = []; model.toast("Marked as backed up"); dismiss() }
                    .buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { words = []; dismiss() }.buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
            }
        }
        .onDisappear { words = [] }
    }

    private func reveal() {
        busy = true; error = nil
        Task {
            do { words = try await vm.recoveryPhrase(walletID) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

// MARK: Add wallet

/// Add a wallet: create one (shows the recovery phrase once, then a short check), or import a phrase.
/// Hardware wallets and keyless (Privy) wallets aren't available yet and are shown greyed out.
struct AddWalletSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vm: WalletsViewModel
    let custody: WalletAccount.Custody
    let onCreated: (WalletAccount) -> Void

    enum Step: Equatable { case pick, create, importPhrase, backup, quiz, done }
    @State private var step: Step
    @State private var name = ""
    @State private var phrase = ""
    @State private var created: WalletAccount?
    @State private var newWords: [String] = []
    @State private var quiz: [Int] = []
    @State private var answers = ["", ""]
    @State private var error: String?
    @State private var busy = false

    init(vm: WalletsViewModel, custody: WalletAccount.Custody, start: Step = .pick, onCreated: @escaping (WalletAccount) -> Void) {
        self.vm = vm; self.custody = custody; self.onCreated = onCreated
        _step = State(initialValue: custody == .privy ? .pick : start)
        _name = State(initialValue: start == .importPhrase ? "Imported" : "Wallet \(vm.wallets.count + 1)")
    }

    private var typedWords: [String] { phrase.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) }

    var body: some View {
        Group {
            switch step {
            case .pick: custody == .privy ? AnyView(privy) : AnyView(pick)
            case .create: create
            case .importPhrase: importView
            case .backup: backup
            case .quiz: quizView
            case .done: done
            }
        }
        .animation(.smooth(duration: 0.25), value: step)
        .onDisappear { newWords = []; phrase = "" }
    }

    private func back() { withAnimation(.smooth) { step = .pick; error = nil } }

    private var pick: some View {
        SheetChrome(title: "Add local wallet") {
            Text("Keys are created and kept on this device, sealed by the Secure Enclave.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            option("plus", "Create a new wallet", "New 12-word recovery phrase") { step = .create; name = "Wallet \(vm.wallets.count + 1)" }
            option("key.horizontal", "Import with recovery phrase", "12 or 24 words, entered on this device only") { step = .importPhrase; name = "Imported" }
            option("externaldrive", "Connect a hardware wallet", "Ledger or Trezor, not supported yet") {}
                .notYet("Hardware wallets aren't supported yet")
            HStack(spacing: 6) {
                Text("Works on").font(.system(size: 12)).foregroundStyle(Theme.faint)
                ChainStack(chains: Chain.mainnets, size: 16)
            }
        }
    }

    private var privy: some View {
        SheetChrome(title: "Keyless wallets") {
            Text("Keyless wallets (sign in with email, Google, Apple or a passkey) aren't available yet. Create a local wallet instead.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Group {
                option("envelope", "Continue with email", "Not available yet") {}
                option("apple.logo", "Continue with Apple", "Not available yet") {}
                option("person.badge.key", "Use a passkey", "Not available yet") {}
            }
            .notYet("Keyless wallets aren't available yet")
        } foot: {
            Button("Close") { dismiss() }.buttonStyle(WideButton(kind: .plain))
        }
    }

    private func option(_ symbol: String, _ title: String, _ sub: String, _ action: @escaping () -> Void) -> some View {
        SelectRow(title: title, subtitle: sub, action: { withAnimation(.smooth) { action() } }) { WalletSymbolTile(symbol: symbol, size: 34) } trailing: {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
        }
    }

    private var create: some View {
        SheetChrome(title: "Create a wallet", onBack: back) {
            FormField(label: "Name") { BoxedTextField(placeholder: "e.g. Savings", text: $name) }
            DetailLines(lines: [("Keys", vm.service.vault.protection.label), ("Recovery phrase", "12 new words"),
                                ("Addresses", "One EVM, one Solana"), ("Unlock", "Touch ID, Face ID or password")])
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            NoteBox(symbol: "checkmark.shield", text: "Next you'll see the recovery phrase once. Write it down: it is the only way to restore this wallet.")
        } foot: {
            Button("Create wallet") {
                let n = name.trimmingCharacters(in: .whitespaces)
                do {
                    let (w, words) = try vm.createWallet(name: n.isEmpty ? "Wallet" : n)
                    created = w; newWords = words; error = nil
                    onCreated(w)
                    withAnimation(.smooth) { step = .backup }
                } catch { self.error = error.localizedDescription }
            }
            .buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
        }
    }

    private var backup: some View {
        SheetChrome(title: "Write down your recovery phrase") {
            NoteBox(symbol: "eye.slash", text: "These 12 words are the wallet. Anyone with them can take its money, and Hermit can't show them again without your Touch ID or password.", tint: Theme.amber)
            PhraseGrid(words: newWords)
        } foot: {
            Button("Later") { finish(backedUp: false) }.buttonStyle(WideButton(kind: .plain))
            Button("I wrote it down") {
                quiz = Array((0..<newWords.count).shuffled().prefix(2)).sorted(); answers = ["", ""]; error = nil
                withAnimation(.smooth) { step = .quiz }
            }
            .buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
        }
    }

    private var quizView: some View {
        SheetChrome(title: "Check your backup", onBack: { withAnimation(.smooth) { step = .backup } }) {
            Text("Type these two words from what you wrote down.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            ForEach(Array(quiz.enumerated()), id: \.offset) { i, n in
                FormField(label: "Word \(n + 1)") { BoxedTextField(placeholder: "word \(n + 1)", text: $answers[i], mono: true) }
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
        } foot: {
            Button("Confirm") {
                let ok = quiz.enumerated().allSatisfy { i, n in answers[i].trimmingCharacters(in: .whitespaces).lowercased() == newWords[n] }
                if ok { finish(backedUp: true) } else { error = "That doesn't match. Check the words and try again." }
            }
            .buttonStyle(WideButton()).disabled(answers.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }).keyboardShortcut(.defaultAction)
        }
    }

    private var importView: some View {
        let n = typedWords.count
        let ok = n == 12 || n == 15 || n == 18 || n == 21 || n == 24
        return SheetChrome(title: "Import recovery phrase", onBack: back) {
            FormField(label: "Recovery phrase", trailing: "\(n) words") {
                TextEditor(text: $phrase)
                    .font(.system(size: 13.5, design: .monospaced)).scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .privacySensitive()
                    .frame(height: 96).padding(8)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
            FormField(label: "Name") { BoxedTextField(placeholder: "Imported", text: $name) }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            NoteBox(symbol: "lock.shield", text: "Your words never leave this device. Hermit derives an EVM address (m/44'/60'/0'/0/0) and a Solana address (m/44'/501'/0'/0') from them, like MetaMask and Phantom.")
        } foot: {
            Button("Import") {
                let nm = name.trimmingCharacters(in: .whitespaces)
                do {
                    let w = try vm.importWallet(words: typedWords, name: nm.isEmpty ? "Imported" : nm)
                    phrase = ""; created = w; error = nil
                    onCreated(w)
                    model.toast("\(w.name) imported")
                    withAnimation(.bouncy) { step = .done }
                } catch { self.error = error.localizedDescription }
            }
            .buttonStyle(WideButton()).disabled(!ok).keyboardShortcut(.defaultAction)
        }
    }

    private var done: some View {
        SheetChrome(title: "Wallet ready") {
            VStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(Theme.green, in: Circle())
                    .transition(.scale.combined(with: .opacity))
                Text(created?.name ?? "Wallet").font(.system(size: 16, weight: .semibold))
                Text(created?.protection ?? "").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            if let w = created {
                DetailLines(lines: [w.evmAddress.map { ("EVM", shortAddr($0)) }, w.solanaAddress.map { ("Solana", shortAddr($0)) }].compactMap { $0 },
                            monoKeys: ["EVM", "Solana"])
                if !w.backedUp && !(vm.wallet(w.id)?.backedUp ?? false) {
                    NoteBox(symbol: "exclamationmark.triangle", text: "Not backed up yet. You can show the phrase again from the wallet's Security tab.", tint: Theme.amber)
                }
            }
        } foot: {
            Button("Done") { dismiss() }.buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
        }
    }

    private func finish(backedUp: Bool) {
        if backedUp, let w = created { vm.markBackedUp(w.id) }
        newWords = []; answers = ["", ""]
        if let w = created { model.toast("\(w.name) created") }
        withAnimation(.bouncy) { step = .done }
    }
}
