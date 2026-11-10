import SwiftUI
import Observation
import HermitCore
import HermitModel
import HermitCloud

/// Where chat answers come from. On-device is the default and works in flight mode; Private Cloud sends the prompt to a
/// NEAR AI Cloud enclave only after this phone has checked its attestation.
enum ChatMode: String, CaseIterable, Identifiable {
    case device, cloud
    var id: String { rawValue }
    static let key = "hermit.chatMode"
    static var current: ChatMode { UserDefaults.standard.string(forKey: key).flatMap(ChatMode.init) ?? .device }
    var title: String { self == .device ? "On-device" : "Private Cloud" }
    var detail: String { self == .device ? "Flight-mode private, runs on \(Device.here)" : "NEAR AI, in a verified enclave (TEE)" }
    var symbol: String { self == .device ? "iphone" : "lock.shield" }
}

/// Sends each prompt to the on-device model or to Private Cloud, by the mode picked in the chat box.
/// Each keeps its own conversation; New chat clears both.
final class ModeAgent: Agent, @unchecked Sendable {
    let local: HybridAgent
    let cloud: NearCloudAgent

    @MainActor init(local: HybridAgent) {
        self.local = local
        // One toolbox for both modes: the on-device model gets the same tools, guard and approval sheets as Private Cloud.
        local.local.toolbox = HermitToolbox.onDevice
        cloud = NearCloudAgent(toolbox: HermitToolbox())
    }

    func reply(to prompt: String) -> AsyncStream<AgentEvent> {
        ChatMode.current == .cloud ? cloud.reply(to: prompt) : local.reply(to: prompt)
    }
    func reset() { local.reset(); cloud.reset() }
    func setContext(name: String, memory: [String]) {
        local.setContext(name: name, memory: memory); cloud.setContext(name: name, memory: memory)
    }
}

/// The enclave check that runs without an API key: Settings and the home card show it live.
@MainActor @Observable
final class CloudStatus {
    static let shared = CloudStatus()

    enum State: Equatable { case idle, checking, done, failed(String) }
    private(set) var state: State = .idle
    private(set) var preflight: Preflight?
    private(set) var models: [NearAICloud.Model] = []
    var hasKey = NearAICloud.apiKey != nil
    var hasOwnKey = NearAICloud.ownKey != nil
    var model = NearAICloud.model { didSet { NearAICloud.model = model; preflight = nil } }

    var passed: Bool { preflight?.passed == true }

    func check() async {
        guard state != .checking, !SnapshotMode.active else { return }
        state = .checking
        do {
            let p = try await Preflight.run(model: model)
            preflight?.connection?.invalidate()
            p.connection?.invalidate()   // nothing is sent after a status check
            preflight = p; state = .done
        } catch {
            state = .failed((error as? NearAICloud.Failure)?.description ?? "Couldn't reach NEAR AI Cloud. \(error.localizedDescription)")
        }
    }

    func loadModels() async {
        guard models.isEmpty, !SnapshotMode.active else { return }
        models = (try? await NearAICloud().models()) ?? []
    }

    func setKey(_ key: String?) {
        NearAICloud.ownKey = key
        hasKey = NearAICloud.apiKey != nil
        hasOwnKey = NearAICloud.ownKey != nil
    }

    /// The proof to show for a check made outside a chat (no completion).
    var proof: CloudProof? { preflight?.proof(completions: 0, signed: 0, kind: nil, replyChecks: []) }
}

/// Picks the chat mode. Shown in the chat box next to the send button.
struct ModeMenu: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ChatMode.key) private var mode = ChatMode.device.rawValue
    var showModels: () -> Void

    private var current: ChatMode { ChatMode(rawValue: mode) ?? .device }

    var body: some View {
        Menu {
            ForEach(ChatMode.allCases) { m in
                Button { pick(m) } label: {
                    Label { Text(m.title); Text(m.detail) } icon: { Image(systemName: current == m ? "checkmark" : m.symbol) }
                }
            }
            Divider()
            Button("On-device models", systemImage: "cpu") { showModels() }
            Button("Private Cloud settings", systemImage: "gearshape") { model.open(.settings, tab: "cloud") }
        } label: {
            HStack(spacing: 4) {
                if current == .cloud { Image(systemName: "lock.shield").font(.system(size: 11, weight: .medium)) }
                Text(current == .cloud ? "Private Cloud" : model.models.label).lineLimit(1)
                    .contentTransition(.numericText()).animation(.snappy, value: model.models.label)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .padding(.trailing, 6)
        .help("On-device or Private Cloud")
    }

    private func pick(_ m: ChatMode) {
        guard m != current else { return }
        withAnimation(.snappy) { mode = m.rawValue }
        model.toast(m == .cloud ? "Private Cloud: checked enclave on NEAR AI" : "On-device: nothing leaves \(Device.here)")
    }
}

/// Home, Private Cloud mode: what this mode does, with the live enclave check. Without a key it says so plainly.
struct CloudPrompt: View {
    @Environment(AppModel.self) private var model
    @State private var status = CloudStatus.shared
    @State private var proof: CloudProof?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 19, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(status.hasKey ? "Private Cloud" : "Private Cloud needs a key")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                Text(line).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            if !status.hasKey {
                Button("Add key") { model.open(.settings, tab: "cloud") }.buttonStyle(BlackButton())
            } else if let p = status.proof {
                Button { proof = p } label: { Image(systemName: "checkmark.shield").font(.system(size: 15)) }
                    .buttonStyle(PlainCardButton()).help("See what was checked")
            }
        }
        .padding(12)
        .background(LinearGradient(colors: [.white, Color(hex: 0xF7F4FF), .white], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
        .onTapGesture { if let p = status.proof { proof = p } }
        .task { if status.preflight == nil { await status.check() } }
        .sheet(item: $proof) { ProofSheet(proof: $0) }
        #if DEBUG
        .onChange(of: status.proof?.id) { _, _ in if let p = status.proof, DebugLaunch.take("proof") { proof = p } }
        #endif
        .animation(.smooth, value: status.state)
    }

    private var line: String {
        let name = status.model.split(separator: "/").last.map(String.init) ?? status.model
        switch status.state {
        case .idle, .checking: return "Checking NEAR AI's enclave for \(name)…"
        case .failed(let why): return why
        case .done:
            guard let p = status.preflight else { return "" }
            if !p.passed { return "The enclave's evidence failed a check. Nothing will be sent." }
            return status.hasKey ? "\(name) in an enclave \(Device.here) just verified" : "Enclave verified, no key needed for that. Chat needs a NEAR AI Cloud key."
        }
    }
}

extension CloudProof: Identifiable {
    public var id: String { nonce + (repliedAt.map { "\($0.timeIntervalSince1970)" } ?? "") }
}
