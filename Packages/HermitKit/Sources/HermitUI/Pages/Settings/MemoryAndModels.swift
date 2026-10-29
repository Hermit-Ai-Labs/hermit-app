import SwiftUI
import Observation

/// Long-term memory as a real markdown file, hermit.md in Application Support. Chat can append to it too.
@MainActor @Observable
final class MemoryStore {
    static let shared = MemoryStore()
    static let seed = [
        "Show RSI, MACD and the 50/200 EMA on every chart",
        "Never use more than 5x leverage",
        "Prefer audited protocols for stablecoin yield",
        "Keep replies short, numbers first",
    ].map { "- \($0)" }.joined(separator: "\n")

    private(set) var text: String
    var url: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Hermit") else { return nil }
        return dir.appendingPathComponent("hermit.md")
    }

    init() {
        text = Self.seed
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

    func append(_ item: String) { save(text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n- " + item) }
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
            Text("Hermit follows this in every chat. Add to it here, or say \"add … to your long-term memory\" in chat.")
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
                .accessibilityLabel("Long-term memory")
            HStack(spacing: 8) {
                Text("\(MemoryStore.lines(draft)) rules").font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit()
                Spacer()
                if dirty {
                    Button("Discard") { withAnimation(.snappy) { draft = store.text } }.buttonStyle(OutlineButton())
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                Button("Save") { store.save(draft); focus = false; model.toast("Memory saved") }
                    .buttonStyle(BlackButton()).disabled(!dirty).opacity(dirty ? 1 : 0.4)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .animation(.snappy, value: dirty)
        }
    }
}

extension MemoryStore {
    nonisolated static func lines(_ s: String) -> Int { s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }
}

// MARK: Models

struct LocalModel: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let by: String
    let role: String
    let size: String
    let symbol: String
    var state: Status
    enum Status: Hashable { case ready, update, available, downloading(Double) }
}

@MainActor @Observable
final class ModelsStore {
    static let shared = ModelsStore()
    var activeText = "Woof 2B"
    var models: [LocalModel] = [
        LocalModel(name: "Woof 2B", by: "Underdog", role: "Text", size: "1.4 GB", symbol: "pawprint", state: .ready),
        LocalModel(name: "Hermit 8B", by: "Hermit", role: "Text", size: "4.9 GB", symbol: "text.bubble", state: .available),
        LocalModel(name: "Speech", by: "Whisper small, on device", role: "Speech", size: "1.5 GB", symbol: "waveform", state: .ready),
        LocalModel(name: "Image and video", by: "Vision encoder", role: "Vision", size: "6.2 GB", symbol: "photo", state: .ready),
        LocalModel(name: "Documents", by: "Layout reader", role: "Documents", size: "2.1 GB", symbol: "doc.text", state: .update),
    ]

    func download(_ name: String, done: String) {
        guard let i = models.firstIndex(where: { $0.name == name }) else { return }
        models[i].state = .downloading(0)
        Task {
            for step in 1...20 {
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.smooth) { models[i].state = .downloading(Double(step) / 20) }
            }
            withAnimation(.snappy) { models[i].state = .ready }
            ToastRelay.post(done)
        }
    }
}

/// Lets stores show a toast without holding the app model.
@MainActor enum ToastRelay {
    static var post: (String) -> Void = { _ in }
}

struct ModelsList: View {
    @Environment(AppModel.self) private var model
    @State private var store = ModelsStore.shared
    @State private var open: LocalModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let active = store.models.first(where: { $0.name == store.activeText }) { activeCard(active) }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("On this device")
                RowList(items: store.models) { m in row(m) }
            }
            NoteBox(symbol: "airplane", text: "Every model runs on this device, so Hermit works in flight mode and nothing you say leaves it.")
        }
        .onAppear { ToastRelay.post = { [model] in model.toast($0) } }
        .sheet(item: $open) { m in ModelSheet(name: m.name).environment(model).tint(Theme.text) }
    }

    private func activeCard(_ m: LocalModel) -> some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: m.symbol, size: 44, tint: Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(m.name).font(.system(size: 16, weight: .semibold))
                    PillTag(text: "Active", color: Theme.accent, dot: true)
                }
                Text("by \(m.by), \(m.size). Chat, tools and wallet actions.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Details") { open = m }.buttonStyle(OutlineButton())
        }
        .padding(16).card()
    }

    private func row(_ m: LocalModel) -> some View {
        Button { open = m } label: {
            HStack(spacing: 12) {
                SymbolTile(symbol: m.symbol, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.role == "Text" ? "\(m.name) by \(m.by)" : m.name).font(.system(size: 14, weight: .medium))
                    Text(m.role == "Text" ? "Text, \(m.size)" : "\(m.by), \(m.size)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                status(m)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(RowButtonStyle())
    }

    @ViewBuilder private func status(_ m: LocalModel) -> some View {
        switch m.state {
        case .ready:
            if m.role == "Text" && m.name == store.activeText { PillTag(text: "Active", color: Theme.accent, dot: true) }
            else { PillTag(text: "Ready", color: Theme.green, dot: true) }
        case .update: Text("Update").font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Theme.border))
        case .available: Text("Download").font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Theme.border))
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 70).tint(Theme.text)
                Text("\(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        }
    }
}

/// One model: size, where it runs, use it, update or re-download.
struct ModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = ModelsStore.shared
    let name: String

    var body: some View {
        let m = store.models.first { $0.name == name }!
        let isText = m.role == "Text"
        let active = isText && store.activeText == m.name
        SheetChrome(title: m.name, subtitle: "by \(m.by)") {
            DetailLines(lines: [("Kind", m.role), ("Size", m.size), ("Runs", "On this device"),
                                ("Last updated", m.state == .update ? "2 months ago" : "Oct 20"),
                                ("Status", stateText(m))])
            if isText {
                SettingRow(title: "Use for chat", sub: active ? "Hermit answers with this model" : "Switch Hermit's text model") {
                    Toggle("Use for chat", isOn: Binding(get: { active }, set: { on in
                        guard on, m.state == .ready else { return }
                        withAnimation(.snappy) { store.activeText = m.name }
                        model.toast("\(m.name) is now the text model")
                    }))
                    .labelsHidden().toggleStyle(.switch).tint(Theme.text).disabled(active || m.state != .ready)
                }
            }
        } foot: {
            switch m.state {
            case .available:
                Button("Download \(m.size)") { store.download(m.name, done: "\(m.name) downloaded") }.buttonStyle(WideButton())
            case .update:
                Button("Update") { store.download(m.name, done: "\(m.name) updated"); dismiss() }.buttonStyle(WideButton())
            case .downloading(let p):
                Button("Downloading \(Int(p * 100))%") {}.buttonStyle(WideButton(kind: .plain)).disabled(true)
            case .ready:
                Button("Re-download") { store.download(m.name, done: "\(m.name) re-downloaded"); dismiss() }.buttonStyle(WideButton(kind: .plain))
            }
        }
    }

    private func stateText(_ m: LocalModel) -> String {
        switch m.state {
        case .ready: "Ready"
        case .update: "Update available"
        case .available: "Not downloaded"
        case .downloading(let p): "Downloading, \(Int(p * 100))%"
        }
    }
}
