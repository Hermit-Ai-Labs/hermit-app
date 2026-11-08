import SwiftUI
import HermitCore

/// A conversation: your messages on the right in a soft bubble, Hermit's answers full width with tool steps,
/// cards and actions. Project chats keep a back link to their project at the top.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact

    var body: some View {
        VStack(spacing: 0) {
            if SnapshotMode.active { thread.frame(maxHeight: .infinity, alignment: .bottom).clipped() } else {
                ScrollView { thread }
                    .defaultScrollAnchor(.bottom)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .scrollIndicators(.automatic)
                    .scrollDismissesKeyboard(.interactively)
            }
            Composer()
                .frame(maxWidth: 720)
                .padding(.horizontal, compact ? 12 : 28).padding(.bottom, compact ? 8 : 20).padding(.top, 4)
        }
    }

    private var thread: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            if let p = model.project(model.chatProject) { crumb(p) }
            ForEach(model.messages) { m in
                MessageView(message: m)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 16 : 28).padding(.top, compact ? 16 : 40).padding(.bottom, 24)
        .animation(.smooth(duration: 0.35), value: model.messages.count)
    }

    /// Back to the project this chat belongs to.
    private func crumb(_ p: Project) -> some View {
        Button { model.openProject(p.name) } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left").font(.system(size: 11, weight: .medium))
                Circle().fill(p.color).frame(width: 6, height: 6)
                Text(p.name).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                Text(model.currentTitle).foregroundStyle(Theme.text).lineLimit(1)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var showTools = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .leading, spacing: 6) {
                    if let a = message.attachment { AttachmentChip(file: a, background: Theme.bg) }
                    Text(message.text).font(.system(size: 14.5)).foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant:
            if message.note {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 13))
                    Text(rich(message.text)).font(.system(size: 14.5)).lineSpacing(3).textSelection(.enabled)
                }
            } else if let run = message.run {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Run \(run)", systemImage: "clock").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    Text(message.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            } else {
                reply
            }
        }
    }

    private var reply: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = message.status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .contentTransition(.opacity)
                        .id(status)
                        .transition(.opacity)
                }
                .animation(.smooth(duration: 0.2), value: status)
            } else if message.steps > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Button { withAnimation(.snappy) { showTools.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
                            Text(message.steps == 1 ? "1 step" : "\(message.steps) steps").foregroundStyle(Theme.muted)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                                .rotationEffect(.degrees(showTools ? 90 : 0))
                        }
                        .font(.system(size: 12.5)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showTools {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.tools, id: \.self) { t in
                                Label(t, systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            }
                        }
                        .padding(.leading, 4)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
            }
            if !message.text.isEmpty {
                Text(rich(message.text)).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
            if let card = message.card { CardView(card: card).transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top))) }
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, b in
                BlockView(block: b)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if !message.actions.isEmpty { ActionRow(actions: message.actions) }
            if let p = message.proof { ProofChip(proof: p).transition(.opacity) }
        }
        .animation(.smooth(duration: 0.3), value: message.proof)
        .animation(.smooth(duration: 0.3), value: message.blocks.count)
        .animation(.smooth(duration: 0.3), value: message.card)
        .animation(.smooth(duration: 0.3), value: message.actions)
    }
}

struct BlockView: View {
    let block: Block
    var body: some View {
        switch block {
        case .text(let t):
            if !t.isEmpty {
                Text(rich(t)).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .card(let c): CardView(card: c)
        case .actions(let a): ActionRow(actions: a)
        }
    }
}

/// Buttons under a reply: money moves open the approval sheet, the rest post your action and get a reply.
struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let actions: [Action]
    var body: some View {
        Flow(spacing: 8) {
            ForEach(actions) { a in
                if a.primary {
                    Button { model.run(a) } label: { label(a) }.buttonStyle(BlackButton())
                } else {
                    Button { model.run(a) } label: { label(a) }.buttonStyle(PlainCardButton())
                }
            }
        }
    }

    @ViewBuilder private func label(_ a: Action) -> some View {
        if let s = a.symbol { Label(a.title, systemImage: s) } else { Text(a.title) }
    }
}

struct BlackButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(enabled ? .white : Theme.disabledText)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(enabled ? Theme.text.opacity(configuration.isPressed ? 0.8 : 1) : Theme.disabledFill, in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A file in the composer or in a sent message.
struct AttachmentChip: View {
    let file: Attachment
    var background: Color = Theme.hover
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 9) {
            FileIcon(kind: file.kind, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !file.size.isEmpty { Text(file.size).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20).background(Theme.hover, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
    }
}

struct FileIcon: View {
    let kind: Attachment.Kind
    var size: CGFloat = 34
    private var look: (String, Color) {
        switch kind {
        case .chart: ("photo", Theme.text)
        case .csv, .sheet: ("tablecells", Theme.green)
        case .code: ("chevron.left.forwardslash.chevron.right", Theme.text)
        default: ("doc.text", Theme.text)
        }
    }
    var body: some View {
        SymbolTile(symbol: look.0, size: size, tint: look.1)
    }
}

extension EnvironmentValues {
    /// True in the iPhone layout (bottom tab bar, no sidebar).
    @Entry var compact: Bool = false
}

extension View {
    /// Mac hover: a soft background lift. No effect on touch.
    func hoverLift(_ radius: CGFloat = 8) -> some View { modifier(HoverLift(radius: radius)) }
}

struct HoverLift: ViewModifier {
    let radius: CGFloat
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(hover ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: radius))
            .padding(.horizontal, -6).padding(.vertical, -3)
            .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}
