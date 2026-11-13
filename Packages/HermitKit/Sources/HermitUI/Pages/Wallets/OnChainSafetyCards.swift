import SwiftUI
import HermitCore
import HermitWallet

/// Wallets > Security, next to Budgets and in the same style: Black box (step 1) and AI insurance (step 2).
/// Insurance needs the Black box first, because a claim's evidence is a Black box record, so its button stays
/// locked, with a line saying why, until the Black box is on.
struct OnChainSafetyCards: View {
    let vm: WalletsViewModel
    let wallet: WalletAccount
    @Environment(AppModel.self) private var model
    @State private var boxOn = BlackBox.isOn
    @State private var records = BlackBox.log.count
    @State private var until: Date?
    @State private var pool: Decimal?
    @State private var busy: String?

    private var service: WalletService { vm.service }

    var body: some View {
        if wallet.record.nearAccount != nil {
            VStack(alignment: .leading, spacing: 18) {
                card(title: "Black box", step: "1",
                     pill: busy == "box" ? "…" : boxOn ? "Turn off" : "Turn on", pillEnabled: busy == nil,
                     status: boxOn ? "On" : "Off", dot: boxOn ? Theme.green : Theme.faint,
                     detail: boxOn ? (records == 1 ? "1 move recorded" : "\(records) moves recorded") : nil,
                     blurb: "Every move the AI prepares and you approve leaves a fingerprint on NEAR. Only a hash, never the chat.",
                     link: BlackBox.explorer, linkLabel: "View the contract, hermit-blackbox.near", action: { Task { await toggleBox() } })
                card(title: "AI insurance", step: "2",
                     pill: busy == "ins" ? "…" : until == nil ? "Turn on" : "Add 30 days", pillEnabled: busy == nil && boxOn,
                     status: until.map { "Covered until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? (boxOn ? "Not covered" : "Turn on Black box first"),
                     dot: until != nil ? Theme.green : boxOn ? Theme.faint : Theme.amber,
                     detail: pool.map { "Pool \(MoneyFmt.usd(NSDecimalNumber(decimal: $0).doubleValue, digits: 2))" },
                     blurb: boxOn
                        ? "1 USDC on NEAR for 30 days. If the AI's mistake costs you money, claim it back from a public pool. Claims are filed in Settings, Safety."
                        : "Needs the Black box: its record is the proof for a claim. Turn on step 1, then this unlocks.",
                     link: AIInsurance.explorer, linkLabel: "View the pool, hermit-insurance.near", action: { Task { await buy() } })
            }
            .task(id: wallet.id) { await load() }
            .onReceive(NotificationCenter.default.publisher(for: BlackBox.changed)) { _ in boxOn = BlackBox.isOn }
            .onReceive(NotificationCenter.default.publisher(for: AIInsurance.changed)) { _ in if let a = wallet.record.nearAccount { until = AIInsurance.knownUntil(a) } }
        }
    }

    private func card(title: String, step: String, pill: String, pillEnabled: Bool, status: String, dot: Color,
                      detail: String?, blurb: String, link: URL, linkLabel: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                SectionLabel("\(step). \(title)")
                Spacer(minLength: 6)
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(pill)
                        if pillEnabled { Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold)) }
                        else { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)) }
                    }
                }
                .buttonStyle(HoloPillButton())
                .disabled(!pillEnabled)
                .opacity(pillEnabled ? 1 : 0.55)
                .accessibilityLabel("\(pill) \(title)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(status).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13)
                    .overlay(alignment: .leading) { GuardDot(color: dot) }
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).monospacedDigit() }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            Text(blurb).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Link(destination: link) {
                HStack(spacing: 3) {
                    Text(linkLabel).font(.system(size: 12))
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(Theme.muted)
            }
        }
    }

    private func load() async {
        boxOn = BlackBox.isOn
        records = BlackBox.log.count
        if let a = wallet.record.nearAccount {
            until = AIInsurance.knownUntil(a) ?? until            // instant, from this device
            if let c = try? await AIInsurance.coveredUntil(a) { until = c }
        }
        pool = (try? await AIInsurance.info())?.pool
    }

    private func toggleBox() async {
        busy = "box"; defer { busy = nil }
        do {
            if boxOn {
                try await service.disableBlackBox()
                model.toast("Black box off")
            } else {
                _ = try await service.enableBlackBox(walletID: wallet.record.id)
                model.toast("Black box on. AI insurance can be turned on now")
            }
        } catch { model.toast(error.localizedDescription, kind: .info) }
        await load()
    }

    private func buy() async {
        guard BlackBox.isOn else { model.toast("Turn on the Black box first", kind: .info); return }
        busy = "ins"; defer { busy = nil }
        do {
            _ = try await service.buyInsurance(walletID: wallet.record.id)
            model.toast("AI insurance on for 30 days")
        } catch { model.toast(error.localizedDescription, kind: .info) }
        await load()
    }
}
