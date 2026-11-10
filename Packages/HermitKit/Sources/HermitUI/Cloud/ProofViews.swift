import SwiftUI
import HermitCore
import HermitCloud

/// Under a Private Cloud reply: what was verified, one tap from every check.
struct ProofChip: View {
    let proof: CloudProof
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(proof.headline).foregroundStyle(Theme.text)
                Text(proof.model.split(separator: "/").last.map(String.init) ?? proof.model).foregroundStyle(Theme.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.subtle, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .sheet(isPresented: $open) { ProofSheet(proof: proof) }
        #if DEBUG
        // Screenshots: -hermitProof YES opens the sheet once the proof arrives.
        .onAppear { if UserDefaults.standard.bool(forKey: "hermitProof") { open = true } }
        #endif
        .accessibilityLabel("\(proof.headline). Show what was checked")
    }

    private var icon: String { proof.failed.isEmpty ? (proof.fullyVerified ? "checkmark.shield.fill" : "checkmark.shield") : "xmark.shield" }
    private var tint: Color { proof.failed.isEmpty ? (proof.fullyVerified ? Theme.green : Theme.text) : Theme.red }
}

/// Every check behind a Private Cloud reply, with who did it: this phone, NVIDIA's attestation service, or nobody.
struct ProofSheet: View {
    let proof: CloudProof
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showMeasurements = false

    private var groups: [String] {
        var seen: [String] = []
        for c in proof.checks where !seen.contains(c.group) { seen.append(c.group) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            privacy
            facts
            ForEach(groups, id: \.self) { g in group(g) }
            measurements
            Button { openURL(NearAICloud.verificationCenter) } label: {
                Label("Check it again in NEAR's Verification Center", systemImage: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(PlainCardButton())
        }
        .padding(.horizontal, 22).padding(.top, SheetMetricsTop.value).padding(.bottom, 24)
        .frame(maxWidth: 560)
        .proofSheetChrome()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: proof.failed.isEmpty ? "checkmark.shield.fill" : "xmark.shield.fill")
                .font(.system(size: 26)).foregroundStyle(proof.failed.isEmpty ? Theme.green : Theme.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(proof.headline).font(.serif(24))
                Text(summary).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            #if os(macOS)
            Button("Done") { dismiss() }.buttonStyle(PlainCardButton())
            #endif
        }
    }

    private var summary: String {
        let passed = proof.checks.filter { $0.status == .pass }.count
        let skipped = proof.checks.filter { $0.status == .skipped }.count
        var s = "\(passed) checks passed"
        if !proof.failed.isEmpty { s += ", \(proof.failed.count) failed" }
        if skipped > 0 { s += ", \(skipped) not checked" }
        return s + "."
    }

    private var privacy: some View {
        NoteBox(symbol: "lock", text: proof.completions == 0
                ? "Your message was not sent. Attestation needs no key, so \(Device.here) checked the enclave without sending anything about you."
                : "Your prompt left \(Device.here) only after the enclave passed these checks, and only to that enclave over HTTPS. Hermit has no server and keeps this chat on \(Device.here). NEAR's gateway keeps the signed hashes of this exchange so the signature could be fetched.")
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 0) {
            fact("Model", proof.model)
            fact("TEE", proof.tee)
            fact("Nonce", proof.nonce, mono: true)
            if let s = proof.modelSigner { fact("Model signer", s, mono: true) }
            if let g = proof.gatewaySigner { fact("Gateway signer", g, mono: true) }
            if proof.completions > 0 {
                fact("Signed", "\(proof.signedCompletions) of \(proof.completions) completions by the model enclave")
            }
            fact("Evidence", proof.fetchedAt.formatted(date: .omitted, time: .standard))
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }

    private func fact(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(k).font(.system(size: 12.5)).foregroundStyle(Theme.muted).frame(width: 96, alignment: .leading)
            Text(v).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 13)).foregroundStyle(Theme.text)
                .lineLimit(mono ? 1 : 3).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func group(_ g: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(g).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).textCase(.uppercase).tracking(0.4)
            VStack(alignment: .leading, spacing: 0) {
                let rows = proof.checks.filter { $0.group == g }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, c in
                    if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                    row(c)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        }
    }

    private func row(_ c: CloudProof.Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.status == .pass ? "checkmark.circle.fill" : c.status == .fail ? "xmark.circle.fill" : "minus.circle")
                .font(.system(size: 14)).foregroundStyle(c.status == .pass ? Theme.green : c.status == .fail ? Theme.red : Theme.faint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 13.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                if !c.detail.isEmpty {
                    Text(c.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(source(c)).font(.system(size: 11)).foregroundStyle(Theme.faint).multilineTextAlignment(.trailing).fixedSize()
        }
        .padding(.vertical, 10)
    }

    private func source(_ c: CloudProof.Check) -> String {
        switch c.source {
        case .device: "This phone"
        case .remote: "NVIDIA"
        case .none: c.status == .skipped ? "Not checked" : ""
        }
    }

    @ViewBuilder private var measurements: some View {
        if !proof.measurements.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.snappy) { showMeasurements.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("Measurements, from the model's quote").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                            .textCase(.uppercase).tracking(0.4)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                            .rotationEffect(.degrees(showMeasurements ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMeasurements {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(proof.measurements, id: \.self) { m in
                            if m.count == 2 { fact(m[0], m[1], mono: true) }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                    .transition(.opacity)
                }
            }
        }
    }
}

extension View {
    /// iPhone: a tall paper-tint glass sheet that scrolls. Mac: a plain sheet with a fixed width.
    @ViewBuilder func proofSheetChrome() -> some View {
        #if os(iOS)
        ScrollView { self.frame(maxWidth: .infinity) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
            .glassSheetBackground()
        #else
        ScrollView { self }.frame(width: 560, height: 680).background(Theme.bg)
        #endif
    }
}
