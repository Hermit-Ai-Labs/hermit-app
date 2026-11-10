import SwiftUI
import UniformTypeIdentifiers
import HermitCore

/// Projects, Claude-style: a grid of projects; each opens a page with a chat box above its tabs
/// (Chats, Instructions, Files). Everything here is made by the user and kept on the device.
struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    @State private var creating = false

    var body: some View {
        Group {
            if let p = model.project(model.projectOpen) {
                ProjectDetail(project: p).id(p.name)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            } else {
                ScrollPage { list }
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.projectOpen)
        .sheet(isPresented: $creating) { NewProjectSheet() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button { creating = true } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(BlackButton())
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            if model.projectList.isEmpty {
                EmptyState(symbol: "folder", title: "No projects yet",
                           text: "A project keeps its own chats, files and instructions together.") {
                    Button { creating = true } label: { Label("New project", systemImage: "plus") }.buttonStyle(BlackButton())
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 280 : 230), spacing: 14)], spacing: 14) {
                ForEach(model.projectList) { p in ProjectTile(project: p, chats: model.chats(in: p.name).count) }
            }
        }
    }
}

struct ProjectTile: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let chats: Int
    @State private var hover = false
    @State private var renaming = false
    @State private var deleting = false

    var body: some View {
        Button { model.openProject(project.name) } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: project.symbol).font(.system(size: 16)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(project.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(chats == 1 ? "1 chat" : "\(chats) chats").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(hover ? Theme.faint.opacity(0.5) : Theme.border))
            .shadow(color: .black.opacity(hover ? 0.06 : 0), radius: 12, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hover = h } }
        .contextMenu {
            Button("Open", systemImage: "folder") { model.openProject(project.name) }
            Button("New chat in project", systemImage: "square.and.pencil") { model.newChat(project: project.name) }
            Button("Rename", systemImage: "pencil") { renaming = true }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
        }
        .projectActions(project, renaming: $renaming, deleting: $deleting)
    }
}

/// One project: chat box above the tabs; sending starts a chat inside the project.
struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var tab = "chats"
    @State private var renaming = false
    @State private var deleting = false

    var body: some View {
        ScrollPage(maxWidth: 760) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { withAnimation(.smooth) { model.projectOpen = nil } } label: {
                        Image(systemName: "arrow.left").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(ToolStyle()).help("All projects").keyboardShortcut("[", modifiers: .command)
                    Text(project.name).font(.system(size: 24, weight: .semibold)).tracking(-0.4).lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Rename", systemImage: "pencil") { renaming = true }
                        Button("Delete project", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Project options")
                }
                .padding(.leading, -8)
                Composer(placeholder: "Start a chat in \(project.name)", label: "", projectPicker: false, minLines: 2, autoFocus: false) { text, f in
                    model.newChat(project: project.name)
                    model.send(text, attachment: f)
                }
                .padding(.top, 16)
                PageTabs(tabs: [("chats", "Chats \(model.chats(in: project.name).count)"), ("instructions", "Instructions"), ("files", "Files")],
                         selection: $tab)
                    .padding(.top, 22)
                Group {
                    switch tab {
                    case "instructions": ProjectInstructions(project: project)
                    case "files": ProjectFiles(project: project.name)
                    default: chats
                    }
                }
                .padding(.top, 20)
                .id(tab)
                .transition(.opacity)
            }
            .animation(.smooth(duration: 0.2), value: tab)
        }
        .projectActions(project, renaming: $renaming, deleting: $deleting)
        .onAppear {
            if let r = model.tabRequest, ["chats", "instructions", "files"].contains(r) { tab = r; model.tabRequest = nil }
        }
    }

    private var chats: some View {
        let list = model.chats(in: project.name)
        return VStack(spacing: 0) {
            if list.isEmpty {
                Text("No chats yet. Start one above and it will show up here.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            ForEach(list) { c in
                ListButton(symbol: "bubble.left", title: c.title, subtitle: c.when) { model.openConversation(c.id) }
                    .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { model.deleteConversation(c.id) } }
                Divider().overlay(Theme.border)
            }
        }
    }
}

/// Files kept with a project: added from the device, opened in the Files viewer.
struct ProjectFiles: View {
    @Environment(AppModel.self) private var model
    let project: String
    @State private var importing = false
    private var store: FilesStore { .shared }

    var body: some View {
        let list = store.files.filter { $0.project == project }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(list.isEmpty ? "Files you add here stay on this device." : list.count == 1 ? "1 file" : "\(list.count) files")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
                Button { importing = true } label: { Label("Add files", systemImage: "plus") }.buttonStyle(OutlineButton())
            }
            .padding(.bottom, 8)
            ForEach(list) { f in
                FileRow(file: f) { store.open(f); model.open(.files) }
                Divider().overlay(Theme.border)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let n = store.importFiles(urls, project: project)
            if n > 0 { model.toast(n == 1 ? "File added" : "\(n) files added") }
        }
    }
}

extension View {
    /// Rename prompt and delete confirmation for a project.
    func projectActions(_ project: Project, renaming: Binding<Bool>, deleting: Binding<Bool>) -> some View {
        modifier(ProjectActions(project: project, renaming: renaming, deleting: deleting))
    }
}

private struct ProjectActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var renaming: Bool
    @Binding var deleting: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename project", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { model.renameProject(project.name, to: name) }
            }
            .onChange(of: renaming) { _, on in if on { name = project.name } }
            .confirmationDialog("Delete \(project.name)?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete project", role: .destructive) { model.deleteProject(project.name) }
            } message: {
                Text("Its chats move to Recents. Its files and instructions are removed.")
            }
    }
}

extension AppModel {
    /// Renames a project and everything that points at it (chats, project.md, files, to-dos).
    func renameProject(_ old: String, to raw: String) {
        let new = raw.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, project(new) == nil, let i = projectList.firstIndex(where: { $0.name == old }) else { return }
        projectList[i].name = new
        for j in conversations.indices where conversations[j].project == old { conversations[j].project = new }
        for j in todos.indices where todos[j].project == old { todos[j].project = new }
        if let md = projectMD.removeValue(forKey: old) { projectMD[new] = md.replacingOccurrences(of: "# \(old)", with: "# \(new)") }
        if projectOpen == old { projectOpen = new }
        if chatProject == old { chatProject = new }
        FilesStore.shared.moveProject(old, to: new)
        toast("Renamed to \(new)")
    }

    /// Deletes a project. Its chats stay, as standalone chats.
    func deleteProject(_ name: String) {
        withAnimation(.snappy) { projectList.removeAll { $0.name == name } }
        for j in conversations.indices where conversations[j].project == name { conversations[j].project = nil }
        todos.removeAll { $0.project == name }
        projectMD[name] = nil
        if projectOpen == name { projectOpen = nil }
        if chatProject == name { chatProject = nil }
        FilesStore.shared.deleteProject(name)
        toast("Project deleted")
    }
}

/// project.md: followed in every chat of the project. Read view, or edit and save.
struct ProjectInstructions: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        let saved = model.instructions(for: project)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext").font(.system(size: 13))
                Text("Instructions").font(.system(size: 14, weight: .medium))
                Text("project.md").font(Theme.mono).foregroundStyle(Theme.faint)
                Spacer()
                Button(editing ? "Close" : "Edit") {
                    if !editing { text = saved }
                    withAnimation(.snappy) { editing.toggle() }
                }
                .buttonStyle(PlainCardButton())
            }
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(10).frame(minHeight: 220)
                    .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                HStack {
                    Spacer()
                    Button("Save") {
                        model.projectMD[project.name] = text
                        withAnimation(.snappy) { editing = false }
                        model.toast("Instructions saved")
                    }
                    .buttonStyle(BlackButton()).disabled(text == saved)
                    .keyboardShortcut("s", modifiers: .command)
                }
            } else if model.projectMD[project.name] == nil {
                Text("No instructions yet. Add the goal, rules to follow and how Hermit should reply in this project.")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.faint).lineSpacing(6)
            } else {
                Text(saved.replacingOccurrences(of: #"(?m)^#+ .*\n+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineSpacing(6)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Name, a short description and a kind (sets the icon).
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""
    @State private var template = "Blank"

    private var taken: Bool { model.project(name.trimmingCharacters(in: .whitespaces)) != nil }

    var body: some View {
        SheetScaffold(title: "New project") {
            field("Name", "e.g. ETH staking ladder", $name)
            if taken { Text("A project with this name already exists.").font(.system(size: 12)).foregroundStyle(Theme.red) }
            field("Description", "Optional", $desc)
            VStack(alignment: .leading, spacing: 8) {
                Text("Kind").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Flow(spacing: 6) {
                    ForEach(Project.templates, id: \.0) { t in
                        Button { withAnimation(.snappy) { template = t.0 } } label: { Label(t.0, systemImage: t.1) }
                            .buttonStyle(SmallChip(on: template == t.0))
                    }
                }
            }
            Text("The project gets its own chats, files and instructions.").font(.system(size: 12)).foregroundStyle(Theme.faint)
        } foot: {
            Button("Create", action: create).buttonStyle(SheetButton(primary: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || taken)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            TextField(text: text, prompt: Text(prompt).foregroundStyle(Theme.faint)) { Text(label) }.textFieldStyle(.plain).font(.system(size: 14))
                .padding(12).background(Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
                .onSubmit(create)
        }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !taken else { return }
        model.addProject(name: n, template: template, budget: 0)
        let d = desc.trimmingCharacters(in: .whitespaces)
        if let i = model.projectList.firstIndex(where: { $0.name == n }) {
            model.projectList[i].desc = d.isEmpty ? (template == "Blank" ? "Project" : template) : d
            model.projectList[i].files = []
            model.projectList[i].gainNote = ""
        }
        model.toast("Project created")
        dismiss()
    }
}

/// A plain list row with an icon, title, subtitle and chevron.
struct ListButton: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.muted).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 10).padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// A scrolling page column (flat in snapshots).
struct ScrollPage<Content: View>: View {
    var maxWidth: CGFloat = 1040
    @ViewBuilder var content: () -> Content
    @Environment(\.compact) private var compact
    var body: some View {
        let inner = content()
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, compact ? 16 : 32).padding(.top, compact ? 12 : 36).padding(.bottom, 48)
        if SnapshotMode.active { inner.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
            ThinScrollView { inner }
        }
    }
}
