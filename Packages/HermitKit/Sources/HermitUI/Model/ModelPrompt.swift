import SwiftUI
import HermitModel

/// First run on the home screen: the model isn't on this device yet. Download it right here, watch the ring
/// fill, and the card folds away once the model is ready.
struct ModelPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.models
        let spec = store.selected
        let state = store.selectedState
        Group {
            if state != .ready {
                HStack(spacing: 14) {
                    Button { store.toggle(spec.id) } label: { ModelRing(state: state, size: 40) }
                        .buttonStyle(PressStyle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(state, spec)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle(store, spec)).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            .monospacedDigit().contentTransition(.numericText())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    button(store, spec, state).fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .card()
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97))))
            }
        }
        .animation(.smooth(duration: 0.35), value: state)
    }

    private func title(_ state: ModelStore.State, _ spec: ModelSpec) -> String {
        switch state {
        case .downloading: "Downloading \(spec.name)"
        case .verifying: "Almost ready"
        case .failed: "Download stopped"
        default: "Run Hermit offline"
        }
    }

    private func subtitle(_ store: ModelStore, _ spec: ModelSpec) -> String {
        switch store.selectedState {
        case .notDownloaded where (store.received[spec.id] ?? 0) == 0:
            "\(spec.name), \(store.sizeLine(spec)). Then chat works offline and stays private."
        default: store.sizeLine(spec)
        }
    }

    @ViewBuilder private func button(_ store: ModelStore, _ spec: ModelSpec, _ state: ModelStore.State) -> some View {
        switch state {
        case .downloading: Button("Pause") { store.cancel(spec.id) }.buttonStyle(OutlineButton())
        case .failed: Button("Try again") { store.download(spec.id) }.buttonStyle(OutlineButton())
        case .verifying, .ready: EmptyView()
        case .notDownloaded:
            Button { store.download(spec.id) } label: {
                Label((store.received[spec.id] ?? 0) > 0 ? "Resume" : "Download", systemImage: "arrow.down")
            }
            .buttonStyle(GradientPill())
        }
    }
}
