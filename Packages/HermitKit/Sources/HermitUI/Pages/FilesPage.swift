import SwiftUI
import Observation
import UniformTypeIdentifiers

/// Files (demo: Files.jsx): search, type filter, Record and Upload. Opening a file shows the file viewer.
struct FilesPage: View {
    @Environment(AppModel.self) private var model
    @State private var store = FilesStore.shared
    @State private var query = ""
    @State private var type = "All"
    @State private var sheet: FilesSheet?
    @FocusState private var searching: Bool

    enum FilesSheet: String, Identifiable { case record, upload; var id: String { rawValue } }
    static let types: [(String, String)] = [("All", "All"), ("Meeting notes", "Notes"), ("Email", "Email"), ("Doc", "Docs"), ("Research", "Research")]

    var body: some View {
        let list = store.files.filter { (type == "All" || $0.type == type) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.src.localizedCaseInsensitiveContains(query)) }
        ZStack {
            Page(title: "Files", tabs: [(0, "Files")], tab: .constant(0)) {
                HStack(spacing: 8) {
                    Button { sheet = .record } label: { Label("Record", systemImage: "mic") }.buttonStyle(OutlineButton())
                    Button { sheet = .upload } label: { Label("Upload", systemImage: "arrow.up.doc") }.buttonStyle(OutlineButton())
                }
            } content: { _ in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
                        TextField("Search files", text: $query).textFieldStyle(.plain).font(.system(size: 14)).focused($searching)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain)
                        }
                    }
                    .modifier(FieldBox(focused: searching))
                    Segmented(options: Self.types, selection: $type)
                    if list.isEmpty { EmptyNote(text: query.isEmpty ? "No files of this type yet." : "No files match \"\(query)\".") }
                    RowList(items: list) { f in
                        Button { store.open(f) } label: {
                            HStack(spacing: 12) {
                                SymbolTile(symbol: f.symbol, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text("\(f.type), \(f.src)").font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(f.when).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(RowButtonStyle())
                        .contextMenu {
                            Button("Open") { store.open(f) }
                            Button("Ask Hermit about it") { model.send("What's in \(f.name)?") }
                            Divider()
                            Button("Delete", role: .destructive) { store.delete(f); model.toast("\(f.name) deleted") }
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: list.map(\.id))
                }
            }
            if !store.openFiles.isEmpty {
                FileViewer(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.smooth(duration: 0.28), value: store.openFiles.isEmpty)
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .record: RecordSheet { f in store.add(f); model.toast("\(f.name) added") }
                case .upload: UploadSheet { f in store.add(f); model.toast("\(f.name) added") }
                }
            }
            .environment(model).tint(Theme.text)
        }
        .onDisappear { store.closeAll() }
    }
}

struct HFile: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let src: String
    let when: String
    let size: String
    var kindOverride: String? = nil

    /// How the viewer lays it out (demo fileKind).
    var kind: String {
        if let kindOverride { return kindOverride }
        let n = name.lowercased()
        if n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".heic") { return "chart" }
        if n.hasSuffix(".csv") || n.hasSuffix(".xlsx") { return "csv" }
        if n.contains("invoice") { return "invoice" }
        if [".ts", ".js", ".json", ".py", ".swift", ".prompt"].contains(where: { n.hasSuffix($0) }) { return "code" }
        if n.hasSuffix(".pdf") { return "paper" }
        return ["Meeting notes": "notes", "Email": "email", "Research": "research"][type] ?? "doc"
    }
    var symbol: String {
        switch kind {
        case "notes": "mic"
        case "email": "envelope"
        case "research": "book"
        case "csv": "tablecells"
        case "chart": "photo"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "invoice": "doc.text.below.ecg"
        default: "doc.text"
        }
    }
}

@MainActor @Observable
final class FilesStore {
    static let shared = FilesStore()
    var files: [HFile] = [
        HFile(name: "Weekly sync — dev team", type: "Meeting notes", src: "Dictation", when: "Today", size: "4 min read"),
        HFile(name: "Re: Partnership with Pendle", type: "Email", src: "Gmail", when: "Today", size: "3 messages"),
        HFile(name: "Hermit PRD v0.3", type: "Doc", src: "Notion", when: "Yesterday", size: "12 pages"),
        HFile(name: "HYPE thesis", type: "Research", src: "Hermit", when: "Yesterday", size: "6 pages"),
        HFile(name: "Invoice #2291 — Figma", type: "Email", src: "Gmail", when: "Oct 24", size: "PDF"),
        HFile(name: "Voice memo — airdrop ideas", type: "Meeting notes", src: "Dictation", when: "Oct 23", size: "2 min"),
        HFile(name: "trades_Q3.csv", type: "Doc", src: "Device", when: "Oct 22", size: "412 rows"),
        HFile(name: "Q4 trading journal", type: "Doc", src: "Hermit", when: "Oct 21", size: "18 entries"),
        HFile(name: "news-bot.ts", type: "Doc", src: "GitHub", when: "Oct 21", size: "1 KB"),
        HFile(name: "Ethena docs — sUSDe risks", type: "Doc", src: "Web clip", when: "Oct 20", size: "9 pages"),
        HFile(name: "PENGU_4H_chart.png", type: "Doc", src: "Photos", when: "Oct 19", size: "1.2 MB"),
    ]
    var openFiles: [HFile] = []
    var active: String?

    func open(_ f: HFile) {
        withAnimation(.smooth(duration: 0.28)) {
            if !openFiles.contains(f) { openFiles.append(f) }
            active = f.name
        }
    }
    func close(_ f: HFile) {
        withAnimation(.smooth(duration: 0.25)) {
            openFiles.removeAll { $0 == f }
            if active == f.name { active = openFiles.last?.name }
        }
    }
    func closeAll() { withAnimation(.smooth(duration: 0.25)) { openFiles = []; active = nil } }
    func add(_ f: HFile) { withAnimation(.smooth) { files.removeAll { $0.name == f.name }; files.insert(f, at: 0) } }
    func delete(_ f: HFile) { withAnimation(.smooth) { files.removeAll { $0 == f }; openFiles.removeAll { $0 == f } } }
}

// MARK: Record

/// Dictation: a live waveform and timer, stop or keep going, then save to Files.
struct RecordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (HFile) -> Void
    @State private var seconds = 0
    @State private var on = true

    private var clock: String { "\(seconds / 60):" + String(format: "%02d", seconds % 60) }

    var body: some View {
        SheetChrome(title: "Record") {
            VStack(spacing: 16) {
                Text(clock).font(.system(size: 40, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                    .animation(.snappy, value: seconds)
                Waveform(on: on).frame(height: 44)
                Button { withAnimation(.snappy) { on.toggle() } } label: {
                    Image(systemName: on ? "stop.fill" : "mic.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 58, height: 58).background(on ? Theme.red : Theme.text, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(on ? "Stop" : "Resume")
                .keyboardShortcut(.space, modifiers: [])
                Text(on ? "Transcribing on device" : "Stopped. Save it or keep recording.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        } foot: {
            Button("Save to Files") {
                onSave(HFile(name: "Voice memo \(clock)", type: "Meeting notes", src: "Dictation", when: "Just now", size: "\(max(1, Int((Double(seconds) / 60).rounded()))) min"))
                dismiss()
            }
            .buttonStyle(WideButton()).disabled(on || seconds == 0).keyboardShortcut(.defaultAction)
        }
        .task(id: on) {
            while on && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if on && !Task.isCancelled { seconds += 1 }
            }
        }
    }
}

/// Bars that move while recording.
struct Waveform: View {
    let on: Bool
    var body: some View {
        TimelineView(.animation(paused: !on)) { t in
            let time = t.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<32, id: \.self) { i in
                    let v = on ? 0.25 + 0.75 * abs(sin(time * 3.1 + Double(i) * 0.55) * cos(time * 1.7 + Double(i % 7) * 0.9)) : 0.15
                    Capsule().fill(on ? Theme.text : Theme.faint).frame(width: 3, height: max(4, 44 * v))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Upload

/// Pick a file from the device (a real file picker), Photos, Hermit files or Drive.
struct UploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (HFile) -> Void
    @State private var source = "Device"
    @State private var importing = false

    static let samples: [(HFile, String)] = [
        (HFile(name: "wallets.xlsx", type: "Doc", src: "Device", when: "Just now", size: "49 rows"), "Device"),
        (HFile(name: "Invoice_Figma_2291.pdf", type: "Doc", src: "Device", when: "Just now", size: "84 KB"), "Device"),
        (HFile(name: "trades_Q4.csv", type: "Doc", src: "Device", when: "Just now", size: "212 rows"), "Device"),
        (HFile(name: "Monad_whitepaper.pdf", type: "Research", src: "Drive", when: "Just now", size: "38 pages"), "Drive"),
        (HFile(name: "Base grant proposal", type: "Doc", src: "Drive", when: "Just now", size: "7 pages"), "Drive"),
        (HFile(name: "PENGU_1D_chart.png", type: "Doc", src: "Photos", when: "Just now", size: "1.1 MB"), "Photos"),
        (HFile(name: "Receipt_Vercel.png", type: "Doc", src: "Photos", when: "Just now", size: "640 KB"), "Photos"),
    ]

    var body: some View {
        let list: [HFile] = source == "Hermit files"
            ? FilesStore.shared.files.prefix(4).map { HFile(name: $0.name + " (copy)", type: $0.type, src: "Hermit", when: "Just now", size: $0.size, kindOverride: $0.kind) }
            : Self.samples.filter { $0.1 == source }.map(\.0)
        SheetChrome(title: "Upload") {
            Segmented(options: ["Device", "Photos", "Hermit files", "Drive"].map { ($0, $0) }, selection: $source)
            if source == "Device" {
                SelectRow(title: "Choose a file…", subtitle: "PDF, CSV, images, docs or code", action: { importing = true }) {
                    SymbolTile(symbol: "folder", size: 34)
                }
            }
            RowList(items: list) { f in
                Button { onPick(f); dismiss() } label: {
                    HStack(spacing: 12) {
                        SymbolTile(symbol: f.symbol, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(f.size).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 9)
                }
                .buttonStyle(RowButtonStyle())
            }
            Text("Files are read on your device. Nothing is uploaded.").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            onPick(HFile(name: url.lastPathComponent, type: url.pathExtension.lowercased() == "pdf" ? "Doc" : "Doc", src: "Device", when: "Just now", size: size))
            dismiss()
        }
    }
}
