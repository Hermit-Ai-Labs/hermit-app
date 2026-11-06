import SwiftUI
import Observation

/// Long-term memory as a real markdown file, hermit.md in Application Support. Chat can append to it too.
@MainActor @Observable
final class MemoryStore {
    static let shared = MemoryStore()
    /// Lines the demo used to seed hermit.md with; old installs may have them saved.
    private static let demoSeed: Set<String> = [
        "Show RSI, MACD and the 50/200 EMA on every chart", "Never use more than 5x leverage",
        "Prefer audited protocols for stablecoin yield", "Keep replies short, numbers first",
    ]

    private(set) var text = ""
    var url: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Hermit") else { return nil }
        return dir.appendingPathComponent("hermit.md")
    }

    init() {
        if let url, let s = try? String(contentsOf: url, encoding: .utf8) { text = s }
    }

    var items: [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }.filter { !$0.isEmpty }
    }

    func save(_ new: String) {
        text = new
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? new.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ item: String) {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        save(current.isEmpty ? "- " + item : current + "\n- " + item)
    }

    /// Removes the demo's seeded lines and keeps everything the user wrote.
    func dropDemoSeed() {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            let item = t.hasPrefix("- ") || t.hasPrefix("* ") ? String(t.dropFirst(2)) : t
            return !Self.demoSeed.contains(item)
        }
        let new = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if new != text { save(new) }
    }
}

/// The hermit.md editor.
struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @State private var store = MemoryStore.shared
    @State private var draft = MemoryStore.shared.text
    @FocusState private var focus: Bool

    var body: some View {
        let dirty = draft != store.text
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Long-term memory", systemImage: "book.closed").font(.system(size: 13.5, weight: .medium))
                Spacer()
                Text("hermit.md").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.faint)
            }
            Text("Hermit follows this in every new chat. Add to it here, or say \"remember …\" in chat. It stays on this device.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            TextEditor(text: $draft)
                .font(.system(size: 13.5, design: .monospaced)).lineSpacing(4)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .focused($focus)
                .padding(12)
                .frame(minHeight: 220)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focus ? Theme.text.opacity(0.4) : Theme.border))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Empty. One note per line, for example:\n- Keep answers short\n- I live in Berlin, show prices in euros")
                            .font(.system(size: 13.5, design: .monospaced)).lineSpacing(4).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 17).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Long-term memory")
            HStack(spacing: 8) {
                Text(MemoryStore.lines(draft) == 1 ? "1 note" : "\(MemoryStore.lines(draft)) notes").font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit()
                Spacer()
                if dirty {
                    Button("Discard") { withAnimation(.snappy) { draft = store.text } }.buttonStyle(OutlineButton())
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                Button("Save") { store.save(draft); focus = false; model.pushContext(); model.toast("Saved, used from your next chat") }
                    .buttonStyle(BlackButton()).disabled(!dirty).opacity(dirty ? 1 : 0.4)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .animation(.snappy, value: dirty)
        }
        // Chat can add lines while this page is closed.
        .onAppear { draft = store.text }
    }
}

extension MemoryStore {
    nonisolated static func lines(_ s: String) -> Int { s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
}
