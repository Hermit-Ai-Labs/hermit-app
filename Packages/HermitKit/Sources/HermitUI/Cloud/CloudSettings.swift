import SwiftUI
import HermitCore
import HermitCloud

/// Settings, Private Cloud: the NEAR AI Cloud key (Keychain, this device only), the model, and a live enclave check
/// that needs no key.
struct CloudSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage(ChatMode.key) private var mode = ChatMode.device.rawValue
    @State private var status = CloudStatus.shared
    @State private var draft = ""
    @State private var proof: CloudProof?
    /// The key is being checked with NEAR before it's saved; why it wasn't saved.
    @State private var checkingKey = false
    @State private var keyError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("For questions too big for the on-device model. Your prompt goes to an open model on NEAR AI Cloud, inside a hardware enclave (a TEE), and only after \(Device.here) has checked the enclave's attestation. On-device stays the default.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            SettingRow(title: "Use Private Cloud in chat", sub: mode == ChatMode.cloud.rawValue ? "New messages go to the verified enclave" : "Chat answers on this device") {
                Toggle("Private Cloud", isOn: Binding(get: { mode == ChatMode.cloud.rawValue },
                                                      set: { mode = ($0 ? ChatMode.cloud : .device).rawValue }))
                    .labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
            Hairline()
            keyRow
            Hairline()
            SettingRow(title: "Model", sub: "Open models NEAR runs in TEEs (Intel TDX and NVIDIA confidential GPUs)") {
                if status.models.isEmpty {
                    Text(status.model).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                } else {
                    ValueMenu(selection: $status.model, options: status.models.map(\.id)) { id in
                        status.models.first { $0.id == id }.map { "\($0.name)" } ?? id
                    }
                }
            }
            Hairline()
            enclaveRow
            NoteBox(symbol: "lock", text: "Hermit has no server. The chat stays on \(Device.here); the prompt leaves it only to the attested enclave, over HTTPS. Money actions from the cloud model only prepare a review: you approve with \(Device.bio), as always.")
                .padding(.top, 18)
        }
        .task { if let note = await status.loadModels() { model.toast(note) } }
        .task { if status.preflight == nil { await status.check() } }
        .onChange(of: status.model) { Task { await status.check() } }
        .sheet(item: $proof) { ProofSheet(proof: $0) }
    }

    private var keySub: String {
        if status.hasOwnKey { return "Saved in the Keychain on this device only" }
        if NearAICloud.usesSharedKey {
            return "Using Hermit's shared key: \(SharedQuota.left) of \(SharedQuota.perDay) free messages left today. Add your own key for unlimited use."
        }
        return "Get one at cloud.near.ai. NEAR Builders members can claim $10 of credit"
    }

    private var keyRow: some View {
        SettingRow(title: "NEAR AI Cloud API key", sub: keySub) {
            if status.hasOwnKey {
                HStack(spacing: 8) {
                    Text("Saved").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                    Button("Remove") { status.setKey(nil); model.toast("Key removed") }.buttonStyle(PlainCardButton())
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SecureField(text: $draft, prompt: Text("sk-…").foregroundStyle(Theme.faint)) { Text("API key") }
                            .textFieldStyle(.plain).font(.system(size: 13.5, design: .monospaced)).focused($focused)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .padding(.horizontal, 12).frame(minWidth: 200, maxWidth: .infinity).frame(height: 36)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Theme.faint : Theme.border))
                            .onSubmit(save)
                        if checkingKey { ProgressView().controlSize(.small) }
                        Button("Save", action: save).buttonStyle(BlackButton())
                            .disabled(checkingKey || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 8)
                    }
                    if let keyError {
                        Text(keyError).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        Button("Get a key") { openURL(NearAICloud.dashboard) }.buttonStyle(.plain)
                        Button("Claim $10 credit") { openURL(NearAICloud.builders) }.buttonStyle(.plain)
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                }
            }
        }
    }

    private var enclaveRow: some View {
        SettingRow(title: "Enclave check", sub: enclaveLine) {
            HStack(spacing: 8) {
                if status.state == .checking { ProgressView().controlSize(.small) }
                if let p = status.proof { Button("See checks") { proof = p }.buttonStyle(PlainCardButton()) }
                Button("Check again") { Task { await status.check() } }.buttonStyle(PlainCardButton())
                    .disabled(status.state == .checking)
            }
        }
    }

    private var enclaveLine: String {
        switch status.state {
        case .idle, .checking: return "Fetching fresh evidence with a new random nonce…"
        case .failed(let why): return why
        case .done:
            guard let p = status.preflight else { return "" }
            let n = p.checks.filter { $0.status == .pass }.count
            if p.passed && !p.gpuVerdicts { return "NVIDIA's verdict on the GPUs didn't come back, so chat won't send yet. Check again in a moment." }
            return p.passed ? "Verified just now, no key needed: \(n) checks passed for the gateway and \(p.bundle.models.count == 1 ? "the model" : "\(p.bundle.models.count) model instances")"
                            : "Failed: \(p.checks.filter { $0.status == .fail }.map(\.title).prefix(2).joined(separator: ", "))"
        }
    }

    /// Asks NEAR whether the key works before saving it, and only says it's saved once the Keychain has it.
    private func save() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count >= 8, !checkingKey else { return }
        checkingKey = true; keyError = nil
        Task { @MainActor in
            let check = await NearAICloud().checkKey(k)
            checkingKey = false
            if check == .rejected { keyError = "NEAR AI didn't accept this key. Check it and try again."; return }
            status.setKey(k)
            guard NearAICloud.ownKey == k else { keyError = "Couldn't save the key in the Keychain. Try again."; return }
            draft = ""; focused = false
            switch check {
            case .valid: model.toast("Key saved on \(Device.here)")
            case .noCredits: model.toast("Key saved. It has no credits left: add some at cloud.near.ai")
            case .rejected, .unchecked: model.toast("Key saved, not checked yet")
            }
        }
    }
}
