import SwiftUI
import Observation
import Accessibility

/// Every toast in the app goes through here, so it can show on top of whatever is in front: the page, or an open
/// sheet (sheets cover the page, so a page-level toast would be hidden behind them).
@MainActor @Observable
final class ToastCenter {
    static let shared = ToastCenter()
    /// `progress`: work under way ("Getting a quote…"), shown with a spinner until the next toast replaces it.
    enum Kind { case success, info, error, progress }
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
        // Errors stay long enough to read; progress waits for its result (with a ceiling, so it never sticks).
        let t = Toast(text: text, kind: k, seconds: k == .error ? 6 : k == .progress ? 20 : 2.8)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { current = t }
        // VoiceOver reads it out: the toast is often the only sign a send or a save worked or failed.
        AccessibilityNotification.Announcement(text).post()
        Task {
            try? await Task.sleep(for: .seconds(t.seconds))
            if current?.id == t.id { withAnimation(.smooth(duration: 0.25)) { current = nil } }
        }
    }

    func dismiss() { withAnimation(.smooth(duration: 0.2)) { current = nil } }

    /// For callers that pass plain text only: failures read as failures, work under way as progress. Callers that
    /// know the outcome pass `kind`.
    static func guess(_ text: String) -> Kind {
        let t = text.lowercased()
        let failure = ["couldn't", "can't", "cannot", "failed", "isn't", "error", "not enough", "too ", "need ", "needs ", "blocked",
                       "no verified", "busy", "off in this build", "not confirmed", "unavailable", "rejected", "refused"]
        if failure.contains(where: { t.hasPrefix($0) || t.contains(" \($0)") }) { return .error }
        if t.hasPrefix("copied") || t.hasPrefix("address copied") { return .info }
        if t.hasSuffix("…") || t.hasSuffix("...") { return .progress }
        return .success
    }
}

/// Where toasts appear. `sheet` hosts sit inside SheetChrome; the `page` host in RootView.
struct ToastHost: View {
    enum Place { case page, sheet }
    let place: Place
    var bottom: CGFloat = 28
    private var center: ToastCenter { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sized to the toast alone (no frame that grows), so hosting it never changes the size of a sheet's window.
    /// Hosts use `.overlay(alignment: .bottom) { ToastHost(...) }`.
    var body: some View {
        if let t = center.current, place == .sheet || center.sheetsOpen == 0 {
            ToastView(toast: t).id(t.id)
                .padding(.bottom, bottom).padding(.horizontal, 16)
                // Reduce Motion: the toast fades in and out, no slide or scale.
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.asymmetric(
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch toast.kind {
        case .error: Theme.red
        case .info, .progress: Theme.text
        case .success: Theme.green
        }
    }
    private var symbol: String { toast.kind == .error ? "exclamationmark" : toast.kind == .info ? "doc.on.doc.fill" : "checkmark" }
    /// A capsule while it is one line; longer messages wrap in full (never cut with "…") and keep the same ends.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            if toast.kind == .progress {
                ProgressView().controlSize(.small).frame(width: 22, height: 22)
            } else {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(tint, in: Circle())
                    .scaleEffect(pop ? 1 : 0.3).rotationEffect(.degrees(pop ? 0 : -40))
            }
            Text(toast.text).uiFont(13.5, weight: .medium).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: shape)
        .overlay(alignment: .bottom) {
            if toast.kind != .progress {
                Capsule().fill(tint.opacity(0.55)).frame(height: 2).scaleEffect(x: left, anchor: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 1)
            }
        }
        .overlay(shape.strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .frame(maxWidth: 440)
        .contentShape(shape)
        .onTapGesture { ToastCenter.shared.dismiss() }
        .accessibilityAddTraits(.isStaticText)
        .onAppear {
            if reduceMotion { pop = true } else { withAnimation(.spring(response: 0.38, dampingFraction: 0.5).delay(0.08)) { pop = true } }
            withAnimation(.linear(duration: toast.seconds)) { left = 0 }
        }
    }
}
