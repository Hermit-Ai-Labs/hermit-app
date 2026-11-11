import SwiftUI
import HermitModel

/// For a person whose model works and has been replaced by a newer one: shown on the home screen where "Fly offline"
/// sits on a first run. Calm and once: the new model's name, one line on what is better, the download size, Download
/// and Not now. After Download it shows the download, and the model they have keeps answering until the new one is
/// fully on the device and checked (`ModelStore.upgrade`).
struct ModelUpgradeCard: View {
    @Environment(AppModel.self) private var model
    let upgrade: ModelUpgrade

    var body: some View {
        let store = model.models
        let state = store.state(upgrade.to.id)
        let words = copy(store, state)
        HStack(alignment: .top, spacing: 12) {
            Image.hermit("crab-flight").resizable().interpolation(.high).scaledToFit()
                .frame(width: 46).offset(y: 2)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(words.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(words.line).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .monospacedDigit().contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
                if let note = words.note {
                    Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                if upgrade.phase == .inProgress, case .downloading(let p) = state { HoloBar(value: p).padding(.top, 6) }
                if let button = words.button {
                    HStack(spacing: 8) {
                        Button(button) { start(store) }.buttonStyle(AccentButton())
                        Button("Not now") { store.declineUpgrade() }.buttonStyle(OutlineButton())
                    }
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 8)
            trailing(store, state)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.white, Color(hex: 0xF7F4FF), .white], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
        .animation(.smooth(duration: 0.35), value: state)
    }

    /// What the card says in each state.
    private struct Copy {
        var title: String
        var line: String
        /// A second, quieter line.
        var note: String? = nil
        /// The main button's title. nil shows no buttons (the download is running, or everything is done).
        var button: String? = nil
    }

    private func copy(_ store: ModelStore, _ state: ModelStore.State) -> Copy {
        let to = upgrade.to, from = upgrade.from
        switch upgrade.phase {
        case .offered:
            return Copy(title: "\(to.name) is here", line: to.whatsNew.isEmpty ? to.detail : to.whatsNew,
                        note: "\(store.downloadSize(to)) download. \(from.name) keeps answering until it's ready.", button: "Download")
        case .landed:
            return Copy(title: "\(to.name) is ready", line: "It takes over with your next chat.")
        case .inProgress:
            switch state {
            case .downloading:
                return Copy(title: "Getting \(to.name)", line: store.sizeLine(to))
            case .verifying:
                return Copy(title: "Checking \(to.name)", line: store.sizeLine(to))
            case .failed(let why):
                return Copy(title: "Download stopped", line: why, note: "\(from.name) keeps answering.", button: "Try again")
            case .ready:
                return Copy(title: "\(to.name) is ready", line: "It takes over with your next chat.")
            case .notDownloaded:
                if store.waitingForWiFi == to.id {
                    return Copy(title: "Waiting for Wi-Fi", line: "\(to.name), \(store.downloadSize(to)). It starts by itself on Wi-Fi.",
                                button: "Download now")
                }
                if (store.received[to.id] ?? 0) > 0 {
                    return Copy(title: "\(to.name) is paused", line: store.sizeLine(to), button: "Resume")
                }
                return Copy(title: "Getting \(to.name)", line: store.downloadSize(to), button: "Download")
            }
        }
    }

    /// Download on the offer follows the Wi-Fi rule (one question on mobile data). Resume, Try again and Download now
    /// are the user saying "now", as on the first-run card.
    private func start(_ store: ModelStore) {
        if upgrade.phase == .offered { store.acceptUpgrade() } else { store.download(upgrade.to.id) }
    }

    @ViewBuilder private func trailing(_ store: ModelStore, _ state: ModelStore.State) -> some View {
        if upgrade.phase == .inProgress {
            switch state {
            case .downloading: HoloIconButton(symbol: "pause.fill", label: "Pause download") { store.cancel(upgrade.to.id) }
            case .verifying: ProgressView().controlSize(.small).frame(width: 38, height: 38)
            default: EmptyView()
            }
        }
    }
}
