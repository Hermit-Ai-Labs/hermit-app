import SwiftUI
import Observation
import HermitCore
import HermitWallet

/// Which pools Hermit can deposit into from the wallet today: Aave v3 on Ethereum, Base and Arbitrum, for tokens the
/// wallet already knows (USDC, USDT and the like). Other pools keep Ask and their history; they have no Deposit button.
enum EarnRoute {
    static func aave(_ pool: EarnData.Pool) -> (chain: Chain, token: Token)? {
        guard pool.project == "aave-v3" else { return nil }
        let id = pool.chain.lowercased()
        guard let chain = Chain.mainnets.first(where: { $0.id == id }), AaveV3.pool(on: chain) != nil,
              let token = chain.token(pool.symbol) else { return nil }
        return (chain, token)
    }
}

/// The pool whose Deposit sheet is open. EarnPage presents it, so the approval sheet can follow it.
@MainActor @Observable
final class EarnFlow {
    static let shared = EarnFlow()
    var deposit: EarnData.Pool?
}

/// Deposit into an Aave v3 pool: amount from the wallet's balance, then the review screen. Approve + supply are signed
/// on this phone (Face ID) and confirmed one after the other. The deposit earns from the next block and can be withdrawn
/// any time from Earn → Positions.
struct EarnDepositSheet: View {
    let pool: EarnData.Pool
    @Environment(AppModel.self) private var model
    @Environment(\.askApproval) private var ask
    @State private var amount = ""
    @State private var walletID: String
    @State private var busy = false
    @State private var error: String?
    private var vm: WalletsViewModel { .shared }

    init(pool: EarnData.Pool) {
        self.pool = pool
        _walletID = State(initialValue: WalletsViewModel.shared.firstWalletID ?? "")
    }

    private var route: (chain: Chain, token: Token)? { EarnRoute.aave(pool) }
    private var held: Holding? { route.flatMap { vm.holding($0.token.symbol, wallet: walletID, chain: $0.chain) } }
    private var value: Double { AmountText.value(amount) ?? 0 }
    private var canReview: Bool { value > 0 && value <= (held?.amount ?? 0) && !busy && route != nil }

    var body: some View {
        SheetChrome(title: "Deposit \(pool.symbol)", subtitle: "\(pool.name) on \(pool.chainName), \(EarnPoolRow.pct(pool.apy)) APY") {
            if vm.wallets.count > 1 {
                FormField(label: "From") {
                    MenuField(selection: $walletID, options: vm.wallets.map(\.id), title: { vm.wallet($0)?.name ?? $0 },
                              symbol: { vm.wallet($0)?.symbol })
                }
            }
            FormField(label: "Amount", trailing: "\(held?.exact ?? "0") \(pool.symbol) in your wallet") { AmountTextField(text: $amount) }
            WrapRow {
                ForEach([("25%", 0.25), ("50%", 0.5)], id: \.0) { q in
                    SelectChip(title: q.0, on: amount == fractionText(held, q.1) && (held?.amount ?? 0) > 0) { amount = fractionText(held, q.1) }
                }
                SelectChip(title: "Max", on: amount == (held?.exact ?? "") && (held?.amount ?? 0) > 0) { amount = held?.exact ?? "0" }
            }
            if (held?.amount ?? 0) == 0 {
                NoteBox(symbol: "arrow.down.to.line", text: "You have no \(pool.symbol) on \(pool.chainName) yet. Add some from Wallets first.")
            } else if value > (held?.amount ?? 0) {
                Text("Only \(held?.exact ?? "0") \(pool.symbol) in this wallet.").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            NoteBox(symbol: "info.circle", text: "Aave is a lending protocol: your \(pool.symbol) is lent out and earns the variable rate. "
                    + "Withdraw any time from Earn, Positions. Smart-contract risk applies.")
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            if (held?.amount ?? 0) == 0 {
                Button("Add \(pool.symbol)") {
                    let goal = route.map { FundGoal.token($0.chain, $0.token.symbol) } ?? .wallet
                    EarnFlow.shared.deposit = nil
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); model.fundGoal = goal }
                }
                .buttonStyle(WideButton())
            } else {
                Button { Task { await review() } } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(busy ? "Checking" : "Review")
                    }
                }
                .buttonStyle(WideButton()).disabled(!canReview)
            }
        }
    }

    private func review() async {
        guard let (chain, token) = route, let w = vm.wallet(walletID), let pool = AaveV3.pool(on: chain),
              let owner = EVMAddress(w.record.evmAddress) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let amt = try Units.parse(amount, decimals: token.decimals)
            let allowance = try await vm.service.allowance(chain: chain, token: EVMAddress(token.address)!, owner: owner, spender: pool)
            let calls = AaveV3.supplyCalls(token: token, amount: amt, owner: owner, pool: pool, allowance: allowance)
            let svc = vm.service, wid = w.record.id
            let a = Approval(kind: "Deposit on \(chain.name)", title: "Deposit \(amount) \(token.symbol) into Aave",
                             lines: [["Pool", "Aave v3, \(chain.name)"], ["Amount", "\(amount) \(token.symbol)"],
                                     ["Rate now", "\(EarnPoolRow.pct(self.pool.apy)) APY, variable"],
                                     ["Steps", calls.count == 2 ? "Allow, then deposit (two Face ID prompts)" : "Deposit"],
                                     ["Contract", short(pool.checksummed)]],
                             checks: ["Each step is simulated before it's signed", "Signed on this phone with your wallet's key"],
                             success: "Deposited \(amount) \(token.symbol)") {
                try await svc.executeCalls(walletID: wid, chain: chain, calls).last ?? ""
            }
            ask(a) { Task { await vm.refresh() } }
        } catch {
            self.error = (error as? WalletError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func short(_ a: String) -> String { a.count > 12 ? "\(a.prefix(6))…\(a.suffix(4))" : a }
}
