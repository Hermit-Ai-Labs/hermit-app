import SwiftUI
import HermitModel

/// First run on the home screen: the model isn't on this device yet. Card B from the design round: the flight-mode crab,
/// copycat's holo foil drifting over a pale violet card, and one small holo icon that keeps changing its look.
/// While it downloads, a holo strip fills under the text. The card folds away once the model is ready.
/// A person whose model is ready and has been replaced by a newer one gets the upgrade card here instead.
struct ModelPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.models
        let spec = store.selected
        let state = store.selectedState
        Group {
            if state != .ready {
                HStack(spacing: 12) {
                    Image.hermit("crab-flight").resizable().interpolation(.high).scaledToFit()
                        .frame(width: 46).offset(y: 2)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(state, spec)).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle(store, spec)).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            .monospacedDigit().contentTransition(.numericText())
                            .fixedSize(horizontal: false, vertical: true)
                        if case .downloading(let p) = state { HoloBar(value: p).padding(.top, 6) }
                    }
                    Spacer(minLength: 8)
                    button(store, spec, state)
                }
                .padding(12)
                .background {
                    ZStack {
                        LinearGradient(colors: [.white, Color(hex: 0xF7F4FF), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
                        HoloFoil(strength: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97))))
            } else if let upgrade = store.upgrade {
                ModelUpgradeCard(upgrade: upgrade)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97))))
            }
        }
        .animation(.smooth(duration: 0.35), value: state)
        .animation(.smooth(duration: 0.35), value: store.upgrade)
    }

    private func title(_ state: ModelStore.State, _ spec: ModelSpec) -> String {
        switch state {
        case .downloading: "In flight"
        case .verifying: "Landing"
        case .failed: "Download stopped"
        case .notDownloaded where model.models.waitingForWiFi == spec.id: "Waiting for Wi-Fi"
        default: "Fly offline"
        }
    }

    private func subtitle(_ store: ModelStore, _ spec: ModelSpec) -> String {
        switch store.selectedState {
        case .notDownloaded where store.waitingForWiFi == spec.id:
            "\(spec.name), \(store.sizeLine(spec)). Starts on Wi-Fi, or tap to download now."
        case .notDownloaded where (store.received[spec.id] ?? 0) == 0:
            "\(spec.name), \(store.sizeLine(spec))"
        case .failed(let why): why
        default: store.sizeLine(spec)
        }
    }

    @ViewBuilder private func button(_ store: ModelStore, _ spec: ModelSpec, _ state: ModelStore.State) -> some View {
        switch state {
        case .downloading: HoloIconButton(symbol: "pause.fill", label: "Pause download") { store.cancel(spec.id) }
        case .failed: HoloIconButton(symbol: "arrow.clockwise", label: "Try again") { store.download(spec.id) }
        case .verifying: ProgressView().controlSize(.small).frame(width: 38, height: 38)
        case .ready: EmptyView()
        case .notDownloaded:
            HoloIconButton(symbol: "arrow.down",
                           label: (store.received[spec.id] ?? 0) > 0 ? "Resume download" : "Download \(spec.name)") { store.download(spec.id) }
        }
    }
}
