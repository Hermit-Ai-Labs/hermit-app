import SwiftUI
import HermitWallet

/// Money that just landed on the Receive screen.
struct DepositArrival: Equatable {
    let chain: Chain
    let symbol: String
    let amount: Double
    let usd: Double?
}

/// Watches one wallet for incoming money, fast: every second it reads only the networks the Receive screen shows
/// (Solana, NEAR, or the EVM networks), every balance in parallel, compares each with the last reading, and reports
/// any increase, however small. A balance the first round couldn't read is compared with `known` (the last full wallet
/// refresh) instead, so a deposit that lands while a network is throttled still shows. A network that fails is skipped
/// for a few rounds (2, 4, 8, then 16) rather than read every second. Base is read from its Flashblocks preconf RPC
/// ("pending"), so a transfer shows about 200 ms after it's sent. Solana also holds a live subscription (SolanaPush), so
/// a transfer is read the moment it confirms. The full wallet refresh runs once, after the money lands.
enum DepositWatcher {
    static func chains(_ family: FundSheet.Family) -> [Chain] {
        switch family {
        case .solana: [.solana]
        case .near: [.near]
        case .evm: Chain.evmMainnets.filter { $0.id != "robinhood" }
        }
    }

    /// The last full refresh's balances for one wallet, keyed like Balance.id ("base:USDC"), in base units.
    static func known(_ holdings: [Holding]) -> [String: UInt128] {
        var out: [String: UInt128] = [:]
        for h in holdings {
            let decimals: Int? = h.symbol == h.chain.nativeSymbol ? h.chain.nativeDecimals : h.chain.token(h.symbol)?.decimals
            guard let decimals, let v = try? Units.parse(h.exact, decimals: decimals) else { continue }
            out["\(h.chain.id):\(h.symbol)"] = v
        }
        return out
    }

    /// Returns the first increase seen, or nil when cancelled.
    @MainActor
    static func watch(wallet: WalletRecord, family: FundSheet.Family, service: WalletService,
                      known: [String: UInt128] = [:]) async -> DepositArrival? {
        let chains = chains(family)
        var baseline: [String: UInt128] = [:]
        var round = 0
        // Per network: failures in a row, and the round it is read again.
        var backoff: [String: (fails: Int, next: Int)] = [:]
        let kick = Kick()
        var push: SolanaPush?
        if family == .solana, let owner = SolanaPublicKey(wallet.address(on: .solana)) {
            let accounts = [owner] + Chain.solana.tokens.compactMap { t in SolanaPublicKey(t.address).map { SolanaPublicKey.associatedTokenAccount(owner: owner, mint: $0) } }
            push = SolanaPush(accounts: accounts) { kick.fire() }
        }
        defer { push?.stop() }
        while !Task.isCancelled {
            let due = chains.filter { (backoff[$0.id]?.next ?? 0) <= round }
            var read: [Balance] = [], failed: [Chain] = []
            if family == .evm {
                let r = await evmBalances(wallet: wallet, chains: due, service: service)
                read = r.balances
                failed = r.failed
            } else if !due.isEmpty {
                let r = await service.fetchBalances(for: wallet, chains: due)
                read = r.balances.values.flatMap { $0 }
                failed = r.failed
            }
            for c in due {
                if failed.contains(c) {
                    let fails = (backoff[c.id]?.fails ?? 0) + 1
                    backoff[c.id] = (fails, round + (1 << Swift.min(fails, 4)))
                } else { backoff[c.id] = nil }
            }
            for b in read {
                // The first round sets the baseline. A balance it missed is compared with the last full refresh.
                if let before = baseline[b.id] ?? (round > 0 ? known[b.id] : nil), b.amount > before {
                    let delta = Double(Units.format(b.amount - before, decimals: b.decimals)) ?? 0
                    let price = WalletsViewModel.shared.price(b.symbol)
                    return DepositArrival(chain: b.chain, symbol: b.symbol, amount: delta, usd: price.map { $0 * delta })
                }
                baseline[b.id] = b.amount
            }
            round += 1
            await kick.wait(upTo: 1)
        }
        return nil
    }
}

extension DepositWatcher {
    static let basePreconf = URL(string: "https://mainnet-preconf.base.org")!

    /// Native coin and every listed token on each EVM network, all at once. A read that fails is skipped this round, and
    /// its network is reported in `failed`.
    @MainActor
    static func evmBalances(wallet: WalletRecord, chains: [Chain], service: WalletService) async -> (balances: [Balance], failed: [Chain]) {
        guard !chains.isEmpty, let owner = EVMAddress(wallet.address(on: chains.first ?? .base)) else { return ([], []) }
        let clients = chains.map { c in (c, c.id == "base" ? EVMClient(url: basePreconf) : service.evm(c)) }
        return await withTaskGroup(of: (Chain, Balance?).self) { g in
            for (c, client) in clients {
                let block = c.id == "base" ? "pending" : "latest"
                g.addTask { (c, (try? await client.balance(owner, block: block)).map { Balance(chain: c, token: nil, amount: $0) }) }
                for t in c.tokens {
                    guard let addr = EVMAddress(t.address) else { continue }
                    g.addTask { (c, (try? await client.tokenBalance(token: addr, owner: owner, block: block)).map { Balance(chain: c, token: t, amount: $0) }) }
                }
            }
            var out: [Balance] = [], failed: [Chain] = []
            for await (c, b) in g {
                if let b { out.append(b) } else if !failed.contains(c) { failed.append(c) }
            }
            return (out, failed)
        }
    }
}

/// Wakes the watcher early: `fire()` from the live subscription ends the current 2-second wait.
@MainActor
final class Kick {
    private var fired = false
    func fire() { fired = true }
    func wait(upTo seconds: Double) async {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !fired && ContinuousClock.now < end && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
        fired = false
    }
}

/// A live Solana subscription (accountSubscribe over the RPC's WebSocket, "confirmed"): calls `onChange` whenever one
/// of the accounts changes, usually within a second of the transfer. Reconnects if the socket drops; stop() ends it.
@MainActor
final class SolanaPush {
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    init(accounts: [SolanaPublicKey], url: URL = URL(string: "wss://api.mainnet-beta.solana.com")!, onChange: @escaping @MainActor () -> Void) {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let ws = URLSession.shared.webSocketTask(with: url)
                self?.task = ws
                ws.resume()
                for (i, a) in accounts.enumerated() {
                    let msg = #"{"jsonrpc":"2.0","id":\#(i + 1),"method":"accountSubscribe","params":["\#(a.description)",{"encoding":"base64","commitment":"confirmed"}]}"#
                    try? await ws.send(.string(msg))
                }
                while !Task.isCancelled {
                    guard let m = try? await ws.receive() else { break }
                    if case .string(let s) = m, s.contains("accountNotification") { onChange() }
                }
                ws.cancel(with: .goingAway, reason: nil)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() { loop?.cancel(); task?.cancel(with: .normalClosure, reason: nil) }
}

/// The "Received" moment: a green ring draws itself, the check pops in, the amount counts up, then a short line and the
/// next step. Shown in place of the QR code.
struct DepositArrivedView: View {
    let arrival: DepositArrival
    let primary: String
    let action: () -> Void
    @State private var ring: CGFloat = 0
    @State private var check = false
    @State private var shown = 0.0
    @State private var details = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.green.opacity(0.10)).frame(width: 112, height: 112).scaleEffect(check ? 1 : 0.6).opacity(check ? 1 : 0)
                Circle().trim(from: 0, to: ring).stroke(Theme.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 84, height: 84)
                Image(systemName: "checkmark").font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.green)
                    .scaleEffect(check ? 1 : 0.2).opacity(check ? 1 : 0)
            }
            .frame(height: 116)
            VStack(spacing: 4) {
                Text("+\(MoneyFmt.amount(shown)) \(arrival.symbol)")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: shown))
                Text(([arrival.usd.map { "≈ " + MoneyFmt.usdSmart($0) }, "on \(arrival.chain.name)"].compactMap { $0 }).joined(separator: ", "))
                    .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
            }
            .opacity(details || shown > 0 ? 1 : 0)
            if details {
                Text("It's in your wallet.").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                Button(primary, action: action).buttonStyle(WideButton(kind: .black)).keyboardShortcut(.defaultAction)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .task {
            CoinSound.play()
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #elseif os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            #endif
            withAnimation(.easeOut(duration: 0.45)) { ring = 1 }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { check = true }
            // Count up in ~10 steps over half a second.
            for i in 1...10 {
                try? await Task.sleep(for: .milliseconds(45))
                withAnimation(.snappy(duration: 0.12)) { shown = arrival.amount * Double(i) / 10 }
            }
            withAnimation(.smooth(duration: 0.3)) { details = true }
        }
    }
}

/// "Waiting for funds" with a softly pulsing dot, instead of a spinner.
struct DepositWaitingRow: View {
    let network: String
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.green.opacity(0.25)).frame(width: 18, height: 18).scaleEffect(pulse ? 1.25 : 0.6).opacity(pulse ? 0 : 1)
                Circle().fill(Theme.green).frame(width: 8, height: 8)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Waiting for your deposit").font(.system(size: 13.5, weight: .medium))
                Text("Checking \(network) live. This screen updates the moment it lands.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        // Reduce Motion (and snapshots): the dot stays still.
        .onAppear {
            guard !reduceMotion && !SnapshotMode.active else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}
