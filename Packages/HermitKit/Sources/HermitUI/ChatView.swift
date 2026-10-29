import SwiftUI
import HermitCore

/// A conversation: your messages on the right in a soft bubble, Hermit's answers full width with cards and actions.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.messages) { m in
                        MessageView(message: m)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
                .animation(.smooth(duration: 0.35), value: model.messages)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.automatic)
            Composer()
                .frame(maxWidth: 720)
                .padding(.horizontal, 28).padding(.bottom, 20)
        }
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text).font(.system(size: 14.5)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.hover, in: RoundedRectangle(cornerRadius: 14))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if let status = message.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.system(size: 13)).foregroundStyle(Theme.muted)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeOut(duration: 0.2), value: status)
                } else if message.steps > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
                        Text("\(message.steps) steps").foregroundStyle(Theme.muted)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                    .font(.system(size: 12.5))
                }
                if !message.text.isEmpty {
                    Text(rich(message.text)).font(.system(size: 14.5)).lineSpacing(3).foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
                if let card = message.card { CardView(card: card).transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top))) }
                if !message.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(message.actions) { a in
                            Button(a.title) { model.run(a) }.buttonStyle(BlackButton())
                        }
                    }
                }
            }
            .animation(.smooth(duration: 0.3), value: message.card)
            .animation(.smooth(duration: 0.3), value: message.actions)
        }
    }

    private func rich(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct BlackButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.text.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
