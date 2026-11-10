import SwiftUI
import Observation

/// Every toast in the app goes through here, so it can show on top of whatever is in front: the page, or an open
/// sheet (sheets cover the page, so a page-level toast would be hidden behind them).
@MainActor @Observable
final class ToastCenter {
    static let shared = ToastCenter()
    enum Kind { case success, info, error }
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let kind: Kind
        let seconds: Double
    }
    private(set) var current: Toast?
    /// How many SheetChromes are open; the page-level host stays quiet while one is, and the sheet shows the toast.
    var sheetsOpen = 0

    func show(_ text: String, kind: Kind? = nil) {
        let k = kind ?? Self.guess(text)
        let t = Toast(text: text, kind: k, seconds: k == .error ? 4 : 2.8)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { current = t }
        Task {
            try? await Task.sleep(for: .seconds(t.seconds))
            if current?.id == t.id { withAnimation(.smooth(duration: 0.25)) { current = nil } }
        }
    }

    func dismiss() { withAnimation(.smooth(duration: 0.2)) { current = nil } }

    /// Callers pass plain text; failures read as failures.
    private static func guess(_ text: String) -> Kind {
        let t = text.lowercased()
        if ["couldn't", "can't", "cannot", "failed", "isn't", "error", "not enough", "too "].contains(where: { t.hasPrefix($0) || t.contains(" \($0)") }) { return .error }
        if t.hasPrefix("copied") || t.hasPrefix("address copied") { return .info }
        return .success
    }
}

/// Where toasts appear. `sheet` hosts sit inside SheetChrome; the `page` host in RootView.
struct ToastHost: View {
    enum Place { case page, sheet }
    let place: Place
    var bottom: CGFloat = 28
    private var center: ToastCenter { .shared }

    /// Sized to the toast alone (no frame that grows), so hosting it never changes the size of a sheet's window.
    /// Hosts use `.overlay(alignment: .bottom) { ToastHost(...) }`.
    var body: some View {
        if let t = center.current, place == .sheet || center.sheetsOpen == 0 {
            ToastView(toast: t).id(t.id)
                .padding(.bottom, bottom).padding(.horizontal, 16)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .scale(scale: 0.8, anchor: .bottom)).combined(with: .opacity),
                    removal: .scale(scale: 0.92).combined(with: .opacity)))
        }
    }
}

/// The toast: an icon that pops, the message, and a hairline that runs down while it's up. Tap to close it early.
struct ToastView: View {
    let toast: ToastCenter.Toast
    @State private var left: CGFloat = 1
    @State private var pop = false

    private var tint: Color { toast.kind == .error ? Theme.red : toast.kind == .info ? Theme.text : Theme.green }
    private var symbol: String { toast.kind == .error ? "exclamationmark" : toast.kind == .info ? "doc.on.doc.fill" : "checkmark" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(tint, in: Circle())
                .scaleEffect(pop ? 1 : 0.3).rotationEffect(.degrees(pop ? 0 : -40))
            Text(toast.text).font(.system(size: 13.5, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(alignment: .bottom) {
            Capsule().fill(tint.opacity(0.55)).frame(height: 2).scaleEffect(x: left, anchor: .leading)
                .padding(.horizontal, 18).padding(.bottom, 1)
        }
        .overlay(Capsule().strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .frame(maxWidth: 440)
        .contentShape(Capsule())
        .onTapGesture { ToastCenter.shared.dismiss() }
        .accessibilityAddTraits(.isStaticText)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.5).delay(0.08)) { pop = true }
            withAnimation(.linear(duration: toast.seconds)) { left = 0 }
        }
    }
}
