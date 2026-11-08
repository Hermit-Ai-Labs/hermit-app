#if DEBUG
import SwiftUI
import HermitCore
import HermitWallet

/// Debug builds only: launch arguments that open a sheet or scroll a page, for the simulator screenshots
/// (scripts/phone-shots.sh). Never compiled into Release.
///   -hermitSheet <name>   opens one sheet once (see `DebugLaunch.Sheet` for the names)
///   -hermitScroll bottom  scrolls the page to its end; a number scrolls to that y offset
@MainActor
enum DebugLaunch {
    private static var used: Set<String> = []
    static var sheet: String? { UserDefaults.standard.string(forKey: "hermitSheet") }
    static var scroll: String? { UserDefaults.standard.string(forKey: "hermitScroll") }

    /// True once, for the view that owns the sheet called `name`.
    static func take(_ name: String) -> Bool {
        guard sheet == name, !used.contains(name) else { return false }
        used.insert(name)
        return true
    }

    /// Sheets RootView owns: the approval sheet, Add funds, the live swap status.
    static func applyRoot(_ model: AppModel) {
        guard let s = sheet else { return }
        switch s {
        case "approval":
            guard take(s) else { return }
            model.approval = Approval(
                kind: "Send on Base", title: "Send 25 USDC",
                lines: [["From", "Test wallet"], ["To", shortAddr("0x8c3F2b9A41D0e7C5a96B1f2E4d3C0a9B8e7D6c51")], ["Amount", "25 USDC"],
                        ["Network fee", "$0.01"], ["Arrives", "Under a minute"]],
                checks: Approval.checks(["Recipient is not a known scam address"]), success: "Sent 25 USDC",
                warnings: ["First payment to \(shortAddr("0x8c3F2b9A41D0e7C5a96B1f2E4d3C0a9B8e7D6c51")). Check it character by character.",
                           "This send is $25 of your $100 daily limit for the assistant."])
        case "fund", "fund-wallet": if take(s) { model.fundGoal = .wallet }
        case "fund-any": if take(s) { FundSheet.startAnyChain = true; model.fundGoal = .wallet }
        case "fund-hyperliquid": if take(s) { model.fundGoal = .hyperliquid }
        case "status-pending", "status-processing", "status-success", "status-refunded", "status-failed", "status-incomplete":
            guard take(s) else { return }
            IntentsActivity.shared.debugFixture(String(s.dropFirst("status-".count)))
        default: break
        }
    }
}

extension IntentsActivity {
    /// A swap in a given state with no network: the status sheet's look in pending, processing, success, refunded,
    /// failed and incomplete.
    func debugFixture(_ which: String) {
        let status: IntentsStatus = switch which {
        case "processing": .processing
        case "success": .success
        case "refunded": .refunded
        case "failed": .failed
        case "incomplete": .incompleteDeposit
        default: .pendingDeposit
        }
        let deposit = "0x5f1E8c42A9d07b3C6e2F1a0D9c8B7a6E5d4C3b2A"
        let swap = TrackedSwap(depositAddress: deposit, depositMemo: nil, walletID: nil, from: "10 USDC on Base", to: "about 4.1 NEAR on NEAR",
                               fromChainID: "base", toPlaceName: "NEAR", created: Date().addingTimeInterval(-90),
                               deadline: Date().addingTimeInterval(600),
                               txHash: status == .pendingDeposit ? nil : "0x9a7c4e1b2d3f5a6c8e0b1d2f4a6c8e0b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c",
                               status: status)
        var details: [String: JSON] = [:]
        if status != .pendingDeposit {
            details["originChainTxHashes"] = .array([.object(["hash": .string(swap.txHash ?? ""), "explorerUrl": .string("https://basescan.org/tx/\(swap.txHash ?? "")")])])
        }
        if [.processing, .success, .refunded, .failed].contains(status) { details["nearTxHashes"] = .array([.string("8kQ3"), .string("9mR4")]) }
        if status == .success {
            details["amountOutFormatted"] = .string("4.128734912")
            details["destinationChainTxHashes"] = .array([.object(["hash": .string("Fq7m2"), "explorerUrl": .string("https://nearblocks.io/txns/Fq7m2")])])
        }
        if status == .refunded { details["refundedAmountFormatted"] = .string("10"); details["refundReason"] = .string("DEADLINE_EXCEEDED") }
        if status == .incompleteDeposit { details["depositedAmountFormatted"] = .string("6.5") }
        let json: JSON = .object([
            "status": .string(status.rawValue),
            "updatedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "swapDetails": .object(details),
            "quoteResponse": .object(["quoteRequest": .object(["refundTo": .string("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")])]),
        ])
        debugInsert(swap, state: IntentsSwapState(json))
        focus = Focus(id: deposit)
    }
}

/// `-hermitScroll bottom` (or a y offset) on a page's scroll view.
struct DebugScroll: ViewModifier {
    @State private var position = ScrollPosition(idType: Int.self)
    func body(content: Content) -> some View {
        if let s = DebugLaunch.scroll {
            content.scrollPosition($position)
                .task {
                    try? await Task.sleep(for: .seconds(2.2))
                    if let y = Double(s) { position.scrollTo(y: y) } else { position.scrollTo(edge: .bottom) }
                }
        } else {
            content
        }
    }
}
#endif

extension View {
    /// Debug builds: honours `-hermitScroll`. Release: nothing.
    @ViewBuilder func debugScroll() -> some View {
        #if DEBUG
        modifier(DebugScroll())
        #else
        self
        #endif
    }
}
