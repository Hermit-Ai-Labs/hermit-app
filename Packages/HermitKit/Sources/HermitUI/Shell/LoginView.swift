import SwiftUI
import AVFoundation
import HermitCore

/// First launch: no account, just what Hermit should call you. The headline on the left, the crab film on the
/// right (wide windows only). The name is kept on this device and can be changed in Settings > Profile.
struct LoginView: View {
    let onDone: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

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
    }

    private var left: some View {
        VStack(spacing: 0) {
            HStack { HermitMark(height: 20); Spacer() }.padding(.horizontal, 32).padding(.top, 28)
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                Text("Your almighty intern").font(.serif(52)).tracking(-0.8).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(2)
                Text("Private AI that runs on this device.").font(.serif(20)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).padding(.top, 12)
                card
                    .padding(28).frame(maxWidth: 420)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.05), radius: 24, y: 10)
                    .padding(.top, 40)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 24)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should Hermit call you?").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            TextField(text: $name, prompt: Text("Your name").foregroundStyle(Theme.faint)) { Text("Name") }
                .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.text)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.words).textContentType(.givenName).submitLabel(.continue)
                #endif
                .padding(.horizontal, 16).frame(height: 46)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Theme.faint : Theme.border))
                .onSubmit(done)
            Button("Continue", action: done)
                .buttonStyle(LoginButton(dark: true)).disabled(trimmed.isEmpty)
                .padding(.top, 2)
            Text("No account. Your name, chats and keys stay on this device.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 6)
        }
        .onAppear { if !SnapshotMode.active { focused = true } }
    }

    private func done() {
        guard !trimmed.isEmpty else { return }
        onDone(String(trimmed.prefix(40)))
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
