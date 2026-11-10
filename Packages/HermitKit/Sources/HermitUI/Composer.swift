import SwiftUI
import UniformTypeIdentifiers
import HermitCore
#if os(iOS)
import PhotosUI
#endif

/// The chat box, the same everywhere (home, chat, project pages, automations), like Claude and ChatGPT:
/// text, then + (files, commands, project), attach and speak on the left; model and send on the right.
/// Speak, connectors and plugins are greyed out until they exist.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    var placeholder = "How can I help?"
    /// Empty hides it; nil shows the real on-device model (tap to manage models).
    var label: String? = nil
    var projectPicker = true
    var minLines = 1
    /// Example words for voice input. Not used until voice input exists; callers still pass one.
    var dictation = ""
    var autoFocus = true
    /// Where the message goes. Nil sends it to the main chat.
    var onSend: ((String, Attachment?) -> Void)? = nil

    @State private var text = ""
    @State private var file: Attachment?
    @State private var importing = false
    /// A file is being read (PDF, OCR, spreadsheet): the chip shows that until it's ready.
    @State private var reading: String?
    @State private var dropping = false
    #if os(iOS)
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    #endif
    @State private var showModels = false
    @FocusState private var focused: Bool
    @AppStorage(ChatMode.key) private var chatMode = ChatMode.device.rawValue

    /// Commands that do something real today.
    static let commands: [(String, String)] = [("/remember", "Save something to long-term memory")]

    private var slash: String? {
        text.range(of: #"^/\w*$"#, options: .regularExpression) != nil ? text.lowercased() : nil
    }
    private var matching: [(String, String)] { Self.commands.filter { slash == nil || $0.0.hasPrefix(slash!) } }

    var body: some View {
        VStack(spacing: 0) {
            if onSend == nil && !model.inChat && projectPicker {
                if chatMode == ChatMode.cloud.rawValue { CloudPrompt().padding(.bottom, 14) } else { ModelPrompt().padding(.bottom, 14) }
            }
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
        .sheet(isPresented: $showModels) { ModelSheet().environment(model) }
        #if DEBUG
        .task { try? await Task.sleep(for: .seconds(1.2)); if DebugLaunch.take("models") { showModels = true } }
        #endif
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            // The file is read on this device (text, spreadsheet, PDF, image text); that text goes to the model with the message.
            if case .success(let url) = result { attach(url) }
        }
        #if os(iOS)
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            withAnimation(.snappy) { reading = "Photo" }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                var picked: Attachment?
                if let data { picked = await AttachmentReader.read(imageData: data, name: "Photo.jpg") }
                withAnimation(.snappy) { reading = nil; if let picked { file = picked } }
                if picked == nil { model.toast("Couldn't open that photo") }
                focused = true
            }
        }
        #endif
    }

    /// Reads a picked or dropped file off the main thread, then shows its chip.
    private func attach(_ url: URL) {
        withAnimation(.snappy) { reading = url.lastPathComponent }
        Task {
            let picked = await AttachmentReader.read(url)
            withAnimation(.snappy) { reading = nil; file = picked }
            focused = true
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = reading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    Text("Reading \(r)").font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 11))
                .transition(.opacity)
            } else if let f = file {
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
                tool("paperclip", "Attach a file") { importing = true }
                Spacer(minLength: 8)
                if let label, !label.isEmpty {
                    Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.faint).lineLimit(1).padding(.trailing, 6)
                } else if label == nil {
                    ModeMenu { showModels = true }
                }
                sendButton
            }
            .padding(.leading, -6)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 11)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(dropping ? Theme.accent.opacity(0.7) : focused ? Theme.faint.opacity(0.6) : Theme.border,
                                                                 lineWidth: dropping ? 2 : 1))
        // Drag a file from Finder (or another app on iPad) onto the box to attach it.
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: \.isFileURL) else { return false }
            attach(u)
            return true
        } isTargeted: { dropping = $0 }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .overlay(alignment: .topLeading) { if let _ = slash, !matching.isEmpty { commandList } }
        .animation(.smooth(duration: 0.15), value: focused)
        .onAppear {
            #if os(macOS)
            if autoFocus && !SnapshotMode.active { focused = true }
            #endif
        }
        .onChange(of: model.focusTick) { if onSend == nil || autoFocus { focused = true } }
        .onChange(of: model.droppedFile) { _, u in if let u { model.droppedFile = nil; attach(u) } }
        // Dropped while another page was showing: the chat opened for it, and the composer appears with it waiting.
        .onAppear { if let u = model.droppedFile { model.droppedFile = nil; attach(u) } }
    }

    private var canSend: Bool { reading == nil && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || file != nil) }
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
            Button("Add a file", systemImage: "paperclip") { importing = true }
            #if os(iOS)
            Button("Add a photo", systemImage: "photo") { pickingPhoto = true }
            #endif
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
        } label: {
            Image(systemName: "plus").font(.system(size: 15)).foregroundStyle(Theme.muted)
                .frame(width: compact ? 36 : 30, height: compact ? 36 : 30).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(ToolStyle()).menuIndicator(.hidden).fixedSize()
        .help("Add a file, a command or a project")
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
