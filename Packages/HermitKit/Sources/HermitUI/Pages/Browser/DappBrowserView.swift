import SwiftUI
import WebKit
import HermitWallet

/// The browser: a bar with Close, back, forward, the address (the site's host is always shown, with its lock) and a
/// menu, then any site warnings, then the page.
struct DappBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Bindable var session: DappBrowserSession
    @State private var editing = false
    @State private var text = ""
    @State private var width: CGFloat = 1000
    @FocusState private var focused: Bool

    private var compact: Bool { width < 560 }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack(alignment: .topLeading) {
                Hairline()
                if session.loading {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                        .frame(width: max(24, width * session.progress), alignment: .leading)
                        .animation(.smooth(duration: 0.25), value: session.progress)
                        .transition(.opacity)
                }
            }
            .frame(height: 2, alignment: .top)
            notices
            ZStack {
                DappWebView(webView: session.webView)
                if let f = session.failure {
                    EmptyState(symbol: "wifi.exclamationmark", title: "This page didn't load", text: f) {
                        Button("Try again") { session.reload() }.buttonStyle(OutlineButton())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
                }
            }
        }
        .background(Theme.bg)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { DappBrowser.shared.model = model }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: compact ? 4 : 6) {
            PayIconButton(symbol: "xmark", label: "Close browser") { DappBrowser.shared.close() }
            if !compact || !editing {
                PayIconButton(symbol: "chevron.left", label: "Back") { session.back() }
                    .disabled(!session.canGoBack).opacity(session.canGoBack ? 1 : 0.35)
                PayIconButton(symbol: "chevron.right", label: "Forward") { session.forward() }
                    .disabled(!session.canGoForward).opacity(session.canGoForward ? 1 : 0.35)
            }
            address
            if !compact {
                PayIconButton(symbol: session.loading ? "xmark.circle" : "arrow.clockwise", label: session.loading ? "Stop" : "Reload") { session.reload() }
            }
            menu
        }
        .padding(.horizontal, compact ? 10 : 14).padding(.vertical, 8)
    }

    /// Host in full, always: the lock (or "Not secure"), the host, then the path faint. Tap to type an address.
    private var address: some View {
        Group {
            if editing {
                TextField("Address", text: $text)
                    .textFieldStyle(.plain).focused($focused).autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL).submitLabel(.go)
                    #endif
                    .onSubmit { session.load(text); editing = false }
                    .onChange(of: focused) { _, f in if !f { editing = false } }
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
            } else {
                Button {
                    text = session.url?.absoluteString ?? ""
                    editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: session.secure ? "lock.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(session.secure && session.warnings.isEmpty ? Theme.muted : Theme.amber)
                        if !session.secure { Text("Not secure").foregroundStyle(Theme.amber).fixedSize() }
                        Text("\(Text(session.host).foregroundStyle(Theme.text).fontWeight(.medium))\(Text(compact ? "" : pathText).foregroundStyle(Theme.hint))")
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        connection
                    }
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Address \(session.host). Tap to edit.")
            }
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(editing ? Theme.text.opacity(0.25) : .clear))
    }

    private var pathText: String {
        guard let u = session.url else { return "" }
        let p = u.path(percentEncoded: false)
        return p == "/" ? "" : p
    }

    /// A green dot and the network when this site is connected to a wallet.
    @ViewBuilder private var connection: some View {
        if session.connected != nil, let c = session.chain {
            HStack(spacing: 5) {
                Circle().fill(Theme.green).frame(width: 6, height: 6)
                if !compact { Text(c.name).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize() }
            }
            .accessibilityLabel("Connected on \(c.name)")
        }
    }

    private var menu: some View {
        Menu {
            if let s = session.connected {
                Section("Connected: \(s.address.isEmpty ? SolanaDecoder.short(s.solana ?? "") : DappDecoder.short(s.address))") {
                    if session.evmConnected { Menu("Network") {
                        ForEach(DappProvider.evmChains.filter { !$0.isTestnet || WalletsViewModel.shared.service.showTestnets }) { c in
                            Button { session.switchChain(c) } label: {
                                if c == session.chain { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                            }
                        }
                    } }
                    Button("Disconnect this site", systemImage: "xmark.circle") { session.disconnect() }
                }
            }
            if compact {
                Button(session.loading ? "Stop" : "Reload", systemImage: "arrow.clockwise") { session.reload() }
            }
            if let u = session.url {
                if SavedSites.shared.contains(u) {
                    Button("Remove from Your sites", systemImage: "star.slash") { SavedSites.shared.remove(u); model.toast("Removed from Your sites") }
                } else {
                    Button("Add to Your sites", systemImage: "star") { SavedSites.shared.add(u, title: session.title); model.toast("Added to Your sites") }
                }
                Button("Open in Safari", systemImage: "safari") { openURL(u) }
                Button("Copy link", systemImage: "doc.on.doc") { PayClipboard.copy(u.absoluteString); model.toast("Copied") }
            }
            Button("Connected sites", systemImage: "list.bullet") { model.open(.settings, tab: "sites") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: PayMetrics.icon, height: PayMetrics.icon).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Page menu")
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        let warnings = session.warnings
        if !warnings.isEmpty || !session.secure {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                }
                if !session.secure && session.url != nil {
                    Label("This page isn't encrypted (http). Hermit's wallet stays off here.", systemImage: "lock.slash")
                        .foregroundStyle(Theme.amber)
                }
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(warnings.isEmpty ? Theme.subtle : Theme.amber.opacity(0.08))
        }
    }
}

// MARK: Web view

#if os(iOS)
struct DappWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#else
struct DappWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#endif
