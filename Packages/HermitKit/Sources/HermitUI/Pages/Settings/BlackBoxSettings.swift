import SwiftUI
import HermitCore
import HermitModel
import HermitWallet

/// Settings > Safety: the flight recorder on hermit-blackbox.near.
struct BlackBoxRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var on = BlackBox.isOn
    @State private var busy = false
    @State private var count = BlackBox.log.count

    private var service: WalletService { WalletsViewModel.shared.service }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Black box", sub: on
                       ? "On. \(count == 1 ? "1 decision" : "\(count) decisions") fingerprinted on NEAR. Only a hash leaves \(Device.here), never the chat"
                       : "Writes a fingerprint of every move the AI prepares and you approve to NEAR, so there's a record nobody can rewrite. Only a hash, never the chat") {
                HStack(spacing: 8) {
                    Button("Contract") { openURL(BlackBox.explorer) }.buttonStyle(BlackButton())
                    Button(busy ? "…" : on ? "Turn off" : "Turn on") { Task { await toggle() } }
                        .buttonStyle(BlackButton()).disabled(busy)
                }
            }
        }
        .onAppear { on = BlackBox.isOn; count = BlackBox.log.count }
    }

    private func toggle() async {
        busy = true
        defer { busy = false }
        do {
            if on {
                try await service.disableBlackBox()
                on = false
                model.toast("Black box off")
            } else {
                guard let w = service.wallets.first(where: { $0.nearAccount != nil }) else {
                    model.toast("Open Wallets once so Hermit can add your NEAR account", kind: .info); return
                }
                _ = try await service.enableBlackBox(walletID: w.id)
                on = true
                model.toast("Black box on. Approved AI moves are fingerprinted on hermit-blackbox.near")
            }
        } catch {
            model.toast(error.localizedDescription, kind: .info)
        }
    }
}

/// Settings > Models: is the model this app pins the one Hermit published on hermit-blackbox.near?
struct ModelRegistryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var state: Bool?? = .none
    @State private var checked = false

    var body: some View {
        let spec = model.models.selected
        SettingRow(title: "Checked on NEAR", sub: text(spec.name)) {
            Button("Registry") { openURL(BlackBox.explorer) }.buttonStyle(BlackButton())
        }
        .task(id: spec.id) { await check(spec) }
    }

    private func text(_ name: String) -> String {
        guard checked else { return "Comparing \(name) with Hermit's model registry on hermit-blackbox.near…" }
        switch state {
        case .some(.some(true)): return "\(name) matches the hashes Hermit published on hermit-blackbox.near"
        case .some(.some(false)): return "\(name) isn't in the registry on hermit-blackbox.near. It still passed its download check"
        default: return "Couldn't reach NEAR just now. \(name) still passed its download check"
        }
    }

    private func check(_ spec: ModelSpec) async {
        checked = false
        guard let pin = spec.pin, let weights = pin.files.first(where: { $0.path == "model.safetensors" }) else {
            state = .some(false); checked = true; return
        }
        let digest = BlackBox.pinDigest(files: pin.files.map { ($0.path, $0.size, $0.sha256) })
        state = .some(await BlackBox.checkModel(id: spec.id, weightsSHA256: weights.sha256, pinDigest: digest))
        checked = true
    }
}
