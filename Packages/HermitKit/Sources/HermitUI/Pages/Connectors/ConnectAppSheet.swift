import SwiftUI

/// Demo sign-in for third-party accounts: consent, a short redirect, then connected.
/// Telegram instead shows @HermitBot with a QR code and a code to send.
struct ConnectAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: String
    let onDone: () -> Void

    enum Step { case consent, wait, done }
    @State private var step: Step = .consent
    @State private var server = "Monad Community"

    struct Scope { let who: String, ok: String, scopes: [String], never: String; var servers: [String] = [] }
    static let scopes: [String: Scope] = [
        "X": Scope(who: "@ryanchi", ok: "Authorize app", scopes: ["Read your posts and profile", "Read who you follow", "Post and reply, only when you ask"],
                   never: "Hermit can never DM, follow or delete on its own."),
        "Discord": Scope(who: "ryanchi", ok: "Authorize", scopes: ["Know your username and avatar", "See servers you are in", "Read roles in airdrop servers"],
                         never: "Hermit cannot read your DMs or send messages as you.", servers: ["Monad Community", "Hyperliquid", "Kaito Yappers", "Hermit Alpha"]),
        "Gmail": Scope(who: "ryan@hermit.app", ok: "Allow", scopes: ["Read email", "Create drafts"], never: "Hermit never sends email without your approval."),
        "Google Calendar": Scope(who: "ryan@hermit.app", ok: "Allow", scopes: ["See and edit events"], never: "Hermit asks before inviting anyone."),
        "GitHub": Scope(who: "RyanRuianChi", ok: "Authorize", scopes: ["Read repositories", "Open pull requests"], never: "Hermit cannot delete repos or change settings."),
    ]
    private var s: Scope { Self.scopes[app] ?? Scope(who: "ryan@hermit.app", ok: "Allow", scopes: ["Read your data", "Act when you ask"], never: "Hermit asks before anything that costs money.") }

    var body: some View {
        SheetChrome(title: "Connect \(app)") {
            VStack(spacing: 16) {
                switch step {
                case .done: done
                case .wait:
                    pair
                    ProgressView().controlSize(.regular)
                    Text("Returning to Hermit…").font(.system(size: 13)).foregroundStyle(Theme.muted)
                case .consent:
                    if app == "Telegram" { telegram } else { consent }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .animation(.smooth(duration: 0.3), value: step)
        }
        .task(id: step) {
            // Telegram: the bot confirms the code by itself after a moment.
            guard app == "Telegram", step == .consent else { return }
            try? await Task.sleep(for: .seconds(4.5))
            if !Task.isCancelled { finish() }
        }
    }

    private var pair: some View {
        HStack(spacing: 14) {
            LogoMark("hermit", size: 46)
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 13)).foregroundStyle(Theme.faint)
            LogoMark(app, size: 46)
        }
    }

    @ViewBuilder private var consent: some View {
        pair
        Text("Hermit wants to access your \(app) account").font(.system(size: 15.5, weight: .semibold)).multilineTextAlignment(.center)
        HStack(spacing: 7) {
            LogoMark(app, size: 18)
            Text(s.who).font(.system(size: 13))
        }
        .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
        .overlay(Capsule().strokeBorder(Theme.border))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(s.scopes.enumerated()), id: \.offset) { _, x in
                Label { Text(x) } icon: { Image(systemName: "checkmark").foregroundStyle(Theme.green) }
                    .font(.system(size: 13.5)).padding(.vertical, 9)
                Hairline()
            }
            Label { Text(s.never) } icon: { Image(systemName: "checkmark.shield") }
                .font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.vertical, 9)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        if !s.servers.isEmpty {
            FormField(label: "Add Hermit to a server") {
                MenuField(selection: $server, options: s.servers, title: { $0 })
            }
        }
        HStack(spacing: 8) {
            Button("Cancel") { dismiss() }.buttonStyle(WideButton(kind: .plain))
            Button(s.ok) {
                withAnimation(.smooth) { step = .wait }
                Task { try? await Task.sleep(for: .milliseconds(1300)); finish() }
            }
            .buttonStyle(WideButton(kind: .accent)).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var telegram: some View {
        pair
        Text("Open @HermitBot and tap Start").font(.system(size: 15.5, weight: .semibold))
        AddressQR(text: "https://t.me/HermitBot?start=HRM-4821").frame(width: 132, height: 132)
            .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        Button { Clip.copy("HRM-4821"); model.toast("Code copied") } label: {
            HStack(spacing: 8) {
                Text("HRM-4821").font(.system(size: 15, weight: .medium, design: .monospaced))
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
        .buttonStyle(PressStyle())
        Text("Or send this code to @HermitBot. Alerts and approvals will arrive in that chat.")
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for Telegram").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
        }
        Button("I tapped Start") { finish() }.buttonStyle(WideButton(kind: .plain))
    }

    @ViewBuilder private var done: some View {
        Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 48, height: 48).background(Theme.green, in: Circle())
            .transition(.scale.combined(with: .opacity))
        Text("\(app) connected").font(.system(size: 16, weight: .semibold))
        Text("Signed in as \(s.who)\(app == "Discord" ? ", added to \(server)" : "").")
            .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        Button("Done") { dismiss() }.buttonStyle(WideButton()).keyboardShortcut(.defaultAction)
    }

    private func finish() {
        guard step != .done else { return }
        onDone()
        withAnimation(.bouncy) { step = .done }
    }
}

/// Add an MCP server by URL or command.
struct AddMcpSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String) -> Void
    @State private var url = ""
    @State private var name = ""
    var body: some View {
        SheetChrome(title: "Add MCP server") {
            FormField(label: "Server URL or command") { BoxedTextField(placeholder: "https://mcp.example.com or npx my-server", text: $url, mono: true) }
            FormField(label: "Name") { BoxedTextField(placeholder: "Optional", text: $name) }
            NoteBox(symbol: "checkmark.shield", text: "Hermit asks before any tool from this server moves money.")
        } foot: {
            Button("Connect") {
                let u = url.trimmingCharacters(in: .whitespaces)
                let n = name.trimmingCharacters(in: .whitespaces)
                let host = u.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").split(separator: "/").first.map(String.init) ?? u
                onAdd(n.isEmpty ? host : n)
                dismiss()
            }
            .buttonStyle(WideButton()).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
        }
    }
}
