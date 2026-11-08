import SwiftUI
import HermitCore
import HermitWallet

/// The wallet's NEAR account: an implicit account (64 hex) derived from the recovery phrase at m/44'/397'/0'.
/// It exists on chain only once it has received NEAR, and the card says so instead of showing a zero as if it were live.
struct NearAccountCard: View {
    @Environment(AppModel.self) private var model
    let vm: WalletsViewModel
    let wallet: WalletAccount
    let open: (WalletSheet) -> Void
    @State private var state: Loaded = .loading
    @State private var adding = false
    @State private var error: String?

    enum Loaded: Equatable { case loading, missing, inactive, active(NearClient.AccountState), unknown }

    private var account: String? { wallet.record.nearAccount }
    private var isLive: Bool { if case .active = state { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                LogoMark("near", size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEAR account").font(.system(size: 14, weight: .medium))
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                Spacer(minLength: 6)
                trailing
            }
            if let a = account {
                Button { Clip.copy(a); model.toast("NEAR account copied") } label: {
                    HStack(spacing: 7) {
                        Text(shortAddr(a, keep: 10)).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text)
                        Image(systemName: "doc.on.doc").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                        Spacer()
                        if isLive, let u = Chain.near.explorerURL(address: a) {
                            Link(destination: u) { Image(systemName: "arrow.up.right.square").font(.system(size: 12.5)) }.foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy NEAR account \(a)")
                if state == .inactive {
                    NoteBox(symbol: "info.circle", text: "Not active yet. A NEAR account appears on chain the first time it receives NEAR: send about 0.01 NEAR here, or swap into NEAR from another chain.")
                }
            }
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: account) { await load() }
    }

    private var subtitle: String {
        switch state {
        case .loading: return account == nil ? "Not added yet" : "Checking NEAR"
        case .missing: return "Not added to this wallet yet"
        case .inactive: return "Waiting for its first NEAR"
        case .active(let s): return "\(IntentsFmt.amount(Units.format(s.available, decimals: 24))) NEAR available"
        case .unknown: return "Couldn't reach NEAR right now"
        }
    }

    @ViewBuilder private var trailing: some View {
        if account == nil {
            Button(adding ? "Adding" : "Add") { add() }.buttonStyle(OutlineButton()).disabled(adding)
        } else if state == .inactive || isLive {
            Button("Add funds") { open(.receive(wallet: wallet.id)) }.buttonStyle(OutlineButton())
        }
    }

    private func load() async {
        guard let a = account else { state = .missing; return }
        do { state = try await vm.service.nearAccountState(a).map { .active($0) } ?? .inactive } catch { state = .unknown }
    }

    private func add() {
        adding = true; error = nil
        Task {
            defer { adding = false }
            do {
                _ = try await vm.service.addNearAccount(wallet.record.id)
                vm.reloadLocal()
                model.toast("NEAR account added")
                await vm.refresh()
            } catch WalletError.cancelled {
            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}

/// NEAR Intents swaps from this device that haven't settled; tap one for its live status.
struct IntentsActiveList: View {
    private var act: IntentsActivity { .shared }
    var body: some View {
        let list = act.active
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Swaps in progress")
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        Button { act.show(s.depositAddress) } label: {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(s.from) to \(s.toPlaceName)").font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                    Text((act.state(s.depositAddress)?.status ?? s.status).headline).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        .task { act.track(s.depositAddress) }
                    }
                }
            }
        }
    }
}

/// The spending policy every move is checked against before the approval sheet opens (Security tab).
struct SpendPolicyCard: View {
    let vm: WalletsViewModel
    @State private var cap: Decimal = 100
    @State private var limit: Decimal = 500
    private var policy: SpendPolicy { vm.service.policy }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Spending policy")
            DetailLines(lines: [("Daily limit", "$\(limit)"), ("Left today", "$\(vm.service.spendLimit.remaining())"),
                                ("Assistant, per move", "up to $\(cap)"), ("Assistant pays out to", "Your own addresses only"),
                                ("New address", "Warned before Approve")])
            HStack(spacing: 8) {
                Text("Assistant cap").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                ForEach([25, 100, 250] as [Decimal], id: \.self) { v in
                    SelectChip(title: "$\(v)", on: cap == v) { cap = v; policy.agentCapUSD = v }
                }
            }
            NoteBox(symbol: "checkmark.shield", text: "NEAR Intents swaps are priced with 1Click's live token prices and counted toward the daily limit; plain sends count stablecoins. The assistant can only prepare. You approve every move with Face ID.")
        }
        .onAppear { cap = policy.agentCapUSD; limit = vm.service.spendLimit.dailyLimitUSD }
    }
}

/// Optional 1Click partner key (partners.near-intents.org). Without it quotes carry 1Click's extra fee and confidential
/// swaps are refused; with it both go away. Kept in this app's settings on this device only.
struct IntentsKeyCard: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var saved = OneClick.configuredJWT != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("NEAR Intents")
            DetailLines(lines: [("Swaps and bridges", "1Click Swap API"), ("Partner key", saved ? "Set" : "Not set, 0.2% API fee"),
                                ("Confidential swaps", saved ? "Available" : "Need a partner key")])
            HStack(spacing: 8) {
                SecureField(saved ? "Replace partner key" : "Paste a 1Click partner key", text: $key)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).modifier(FieldBox())
                Button(key.isEmpty && saved ? "Remove" : "Save") {
                    let v = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserDefaults.standard.set(v.isEmpty ? nil : v, forKey: OneClick.jwtDefaultsKey)
                    saved = !v.isEmpty; key = ""
                    model.toast(v.isEmpty ? "Partner key removed" : "Partner key saved")
                }
                .buttonStyle(OutlineButton()).disabled(key.isEmpty && !saved)
            }
        }
    }
}
