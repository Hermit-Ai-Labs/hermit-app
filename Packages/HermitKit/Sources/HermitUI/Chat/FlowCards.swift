import SwiftUI
import HermitCore

/// A website opened inside Hermit (checkout pages, launchpads), so you never leave the app.
struct InAppTab<Content: View>: View {
    let url: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.border).frame(width: 9, height: 9) }
                }
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(url).lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6).background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 26, height: 26).background(Theme.hover, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(22)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .sheetWidth(440)
    }
}

/* ---------- 1. Developer buys an API key without leaving Hermit ---------- */

struct BuildProgressCard: View {
    let steps: [(String, String, Bool)] = [("Frontend", "12 screens, React + Tailwind", true), ("Bank sync", "CSV import, Plaid later", true),
                                           ("AI categorizer", "Needs an LLM API key", false), ("Budgets and alerts", "Next", false)]
    var body: some View {
        ChatCard {
            CardTitle("Budgeting app")
            Spacer()
            Text("2 of 4 done").font(.system(size: 12)).foregroundStyle(Theme.faint)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 12) {
                        ZStack {
                            if s.2 {
                                Circle().fill(Theme.green).frame(width: 18, height: 18)
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            } else if i == 2 {
                                Circle().strokeBorder(Theme.accent, lineWidth: 2).frame(width: 18, height: 18)
                                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                    .phaseAnimator([1.0, 0.3]) { c, o in c.opacity(o) } animation: { _ in .smooth(duration: 0.8) }
                            } else {
                                Circle().strokeBorder(Theme.border, lineWidth: 1.5).frame(width: 18, height: 18)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.0).font(.system(size: 13.5, weight: s.2 || i == 2 ? .medium : .regular)).foregroundStyle(s.2 || i == 2 ? Theme.text : Theme.faint)
                            Text(s.1).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}

struct ApiCheckoutCard: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var plan = 25

    private var approval: Approval {
        Approval(kind: "API purchase", title: "OpenAI $\(plan) credits",
                 lines: [["Seller", "OpenAI (verified)"], ["Amount", "\(plan) USDC"], ["Pay with", "USDC via x402"], ["Key goes to", "Local vault and .env.local"]],
                 checks: Approval.checks(["Seller matches registry", "Within dev budget ($60 left)"]), success: "Key added to your project")
    }
    private var bought: Int? { [10, 25, 50].first { model.approvedIDs.contains("OpenAI $\($0) credits") } }

    var body: some View {
        ChatCard {
            LogoMark("OpenAI", size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenAI API").font(.system(size: 13.5, weight: .medium))
                Text(bought != nil ? "Connected" : "Needed for the categorizer").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if bought != nil { StatusTag(text: "Active") }
        } content: {
            if let b = bought {
                VStack(spacing: 4) {
                    HStack {
                        Text("sk-proj-7Hq2…a8F2").font(Theme.mono)
                        Spacer()
                        Button { Clipboard.copy("sk-proj-7Hq2…a8F2"); model.toast("Key copied") } label: { Image(systemName: "doc.on.doc").font(.system(size: 12)) }
                            .buttonStyle(PressStyle()).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                    .padding(.bottom, 6)
                    TxLine("Saved to", ".env.local, local vault")
                    TxLine("Credits", "$\(b), auto top-up off")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                Text("You don't have an OpenAI key yet. Buy credits here, no need to visit their site.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        } foot: {
            if bought == nil {
                Button { open = true } label: { Label("Get API key", systemImage: "arrow.up.right.square") }
                    .buttonStyle(BrandButton())
            }
        }
        .animation(.smooth, value: bought)
        .sheet(isPresented: $open) {
            InAppTab(url: "platform.openai.com/settings/billing") {
                HStack(spacing: 10) {
                    LogoMark("OpenAI", size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add API credits").font(.system(size: 15, weight: .semibold))
                        Text("Project: budget-app").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                }
                HStack(spacing: 8) {
                    ForEach([10, 25, 50], id: \.self) { v in
                        Button { withAnimation(.snappy) { plan = v } } label: {
                            VStack(spacing: 3) {
                                Text("$\(v)").font(.system(size: 15, weight: .semibold))
                                Text("≈ \((v * 4000).formatted()) calls").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(plan == v ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(plan == v ? Theme.text : Theme.border, lineWidth: plan == v ? 1.5 : 1))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                VStack(spacing: 0) { TxLine("Model", "gpt-5-mini"); TxLine("Key scope", "budget-app only") }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 11))
                Button {
                    open = false
                    let a = approval
                    Task { try? await Task.sleep(for: .milliseconds(350)); model.approval = a }
                } label: { Label("Pay $\(plan) with Hermit", systemImage: "touchid") }
                    .buttonStyle(BrandButton(full: true))
                Text("USDC via x402. No card, no account.").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
            }
        }
    }
}

/* ---------- 2. Send to many wallets from a spreadsheet, privately ---------- */

struct MultiSendCard: View {
    @Environment(AppModel.self) private var model
    @State private var relay = true
    @State private var sent = -1

    static let recipients: [(String, Int)] = (0..<48).map { i in
        func h(_ n: Int) -> String {
            let v = UInt32(truncatingIfNeeded: (i + 7) &* 2654435761 &+ n &* 40503)
            return String(String(format: "%08x", v).prefix(4))
        }
        return ("0x\(h(1))…\(h(2))", [500, 250, 1000, 300, 750][i % 5])
    }
    static let total = recipients.reduce(0) { $0 + $1.1 }
    static let title = "Send \(total.formatted()) USDC to 48 wallets"

    private var approval: Approval {
        Approval(kind: "Batch send", title: Self.title,
                 lines: [["Recipients", "48 (1 invalid removed)"], ["Total", "\(Self.total.formatted()) USDC"], ["Network", "Base"],
                         ["Route", relay ? "Private, via Relay" : "Direct"], ["Fee", relay ? "$2.88" : "$0.48"]],
                 checks: Approval.checks(["No sanctioned addresses", "No duplicate recipients", relay ? "Sender not linked on-chain" : "Sender visible on-chain"]),
                 success: "All 48 transfers sent")
    }

    var body: some View {
        let done = sent >= 48
        ChatCard {
            Image(systemName: "tablecells").foregroundStyle(Theme.green).font(.system(size: 14))
            CardTitle("wallets.xlsx")
            Spacer()
            Text("49 rows").font(.system(size: 12)).foregroundStyle(Theme.faint)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                KVGrid(pairs: [["Recipients", "48"], ["Total", "\(Self.total.formatted()) USDC"], ["Removed", "1 invalid"]], tones: ["Removed": .red])
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { i in
                        let r = Self.recipients[i]
                        HStack(spacing: 10) {
                            Text("\(i + 1)").foregroundStyle(Theme.faint).frame(width: 18, alignment: .leading)
                            Text(r.0).font(Theme.mono)
                            Spacer()
                            Text("\(r.1.formatted()) USDC").monospacedDigit()
                            ZStack {
                                if i < sent {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.green).transition(.scale.combined(with: .opacity))
                                } else if sent >= 0 {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .frame(width: 16)
                        }
                        .font(.system(size: 12.5))
                        .padding(.vertical, 7)
                        if i < 7 { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                    Text("+ 40 more").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 28).padding(.top, 6)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
                if sent >= 0 {
                    VStack(spacing: 6) {
                        HStack {
                            Text(done ? "All sent" : "Sending…")
                            Spacer()
                            Text("\(min(sent, 48)) / 48").monospacedDigit().contentTransition(.numericText(value: Double(sent)))
                        }
                        .font(.system(size: 12.5))
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hover)
                                Capsule().fill(Theme.green).frame(width: g.size.width * CGFloat(min(sent, 48)) / 48)
                            }
                        }
                        .frame(height: 5)
                    }
                    .transition(.opacity)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Private send via Relay").font(.system(size: 13, weight: .medium))
                            Text("Recipients can't trace it back to you").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Toggle("Private send via Relay", isOn: $relay).labelsHidden().toggleStyle(.switch).tint(Theme.text).controlSize(.small)
                    }
                }
            }
        } foot: {
            if done {
                Label("Done in 41s. Receipts saved to Files.", systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(Theme.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button { model.approval = approval } label: { Label("Send to 48 wallets", systemImage: "touchid") }
                    .buttonStyle(BrandButton()).disabled(sent >= 0)
            }
        }
        .animation(.smooth, value: sent >= 0)
        .onAppear { if model.approvedIDs.contains(Self.title) && sent < 0 { sent = 48 } }
        .onChange(of: model.approvedIDs.contains(Self.title)) { _, ok in if ok && sent < 0 { Task { await send() } } }
    }

    private func send() async {
        sent = 0
        while sent < 48 {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.snappy) { sent = min(48, sent + 3) }
        }
    }
}

/* ---------- 3. Launch a token on flap.sh in one tap ---------- */

struct FlapLaunchCard: View {
    @Environment(AppModel.self) private var model
    @State private var linked = false
    @State private var linking = false
    @State private var open = false
    static let title = "Deploy $HERMIT"
    static let desc = "The crab that runs your money. Community token for Hermit builders."

    private var live: Bool { model.approvedIDs.contains(Self.title) }

    private var approval: Approval {
        Approval(kind: "Token launch on flap.sh", title: Self.title,
                 lines: [["Network", "BNB Chain"], ["Supply", "1,000,000,000"], ["Initial buy", "0.5 BNB"], ["Launch fee", "0.01 BNB"], ["Curve", "flap.sh bonding curve"]],
                 checks: Approval.checks(["Contract is flap.sh factory", "No mint or freeze authority"]), success: "$HERMIT is live")
    }

    private func art(_ size: CGFloat) -> some View {
        Image.hermit("hermit-hero").resizable().interpolation(.high).scaledToFit().padding(size * 0.1)
            .frame(width: size, height: size)
            .background(Color(hex: 0xEDE7F7), in: RoundedRectangle(cornerRadius: size * 0.28))
    }

    var body: some View {
        ChatCard {
            art(34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text("Hermit Crab").font(.system(size: 13.5, weight: .medium))
                    Text("$HERMIT").font(.system(size: 13.5)).foregroundStyle(Theme.muted)
                }
                Text(live ? "Live on flap.sh" : "Ready to launch").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if live { StatusTag(text: "Live") } else { LogoMark("flap.sh", size: 24) }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if live {
                    KVGrid(pairs: [["Market cap", "$18.4k"], ["Holders", "37"], ["Curve", "6%"]]).padding(.bottom, 10)
                    TxLine("Contract", "0x9a4f…flap", mono: true)
                    TxLine("Your buy", "0.5 BNB, 28.1M HERMIT")
                } else {
                    ForEach([["Name", "Hermit Crab"], ["Ticker", "$HERMIT"], ["Supply", "1,000,000,000"], ["Initial buy", "0.5 BNB"], ["Links", "hermit.my, @hermit"]], id: \.self) {
                        TxLine($0[0], $0[1])
                    }
                    Text(Self.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 8)
                }
            }
        } foot: {
            if live {
                Button { open = true } label: { Label("View on flap.sh", systemImage: "arrow.up.right.square") }.buttonStyle(PlainCardButton())
                Button("Share on X") {
                    model.react("Share on X", "Draft posted to your X queue: \"$HERMIT is live on @flapdotsh. The crab that runs your money.\" Say \"post it\" to publish.")
                }
                .buttonStyle(BlackButton())
            } else if !linked {
                Button {
                    linking = true
                    Task { try? await Task.sleep(for: .milliseconds(1100)); withAnimation(.snappy) { linking = false; linked = true } }
                } label: {
                    HStack(spacing: 7) {
                        if linking { ProgressView().controlSize(.small).tint(.white) } else { LogoMark("flap.sh", size: 16) }
                        Text(linking ? "Connecting" : "Connect flap.sh")
                    }
                }
                .buttonStyle(BrandButton()).disabled(linking)
            } else {
                Button { open = true } label: { Label("Open launch page", systemImage: "arrow.up.right.square") }.buttonStyle(BrandButton())
            }
        }
        .sheet(isPresented: $open) {
            InAppTab(url: live ? "flap.sh/token/0x9a4f…flap" : "flap.sh/create") {
                HStack {
                    HStack(spacing: 8) { LogoMark("flap.sh", size: 24); Text("flap.sh").font(.system(size: 15, weight: .semibold)) }
                    Spacer()
                    StatusTag(text: "Connected as Main")
                }
                HStack(alignment: .top, spacing: 14) {
                    art(64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermit Crab").font(.system(size: 17, weight: .semibold))
                        Text("$HERMIT").foregroundStyle(Theme.muted)
                        Text(Self.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 4)
                    }
                }
                VStack(spacing: 0) { TxLine("Supply", "1,000,000,000"); TxLine("Initial buy", "0.5 BNB"); TxLine("Graduates at", "$69k market cap") }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 11))
                if live {
                    Label("Deployed. Trading is open.", systemImage: "checkmark").font(.system(size: 13)).foregroundStyle(Theme.green).frame(maxWidth: .infinity)
                } else {
                    Button {
                        open = false
                        let a = approval
                        Task { try? await Task.sleep(for: .milliseconds(350)); model.approval = a }
                    } label: { Label("Deploy", systemImage: "touchid") }
                        .buttonStyle(BrandButton(full: true))
                }
                Text("Details filled in by Hermit. Signed with your passkey.").font(.system(size: 12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity)
            }
        }
    }
}

extension View {
    /// Fixed width for a sheet on the Mac; on iPhone it fills the bottom sheet.
    @ViewBuilder func sheetWidth(_ w: CGFloat) -> some View {
        #if os(macOS)
        frame(width: w)
        #else
        frame(maxWidth: .infinity).presentationDetents([.large]).presentationCornerRadius(20)
        #endif
    }
}
