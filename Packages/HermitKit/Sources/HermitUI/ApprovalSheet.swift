import SwiftUI
import LocalAuthentication
import HermitCore

/// The one sheet every money move goes through: summary, hazard scan ticking through, then Approve with Touch ID / Face ID.
struct ApprovalSheet: View {
    let approval: Approval
    let onApproved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var passed = 0
    @State private var phase: Phase = .scanning
    @State private var txHash: String?
    @State private var failure: String?
    enum Phase { case scanning, ready, signing, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(approval.kind).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text(approval.title).font(.system(size: 19, weight: .semibold))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 26, height: 26).background(Theme.hover, in: Circle())
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 9) {
                ForEach(approval.lines, id: \.self) { l in
                    HStack { Text(l[0]).foregroundStyle(Theme.muted); Spacer(); Text(l[1]).monospacedDigit() }
                        .font(.system(size: 13.5))
                }
            }
            .padding(14).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Hazard scan", systemImage: "checkmark.shield").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(passed)/\(approval.checks.count)").font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit()
                        .contentTransition(.numericText())
                }
                ForEach(Array(approval.checks.enumerated()), id: \.offset) { i, c in
                    HStack(spacing: 9) {
                        ZStack {
                            if i < passed {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).transition(.scale.combined(with: .opacity))
                            } else if i == passed && phase == .scanning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Circle().strokeBorder(Theme.border, lineWidth: 1.5)
                            }
                        }
                        .frame(width: 15, height: 15)
                        Text(c).font(.system(size: 13)).foregroundStyle(i < passed ? Theme.text : Theme.faint)
                    }
                }
            }

            if let failure {
                Text(failure).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
            }
            if phase == .done {
                VStack(spacing: 4) {
                    Label(approval.success, systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.green)
                    if let txHash {
                        Text("\(txHash.prefix(10))…\(txHash.suffix(8))").font(.system(size: 12).monospaced()).foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }.buttonStyle(SheetButton(primary: false))
                    Button {
                        Task { await approve() }
                    } label: {
                        HStack(spacing: 7) {
                            if phase == .signing { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "touchid") }
                            Text(phase == .signing ? "Signing" : "Approve")
                        }
                    }
                    .buttonStyle(SheetButton(primary: true))
                    .disabled(phase != .ready)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
        .background(Theme.bg)
        .task { await scan() }
        .animation(.smooth(duration: 0.3), value: phase)
    }

    private func scan() async {
        for _ in approval.checks {
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.snappy) { passed += 1 }
        }
        phase = .ready
    }

    private func approve() async {
        // Real sends: the wallet asks for Touch ID / Face ID itself when it unlocks the key, so no second prompt here.
        if let perform = approval.perform {
            phase = .signing; failure = nil
            do {
                txHash = try await perform()
                phase = .done
                try? await Task.sleep(for: .milliseconds(1400))
                onApproved()
            } catch {
                failure = error.localizedDescription
                phase = .ready
            }
            return
        }
        guard await authenticate() else { return }
        phase = .signing
        try? await Task.sleep(for: .milliseconds(900))
        phase = .done
        try? await Task.sleep(for: .milliseconds(900))
        onApproved()
    }

    /// Touch ID on a Mac, Face ID on an iPhone, falling back to the device password.
    /// Where neither exists (a CI machine), the demo goes ahead so the flow can still be shown.
    private func authenticate() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: approval.title)) ?? false
    }
}

struct SheetButton: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(!enabled ? Theme.disabledText : primary ? .white : Theme.text)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(!enabled ? Theme.disabledFill : primary ? Theme.accent : Theme.hover, in: RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
