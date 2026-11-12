import SwiftUI
import HermitCore
import HermitWallet

/// Wallets. A wallet picker, then either every wallet together (Tokens, Gas, Activity, plus DApps and Accounts
/// which aren't connected yet) or one wallet with its addresses, tokens, activity and recovery phrase.
/// Wallets are multichain: one recovery phrase, one EVM address for every EVM chain and one Solana address.
struct WalletsPage: View {
    @Environment(AppModel.self) private var model
    @State private var vm = WalletsViewModel.shared
    @State private var selected = "all"
    @State private var sheet: WalletSheet?
    @State private var removing: WalletAccount?
    @State private var allTab: AllWalletsTab = .tokens
    @State private var width: CGFloat = 900
    /// The sheet waiting for the current one to close. A newer request replaces it, so the last one asked for wins.
    @State private var pendingOpen: Task<Void, Never>?

    var body: some View {
        Page(title: "Wallets", tabs: [(0, "Wallets")], tab: .constant(0)) {
            WalletPicker(vm: vm, selected: $selected, onRemove: { w in removing = w }) { custody in open(.addWallet(custody, start: nil)) }
        } content: { _ in
            Group {
                if !vm.hasWallet {
                    NoWalletView(open: open)
                } else if let w = vm.wallet(selected) {
                    OneWalletView(vm: vm, wallet: w, wide: width > 720, open: open) { removing = w }.id(w.id)
                } else {
                    AllWalletsView(vm: vm, tab: $allTab, wide: width > 720, open: open, pick: { id in withAnimation(.smooth) { selected = id } },
                                   remove: { w in removing = w })
                }
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.25), value: selected)
            .animation(.smooth(duration: 0.25), value: vm.hasWallet)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .sheet(item: $sheet) { s in
            sheetView(s).environment(model).tint(Theme.text)
        }
        .approvalHost(sheetOpen: sheet != nil) { sheet = nil }
        .modifier(RemoveWalletDialog(vm: vm, wallet: $removing))
        .onAppear(perform: readRequest)
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            if DebugLaunch.take("remove"), let w = vm.wallets.first { removing = w }
        }
        #endif
        .onChange(of: model.tabRequest) { _, _ in readRequest() }
        .onChange(of: vm.wallets.map(\.id)) { _, ids in
            if selected != "all" && !ids.contains(selected) { selected = "all" }
            if selected == "all" && ids.count == 1 { selected = ids[0] }
        }
        // With a single wallet, "All wallets" is the same thing with less on it: open that wallet.
        .onAppear { if selected == "all" && vm.wallets.count == 1 { selected = vm.wallets[0].id } }
        .task { if !WalletsViewModel.runningTests { await vm.refresh() } }
    }

    /// Other pages can open a tab (`model.open(.wallets, tab: "gas")`) or a flow
    /// ("send", "receive", "deposit", "transfer", "history", "create", "import").
    private func readRequest() {
        guard model.route == .wallets, let r = model.tabRequest else { return }
        model.tabRequest = nil
        if let t = AllWalletsTab(rawValue: r) { selected = "all"; allTab = t; return }
        switch r {
        case "send": open(.send(from: nil, chain: nil, token: nil))
        case "swap", "bridge":
            // Balances may still be loading (Wallets just opened): decide once they're in, not on an empty list.
            let bridge = r == "bridge"
            Task { @MainActor in
                if vm.hasWallet && !vm.hasFunds && !vm.loaded { await vm.refresh() }
                if vm.hasFunds { open(.swap(from: nil, bridge: bridge, token: nil, chain: nil)) } else { model.fundGoal = .wallet }
            }
        case "quote": open(.tryQuote(from: nil))
        case "fund-any": FundSheet.startAnyChain = true; model.fundGoal = .wallet
        case "security", "policy": vm.openTab = "security"; if let w = vm.wallets.first, vm.wallets.count == 1 { selected = w.id }
        case "agent-swap": if let i = vm.pendingSwap { vm.pendingSwap = nil; open(.agentSwap(i)) }
        case "receive", "deposit": open(.receive(wallet: nil))
        case "transfer": open(.transfer(from: nil))
        case "history": open(.history(wallet: nil))
        case "create", "add": open(.addWallet(.local, start: .create))
        case "import": open(.addWallet(.local, start: .importPhrase))
        default: if vm.wallet(r) != nil { selected = r }
        }
    }

    private var currentWallet: String? { selected == "all" ? vm.firstWalletID : selected }

    /// Opens a sheet; if one is up already, swaps to the new one after it closes. Money sheets need a wallet first.
    private func open(_ s: WalletSheet) {
        var s = s
        pendingOpen?.cancel(); pendingOpen = nil
        if !vm.hasWallet, s.needsWallet {
            // Send won't open, so a Pay now prefill must not wait around for a later, unrelated Send.
            if case .send = s { vm.sendPrefill = nil }
            s = .addWallet(.local, start: nil)
        }
        if case .receive = s { sheet = nil; model.fundGoal = .wallet; return }
        if sheet == nil { sheet = s; return }
        sheet = nil
        pendingOpen = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            sheet = s
        }
    }

    @ViewBuilder private func sheetView(_ s: WalletSheet) -> some View {
        switch s {
        case .send(let from, let chain, let token):
            WalletSendSheet(vm: vm, fromID: from ?? currentWallet ?? "", chain: chain, token: token)
        case .swap(let from, let bridge, let token, let chain):
            SwapSheet(vm: vm, fromID: from ?? currentWallet ?? "", bridge: bridge, token: token, chain: chain)
        case .tryQuote(let from):
            SwapSheet(vm: vm, fromID: from ?? currentWallet ?? "", bridge: true, preview: true)
        case .agentSwap(let i):
            // Prepared by the assistant: the user still reviews and approves. Without funds it can only be previewed.
            SwapSheet(vm: vm, fromID: currentWallet ?? "", bridge: true, preview: !vm.hasFunds, intent: i)
        case .transfer(let from):
            TransferSheet(vm: vm, fromID: from ?? currentWallet ?? "")
        case .receive(let w):
            WalletReceiveSheet(vm: vm, walletID: w ?? currentWallet ?? "", title: w == nil && selected == "all" ? "Deposit" : "Add funds")
        case .history(let w):
            HistorySheet(vm: vm, walletID: w)
        case .token(let g):
            TokenSheet(group: g, vm: vm) { action in
                let best = g.parts.max { $0.amount < $1.amount }
                if action == "send" { open(.send(from: best?.walletID, chain: best?.chain, token: g.symbol)) }
                if action == "receive" { open(.receive(wallet: best?.walletID)) }
                if action == "swap" { open(.swap(from: best?.walletID, bridge: false, token: g.symbol, chain: best?.chain)) }
            }
        case .activity(let a):
            ActivityDetailSheet(item: a, vm: vm)
        case .addWallet(let custody, let start):
            AddWalletSheet(vm: vm, custody: custody, start: start ?? .pick) { w in withAnimation(.smooth) { selected = w.id } }
        case .phrase(let id):
            RecoveryPhraseSheet(vm: vm, walletID: id)
        case .budgets(let id):
            GuardBudgetsSheet(vm: vm, walletID: id, reopen: { open(.budgets(wallet: id)) })
        }
    }
}

enum WalletSheet: Identifiable {
    case send(from: String?, chain: Chain?, token: String?)
    case swap(from: String?, bridge: Bool, token: String?, chain: Chain?)
    case tryQuote(from: String?)
    case agentSwap(SwapIntent)
    case transfer(from: String?)
    case receive(wallet: String?)
    case history(wallet: String?)
    case token(TokenGroup)
    case activity(ActivityItem)
    case addWallet(WalletAccount.Custody, start: AddWalletSheet.Step?)
    case phrase(String)
    case budgets(wallet: String)

    var id: String {
        switch self {
        case .send: "send"
        case .swap: "swap"
        case .tryQuote: "quote"
        case .agentSwap(let i): "agent-\(i.id)"
        case .transfer: "transfer"
        case .receive: "receive"
        case .history: "history"
        case .token(let g): "token-\(g.id)"
        case .activity(let a): "activity-\(a.id)"
        case .addWallet(let c, _): "add-\(c.rawValue)"
        case .phrase(let id): "phrase-\(id)"
        case .budgets: "budgets"
        }
    }

    var needsWallet: Bool {
        switch self { case .send, .swap, .tryQuote, .agentSwap, .transfer, .receive, .phrase, .budgets: true; default: false }
    }
}
