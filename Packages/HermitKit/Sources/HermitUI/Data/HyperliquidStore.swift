import SwiftUI
import Observation
import HermitCore
import HermitWallet

/// The user's Hyperliquid account, for the wallet picked on Trade: USDC margin, positions and open orders, read from
/// Hyperliquid's public API by address. Orders are signed on this phone with that wallet's key (HyperliquidTrader).
@MainActor @Observable
final class HyperliquidStore {
    static let shared = HyperliquidStore()

    private(set) var assets: [String: Hyperliquid.Asset] = [:]
    private(set) var account: Hyperliquid.Account?
    private(set) var state: FeedState = .loading
    /// The wallet trades go through: the first wallet unless one was picked.
    var walletID: String?

    private var wallets: WalletsViewModel { .shared }

    var wallet: WalletAccount? { walletID.flatMap(wallets.wallet) ?? wallets.wallets.first }
    var address: String? { wallet?.record.evmAddress }
    var hasWallet: Bool { wallet != nil }
    /// USDC free to open new positions with.
    var available: Double { account?.withdrawable ?? 0 }

    func refresh() async {
        guard let address, !SnapshotMode.active else { account = nil; state = .ready; return }
        do { account = try await Hyperliquid.account(address); state = .ready }
        catch { if account == nil { state = .failed } }
        if assets.isEmpty, let a = try? await Hyperliquid.assets() { assets = a }
    }

    func asset(_ coin: String) async -> Hyperliquid.Asset? {
        if assets[coin] == nil, let a = try? await Hyperliquid.assets() { assets = a }
        return assets[coin]
    }

    /// Margin one order can use. A standard account keeps a separate balance per perp dex (the main markets, and
    /// trade.xyz as "xyz"), so an xyz order can only use what's on xyz. Unified and portfolio-margin accounts share one.
    enum DexMargin { case shared, free(Double), unknown }

    func margin(dex: String?) async -> DexMargin {
        guard let address, !SnapshotMode.active else { return .unknown }
        let info = "https://api.hyperliquid.xyz/info"
        // userAbstraction answers with a bare JSON string: "default", "unifiedAccount", "portfolioMargin", ...
        // If it can't be read, the stricter per-dex rule applies.
        let raw = try? await MarketHTTP.data(info, json: #"{"type":"userAbstraction","user":"\#(address)"}"#)
        let mode = raw.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if mode.contains("unified") || mode.contains("portfolio") { return .shared }
        let body = dex.map { #"{"type":"clearinghouseState","user":"\#(address)","dex":"\#($0)"}"# } ?? #"{"type":"clearinghouseState","user":"\#(address)"}"#
        guard let state = try? await MarketHTTP.json(info, json: body) as? [String: Any], let free = MarketHTTP.num(state["withdrawable"]) else {
            return .unknown
        }
        return .free(free)
    }

    func trader() -> HyperliquidTrader? {
        guard let w = wallet else { return nil }
        return HyperliquidTrader(vault: wallets.service.vault, wallet: w.record)
    }

    /// Deposit: the Add funds flow, aimed at Hyperliquid (moves any balance there through Relay, or shows QR codes).
    func openDeposit(_ model: AppModel, amount: Double? = nil) { model.fundGoal = .hyperliquid }
}
