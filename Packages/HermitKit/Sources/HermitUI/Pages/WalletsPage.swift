import SwiftUI
import HermitCore

/// Wallets (demo: Portfolio.jsx). A Binance-style wallet picker, then either every wallet together
/// (Tokens, DApps, Gas, Activity, Accounts) or one wallet with its addresses and what it funds.
/// Wallets are multichain: one recovery phrase, one EVM address for every EVM chain and one Solana address.
struct WalletsPage: View {
    @Environment(AppModel.self) private var model
    @State private var vm = WalletsViewModel.shared
    @State private var selected = "all"
    @State private var sheet: WalletSheet?
    @State private var allTab: AllWalletsTab = .tokens
    @State private var width: CGFloat = 900

    var body: some View {
        Page(title: "Wallets", tabs: [(0, "Wallets")], tab: .constant(0)) {
            WalletPicker(vm: vm, selected: $selected) { custody in open(.addWallet(custody)) }
        } content: { _ in
            Group {
                if let w = vm.wallet(selected) {
                    OneWalletView(vm: vm, wallet: w, wide: width > 720, open: open).id(w.id)
                } else {
                    AllWalletsView(vm: vm, tab: $allTab, wide: width > 720, open: open)
                }
            }
            .transition(.opacity)
            .animation(.smooth(duration: 0.25), value: selected)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .sheet(item: $sheet) { s in
            sheetView(s).environment(model).tint(Theme.text)
        }
        .approvalHost(sheetOpen: sheet != nil) { sheet = nil }
        .onAppear(perform: readRequest)
        .onChange(of: model.tabRequest) { _, _ in readRequest() }
    }

    /// Other pages can open a tab (`model.open(.wallets, tab: "gas")`) or a flow ("send", "receive", "bridge", "history").
    private func readRequest() {
        guard model.route == .wallets, let r = model.tabRequest else { return }
        model.tabRequest = nil
        if let t = AllWalletsTab(rawValue: r) { selected = "all"; allTab = t; return }
        switch r {
        case "send": open(.send(from: nil, chain: nil, token: nil))
        case "receive", "deposit": open(.receive(wallet: nil))
        case "bridge": open(.bridge(token: nil))
        case "transfer": open(.transfer(from: nil))
        case "history": open(.history(wallet: nil))
        default: if vm.wallet(r) != nil { selected = r }
        }
    }

    /// Opens a sheet; if one is up already, swaps to the new one after it closes.
    private func open(_ s: WalletSheet) {
        if sheet == nil { sheet = s; return }
        sheet = nil
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(380)); sheet = s }
    }

    @ViewBuilder private func sheetView(_ s: WalletSheet) -> some View {
        switch s {
        case .send(let from, let chain, let token):
            WalletSendSheet(vm: vm, fromID: from ?? (selected == "all" ? "main" : selected), chain: chain, token: token)
        case .transfer(let from):
            TransferSheet(vm: vm, fromID: from ?? (selected == "all" ? "main" : selected))
        case .receive(let w):
            WalletReceiveSheet(vm: vm, walletID: w ?? (selected == "all" ? "main" : selected), title: w == nil && selected == "all" ? "Deposit" : "Add funds")
        case .bridge(let token):
            BridgeSheet(vm: vm, walletID: selected == "all" ? "main" : selected, token: token ?? "USDC")
        case .history(let w):
            HistorySheet(vm: vm, walletID: w)
        case .token(let g):
            TokenSheet(group: g, vm: vm) { action in
                switch action {
                case "send": open(.send(from: g.parts.max { $0.usd < $1.usd }?.walletID, chain: g.parts.max { $0.usd < $1.usd }?.chain, token: g.symbol))
                case "bridge": open(.bridge(token: g.symbol))
                case "swap": sheet = nil; model.open(.trade)
                default: sheet = nil; model.open(.earn)
                }
            }
        case .activity(let a):
            ActivityDetailSheet(item: a, vm: vm)
        case .addWallet(let custody):
            AddWalletSheet(vm: vm, custody: custody) { w in withAnimation(.smooth) { selected = w.id } }
        case .gasTopUp(let c):
            GasTopUpSheet(vm: vm, chain: c)
        case .gasWithdraw(let c):
            GasWithdrawSheet(vm: vm, chain: c)
        case .connect(let app):
            ConnectAppSheet(app: app) { withAnimation(.snappy) { _ = vm.linked.insert(app) } }
        }
    }
}

enum WalletSheet: Identifiable {
    case send(from: String?, chain: WalletChain?, token: String?)
    case transfer(from: String?)
    case receive(wallet: String?)
    case bridge(token: String?)
    case history(wallet: String?)
    case token(TokenGroup)
    case activity(ActivityItem)
    case addWallet(WalletAccount.Custody)
    case gasTopUp(WalletChain), gasWithdraw(WalletChain)
    case connect(String)

    var id: String {
        switch self {
        case .send: "send"
        case .transfer: "transfer"
        case .receive: "receive"
        case .bridge: "bridge"
        case .history: "history"
        case .token(let g): "token-\(g.id)"
        case .activity(let a): "activity-\(a.id)"
        case .addWallet(let c): "add-\(c.rawValue)"
        case .gasTopUp(let c): "topup-\(c.id)"
        case .gasWithdraw(let c): "withdraw-\(c.id)"
        case .connect(let a): "connect-\(a)"
        }
    }
}
