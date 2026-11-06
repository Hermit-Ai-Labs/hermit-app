import SwiftUI
import AVFoundation
import HermitCore

/// First launch: no account, just what Hermit should call you. Editorial type in the r4hu1.xyz manner: oversized
/// light serif with an italic last line, a dial of ticks in the corner, plain facts in grey, a name pill with a
/// glossy black button, and a warm glow over grid paper. Wide windows add the crab film on the right.
/// The name is kept on this device and can be changed in Settings > Profile.
struct LoginView: View {
    let onDone: (String) -> Void
    @State private var name = ""
    @State private var shown = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > 860
            HStack(spacing: 0) {
                page(width: wide ? g.size.width * 0.54 : g.size.width)
                if wide {
                    film.frame(width: min(g.size.width * 0.46, 620)).padding(28)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bg)
        .onAppear {
            if SnapshotMode.active || reduceMotion { shown = true } else { withAnimation(.smooth(duration: 1.1)) { shown = true } }
        }
    }

    private func page(width: CGFloat) -> some View {
        // Type scales with the column: about 66pt on a 393pt iPhone, capped on wide windows.
        let size = min(max(width * 0.168, 52), 92)
        return ZStack(alignment: .topTrailing) {
            WelcomeGlow().ignoresSafeArea()
            WelcomeDial(shown: shown).frame(width: 230, height: 230).offset(x: 70, y: -40).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                HermitMark(height: 20).padding(.top, 24)
                Spacer(minLength: 28)
                VStack(alignment: .leading, spacing: -size * 0.16) {
                    word("your", size: size, delay: 0)
                    word("almighty", size: size, delay: 0.08)
                    word("intern.", size: size, italic: true, delay: 0.16)
                }
                facts.padding(.top, 26).opacity(shown ? 1 : 0).animation(.smooth(duration: 0.8).delay(0.35), value: shown)
                Spacer(minLength: 28)
                ask.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 16).animation(.smooth(duration: 0.8).delay(0.45), value: shown)
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .clipped()
    }

    private func word(_ text: String, size: CGFloat, italic: Bool = false, delay: Double) -> some View {
        Text(text).font(.display(size, italic: italic)).tracking(-size * 0.025)
            .lineLimit(1).minimumScaleFactor(0.5)
            .offset(y: shown ? 0 : size * 0.6).opacity(shown ? 1 : 0)
            .animation(.smooth(duration: 1.0).delay(delay), value: shown)
            .accessibilityHidden(text != "intern.")
            .accessibilityLabel("Your almighty intern")
    }

    /// Plain, true facts in the manner of the site's proof line.
    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 8) {
            GridRow { Text("Runs offline"); Text("No account") }
            GridRow { Text("Keys on this phone"); Text("Nothing leaves it") }
        }
        .font(.system(size: 15)).foregroundStyle(Theme.muted)
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should Hermit call you?").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                TextField(text: $name, prompt: Text("Your name").foregroundStyle(Theme.faint)) { Text("Name") }
                    .textFieldStyle(.plain).font(.system(size: 17)).foregroundStyle(Theme.text)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.words).textContentType(.givenName).submitLabel(.continue)
                    #endif
                    .onSubmit(done)
                    .padding(.leading, 20)
                Button(action: done) {
                    Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(GlossyRound())
                .disabled(trimmed.isEmpty)
                .accessibilityLabel("Continue")
            }
            .padding(5)
            .frame(height: 58)
            .background(.white, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Theme.faint : Theme.border))
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
            Text("No account. Your name, chats and keys stay on this device.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
        .frame(maxWidth: 440, alignment: .leading)
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

/// The ring of ticks in the top corner. Each tick points at the centre; they fade in one after another.
private struct WelcomeDial: View {
    let shown: Bool
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = size.width / 2
            let n = 40
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let long = i % 5 == 0
                let inner = r - (long ? 22 : 14)
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                ctx.stroke(p, with: .color(Theme.text.opacity(long ? 0.85 : 0.45)), lineWidth: 1.2)
            }
        }
        .rotationEffect(.degrees(shown ? 0 : -24))
        .opacity(shown ? 1 : 0)
        .animation(.smooth(duration: 1.6), value: shown)
    }
}

/// Faint grid paper with a warm sun rising from the bottom edge.
private struct WelcomeGlow: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                Canvas { ctx, size in
                    let step: CGFloat = 22
                    var p = Path()
                    var x: CGFloat = 0
                    while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                    ctx.stroke(p, with: .color(Theme.text.opacity(0.045)), lineWidth: 0.5)
                }
                .mask(LinearGradient(colors: [.clear, .black], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom))
                RadialGradient(colors: [Color(hex: 0xFFE45C).opacity(0.55), Color(hex: 0xFFF3B0).opacity(0.25), .clear],
                               center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: g.size.height * 0.55)
            }
        }
    }
}

/// Glossy black round button: a soft top highlight over black, like the site's buttons.
struct GlossyRound: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background {
                Circle().fill(LinearGradient(colors: [Color(hex: 0x3A3A3A), Color(hex: 0x0A0A0A)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)).padding(2))
                    .overlay(Circle().strokeBorder(.black.opacity(0.6)))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
            .opacity(enabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.smooth(duration: 0.2), value: enabled)
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
