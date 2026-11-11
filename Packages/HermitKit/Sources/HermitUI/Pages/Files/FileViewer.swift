import SwiftUI
import PDFKit
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Claude-style file reader over the Files page: open files sit in tabs, a toolbar with zoom, Quick Look, share,
/// Ask and close, then the file itself: text, code, a table, an image or the PDF.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    let store: FilesStore
    @State private var zoom: Double = 1
    @State private var preview: URL?

    private var file: HFile? { store.openFiles.first { $0.id == store.active } ?? store.openFiles.first }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Hairline()
            if let file {
                Group {
                    if file.kind == .pdf {
                        PDFKitView(url: file.url)
                    } else if SnapshotMode.active {
                        page(file).frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView { page(file) }.scrollIndicators(.automatic)
                    }
                }
                .id(file.id)
                .transition(.opacity)
            }
        }
        .background(Theme.bg)
        .animation(.smooth(duration: 0.2), value: store.active)
        .quickLookPreview($preview)
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(store.openFiles) { f in tabView(f) }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                if file?.kind != .pdf {
                    tool("minus.magnifyingglass", "Zoom out") { setZoom(zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                    Button { setZoom(1) } label: {
                        Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(width: 44, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Reset zoom").keyboardShortcut("0", modifiers: .command)
                    tool("plus.magnifyingglass", "Zoom in") { setZoom(zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
                }
                tool("eye", "Quick Look") { preview = file?.url }.keyboardShortcut("y", modifiers: .command)
                if let f = file {
                    ShareLink(item: f.url) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13.5)).foregroundStyle(Theme.text)
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle()).help("Share or save a copy")
                }
                Button { if let f = file { store.ask(f, model: model) } } label: {
                    Label("Ask", systemImage: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(file?.readable != true).opacity(file?.readable == true ? 1 : 0.45)
                .help(file?.readable == true ? "Ask Hermit about this file" : "Hermit can't read this kind of file yet")
                tool("xmark", "Close viewer") { store.closeAll() }.keyboardShortcut(.cancelAction)
            }
            .padding(.trailing, 10)
        }
        .frame(height: 48)
        .background(Theme.bg)
    }

    private func tabView(_ f: HFile) -> some View {
        let on = f.id == (file?.id ?? "")
        return HStack(spacing: 6) {
            Button { withAnimation(.snappy) { store.active = f.id } } label: {
                HStack(spacing: 6) {
                    Image(systemName: f.symbol).font(.system(size: 11.5))
                    Text(f.name).font(.system(size: 12.5, weight: on ? .medium : .regular)).lineLimit(1).frame(maxWidth: 190)
                }
                .foregroundStyle(on ? Theme.text : Theme.muted)
            }
            .buttonStyle(.plain)
            Button { store.close(f) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close \(f.name)")
        }
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 32)
        .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tool(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).help(label).accessibilityLabel(label)
    }

    private func setZoom(_ z: Double) { withAnimation(.snappy) { zoom = min(2, max(0.5, (z * 10).rounded() / 10)) } }

    // MARK: Page

    private func properties(_ f: HFile) -> [(String, String)] {
        var out: [(String, String)] = [("Type", f.kindLabel), ("Size", f.sizeText), ("Added", f.added.formatted(date: .abbreviated, time: .shortened))]
        if let p = f.project { out.append(("Project", p)) }
        return out
    }

    private func page(_ f: HFile) -> some View {
        let z = zoom
        return VStack(alignment: .leading, spacing: 14 * z) {
            Text(f.name).font(.system(size: 30 * z, weight: .bold)).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7 * z) {
                ForEach(properties(f), id: \.0) { p in
                    HStack(spacing: 0) {
                        Text(p.0).foregroundStyle(Theme.hint).frame(width: 110 * z, alignment: .leading)
                        Text(p.1)
                    }
                    .font(.system(size: 13.5 * z))
                }
            }
            Hairline().padding(.vertical, 6 * z)
            FileBody(file: f, text: store.text(of: f), z: z) { preview = f.url }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 760 * z, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 60)
    }
}

/// The file's content by kind.
private struct FileBody: View {
    let file: HFile
    let text: String?
    let z: Double
    let quickLook: () -> Void

    var body: some View {
        switch file.kind {
        case .image:
            if let img = PlatformImage.load(file.url) {
                img.resizable().scaledToFit().frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else { unreadable }
        case .table:
            if let text { FileTable(rows: CSV.rows(text, separator: file.ext == "tsv" ? "\t" : ","), z: z) } else { unreadable }
        case .code:
            if let text { code(text) } else { unreadable }
        case .text:
            if let text {
                Text(text).font(.system(size: 15 * z)).lineSpacing(4 * z).fixedSize(horizontal: false, vertical: true)
            } else { unreadable }
        default: unreadable
        }
    }

    private var unreadable: some View {
        EmptyState(symbol: "eye", title: "No preview here", text: "Open it in Quick Look to see it.") {
            Button("Quick Look", action: quickLook).buttonStyle(OutlineButton())
        }
    }

    private func code(_ src: String) -> some View {
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).prefix(3000).map(String.init)
        return LazyVStack(alignment: .leading, spacing: 3 * z) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .firstTextBaseline, spacing: 14 * z) {
                    Text("\(i + 1)").foregroundStyle(Theme.hint).frame(width: 34 * z, alignment: .trailing)
                    Text(l.isEmpty ? " " : l).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12.5 * z, design: .monospaced))
        .padding(16 * z).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// A CSV or TSV shown as a table (first 300 rows).
private struct FileTable: View {
    let rows: [[String]]
    let z: Double

    var body: some View {
        let shown = Array(rows.prefix(300))
        let cols = shown.map(\.count).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18 * z, verticalSpacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { j in
                                Text(j < r.count ? r[j] : "").font(.system(size: 13.5 * z, weight: i == 0 ? .medium : .regular)).monospacedDigit()
                                    .foregroundStyle(i == 0 ? Theme.muted : Theme.text).lineLimit(1).fixedSize()
                            }
                        }
                        .padding(.vertical, 8 * z)
                        if i < shown.count - 1 { Hairline().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(.horizontal, 14 * z).padding(.vertical, 4)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            if rows.count > shown.count {
                Text("Showing the first \(shown.count) of \(rows.count) rows.").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
            }
        }
    }
}

enum CSV {
    /// Splits CSV text into rows and cells, honouring quoted cells.
    static func rows(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var it = text.makeIterator()
        while let c = it.next() {
            if quoted {
                if c == "\"" { quoted = false } else { cell.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == separator {
                row.append(cell); cell = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(cell); rows.append(row); row = []; cell = ""
            } else if c != "\r" {
                cell.append(c)
            }
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }
}

enum PDFText {
    static func read(_ url: URL, limit: Int) -> String? {
        guard let s = PDFDocument(url: url)?.string, !s.isEmpty else { return nil }
        return String(s.prefix(limit))
    }
}

enum PlatformImage {
    static func load(_ url: URL) -> Image? {
        #if os(macOS)
        NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }
}

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView(); v.document = PDFDocument(url: url); v.autoScales = true; v.backgroundColor = .white
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {}
}
#else
struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView(); v.document = PDFDocument(url: url); v.autoScales = true; v.backgroundColor = .white
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}
#endif
