import SwiftUI
import HermitCore

/// Projects, Claude-style: a grid of projects; each opens a page with a chat box above its tabs
/// (Overview, Chats, Instructions, Files).
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

    var body: some View {
        Button { model.openProject(project.name) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: project.symbol).font(.system(size: 16)).foregroundStyle(Theme.text)
                    Spacer()
                    if project.status != "Running" { Text(project.status).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(project.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack {
                    Text(project.pnl).monospacedDigit()
                        .foregroundStyle(project.gain > 0 ? Theme.green : project.gain < 0 ? Theme.red : Theme.faint)
                    Spacer()
                    Text("\(chats) chats").foregroundStyle(Theme.faint)
                }
                .font(.system(size: 12.5))
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
        }
    }
}

/// One project: chat box above the tabs; sending starts a chat inside the project.
struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    let project: Project
    @State private var tab = "overview"
    @State private var file: Attachment?

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
                }
                .padding(.leading, -8)
                Composer(placeholder: "Start a chat in \(project.name)", label: "Uses this project's files", projectPicker: false, minLines: 2, autoFocus: false) { text, f in
                    model.newChat(project: project.name)
                    model.send(text, attachment: f)
                }
                .padding(.top, 16)
                PageTabs(tabs: [("overview", "Overview"), ("chats", "Chats \(model.chats(in: project.name).count)"), ("instructions", "Instructions"), ("files", "Files")],
                         selection: $tab)
                    .padding(.top, 22)
                Group {
                    switch tab {
                    case "chats": chats
                    case "instructions": ProjectInstructions(project: project)
                    case "files": files
                    default: overview
                    }
                }
                .padding(.top, 20)
                .id(tab)
                .transition(.opacity)
            }
            .animation(.smooth(duration: 0.2), value: tab)
        }
        .sheet(item: $file) { f in FileSheet(file: f, source: project.name) }
    }

    // MARK: Overview

    private var overview: some View {
        let burn = model.burn(of: project)
        let net = project.gain - project.cost
        return VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 130 : 120), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 14) {
                stat("In operation", Money.usd(project.money), nil)
                stat("Cost", Money.usd(project.cost), nil)
                stat(project.gainLabel, Money.usd(project.gain, signed: true), project.gain == 0 ? nil : project.gain > 0)
                stat("Net", Money.usd(net, signed: true), net >= 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Gains").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Money.usd(project.gain, signed: true)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(project.gain > 0 ? Theme.green : project.gain < 0 ? Theme.red : Theme.text)
                }
                if project.gain != 0 {
                    LineChart(values: gainSeries, color: project.gain < 0 ? Theme.red : Theme.text).frame(height: 96).padding(.vertical, 8)
                } else {
                    Text(project.gainNote).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                ForEach(project.gains) { g in
                    HStack {
                        Text(g.what).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Money.usd(g.amount, signed: true)).monospacedDigit()
                            .foregroundStyle(g.amount > 0 ? Theme.green : g.amount < 0 ? Theme.red : Theme.faint)
                    }
                    .font(.system(size: 12.5))
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
            if !project.burn.isEmpty || project.forecast != nil {
                let layout = compact ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    if !project.burn.isEmpty { costs(burn) }
                    if let f = project.forecast { forecast(f, burn) }
                }
            }
        }
    }

    private var gainSeries: [Double] {
        Candle.series(seed: project.name.count, count: 30, start: 100, vol: 0.06, drift: project.gain >= 0 ? 0.01 : -0.01)
            .enumerated().map { $1.c + Double($0) * (project.gain >= 0 ? 4 : -4) }
    }

    private func stat(_ label: String, _ value: String, _ up: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().tracking(-0.3)
                .foregroundStyle(up == nil ? Theme.text : up! ? Theme.green : Theme.red)
        }
    }

    private func costs(_ burn: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Costs").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Text("−\(Money.usd(burn))/mo").font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.red)
                    .contentTransition(.numericText(value: burn))
            }
            ForEach(project.burn) { c in
                let off = model.costsOff.contains("\(project.name)/\(c.what)")
                HStack {
                    Text(c.what).foregroundStyle(off ? Theme.faint : Theme.muted).strikethrough(off, color: Theme.faint)
                    Spacer()
                    Text(Money.usd(c.amount)).monospacedDigit().foregroundStyle(off ? Theme.faint : Theme.text)
                    Toggle(c.what, isOn: Binding(get: { !off }, set: { _ in withAnimation(.snappy) { model.toggleCost(project, c) } }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.text).controlSize(.mini)
                }
                .font(.system(size: 12.5))
            }
            Text(runway(burn)).font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 2)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func runway(_ burn: Double) -> String {
        if burn == 0 { return "All paused" }
        if project.money <= 0 { return "Auto-payments" }
        if project.money >= burn { return "Runway \(Int(project.money / burn)) mo" }
        return "Runway \(Int(project.money / burn * 30)) days"
    }

    private func forecast(_ f: Project.Forecast, _ burn: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Expected / mo").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                Text(Money.usd(f.monthly, signed: true)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(f.monthly >= 0 ? Theme.green : Theme.red)
            }
            Text(f.basis).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            if !project.burn.isEmpty {
                HStack {
                    Text("After costs").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Money.usd(f.monthly - burn, signed: true)).monospacedDigit()
                        .foregroundStyle(f.monthly - burn >= 0 ? Theme.green : Theme.red)
                        .contentTransition(.numericText(value: f.monthly - burn))
                }
                .font(.system(size: 12.5))
            }
            Label("Updates daily, next in \(24 - f.updatedHoursAgo)h", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 2)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    // MARK: Chats and files

    private var chats: some View {
        let list = model.chats(in: project.name)
        return VStack(spacing: 0) {
            if list.isEmpty {
                Text("No chats yet. Start one and it will show up here.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            ForEach(list) { c in
                ListButton(symbol: "bubble.left", title: c.title, subtitle: c.when) { model.openConversation(c.id) }
                    .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { model.deleteConversation(c.id) } }
                Divider().overlay(Theme.border)
            }
        }
    }

    private var files: some View {
        VStack(spacing: 0) {
            ForEach(project.files, id: \.self) { f in
                let a = Attachment(f, size: f.hasSuffix(".md") ? "Instructions" : "")
                Button { file = a } label: {
                    HStack(spacing: 12) {
                        FileIcon(kind: a.kind, size: 32)
                        Text(f).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 6).contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
                Divider().overlay(Theme.border)
            }
        }
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
            } else {
                Text(saved.replacingOccurrences(of: #"(?m)^#+ .*\n+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 13.5)).foregroundStyle(Theme.muted).lineSpacing(6)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Name, template chips and the budget the agent can use.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = "DeFi yield"
    @State private var budget: Double = 1000

    var body: some View {
        SheetScaffold(title: "New project") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                TextField(text: $name, prompt: Text("e.g. ETH staking ladder").foregroundStyle(Theme.faint)) { Text("Name") }.textFieldStyle(.plain).font(.system(size: 14))
                    .padding(12).background(Theme.bg, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
                    .onSubmit(create)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Template").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Flow(spacing: 6) {
                    ForEach(Project.templates, id: \.0) { t in
                        Button { withAnimation(.snappy) { template = t.0 } } label: { Label(t.0, systemImage: t.1) }
                            .buttonStyle(SmallChip(on: template == t.0))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Budget the agent can use").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(Money.usd(budget)).monospacedDigit().contentTransition(.numericText(value: budget))
                }
                .font(.system(size: 12.5))
                Slider(value: $budget, in: 0...20000, step: 250).tint(Theme.text)
            }
            Text("The project gets its own chats, files, instructions and spending limit.").font(.system(size: 12)).foregroundStyle(Theme.faint)
        } foot: {
            Button("Create", action: create).buttonStyle(SheetButton(primary: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        model.addProject(name: n, template: template, budget: budget)
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
            ScrollView { inner }.scrollIndicators(.automatic)
        }
    }
}
