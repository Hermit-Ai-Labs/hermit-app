import SwiftUI
import HermitCore

/// Standard sheet: title and close, content, optional footer. A dialog on the Mac, a bottom sheet on iPhone.
struct SheetScaffold<Content: View, Foot: View>: View {
    let title: String
    var width: CGFloat = 420
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder var content: () -> Content
    @ViewBuilder var foot: () -> Foot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28).background(Theme.hover, in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close")
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)
            if Foot.self != EmptyView.self {
                HStack(spacing: 10) { foot() }.padding(.horizontal, 22).padding(.vertical, 14)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .foregroundStyle(Theme.text)
        #if os(macOS)
        .background(Theme.bg)
        .frame(width: width)
        .frame(minHeight: 200, idealHeight: 460, maxHeight: 640)
        #else
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .glassSheetBackground()
        #endif
    }
}

extension SheetScaffold where Foot == EmptyView {
    init(title: String, width: CGFloat = 420, detents: Set<PresentationDetent> = [.medium, .large], @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, width: width, detents: detents, content: content, foot: { EmptyView() })
    }
}

/// Preview of a file with Ask about it (project files, attachments).
struct FileSheet: View {
    let file: Attachment
    var source: String = ""
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: file.name, width: 520) {
            let meta = [file.size, source.isEmpty ? file.source : source].filter { !$0.isEmpty }.joined(separator: ", ")
            if !meta.isEmpty { Text(meta).font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
            preview
        } foot: {
            Button {
                let f = file
                dismiss()
                model.newChat(project: model.projectOpen)
                model.send("What's in \(f.name)?", attachment: f)
            } label: { Label("Ask about this file", systemImage: "sparkles").frame(maxWidth: .infinity) }
                .buttonStyle(BrandButton(full: true))
        }
    }

    /// The file's text when Hermit could read it; otherwise an honest note.
    @ViewBuilder private var preview: some View {
        if let text = file.text, !text.isEmpty {
            Text(text + (file.truncated ? "\n…" : ""))
                .font(.system(size: 12, design: .monospaced)).lineSpacing(4).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text("No preview for this file. Hermit can read plain text, Markdown, CSV, JSON and code files.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.muted)
        }
    }
}
