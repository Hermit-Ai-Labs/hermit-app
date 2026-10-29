import SwiftUI
import UniformTypeIdentifiers
import HermitCore

/// The chat box, the same everywhere (home, chat, project pages, automations), like Claude and ChatGPT:
/// text, then + (files, commands, project, connectors, plugins), attach and speak on the left; model and send on the right.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    var placeholder = "How can I help?"
    var label = "Local model"
    var projectPicker = true
    var minLines = 1
    var dictation = "Long HYPE 5x on Hyperliquid, stop at $22"
    var autoFocus = true
    /// Where the message goes. Nil sends it to the main chat.
    var onSend: ((String, Attachment?) -> Void)? = nil

    @State private var text = ""
    @State private var file: Attachment?
    @State private var attaching = false
    @State private var recording = false
    @State private var importing = false
    @State private var connectorsOn: Set<String> = ["Gmail", "Google Calendar", "Notion", "X", "OpenAI", "Perplexity"]
    @State private var pluginsOn: Set<String> = ["Research analyst"]
    @FocusState private var focused: Bool

    static let commands: [(String, String)] = [
        ("/trade", "Open a trade with TP and SL"), ("/swap", "Swap one token for another"), ("/pay", "Send or schedule a payment"),
        ("/earn", "Find yield for idle funds"), ("/automate", "Turn a task into an automation"), ("/remember", "Save something to long-term memory"),
    ]
    static let connectors = ["Gmail", "Google Calendar", "Notion", "X", "Telegram", "Discord", "OpenAI"]
    static let plugins: [(String, String, Bool)] = [
        ("Hazard scan", "Checks every transaction", true), ("Injection shield", "Ignores instructions in web pages and email", true),
        ("Browser takeover", "Uses websites for you", false), ("Meme sniper", "Screens new pairs", false),
        ("Airdrop farmer", "Completes quests", false), ("Research analyst", "Token reports", false),
    ]

    private var slash: String? {
        text.range(of: #"^/\w*$"#, options: .regularExpression) != nil ? text.lowercased() : nil
    }
    private var matching: [(String, String)] { Self.commands.filter { slash == nil || $0.0.hasPrefix(slash!) } }

    var body: some View {
        VStack(spacing: 0) {
            box
            if projectPicker, let p = model.project(model.chatProject) {
                HStack(spacing: 7) {
                    Circle().fill(p.color).frame(width: 7, height: 7)
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Button { withAnimation(.snappy) { model.chatProject = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Remove from project")
                }
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
                .background(Theme.subtle, in: UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16).strokeBorder(Theme.border))
                .padding(.horizontal, 10).padding(.top, -8)
                .zIndex(-1)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: model.chatProject)
        .sheet(isPresented: $attaching) {
            AttachSheet { picked in
                withAnimation(.snappy) { file = picked }
                focused = true
            } browse: {
                attaching = false
                Task { try? await Task.sleep(for: .milliseconds(300)); importing = true }
            }
        }
        .sheet(isPresented: $recording) {
            RecordSheet(transcript: dictation) { words in
                text = text.isEmpty ? words : text + " " + words
                focused = true
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                withAnimation(.snappy) { file = Attachment(url.lastPathComponent, size: size) }
            }
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let f = file {
                AttachmentChip(file: f) { withAnimation(.snappy) { file = nil } }
                    .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
            }
            TextField(text: $text, prompt: Text(placeholder).foregroundStyle(Theme.faint), axis: .vertical) { Text(placeholder) }
                .textFieldStyle(.plain).font(.system(size: 15)).lineLimit(minLines...8)
                .focused($focused)
                .onSubmit(submit)
                #if os(macOS)
                .onKeyPress(.escape) { if slash != nil { text = ""; return .handled }; return .ignored }
                #endif
            HStack(spacing: 2) {
                plusMenu
                tool("paperclip", "Attach file") { attaching = true }
                tool("mic", "Speak") { recording = true }
                Spacer(minLength: 8)
                if !label.isEmpty {
                    Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1).padding(.trailing, 6)
                }
                sendButton
            }
            .padding(.leading, -6)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 11)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(focused ? Theme.faint.opacity(0.6) : Theme.border))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .overlay(alignment: .topLeading) { if let _ = slash, !matching.isEmpty { commandList } }
        .animation(.smooth(duration: 0.15), value: focused)
        .onAppear {
            #if os(macOS)
            if autoFocus && !SnapshotMode.active { focused = true }
            #endif
        }
        .onChange(of: model.focusTick) { if onSend == nil || autoFocus { focused = true } }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || file != nil }
    private var stoppable: Bool { onSend == nil && model.busy }

    private var sendButton: some View {
        Button { stoppable ? model.stop() : submit() } label: {
            Image(systemName: stoppable ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white).frame(width: 30, height: 30)
                .background(canSend || stoppable ? Theme.accent : Theme.faint.opacity(0.45), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .help(stoppable ? "Stop" : "Send")
        .animation(.snappy(duration: 0.2), value: canSend)
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.muted)
                .frame(width: compact ? 36 : 30, height: compact ? 36 : 30).contentShape(Rectangle())
        }
        .buttonStyle(ToolStyle()).help(help)
    }

    private var plusMenu: some View {
        Menu {
            Button("Add files or photos", systemImage: "photo.badge.plus") { attaching = true }
            Divider()
            Menu {
                ForEach(Self.commands, id: \.0) { c in Button { use(c.0) } label: { Text(c.0); Text(c.1) } }
            } label: { Label("Commands", systemImage: "slash.circle") }
            if projectPicker {
                Menu {
                    Button { model.chatProject = nil } label: { if model.chatProject == nil { Label("No project", systemImage: "checkmark") } else { Text("No project") } }
                    Divider()
                    ForEach(model.projectList) { p in
                        Button { model.chatProject = p.name } label: {
                            if model.chatProject == p.name { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                } label: { Label("Project", systemImage: "folder"); Text(model.chatProject ?? "None") }
            }
            Menu {
                ForEach(Self.connectors, id: \.self) { c in
                    Toggle(c, isOn: Binding(get: { connectorsOn.contains(c) }, set: { on in if on { connectorsOn.insert(c) } else { connectorsOn.remove(c) } }))
                }
                Divider()
                Button("Manage connectors", systemImage: "puzzlepiece.extension") { model.open(.connectors) }
            } label: { Label("Connectors", systemImage: "powerplug"); Text("\(connectorsOn.count) on") }
            Menu {
                ForEach(Self.plugins, id: \.0) { p in
                    if p.2 {
                        Button { model.toast("\(p.0) is always on") } label: { Label(p.0, systemImage: "lock"); Text(p.1) }
                    } else {
                        Toggle(isOn: Binding(get: { pluginsOn.contains(p.0) }, set: { on in if on { pluginsOn.insert(p.0) } else { pluginsOn.remove(p.0) } })) {
                            Text(p.0); Text(p.1)
                        }
                    }
                }
                Divider()
                Button("Browse plugins", systemImage: "puzzlepiece") { model.open(.connectors, tab: "skills") }
            } label: { Label("Plugins", systemImage: "puzzlepiece"); Text("\(pluginsOn.count + 2) on") }
        } label: {
            Image(systemName: "plus").font(.system(size: 15)).foregroundStyle(Theme.muted)
                .frame(width: compact ? 36 : 30, height: compact ? 36 : 30).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(ToolStyle()).menuIndicator(.hidden).fixedSize()
        .help("Add files, commands, connectors and more")
    }

    /// Typing "/" lists the commands right above the box.
    private var commandList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matching, id: \.0) { c in
                Button { use(c.0) } label: {
                    HStack(spacing: 10) {
                        Text("/").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted)
                            .frame(width: 26, height: 26).background(Theme.hover, in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.0).font(.system(size: 13.5, weight: .medium))
                            Text(c.1).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.1), radius: 18, y: 8)
        .alignmentGuide(.top) { $0[.bottom] + 8 }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
    }

    private func use(_ command: String) {
        text = command + " "
        focused = true
    }

    private func submit() {
        if slash != nil, let first = matching.first { use(first.0); return }
        guard canSend else { return }
        let t = text, f = file
        text = ""; file = nil
        if let onSend { onSend(t, f) } else { model.send(t, attachment: f) }
    }
}

struct ToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBackground(pressed: configuration.isPressed, radius: 8, scale: true) { configuration.label } }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HoverBackground(pressed: configuration.isPressed, radius: 9, scale: false) { configuration.label } }
}

/// Hover and press highlight for icon buttons and menu rows.
struct HoverBackground<Content: View>: View {
    let pressed: Bool
    let radius: CGFloat
    let scale: Bool
    @ViewBuilder var content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .background((pressed || hover) ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: radius))
            .scaleEffect(scale && pressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: pressed)
            .onHover { hover = $0 }
    }
}
