import SwiftUI
import HermitCore

/// New chat: the crab, the greeting, wallet actions, the chat box, then today's cards.
/// A new chat inside a project shows a back link and that project's money and to-dos instead.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    @State private var appeared = SnapshotMode.active
    @State private var sheet: WalletSheet?

    var body: some View {
        Group {
            if SnapshotMode.active { content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
                ScrollView { content }.scrollIndicators(.never).scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.25)) { appeared = true } }
        .sheet(item: $sheet) { s in WalletActionSheet(kind: s) }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let p = model.project(model.chatProject) {
                Button { model.openProject(p.name) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.left").font(.system(size: 12, weight: .medium))
                        Circle().fill(p.color).frame(width: 7, height: 7)
                        Text(p.name).lineLimit(1)
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.hover, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .padding(.top, compact ? 12 : 28)
            }
            Image.hermit("hermit-hero").resizable().interpolation(.high).scaledToFit()
                .frame(height: compact ? 120 : 150).padding(.top, model.chatProject != nil ? 18 : (compact ? 28 : 64))
                .scaleEffect(appeared ? 1 : 0.94).opacity(appeared ? 1 : 0)
            Text("\(greeting), \(model.user)").font(.serif(compact ? 32 : 40)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            HStack(spacing: compact ? 28 : 22) {
                walletAction(.send, "Send", "arrow.up.right")
                walletAction(.swap, "Swap", "arrow.left.arrow.right")
                walletAction(.receive, "Receive", "arrow.down.left")
                walletAction(.buy, "Buy", "creditcard")
            }
            .padding(.top, 22)
            Composer().padding(.top, 26)
            chips.padding(.top, 14)
            cards.padding(.top, compact ? 28 : 48)
            if compact && model.chatProject == nil { projects.padding(.top, 32) }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 16 : 24)
    }

    @ViewBuilder private var chips: some View {
        let row = HStack(spacing: 8) {
            ForEach(Scenario.home) { s in
                Button(s.chip) { model.send(s.prompt) }.buttonStyle(ChipStyle())
            }
        }
        if compact {
            ScrollView(.horizontal) { row.padding(.horizontal, 16) }.scrollIndicators(.never).padding(.horizontal, -16)
        } else {
            row
        }
    }

    @ViewBuilder private var cards: some View {
        let both = model.showManaged && model.showToday
        let layout = compact || !both ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        if model.showManaged || model.showToday {
            layout {
                if model.showManaged {
                    if let p = model.project(model.chatProject) { ProjectMoneyCard(project: p) } else { ManagedCard() }
                }
                if model.showToday { TodayCard(project: model.chatProject) }
            }
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects").font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.bottom, 6)
            ForEach(model.projectList) { p in
                Button { model.openProject(p.name) } label: {
                    HStack(spacing: 12) {
                        SymbolTile(symbol: p.symbol, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(p.desc).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private func walletAction(_ kind: WalletSheet, _ title: String, _ symbol: String) -> some View {
        Button { sheet = kind } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    .frame(width: compact ? 44 : 40, height: compact ? 44 : 40).background(Theme.hover, in: Circle())
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(title)
    }
}

/// What the agent manages in total. Opens Wallets.
struct ManagedCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Managed by agent").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                hideButton { model.showManaged = false }
            }
            Button { model.open(.wallets) } label: {
                HStack(spacing: 18) {
                    Donut(parts: [(0.306, Theme.text), (0.257, Theme.accent), (0.186, Color(hex: 0x9C82D4)), (0.17, Color(hex: 0xC9BFE6)), (0.081, Color(hex: 0xE4E4E2))])
                        .frame(width: 70, height: 70)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("$48,320").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        Text("+2.6% this week").font(.system(size: 12.5)).foregroundStyle(Theme.green)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A project's own money on its new-chat screen: what the agent manages for it, expected gain and burn.
struct ProjectMoneyCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    var body: some View {
        let burn = model.burn(of: project)
        Button { model.openProject(project.name) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("Managed by agent").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Money.usd(project.money)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("\(Money.usd(project.gain, signed: true)) \(project.gainLabel.lowercased())").font(.system(size: 12.5))
                        .foregroundStyle(project.gain >= 0 ? Theme.green : Theme.red)
                }
                HStack {
                    Text("Expected per month").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(project.forecast.map { Money.usd($0.monthly, signed: true) } ?? "None").monospacedDigit()
                        .foregroundStyle((project.forecast?.monthly ?? 0) >= 0 ? Theme.green : Theme.red)
                }
                .font(.system(size: 12.5))
                if burn > 0 {
                    HStack {
                        Text("Burn rate").foregroundStyle(Theme.muted)
                        Spacer()
                        Text("−\(Money.usd(burn))/mo").monospacedDigit().foregroundStyle(Theme.red)
                    }
                    .font(.system(size: 12.5))
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }
}

/// Today's to-dos (or a project's next ones). The box completes it; the row opens where it lives.
struct TodayCard: View {
    @Environment(AppModel.self) private var model
    var project: String? = nil

    private var rows: [Todo] {
        if let project {
            return model.todos.filter { $0.project == project && $0.day >= 0 }.sorted { $0.day < $1.day }
        }
        return model.todos.filter { $0.day == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project != nil && !rows.contains { $0.day == 0 } ? "Up next" : "Today").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                hideButton { model.showToday = false }
            }
            ForEach(rows.prefix(5)) { t in
                HStack(spacing: 9) {
                    if t.event {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.hover).frame(width: 13, height: 13)
                    } else {
                        Button { model.toggleTodo(t.id) } label: {
                            Image(systemName: t.done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(t.done ? Theme.accent : Theme.faint).font(.system(size: 13))
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { model.openTodo(t) } label: {
                        HStack(spacing: 8) {
                            Text(t.title).font(.system(size: 13)).strikethrough(t.done, color: Theme.faint)
                                .foregroundStyle(t.done ? Theme.faint : Theme.text).lineLimit(1)
                            Spacer()
                            if let time = t.time { Text(time).font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit() }
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if rows.isEmpty { Text("Nothing scheduled for this project.").font(.system(size: 13)).foregroundStyle(Theme.muted) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private func hideButton(_ action: @escaping () -> Void) -> some View {
    Button { withAnimation(.snappy) { action() } } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
            .frame(width: 20, height: 20).contentShape(Rectangle())
    }
    .buttonStyle(ToolStyle()).help("Hide")
}

struct Donut: View {
    let parts: [(Double, Color)]
    var body: some View {
        ZStack {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                let start = parts.prefix(i).reduce(0) { $0 + $1.0 }
                Circle().trim(from: start + 0.006, to: start + part.0 - 0.006)
                    .stroke(part.1, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

extension View {
    func card() -> some View {
        background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.hover : Theme.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
