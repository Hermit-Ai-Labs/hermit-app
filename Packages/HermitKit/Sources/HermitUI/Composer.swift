import SwiftUI

/// The chat box, the same everywhere: text, then + / attach / mic on the left, model and send on the right.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showModels = false

    var body: some View {
        VStack(spacing: 14) {
            if !model.inChat { ModelPrompt() }
            box
        }
        .sheet(isPresented: $showModels) { ModelSheet().environment(model) }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("How can I help?", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 14) {
                ForEach(["plus", "paperclip", "mic"], id: \.self) { s in
                    Image(systemName: s).font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { showModels = true } label: {
                    Text(model.models.label).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                        .contentTransition(.numericText()).animation(.snappy, value: model.models.label)
                }
                .buttonStyle(.plain)
                Button { model.busy ? model.stop() : send() } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 30, height: 30)
                        .background(canSend || model.busy ? Theme.accent : Theme.faint.opacity(0.45), in: Circle())
                }
                .buttonStyle(PressStyle())
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 11)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(focused ? Theme.faint.opacity(0.6) : Theme.border))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.15), value: focused)
        .onAppear { focused = true }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        model.send(text); text = ""
    }
}
