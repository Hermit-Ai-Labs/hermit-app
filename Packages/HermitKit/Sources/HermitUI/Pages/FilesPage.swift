import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Files: the files you add, copied into Hermit's own folder on this device. Search, a type filter,
/// Add files, and the viewer for text, tables, images and PDFs.
struct FilesPage: View {
    @Environment(AppModel.self) private var model
    @State private var store = FilesStore.shared
    @State private var query = ""
    @State private var type = HFile.Group.all
    @State private var importing = false
    @FocusState private var searching: Bool

    var body: some View {
        let list = store.files.filter { (type == .all || $0.group == type) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        ZStack {
            Page(title: "Files", tabs: [(0, "Files")], tab: .constant(0)) {
                HStack(spacing: 8) {
                    Button {} label: { Label("Record", systemImage: "mic") }.buttonStyle(OutlineButton())
                        .comingSoon("Recording is coming soon")
                    Button { importing = true } label: { Label("Add files", systemImage: "plus") }.buttonStyle(BlackButton())
                        .keyboardShortcut("o", modifiers: .command)
                }
            } content: { _ in
                VStack(alignment: .leading, spacing: 12) {
                    if store.files.isEmpty {
                        EmptyState(symbol: "doc", title: "No files yet",
                                   text: "Add PDFs, notes, spreadsheets or images. They're copied into Hermit and stay on this device.") {
                            Button { importing = true } label: { Label("Add files", systemImage: "plus") }.buttonStyle(BlackButton())
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                            TextField("Search files", text: $query).textFieldStyle(.plain).font(.system(size: 14)).focused($searching)
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain)
                            }
                        }
                        .modifier(FieldBox(focused: searching))
                        Segmented(options: HFile.Group.allCases.map { ($0, $0.rawValue) }, selection: $type)
                        if list.isEmpty { EmptyNote(text: query.isEmpty ? "No files of this type yet." : "No files match \"\(query)\".") }
                        RowList(items: list) { f in FileRow(file: f) { store.open(f) } }
                            .animation(.smooth(duration: 0.25), value: list.map(\.id))
                    }
                }
            }
            if !store.openFiles.isEmpty {
                FileViewer(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.smooth(duration: 0.28), value: store.openFiles.isEmpty)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let n = store.importFiles(urls)
            if n > 0 { model.toast(n == 1 ? "File added" : "\(n) files added") }
            else { model.toast("Couldn't add that file") }
        }
        .onDisappear { store.closeAll() }
    }
}

/// One file in a list: icon, name, type and size, when it was added. Right-click for Ask and Delete.
struct FileRow: View {
    @Environment(AppModel.self) private var model
    let file: HFile
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                WalletSymbolTile(symbol: file.symbol, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text([file.kindLabel, file.sizeText, file.project].compactMap { $0 }.joined(separator: ", "))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(file.whenText).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu {
            Button("Open", action: open)
            if file.readable { Button("Ask Hermit about it") { FilesStore.shared.ask(file, model: model) } }
            Divider()
            Button("Delete", role: .destructive) { FilesStore.shared.delete(file); model.toast("\(file.name) deleted") }
        }
    }
}

/// A file the user added. The bytes live in Application Support/Hermit/Files; this is its index entry.
struct HFile: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// File name inside the files folder.
    var stored: String
    var added: Date
    var bytes: Int
    /// The project it was added to, if any.
    var project: String?

    enum Kind { case text, code, table, image, pdf, other }
    enum Group: String, CaseIterable, Hashable { case all = "All", docs = "Docs", pdfs = "PDFs", tables = "Tables", images = "Images" }

    var url: URL { FilesStore.folder.appendingPathComponent(stored) }
    var ext: String { (name as NSString).pathExtension.lowercased() }

    var kind: Kind {
        switch ext {
        case "txt", "md", "markdown", "rtf", "log": .text
        case "swift", "ts", "js", "json", "py", "rs", "go", "sol", "yml", "yaml", "toml", "html", "css", "sh", "prompt": .code
        case "csv", "tsv": .table
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": .image
        case "pdf": .pdf
        default: .other
        }
    }
    var group: Group {
        switch kind {
        case .pdf: .pdfs
        case .table: .tables
        case .image: .images
        default: .docs
        }
    }
    var symbol: String {
        switch kind {
        case .text: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .table: "tablecells"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .other: "doc"
        }
    }
    var kindLabel: String {
        switch kind {
        case .text: "Text"
        case .code: "Code"
        case .table: "Table"
        case .image: "Image"
        case .pdf: "PDF"
        case .other: ext.isEmpty ? "File" : ext.uppercased()
        }
    }
    /// Hermit can read the words in it (text, code, tables, PDFs), so Ask works.
    var readable: Bool { [.text, .code, .table, .pdf].contains(kind) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    var whenText: String {
        Calendar.current.isDateInToday(added) ? added.formatted(date: .omitted, time: .shortened) : added.formatted(.dateTime.month(.abbreviated).day())
    }
}

@MainActor @Observable
final class FilesStore {
    static let shared = FilesStore()
    var files: [HFile]
    var openFiles: [HFile] = []
    var active: String?

    init() { files = LocalJSON.load("files.json", as: [HFile].self) ?? [] }

    /// Where added files are copied (a temporary folder in snapshot runs).
    nonisolated static var folder: URL {
        let base = LocalJSON.dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("HermitSnapshot")
        let d = base.appendingPathComponent("Files")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Copies picked files in. Returns how many were added.
    @discardableResult
    func importFiles(_ urls: [URL], project: String? = nil) -> Int {
        var added: [HFile] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = UUID().uuidString
            let stored = id + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
            let dest = Self.folder.appendingPathComponent(stored)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            added.append(HFile(id: id, name: url.lastPathComponent, stored: stored, added: Date(), bytes: bytes, project: project))
        }
        guard !added.isEmpty else { return 0 }
        withAnimation(.smooth) { files.insert(contentsOf: added, at: 0) }
        save()
        return added.count
    }

    func delete(_ f: HFile) {
        try? FileManager.default.removeItem(at: f.url)
        withAnimation(.smooth) { files.removeAll { $0.id == f.id }; openFiles.removeAll { $0.id == f.id } }
        save()
    }

    func moveProject(_ old: String, to new: String) {
        for i in files.indices where files[i].project == old { files[i].project = new }
        save()
    }

    func deleteProject(_ name: String) {
        for f in files where f.project == name { delete(f) }
    }

    func open(_ f: HFile) {
        withAnimation(.smooth(duration: 0.28)) {
            if !openFiles.contains(f) { openFiles.append(f) }
            active = f.id
        }
    }
    func close(_ f: HFile) {
        withAnimation(.smooth(duration: 0.25)) {
            openFiles.removeAll { $0 == f }
            if active == f.id { active = openFiles.last?.id }
        }
    }
    func closeAll() { withAnimation(.smooth(duration: 0.25)) { openFiles = []; active = nil } }

    /// The words in a file, for the viewer and for Ask (text, code, tables, PDF text). Capped so a huge file stays quick.
    func text(of f: HFile, limit: Int = 400_000) -> String? {
        switch f.kind {
        case .pdf: return PDFText.read(f.url, limit: limit)
        case .text, .code, .table:
            guard let data = try? Data(contentsOf: f.url, options: .mappedIfSafe) else { return nil }
            let s = String(decoding: data.prefix(limit), as: UTF8.self)
            return s
        default: return nil
        }
    }

    /// Starts a chat about the file, with its text in the message so the on-device model can read it.
    func ask(_ f: HFile, model: AppModel) {
        guard let body = text(of: f, limit: 8_000), !body.isEmpty else { model.toast("Hermit can't read this file yet"); return }
        closeAll()
        model.newChat(project: f.project)
        model.send("Here is \(f.name):\n\n\(body)\n\nWhat's in it? Give me the key points.")
    }

    private func save() { LocalJSON.save(files, "files.json") }
}
