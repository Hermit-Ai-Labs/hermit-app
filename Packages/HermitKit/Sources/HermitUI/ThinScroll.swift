import SwiftUI

/// A vertical scroll view with Hermit's own indicator: a 3-point rounded line that appears while you scroll (or rest
/// the pointer on it) and fades out, in place of the system's wide gray bar.
struct ThinScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var numbers = ScrollNumbers(offset: 0, content: 1, view: 1)
    @State private var shown = false
    @State private var hover = false
    @State private var hide: Task<Void, Never>?

    struct ScrollNumbers: Equatable { var offset, content, view: CGFloat }

    var body: some View {
        ScrollView {
            content()
                .containerRelativeFrame(.horizontal)   // never wider than the screen, so a page can't slide sideways
                #if os(macOS)
                .background(ScrollerRemover())
                #endif
        }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ScrollNumbers.self) { g in
                ScrollNumbers(offset: g.contentOffset.y + g.contentInsets.top, content: g.contentSize.height, view: g.containerSize.height)
            } action: { old, new in
                numbers = new
                if old.offset != new.offset { flash() }
            }
            .overlay(alignment: .topTrailing) { indicator }
            .onHover { over in hover = over; if over { flash() } else { flash() } }
            .task { try? await Task.sleep(for: .milliseconds(350)); flash() }
    }

    private var scrollable: Bool { numbers.content > numbers.view + 1 }

    @ViewBuilder private var indicator: some View {
        if scrollable {
            let track = numbers.view - 8
            let thumb = max(28, track * min(1, numbers.view / max(numbers.content, 1)))
            let progress = min(1, max(0, numbers.offset / max(1, numbers.content - numbers.view)))
            Capsule().fill(Theme.text.opacity(hover ? 0.32 : 0.22))
                .frame(width: 3, height: thumb)
                .offset(y: 4 + (track - thumb) * progress)
                .padding(.trailing, 3)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: shown)
                .animation(.linear(duration: 0.05), value: progress)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Show the line now and let it fade a moment after the last scroll (it stays while the pointer rests on the view).
    private func flash() {
        guard scrollable else { return }
        shown = true
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .milliseconds(hover ? 1600 : 800))
            if !Task.isCancelled { shown = false }
        }
    }
}

#if os(macOS)
import AppKit

/// Finds the NSScrollView this sits in and takes its scroller away. SwiftUI's `scrollIndicators(.hidden)` isn't enough
/// when System Settings has "Show scroll bars: Always": AppKit keeps drawing the old wide bar. The thin line above is
/// the only indicator we want.
private struct ScrollerRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let v = NSView(); v.isHidden = true; return v }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            var p = v.superview
            while let s = p, !(s is NSScrollView) { p = s.superview }
            guard let scroll = p as? NSScrollView else { return }
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
        }
    }
}
#endif
