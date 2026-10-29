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
        .background(Theme.bg)
        #if os(macOS)
        .frame(width: width)
        .frame(minHeight: 200, idealHeight: 460, maxHeight: 640)
        #else
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        #endif
    }
}

extension SheetScaffold where Foot == EmptyView {
    init(title: String, width: CGFloat = 420, detents: Set<PresentationDetent> = [.medium, .large], @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, width: width, detents: detents, content: content, foot: { EmptyView() })
    }
}

/// Files the attach sheet offers, by source. `kind` decides how Hermit reads it in chat.
enum SampleFiles {
    static let sources = ["Device", "Photos", "Hermit files", "Drive"]
    static let all: [Attachment] = [
        Attachment("wallets.xlsx", kind: .sheet, size: "49 rows", source: "Device"),
        Attachment("Invoice_Figma_2291.pdf", kind: .invoice, size: "84 KB", source: "Device"),
        Attachment("trades_Q3.csv", kind: .csv, size: "412 rows", source: "Device"),
        Attachment("Monad_whitepaper.pdf", kind: .paper, size: "38 pages", source: "Drive"),
        Attachment("PENGU_4H_chart.png", kind: .chart, size: "1.2 MB", source: "Photos"),
    ]
    static let hermit: [Attachment] = [
        Attachment("Weekly sync, dev team", kind: .doc, size: "4 min read", source: "Dictation"),
        Attachment("Re: Partnership with Pendle", kind: .doc, size: "3 messages", source: "Gmail"),
        Attachment("Hermit PRD v0.3", kind: .doc, size: "12 pages", source: "Notion"),
        Attachment("HYPE thesis", kind: .doc, size: "6 pages", source: "Hermit"),
        Attachment("Invoice #2291, Figma", kind: .invoice, size: "PDF", source: "Gmail"),
        Attachment("Q4 trading journal", kind: .doc, size: "18 entries", source: "Hermit"),
    ]
    static func list(_ source: String) -> [Attachment] {
        switch source {
        case "Hermit files": hermit
        case "Device": all.filter { $0.source == "Device" }
        default: all.filter { $0.source == source }
        }
    }
}

/// Attach from Device, Photos, Hermit files or Drive. Files are read on the device.
struct AttachSheet: View {
    let onPick: (Attachment) -> Void
    var browse: (() -> Void)? = nil
    @State private var source = "Device"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(title: "Attach") {
            Segmented(options: SampleFiles.sources.map { ($0, $0) }, selection: $source)
            VStack(spacing: 0) {
                ForEach(SampleFiles.list(source), id: \.name) { f in
                    Button { onPick(f); dismiss() } label: {
                        HStack(spacing: 12) {
                            FileIcon(kind: f.kind)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(f.size).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowStyle())
                }
                if source == "Device", let browse {
                    Button(action: browse) {
                        HStack(spacing: 12) {
                            SymbolTile(symbol: "folder", size: 34)
                            Text("Choose a file…").font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .padding(.vertical, 8).padding(.horizontal, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowStyle())
                }
            }
            .animation(.snappy, value: source)
            Text("Files are read on your device. Nothing is uploaded.").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
    }
}

/// Speak: a live waveform and timer while it transcribes on device, then the words go into the chat box.
struct RecordSheet: View {
    let transcript: String
    let onDone: (String) -> Void
    @State private var listening = true
    @State private var start = Date()
    @State private var elapsed: TimeInterval = 0
    @Environment(\.dismiss) private var dismiss

    private var heard: String {
        let words = transcript.split(separator: " ")
        let n = min(words.count, Int(elapsed * 3.2))
        return words.prefix(n).joined(separator: " ")
    }

    var body: some View {
        SheetScaffold(title: "Speak", detents: [.medium]) {
            VStack(spacing: 16) {
                Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                    .font(.system(size: 34, weight: .semibold)).monospacedDigit().contentTransition(.numericText())
                TimelineView(.animation(paused: !listening || SnapshotMode.active)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 3) {
                        ForEach(0..<28, id: \.self) { i in
                            let h = listening ? 6 + 22 * abs(sin(t * 5 + Double(i) * 0.55) * cos(t * 2.3 + Double(i % 7))) : 6
                            Capsule().fill(Theme.accent.opacity(0.85)).frame(width: 3, height: h)
                        }
                    }
                    .frame(height: 34)
                }
                Text(heard.isEmpty ? "Listening…" : heard).font(.system(size: 15)).foregroundStyle(heard.isEmpty ? Theme.faint : Theme.text)
                    .multilineTextAlignment(.center).frame(minHeight: 40)
                    .animation(.smooth, value: heard)
                Button {
                    withAnimation(.snappy) { listening.toggle() }
                    if listening { start = Date().addingTimeInterval(-elapsed) }
                } label: {
                    Image(systemName: listening ? "stop.fill" : "mic.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(listening ? Theme.red : Theme.text, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressStyle())
                Text(listening ? "Transcribing on device" : "Stopped. Use the text or keep talking.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        } foot: {
            Button("Cancel") { dismiss() }.buttonStyle(SheetButton(primary: false))
            Button("Use text") { onDone(heard.isEmpty ? transcript : heard); dismiss() }.buttonStyle(SheetButton(primary: true))
                .disabled(heard.isEmpty)
        }
        .task {
            start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if listening { elapsed = Date().timeIntervalSince(start) }
            }
        }
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
            Text([file.size, source.isEmpty ? file.source : source, "This week"].filter { !$0.isEmpty }.joined(separator: ", "))
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            preview
        } foot: {
            Button { model.toast("Saved to Downloads") } label: { Image(systemName: "arrow.down.to.line") }
                .buttonStyle(PlainCardButton()).help("Download")
            Button {
                let f = file
                dismiss()
                model.newChat(project: model.projectOpen)
                model.send("What's in \(f.name)?", attachment: f)
            } label: { Label("Ask about this file", systemImage: "sparkles").frame(maxWidth: .infinity) }
                .buttonStyle(BrandButton(full: true))
        }
    }

    @ViewBuilder private var preview: some View {
        switch file.kind {
        case .chart:
            LevelCandles(data: Candle.series(seed: 11, count: 40, start: 0.026, vol: 0.06, drift: 0.005)).frame(height: 200)
        case .csv, .sheet:
            let rows = [["Date", "Pair", "Side", "PnL"], ["Sep 30", "HYPE-PERP", "Long", "+$212"], ["Sep 28", "PENGU", "Buy", "−$64"], ["Sep 27", "ETH-PERP", "Short", "+$88"], ["Sep 25", "SOL", "Buy", "+$41"]]
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { j, c in
                            Text(c).foregroundStyle(i == 0 ? Theme.faint : Theme.text).gridColumnAlignment(j == 3 ? .trailing : .leading)
                        }
                    }
                }
            }
            .font(.system(size: 13)).monospacedDigit()
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        case .invoice:
            VStack(spacing: 0) {
                ForEach([["From", "Figma, Inc."], ["Invoice", "#2291"], ["Plan", "Professional"], ["Amount", "$45.00"], ["Due", "Oct 27"]], id: \.self) { TxLine($0[0], $0[1]) }
            }
            .padding(.horizontal, 14).padding(.vertical, 6).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        case .code:
            Text(file.name.hasSuffix(".json") ? "{\n  \"schedule\": \"0 8 * * *\",\n  \"budget\": 20,\n  \"pay\": \"x402\"\n}"
                 : "const news = hermit.tool(\"perplexity\")\ncron(\"0 8 * * *\", async () => {\n  const digest = await news.search(\"HYPE news\")\n  await telegram.send(me, digest.summary)\n})")
                .font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Summary").font(.system(size: 13.5, weight: .semibold))
                Text("Key points, decisions and next steps from \(file.name), pulled out by Hermit on your device.").foregroundStyle(Theme.muted)
                Text("Action items").font(.system(size: 13.5, weight: .semibold)).padding(.top, 4)
                Text("Ship wallet onboarding by Nov 8. Compare Privy with a local key. Send the Pendle deck.").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13.5)).lineSpacing(3)
        }
    }
}
