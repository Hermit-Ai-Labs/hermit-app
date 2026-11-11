import SwiftUI
import CoreText

/// Brand tokens from the web demo (hermit-demo README, section 2). Purple is for key actions only.
public enum Theme {
    public static let bg = Color(hex: 0xFFFFFF)
    public static let subtle = Color(hex: 0xFAFAF9)
    public static let hover = Color(hex: 0xF5F5F4)
    public static let border = Color(hex: 0xECECEB)
    public static let text = Color(hex: 0x121212)
    public static let muted = Color(hex: 0x6B6B6B)
    /// Icons, chevrons and lines only: about 2.5:1 on white, too light for words.
    public static let faint = Color(hex: 0xA3A3A3)
    /// Light text (hints, captions, placeholders, "Always on"): 4.7:1 on white and 4.5:1 on `subtle`, so it passes AA.
    public static let hint = Color(hex: 0x737373)
    public static let accent = Color(hex: 0x4E1F96)
    public static let green = Color(hex: 0x15803D)
    public static let red = Color(hex: 0xC53030)
    public static let amber = Color(hex: 0xA16207)
    public static let radius: CGFloat = 14
    /// Buttons that can't be pressed yet: a solid light grey with text that stays readable (about 4.5:1), never a fade.
    public static let disabledFill = Color(hex: 0xEFEFED)
    public static let disabledText = Color(hex: 0x76766F)
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

public extension Font {
    /// Newsreader, the serif used for the greeting and headlines. UI text stays in the system font (SF Pro).
    /// Grows with Dynamic Type like a large title (gently, so headlines keep their lines).
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .medium ? "Newsreader-Medium" : "Newsreader-Regular", size: size, relativeTo: .largeTitle)
    }
    /// Newsreader cut at its display optical size, light: for oversized type only (the welcome screen).
    static func display(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "NewsreaderDisplay-LightItalic" : "NewsreaderDisplay-Light", size: size, relativeTo: .largeTitle)
    }
}

/// SF Pro at a design size that follows Dynamic Type (`.font(.system(size:))` stays fixed whatever the user picks).
/// Use `.uiFont(13.5)` where `.font(.system(size: 13.5))` was; RootView caps the range so layouts hold.
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight, design: design)) }
}

extension View {
    func uiFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

public enum HermitFonts {
    /// Call once at launch. Fonts ship inside HermitUI so the apps need no Info.plist entries.
    public static func register() {
        for name in ["Newsreader-Regular", "Newsreader-Medium", "NewsreaderDisplay-Light", "NewsreaderDisplay-LightItalic"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

extension Image {
    static func hermit(_ name: String) -> Image {
        #if os(macOS)
        if let url = Bundle.module.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
            return Image(nsImage: img)
        }
        #else
        if let url = Bundle.module.url(forResource: name, withExtension: "png"), let img = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: img)
        }
        #endif
        return Image(systemName: "questionmark.square.dashed")
    }
}
