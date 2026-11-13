import SwiftUI
import HermitCore
import HermitWallet

/// Settings > Safety: Hermit AI insurance on hermit-insurance.near. Turning it on also turns on the Black Box, whose
/// records are the evidence for a claim. The owner of the contract also sees the claims here and decides them.
struct InsuranceSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var until: Date?
    @State private var info: AIInsurance.Info?
    @State private var claims: [AIInsurance.Claim] = []
    @State private var busy = false
    @State private var filing = false
    @State private var pick: String = ""
    @State private var loss = ""
    @State private var note = ""
    @State private var reason = ""
    @State private var boxOn = BlackBox.isOn

    private var service: WalletService { WalletsViewModel.shared.service }
    private var wallet: WalletRecord? { service.wallets.first { $0.nearAccount != nil } }
    private var isOwner: Bool { info != nil && info?.owner == wallet?.nearAccount }
    private var records: [BlackBox.Entry] { Array(BlackBox.log.prefix(20)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if until != nil {
                SettingRow(title: "File a claim", sub: records.isEmpty
                           ? "Claims use your Black Box records. None yet: approve a move the AI prepared first"
                           : "Pick the move the AI got wrong. Its Black Box record is the evidence") {
                    Button(filing ? "Close" : "Start") { withAnimation(.smooth) { filing.toggle() } }
                        .buttonStyle(HoloPillButton()).disabled(records.isEmpty)
                }
                if filing { claimForm.padding(.bottom, 12) }
            }
            if isOwner {
                Hairline()
                SettingRow(title: "Claims", sub: "You own hermit-insurance.near. Only your approval pays out, and the reason goes on chain") {
                    Button("Refresh") { Task { await load() } }.buttonStyle(HoloPillButton())
                }
                ownerList
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: BlackBox.changed)) { _ in boxOn = BlackBox.isOn }
        .onReceive(NotificationCenter.default.publisher(for: AIInsurance.changed)) { _ in if let a = wallet?.nearAccount { until = AIInsurance.knownUntil(a) } }
    }

    private var status: String {
        let pool = info.map { " Pool: \(MoneyFmt.usd(NSDecimalNumber(decimal: $0.pool).doubleValue)), paid out \(MoneyFmt.usd(NSDecimalNumber(decimal: $0.paidOut).doubleValue))." } ?? ""
        if let until { return "Covered until \(until.formatted(date: .abbreviated, time: .omitted)).\(pool)" }
        return "1 USDC on NEAR for 30 days. If the AI's mistake costs you money, approved claims are paid from a public pool. Turn on the Black box above first: its record is the proof for a claim.\(pool)"
    }

    private var claimForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Move", selection: $pick) {
                ForEach(records) { r in
                    Text("\(r.date.formatted(date: .abbreviated, time: .shortened))  \(r.kind)").tag(r.fp)
                }
            }
            .pickerStyle(.menu)
            field("Loss in USDC", text: $loss)
            field("What went wrong", text: $note)
            Button(busy ? "…" : "File claim (0.05 NEAR deposit)") { Task { await file() } }
                .buttonStyle(HoloPillButton()).disabled(busy || pick.isEmpty || Decimal(string: loss) == nil)
        }
        .onAppear { if pick.isEmpty { pick = records.first?.fp ?? "" } }
    }

    private var ownerList: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Reason (goes on chain)", text: $reason)
            ForEach(claims) { c in
                VStack(alignment: .leading, spacing: 4) {
                    Text("#\(c.id)  \(c.status)  loss \(usd(c.loss))\(c.paid > 0 ? "  paid \(usd(c.paid))" : "")")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    Text("AI: \(c.aiVerdict ?? "not reviewed yet")\(c.aiReason.map { ". " + $0 } ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    if !c.note.isEmpty { Text(c.note).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    if c.status == "open" {
                        HStack(spacing: 8) {
                            Button("Approve \(usd(c.loss))") { Task { await decide(c, approve: true) } }.buttonStyle(HoloPillButton())
                            Button("Reject") { Task { await decide(c, approve: false) } }.buttonStyle(HoloPillButton())
                        }
                        .disabled(busy || reason.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
            }
            if claims.isEmpty { Text("No claims yet.").font(.system(size: 12.5)).foregroundStyle(Theme.hint) }
        }
        .padding(.bottom, 12)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(text: text, prompt: Text(title).foregroundStyle(Theme.hint)) { Text(title) }
            .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Theme.text)
            .padding(.horizontal, 12).frame(height: 36)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }

    private func usd(_ d: Decimal) -> String { MoneyFmt.usd(NSDecimalNumber(decimal: d).doubleValue) }

    private func load() async {
        info = try? await AIInsurance.info()
        if let a = wallet?.nearAccount {
            until = AIInsurance.knownUntil(a) ?? until
            if let c = try? await AIInsurance.coveredUntil(a) { until = c }
        }
        if isOwner { claims = (try? await AIInsurance.claims()) ?? [] }
    }

    private func buy() async {
        guard let w = wallet else { return }
        busy = true; defer { busy = false }
        do {
            guard BlackBox.isOn else { model.toast("Turn on the Black box first", kind: .info); return }
            _ = try await service.buyInsurance(walletID: w.id)
            model.toast("AI insurance on for 30 days")
            await load()
        } catch { model.toast(error.localizedDescription, kind: .info) }
    }

    private func file() async {
        guard let w = wallet, let r = records.first(where: { $0.fp == pick }), let l = Decimal(string: loss), l > 0 else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await service.fileInsuranceClaim(walletID: w.id, record: r, lossUSD: l, note: note)
            model.toast("Claim filed. The review and decision will show on chain")
            filing = false; loss = ""; note = ""
            await load()
        } catch { model.toast(error.localizedDescription, kind: .info) }
    }

    private func decide(_ c: AIInsurance.Claim, approve: Bool) async {
        guard let w = wallet else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await service.decideInsuranceClaim(walletID: w.id, id: c.id, approve: approve, awardUSD: c.loss, reason: reason)
            model.toast(approve ? "Approved. Paid from the pool" : "Rejected")
            reason = ""
            await load()
        } catch { model.toast(error.localizedDescription, kind: .info) }
    }
}
