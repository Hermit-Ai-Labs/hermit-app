import SwiftUI
import AVFoundation
import HermitCore

/// Signed in or not, kept across launches. The sign-in page shows on first launch only.
public enum SignIn {
    public static let key = "hermit.signedIn"
}

/// Sign-in, modelled on Claude's: the headline on the left, the crab film on the right (wide windows only).
/// Google and Apple show "Signing in…"; email goes to a six-digit code with a demo code.
struct LoginView: View {
    let onDone: () -> Void
    enum Step { case start, code, busy }
    @State private var step: Step = .start
    @State private var email = ""
    @State private var code = ""
    @State private var via = ""
    @State private var downloadNote = false
    @FocusState private var codeFocused: Bool
    @FocusState private var emailFocused: Bool

    private var valid: Bool { email.range(of: #"^\S+@\S+\.\S+$"#, options: .regularExpression) != nil }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > 860
            HStack(spacing: 0) {
                left.frame(maxWidth: .infinity)
                if wide {
                    film.frame(width: min(g.size.width * 0.46, 620)).padding(28)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .animation(.smooth(duration: 0.35), value: step)
    }

    private var left: some View {
        VStack(spacing: 0) {
            HStack { HermitMark(height: 20); Spacer() }.padding(.horizontal, 32).padding(.top, 28)
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                Text("Your almighty intern").font(.serif(52)).tracking(-0.8).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(2)
                Text("Pay, earn and build in one place. Fully private.").font(.serif(20)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).padding(.top, 12)
                cardBody
                    .padding(28).frame(maxWidth: 420)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.05), radius: 24, y: 10)
                    .padding(.top, 40)
                Button { withAnimation(.snappy) { downloadNote = true } } label: {
                    Label(downloadNote ? "Mac app ships with the beta" : "Download desktop app", systemImage: "apple.logo")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.hover, in: RoundedRectangle(cornerRadius: 11))
                        .contentTransition(.opacity)
                }
                .buttonStyle(PressStyle()).padding(.top, 28)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 24)
        }
    }

    @ViewBuilder private var cardBody: some View {
        switch step {
        case .start:
            VStack(spacing: 12) {
                Button { go("Google") } label: {
                    HStack(spacing: 10) { Image.hermit("google-g").resizable().frame(width: 17, height: 17); Text("Continue with Google") }
                }
                .buttonStyle(LoginButton())
                Button { go("Apple") } label: {
                    HStack(spacing: 10) { Image(systemName: "apple.logo").font(.system(size: 15)); Text("Continue with Apple") }
                }
                .buttonStyle(LoginButton())
                Text("OR").font(.system(size: 11.5)).tracking(1).foregroundStyle(Theme.faint).padding(.vertical, 6)
                TextField(text: $email, prompt: Text("Enter your email").foregroundStyle(Theme.faint)) { Text("Email") }
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($emailFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.emailAddress).textContentType(.emailAddress)
                    #endif
                    .padding(.horizontal, 16).frame(height: 46)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(emailFocused ? Theme.faint : Theme.border))
                    .onSubmit { if valid { step = .code } }
                Button("Continue with email") { step = .code }
                    .buttonStyle(LoginButton(dark: true)).disabled(!valid)
                Text("Keys stay on your device. Hermit never holds your funds.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).padding(.top, 8)
            }
            .transition(.opacity)
        case .code:
            VStack(spacing: 14) {
                HStack {
                    Button { step = .start; code = "" } label: { Label("Back", systemImage: "arrow.left").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    Spacer()
                }
                Image(systemName: "envelope").font(.system(size: 18)).foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44).background(Theme.hover, in: Circle())
                Text("Check your email").font(.system(size: 17, weight: .semibold))
                (Text("We sent a code to ") + Text(email).bold()).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                ZStack {
                    TextField("", text: $code)
                        .focused($codeFocused).opacity(0.01).frame(width: 1, height: 1)
                        #if os(iOS)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        #endif
                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { i in
                            let ch = i < code.count ? String(Array(code)[i]) : ""
                            Text(ch).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                                .frame(width: 44, height: 52)
                                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(i == code.count && codeFocused ? Theme.text : Theme.border, lineWidth: i == code.count && codeFocused ? 1.5 : 1))
                                .contentTransition(.numericText())
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { codeFocused = true }
                }
                Button("Use demo code") { fillDemo() }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .onAppear { codeFocused = true }
            .onChange(of: code) { _, v in
                let digits = String(v.filter(\.isNumber).prefix(6))
                if digits != v { code = digits }
                if digits.count == 6 { go("email") }
            }
            .transition(.opacity)
        case .busy:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(via == "email" ? "Signing in…" : "Signing in with \(via)…").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .transition(.opacity)
        }
    }

    private func fillDemo() {
        Task {
            for d in "482913" {
                try? await Task.sleep(for: .milliseconds(70))
                withAnimation(.snappy(duration: 0.15)) { code.append(d) }
            }
        }
    }

    private func go(_ how: String) {
        via = how; step = .busy
        Task { try? await Task.sleep(for: .milliseconds(1100)); onDone() }
    }

    /// The crab travelling the world, muted and looping. A still in snapshots.
    private var film: some View {
        ZStack {
            Color(hex: 0x2A1A4A)
            if SnapshotMode.active {
                Image.hermitJPG("login-film").resizable().scaledToFill()
            } else {
                LoopingVideo(name: "login-film")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }
}

struct LoginButton: ButtonStyle {
    var dark = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .foregroundStyle(dark ? .white : Theme.text)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(dark ? Theme.text.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.35) : (configuration.isPressed ? Color(hex: 0xEDEDEC) : Theme.hover),
                        in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension Image {
    static func hermitJPG(_ name: String) -> Image {
        #if os(macOS)
        if let url = Bundle.module.url(forResource: name, withExtension: "jpg"), let img = NSImage(contentsOf: url) { return Image(nsImage: img) }
        #else
        if let url = Bundle.module.url(forResource: name, withExtension: "jpg"), let img = UIImage(contentsOfFile: url.path) { return Image(uiImage: img) }
        #endif
        return Image(systemName: "photo")
    }
}

/// A muted, looping video filling its frame (AVPlayerLooper behind a layer).
struct LoopingVideo: View {
    let name: String
    var body: some View {
        if let url = Bundle.module.url(forResource: name, withExtension: "mp4") {
            PlayerLayerView(url: url)
        } else {
            Image.hermitJPG(name).resizable().scaledToFill()
        }
    }
}

final class LoopingPlayer {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    init(url: URL) {
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }
}

#if os(macOS)
struct PlayerLayerView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: context.coordinator.player)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = CALayer()
        v.layer?.addSublayer(layer)
        layer.frame = v.bounds
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        v.layer?.sublayers?.first?.frame = v.bounds
    }
    func makeCoordinator() -> LoopingPlayer { LoopingPlayer(url: url) }
}
#else
struct PlayerLayerView: UIViewRepresentable {
    let url: URL
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = context.coordinator.player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: PlayerView, context: Context) {}
    func makeCoordinator() -> LoopingPlayer { LoopingPlayer(url: url) }
}
#endif
