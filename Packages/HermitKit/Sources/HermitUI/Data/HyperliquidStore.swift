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

    /// The read in flight, so the Trade screen, the Positions page, Wallets and chat asking at once share one request.
    @ObservationIgnored private var loading: Task<Bool, Never>?
    /// The address `account` belongs to: another wallet picked never shows the last one's positions.
    @ObservationIgnored private var accountAddress: String?

    func refresh() async { _ = await load() }

    /// For a view's poll: false when Hyperliquid couldn't be reached, so the poll backs off.
    func poll() async -> Bool { await load() }

    /// After an order, close or cancel: read the account at once (not a read that started before it went through),
    /// then again 2 s later, when a fill and its take profit and stop loss have settled.
    func refreshAfterTrade() {
        Task {
            if let running = self.loading { _ = await running.value }
            await self.refresh()
            try? await Task.sleep(for: .seconds(2))
            await self.refresh()
        }
    }

    private func load() async -> Bool {
        if let running = loading { return await running.value }
        let t = Task { await self.fetch() }
        loading = t
        let ok = await t.value
        loading = nil
        return ok
    }

    private func fetch() async -> Bool {
        guard let address, !SnapshotMode.active else { account = nil; accountAddress = nil; state = .ready; return true }
        if accountAddress != address { account = nil; accountAddress = address; state = .loading }
        var ok = true
        do {
            let a = try await Hyperliquid.account(address)
            // The wallet may have changed while this was loading.
            if address == self.address { account = a; state = .ready }
        } catch {
            ok = false
            if account == nil { state = .failed }
        }
        if assets.isEmpty, let a = try? await Hyperliquid.assets() { assets = a }
        return ok
    }

    /// Funding a position has paid since it opened, in USDC: Hyperliquid's `cumFunding.sinceOpen`, where positive is
    /// paid and negative received. nil when it can't be read.
    func fundingSinceOpen(_ coin: String) async -> Double? {
        guard let address, !SnapshotMode.active else { return nil }
        let parts = coin.split(separator: ":")
        let dex = parts.count > 1 ? String(parts[0]) : nil
        let body = dex.map { #"{"type":"clearinghouseState","user":"\#(address)","dex":"\#($0)"}"# } ?? #"{"type":"clearinghouseState","user":"\#(address)"}"#
        guard let state = try? await MarketHTTP.json("https://api.hyperliquid.xyz/info", json: body) as? [String: Any],
              let list = state["assetPositions"] as? [[String: Any]] else { return nil }
        for item in list {
            guard let pos = item["position"] as? [String: Any], pos["coin"] as? String == coin else { continue }
            return MarketHTTP.num((pos["cumFunding"] as? [String: Any])?["sinceOpen"])
        }
        return nil
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
