import SwiftUI

/// Drop a file anywhere in the window to attach it to the chat: a dashed outline and "Drop to attach" show while it
/// hovers; on drop the chat opens (if it wasn't showing) and the composer reads the file like a picked one.
struct ChatDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first(where: \.isFileURL) else { return false }
                model.droppedFile = u
                if model.route != .home { model.open(.home) }
                return true
            } isTargeted: { t in withAnimation(.snappy(duration: 0.15)) { over = t } }
            .overlay {
                if over {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.06))
                        RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        Label("Drop to attach", systemImage: "paperclip").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.bg, in: Capsule())
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
    }
}

extension View {
    func chatDropTarget() -> some View { modifier(ChatDropTarget()) }
}
