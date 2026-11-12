import SwiftUI
import HermitCore
import HermitWallet

/// Withdraw USDC from Hyperliquid to this wallet's own address on Arbitrum. The amount is checked against a fresh read of
/// the account (HermitWallet's `withdrawReview`), then the review and Face ID follow on the approval sheet.
struct HyperliquidWithdrawSheet: View {
    @Environment(\.askApproval) private var ask
    @State private var amount = ""
    @State private var busy = false
    @State private var error: String?
    private var hl: HyperliquidStore { .shared }

    private var account: Hyperliquid.Account? { hl.account }
    private var free: Double { account?.withdrawable ?? 0 }
    private var value: Decimal? { Hyperliquid.parseUSDC(AmountText.clean(amount)) }
    private var fee: Decimal { Hyperliquid.withdrawFee }
    private var canReview: Bool {
        guard let v = value, !busy, account != nil else { return false }
        return v > fee
    }
    /// Free USDC cut to 6 decimals, rounded down so Max never asks for a hair more than there is.
    private var maxText: String {
        Hyperliquid.usdcText(dec((free * 1e6).rounded(.down) / 1e6))
    }
    private func part(_ share: Double) -> String {
        Hyperliquid.usdcText(dec((free * share * 1e6).rounded(.down) / 1e6))
    }
    /// A Double from the API as a Decimal, through its 6-decimal text (Decimal(Double) carries binary noise).
    private func dec(_ x: Double) -> Decimal { Decimal(string: String(format: "%.6f", x), locale: Locale(identifier: "en_US_POSIX")) ?? 0 }

    var body: some View {
        SheetChrome(title: "Withdraw USDC", subtitle: "From Hyperliquid to your wallet on Arbitrum") {
            FormField(label: "Amount", trailing: account == nil ? "Reading your balance" : "\(Hyperliquid.usdcText(dec(free))) USDC available") {
                AmountTextField(text: $amount)
            }
            WrapRow {
                SelectChip(title: "25%", on: amount == part(0.25) && free > 0) { amount = part(0.25) }
                SelectChip(title: "50%", on: amount == part(0.5) && free > 0) { amount = part(0.5) }
                SelectChip(title: "Max", on: amount == maxText && free > 0) { amount = maxText }
            }
            DetailLines(lines: [("Fee", "\(Hyperliquid.usdcText(fee)) USDC"),
                                ("You get about", value.map { $0 > fee ? "\(Hyperliquid.usdcText($0 - fee)) USDC on Arbitrum" : "Nothing" } ?? "—"),
                                ("Arrives", "In about \(Hyperliquid.withdrawMinutes) minutes")])
            if let v = value, account != nil, v > dec(free) {
                Text("You can withdraw up to \(maxText) USDC.").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            } else if let v = value, v <= fee {
                Text("Hyperliquid charges \(Hyperliquid.usdcText(fee)) USDC per withdrawal. Withdraw more than that.").font(.system(size: 12.5)).foregroundStyle(Theme.red)
            }
            if (account?.positions.contains { $0.size != 0 }) == true {
                NoteBox(symbol: "exclamationmark.triangle", text: "Your open positions keep their margin. Only free margin can be withdrawn, and taking out most of it leaves less room before a position is closed.")
            }
            NoteBox(symbol: "arrow.down.to.line", text: "USDC goes to your own address on Arbitrum. Hyperliquid takes \(Hyperliquid.usdcText(fee)) USDC and it usually arrives in about \(Hyperliquid.withdrawMinutes) minutes.")
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button { Task { await review() } } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(.white) }
                    Text(busy ? "Checking" : "Review")
                }
            }
            .buttonStyle(WideButton()).disabled(!canReview)
        }
        .task { await hl.refresh() }
    }

    private func review() async {
        guard let trader = hl.trader() else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            // A fresh read, so the limit is what Hyperliquid says now, not what the page showed a few seconds ago.
            let live = try await Hyperliquid.account(trader.ownAddress)
            let r = try Hyperliquid.withdrawReview(walletID: trader.walletID, ownAddress: trader.ownAddress, amount: AmountText.clean(amount), account: live)
            guard r.canSend else { error = r.blockingReason; return }
            ask(HyperliquidWithdrawText.approval(r, trader: trader)) { }
        } catch {
            self.error = HyperliquidWithdrawText.message(error)
        }
    }
}

enum HyperliquidWithdrawText {
    static func message(_ e: Error) -> String {
        if case WalletError.invalidAmount = e { return "Enter an amount with up to 6 decimals." }
        if e is URLError { return "Couldn't reach Hyperliquid. Try again." }
        return (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
    }

    /// The approval sheet for a checked withdrawal. Approve signs it on this device (Face ID) and posts it to Hyperliquid.
    /// It goes to the wallet's own address, so it is not a spend: the spending limits do not count it.
    @MainActor static func approval(_ r: Hyperliquid.WithdrawReview, trader: HyperliquidTrader, label: String? = nil) -> Approval {
        let vm = WalletsViewModel.shared
        var lines: [[String]] = []
        if vm.wallets.count > 1, let name = vm.wallet(r.walletID.uuidString)?.name { lines.append(["Wallet", name]) }
        lines += [["From", "Your Hyperliquid account"], ["Amount", "\(r.amountText) USDC"], ["Fee", "\(Hyperliquid.usdcText(r.fee)) USDC"],
                  ["You get", "About \(r.receiveText) USDC on Arbitrum"], ["To", "Your own address (\(shortAddr(r.destination)))"],
                  ["Arrives", "In about \(Hyperliquid.withdrawMinutes) minutes"]]
        if let label { lines.append(["Asked for by", "\(label), from your message"]) }
        let checks = r.checks.filter { $0.status == .pass }.map(\.title)
        let warnings = r.checks.filter { $0.status == .warn }.map { "\($0.title): \($0.detail)" }
        return Approval(kind: "Withdraw from Hyperliquid", title: "Withdraw \(r.amountText) USDC from Hyperliquid", lines: lines,
                        checks: checks + ["Signed on \(Device.here) with your wallet's key"], success: "Withdrawal sent", warnings: warnings) {
            let line = try await trader.withdraw(r)
            Task { @MainActor in HyperliquidStore.shared.startWithdrawal(r) }
            return line
        }
    }
}

/// Where a withdrawal stands, under the account summary: waiting for the balance to drop, on its way, arrived.
struct HyperliquidWithdrawStatus: View {
    private var hl: HyperliquidStore { .shared }

    var body: some View {
        if let w = hl.withdrawal {
            HStack(alignment: .top, spacing: 10) {
                switch w.phase {
                case .waiting: ProgressView().controlSize(.small)
                case .onTheWay: Image(systemName: "clock").foregroundStyle(Theme.muted)
                case .arrived: Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(w)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                    Text(detail(w)).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if w.phase != .waiting {
                    Button { hl.dismissWithdrawal() } label: { Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Theme.hint) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func title(_ w: HyperliquidStore.Withdrawal) -> String {
        switch w.phase {
        case .waiting: "Sending your withdrawal"
        case .onTheWay: "Withdrawal on its way"
        case .arrived: "Withdrawal arrived"
        }
    }

    private func detail(_ w: HyperliquidStore.Withdrawal) -> String {
        let amt = Hyperliquid.usdcText(Decimal(string: String(format: "%.6f", w.receive)) ?? 0)
        switch w.phase {
        case .waiting: return "Waiting for Hyperliquid to take \(Hyperliquid.usdcText(Decimal(string: String(format: "%.6f", w.amount)) ?? 0)) USDC off your balance."
        case .onTheWay: return "About \(amt) USDC reaches your wallet on Arbitrum in about \(Hyperliquid.withdrawMinutes) minutes. Wallets updates when it lands."
        case .arrived: return "\(amt) USDC is in your wallet on Arbitrum."
        }
    }
}
