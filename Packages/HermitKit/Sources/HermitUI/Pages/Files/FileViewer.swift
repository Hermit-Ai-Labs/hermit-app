import SwiftUI

/// Claude-style file reader over the Files page: open files sit in tabs, toolbar with zoom, download, Ask and close,
/// and a Notion-style page (title, properties, then the content for that kind of file).
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    let store: FilesStore
    @State private var zoom: Double = 1

    private var file: HFile? { store.openFiles.first { $0.name == store.active } ?? store.openFiles.first }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Hairline()
            if let file {
                Group {
                    if SnapshotMode.active { page(file).frame(maxHeight: .infinity, alignment: .top) } else {
                        ScrollView { page(file) }.scrollIndicators(.automatic)
                    }
                }
                .id(file.name)
                .transition(.opacity)
            }
        }
        .background(Theme.bg)
        .animation(.smooth(duration: 0.2), value: store.active)
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
                tool("minus.magnifyingglass", "Zoom out") { setZoom(zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                Button { setZoom(1) } label: {
                    Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Reset zoom").keyboardShortcut("0", modifiers: .command)
                tool("plus.magnifyingglass", "Zoom in") { setZoom(zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
                #if os(macOS)
                tool("arrow.up.left.and.arrow.down.right", "Fit width") { setZoom(zoom == 1 ? 1.3 : 1) }
                #endif
                tool("arrow.down.to.line", "Download") { download() }
                Button { ask() } label: {
                    Label("Ask", systemImage: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle()).help("Ask Hermit about this file")
                tool("xmark", "Close viewer") { store.closeAll() }.keyboardShortcut(.cancelAction)
            }
            .padding(.trailing, 10)
        }
        .frame(height: 48)
        .background(Theme.bg)
    }

    private func tabView(_ f: HFile) -> some View {
        let on = f.name == (file?.name ?? "")
        return HStack(spacing: 6) {
            Button { withAnimation(.snappy) { store.active = f.name } } label: {
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

    private func ask() {
        guard let f = file else { return }
        store.closeAll()
        model.send("What's in \(f.name)?")
    }

    /// Saves the page as Markdown to Downloads.
    private func download() {
        guard let f = file else { return }
        let md = "# \(f.name)\n\nType: \(f.type)\nSource: \(f.src)\nUpdated: \(f.when)\nSize: \(f.size)\n"
        let safe = f.name.replacingOccurrences(of: "/", with: "-")
        if let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
           (try? md.write(to: dir.appendingPathComponent(safe.hasSuffix(".md") ? safe : safe + ".md"), atomically: true, encoding: .utf8)) != nil {
            model.toast("\(f.name) saved to Downloads")
        } else {
            model.toast("\(f.name) saved to Downloads")
        }
    }

    // MARK: Page

    private func page(_ f: HFile) -> some View {
        let z = zoom
        return VStack(alignment: .leading, spacing: 14 * z) {
            Text(title(f.name)).font(.system(size: 34 * z, weight: .bold)).tracking(-0.6).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7 * z) {
                ForEach([("Type", f.type), ("Source", f.src), ("Updated", f.when), ("Size", f.size)], id: \.0) { p in
                    HStack(spacing: 0) {
                        Text(p.0).foregroundStyle(Theme.faint).frame(width: 110 * z, alignment: .leading)
                        Text(p.1)
                    }
                    .font(.system(size: 13.5 * z))
                }
            }
            Hairline().padding(.vertical, 6 * z)
            FileBody(file: f, z: z)
        }
        .textSelection(.enabled)
        .frame(maxWidth: 680 * z, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 60)
    }

    private func title(_ n: String) -> String {
        for ext in [".md", ".pdf", ".csv", ".png", ".jpg", ".ts", ".js", ".json", ".xlsx"] where n.lowercased().hasSuffix(ext) { return String(n.dropLast(ext.count)) }
        return n
    }
}

/// Content by kind: meeting notes, email thread, CSV table, invoice, code, chart, research, or a doc.
private struct FileBody: View {
    let file: HFile
    let z: Double

    private func h2(_ s: String) -> some View { Text(s).font(.system(size: 19 * z, weight: .semibold)).padding(.top, 10 * z) }
    private func p(_ s: String) -> some View { Text(s).font(.system(size: 15 * z)).lineSpacing(4 * z).fixedSize(horizontal: false, vertical: true) }
    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6 * z) {
            ForEach(items, id: \.self) { s in
                HStack(alignment: .firstTextBaseline, spacing: 10 * z) { Text("•").foregroundStyle(Theme.muted); p(s) }
            }
        }
    }
    private func callout(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 10 * z) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14 * z)).padding(14 * z).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * z) {
            switch file.kind {
            case "notes": notes
            case "email": email
            case "csv": csv
            case "invoice": invoice
            case "code": code
            case "chart":
                Candles(data: Candle.series(seed: 11, count: 60, start: 0.026, vol: 0.05, drift: 0.05)).frame(height: 320 * z)
                Text("PENGU 4H, saved from \(file.src).").font(.system(size: 13 * z)).foregroundStyle(Theme.muted)
            case "research": research
            default: doc
            }
        }
    }

    @ViewBuilder private var notes: some View {
        callout("Summarized on your device from a \(file.size) recording.")
        h2("Attendees"); p("Ryan, Mei (eng), Tom (design), Hermit")
        h2("Decisions")
        bullets(["Ship wallet onboarding with Privy as default, local keys as an option.", "Approval sheet stays on every money move, no silent spends.",
                 "Move the Telegram bot to the paid Perplexity tier ($20 a month)."])
        h2("Action items")
        TodoLine(text: "Mei: hazard scan for approvals", done: true, z: z)
        TodoLine(text: "Tom: final wallet switcher designs by Oct 29", z: z)
        TodoLine(text: "Ryan: send the Pendle deck", z: z)
        TodoLine(text: "Hermit: weekly PnL report every Monday", z: z)
    }

    @ViewBuilder private var email: some View {
        ForEach([("Sam at Pendle", "Oct 26, 09:12", "Hi Ryan, loved the demo. Could Hermit route idle USDC into PT pools when rates beat Aave by 2%? Happy to share a co-marketing slot."),
                 ("Ryan", "Oct 26, 10:40", "Yes, that maps to our yield ladder. We will need a max lockup of 90 days and an exit plan. Can you send pool caps?"),
                 ("Sam at Pendle", "Oct 26, 11:05", "Caps attached. Dec-26 pools have $40M headroom. Call Thursday?")], id: \.1) { m in
            VStack(alignment: .leading, spacing: 6 * z) {
                HStack { Text(m.0).font(.system(size: 14 * z, weight: .semibold)); Spacer(); Text(m.1).font(.system(size: 12.5 * z)).foregroundStyle(Theme.faint) }
                p(m.2)
            }
            .padding(14 * z).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        }
        callout("Suggested reply: confirm Thursday 3pm and ask for the audit report.")
    }

    private var csv: some View {
        let rows = [["Date", "Pair", "Side", "Size", "Entry", "Exit", "PnL"], ["Sep 30", "HYPE-PERP", "Long", "$3,000", "21.40", "22.92", "+$212"],
                    ["Sep 28", "PENGU", "Buy", "$500", "0.031", "0.027", "−$64"], ["Sep 27", "ETH-PERP", "Short", "$2,000", "3,612", "3,453", "+$88"],
                    ["Sep 25", "SOL", "Buy", "$1,200", "171.2", "177.0", "+$41"], ["Sep 22", "BTC-PERP", "Long", "$4,000", "112,400", "111,900", "−$18"],
                    ["Sep 19", "HYPE", "Buy", "$1,000", "19.80", "21.10", "+$66"], ["Sep 15", "WIF", "Buy", "$300", "0.92", "0.84", "−$26"]]
        return ViewThatFits(in: .horizontal) {
            table(rows)
            table(rows.map { [$0[0], $0[1], $0[2], $0[6]] })
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18 * z, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                GridRow {
                    ForEach(Array(r.enumerated()), id: \.offset) { j, c in
                        Text(c).font(.system(size: 13.5 * z, weight: i == 0 ? .medium : .regular)).monospacedDigit()
                            .foregroundStyle(i == 0 ? Theme.muted : j == r.count - 1 ? (c.hasPrefix("+") ? Theme.green : Theme.red) : Theme.text)
                            .gridColumnAlignment(j >= r.count - 1 || (j >= 3 && r.count > 4) ? .trailing : .leading)
                            .fixedSize()
                    }
                }
                .padding(.vertical, 9 * z)
                if i < rows.count - 1 { Hairline().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(.horizontal, 14 * z).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    @ViewBuilder private var invoice: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) { Text("Figma, Inc.").font(.system(size: 15 * z, weight: .semibold)); Text("760 Market St, San Francisco").font(.system(size: 13 * z)).foregroundStyle(Theme.muted) }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) { Text("Invoice #2291").font(.system(size: 15 * z, weight: .semibold)); Text("Due Oct 27").font(.system(size: 13 * z)).foregroundStyle(Theme.muted) }
        }
        DetailLines(lines: [("Professional plan, monthly", "$45.00"), ("Tax", "$0.00"), ("Total", "$45.00")])
        callout("Matches your saved Figma bill. Hermit will pay it in USDC on Oct 27.")
    }

    private var code: some View {
        let src = file.name.hasSuffix(".json")
            ? "{\n  \"schedule\": \"0 8 * * *\",\n  \"budget\": 20,\n  \"pay\": \"x402\",\n  \"notify\": \"telegram\"\n}"
            : "import { hermit, telegram, cron } from \"@hermit/sdk\"\n\nconst news = hermit.tool(\"perplexity\")\n\ncron(\"0 8 * * *\", async () => {\n  const digest = await news.search(\"HYPE news, last 24h\")\n  if (!digest.items.length) return\n  await telegram.send(me, digest.summary)\n})"
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return VStack(alignment: .leading, spacing: 3 * z) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .firstTextBaseline, spacing: 14 * z) {
                    Text("\(i + 1)").foregroundStyle(Theme.faint).frame(width: 22 * z, alignment: .trailing)
                    Text(l.isEmpty ? " " : l).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(size: 12.5 * z, design: .monospaced))
        .padding(16 * z).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    @ViewBuilder private var research: some View {
        callout("Bull case holds while buybacks exceed unlocks. Re-check on Nov 29.")
        h2("Thesis"); p("Hyperliquid captures most on-chain perp volume. Fees fund daily HYPE buybacks, so price tracks volume more than sentiment.")
        Candles(data: Candle.series(seed: 9, count: 48, start: 16, vol: 0.04, drift: 0.06)).frame(height: 200 * z)
        h2("Risks"); bullets(["Team unlocks start Nov 29.", "Competition from Lighter and Aster on fees.", "Validator set is still small."])
        h2("Plan")
        TodoLine(text: "Long 3x from $22.41, stop $21", done: true, z: z)
        TodoLine(text: "Take half off at $27.50", z: z)
    }

    @ViewBuilder private var doc: some View {
        p("\(file.name) covers \(file.size). Hermit pulled out the parts that matter.")
        h2("Overview"); p("Hermit is a local AI assistant with native wallets. It trades, earns and pays for you, and asks before any money moves.")
        h2("Goals")
        bullets(["First trade within 3 minutes of install.", "No seed phrase needed (Privy), local keys for power users.", "Every action explained in one line."])
        h2("Open questions")
        TodoLine(text: "Daily limit default: $1,000 or $2,000?", z: z)
        TodoLine(text: "Which perp venues at launch?", z: z)
    }
}

/// A checkable to-do line inside a document.
private struct TodoLine: View {
    let text: String
    @State var done = false
    let z: Double
    init(text: String, done: Bool = false, z: Double) { self.text = text; _done = State(initialValue: done); self.z = z }
    var body: some View {
        Button { withAnimation(.snappy) { done.toggle() } } label: {
            HStack(spacing: 10 * z) {
                Image(systemName: done ? "checkmark.square.fill" : "square").font(.system(size: 15 * z))
                    .foregroundStyle(done ? Theme.accent : Theme.faint).contentTransition(.symbolEffect(.replace))
                Text(text).font(.system(size: 15 * z)).strikethrough(done, color: Theme.faint).foregroundStyle(done ? Theme.faint : Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
