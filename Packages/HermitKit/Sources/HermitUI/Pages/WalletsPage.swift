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
        case "swap": if vm.hasFunds { open(.swap(from: nil, bridge: false, token: nil, chain: nil)) } else { model.fundGoal = .wallet }
        case "bridge": if vm.hasFunds { open(.swap(from: nil, bridge: true, token: nil, chain: nil)) } else { model.fundGoal = .wallet }
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
        if !vm.hasWallet, s.needsWallet { s = .addWallet(.local, start: nil) }
        if case .receive = s { sheet = nil; model.fundGoal = .wallet; return }
        if sheet == nil { sheet = s; return }
        sheet = nil
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(380)); sheet = s }
    }

    @ViewBuilder private func sheetView(_ s: WalletSheet) -> some View {
        switch s {
        case .send(let from, let chain, let token):
            WalletSendSheet(vm: vm, fromID: from ?? currentWallet ?? "", chain: chain, token: token)
        case .swap(let from, let bridge, let token, let chain):
            SwapSheet(vm: vm, fromID: from ?? currentWallet ?? "", bridge: bridge, token: token, chain: chain)
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
        }
    }
}

enum WalletSheet: Identifiable {
    case send(from: String?, chain: Chain?, token: String?)
    case swap(from: String?, bridge: Bool, token: String?, chain: Chain?)
    case transfer(from: String?)
    case receive(wallet: String?)
    case history(wallet: String?)
    case token(TokenGroup)
    case activity(ActivityItem)
    case addWallet(WalletAccount.Custody, start: AddWalletSheet.Step?)
    case phrase(String)

    var id: String {
        switch self {
        case .send: "send"
        case .swap: "swap"
        case .transfer: "transfer"
        case .receive: "receive"
        case .history: "history"
        case .token(let g): "token-\(g.id)"
        case .activity(let a): "activity-\(a.id)"
        case .addWallet(let c, _): "add-\(c.rawValue)"
        case .phrase(let id): "phrase-\(id)"
        }
    }

    var needsWallet: Bool {
        switch self { case .send, .swap, .transfer, .receive, .phrase: true; default: false }
    }
}
