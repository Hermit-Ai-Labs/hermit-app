import SwiftUI
import HermitModel

/// Models on this device: download, pause, pick the one chat uses, delete. Opened from the model name in the chat box.
struct ModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Inside Settings › Models: just the list, no title or close button.
    var embedded = false

    var body: some View {
        if embedded {
            list.animation(.smooth(duration: 0.3), value: model.models.states)
        } else {
            sheet
        }
    }

    private var list: some View {
        let store = model.models
        return VStack(spacing: 0) {
            ForEach(Array(ModelCatalog.all.filter(\.supported).enumerated()), id: \.element.id) { i, spec in
                if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                row(store, spec)
            }
        }
        .card()
    }

    private var sheet: some View {
        let store = model.models
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models").font(.system(size: 19, weight: .semibold))
                    Text("Hermit runs on this device. Nothing you type leaves it.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 26, height: 26).background(Theme.hover, in: Circle())
                }
                .buttonStyle(.plain)
            }
            list
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 460)
        #else
        .presentationDetents([.medium])
        #endif
        .animation(.smooth(duration: 0.3), value: store.states)
    }

    private func row(_ store: ModelStore, _ spec: ModelSpec) -> some View {
        let state = store.state(spec.id)
        let usable = spec.supported && ModelCatalog.fits(spec)
        return HStack(spacing: 12) {
            Button { if usable { store.toggle(spec.id) } } label: { ModelRing(state: state, size: 34) }
                .buttonStyle(PressStyle()).disabled(!usable).opacity(usable ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(spec.name).font(.system(size: 13.5, weight: .medium))
                    if store.selectedID == spec.id {
                        Text("In use").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.hover, in: Capsule())
                    }
                }
                Text(spec.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(usable ? store.sizeLine(spec) : "Needs \(spec.minMemoryGB) GB of memory")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if usable { trailing(store, spec, state).fixedSize() }
        }
        .padding(14)
    }

    @ViewBuilder private func trailing(_ store: ModelStore, _ spec: ModelSpec, _ state: ModelStore.State) -> some View {
        switch state {
        case .ready:
            HStack(spacing: 8) {
                if store.selectedID != spec.id {
                    Button("Use") { store.select(spec.id); model.newChat(); model.toast("Chatting with \(spec.name)") }
                        .buttonStyle(OutlineButton())
                }
                Button {
                    store.delete(spec.id); model.toast("\(spec.name) removed")
                } label: {
                    Image(systemName: "trash").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).background(Theme.hover, in: Circle())
                }
                .buttonStyle(PressStyle())
                .help("Delete from this device")
            }
        case .downloading: Button("Pause") { store.cancel(spec.id) }.buttonStyle(OutlineButton())
        case .verifying: EmptyView()
        case .failed: Button("Try again") { store.download(spec.id) }.buttonStyle(OutlineButton())
        case .notDownloaded:
            Button((store.received[spec.id] ?? 0) > 0 ? "Resume" : "Download") {
                store.download(spec.id)
                if store.state(store.selectedID) != .ready { store.select(spec.id) }
            }
            .buttonStyle(AccentButton())
        }
    }
}
