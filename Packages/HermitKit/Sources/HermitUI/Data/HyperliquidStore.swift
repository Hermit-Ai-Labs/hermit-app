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

    func trader() -> HyperliquidTrader? {
        guard let w = wallet else { return nil }
        return HyperliquidTrader(vault: wallets.service.vault, wallet: w.record)
    }

    /// Deposit: Send opens on Arbitrum, USDC, to Hyperliquid's bridge. Lands in about a minute.
    func openDeposit(_ model: AppModel, amount: Double? = nil) {
        wallets.sendPrefill = .init(address: Hyperliquid.bridge, amount: amount.map { String(Int(max($0, 5).rounded(.up))) } ?? "",
                                    token: "USDC", chain: .arbitrum, label: "Hyperliquid deposit")
        model.open(.wallets, tab: "send")
    }
}
