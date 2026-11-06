import SwiftUI
import HermitCore

/// New chat: the crab, the greeting, wallet actions, the chat box, then the balance and today's to-dos.
/// A new chat inside a project shows a back link and that project's money and to-dos instead.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    @State private var appeared = SnapshotMode.active
    @AppStorage("home.showBalance") private var showBalance = true
    @AppStorage("home.showToday") private var showToday = true

    /// Things the on-device model answers well on its own.
    static let suggestions: [(String, String)] = [
        ("What's a seed phrase?", "What is a seed phrase, and how should I keep mine safe?"),
        ("Stablecoins, simply", "Explain how stablecoins keep their price, in a few sentences."),
        ("Plan my week", "Help me plan my week. Ask me what I have on first."),
        ("Write a message", "Help me write a short, friendly message to a friend I haven't talked to in a while."),
    ]

    private var wallets: WalletsViewModel { .shared }

    var body: some View {
        Group {
            if SnapshotMode.active { content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
                ScrollView { content }.scrollIndicators(.never).scrollDismissesKeyboard(.interactively)
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.25)) { appeared = true } }
        .task { if !wallets.loaded { await wallets.refresh() } }
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
            Text(model.user.isEmpty ? greeting : "\(greeting), \(model.user)").font(.serif(compact ? 32 : 40)).foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            if wallets.loaded && wallets.wallets.isEmpty {
                GradientCTA(symbol: "wallet.bifold", title: "Create your wallet",
                            subtitle: "Made on this phone, locked by Face ID") { model.open(.wallets, tab: "create") }
                    .frame(maxWidth: 460)
                    .padding(.top, 22)
            } else {
                HStack(spacing: compact ? 28 : 22) {
                    walletAction("Send", "arrow.up.right") { model.open(.wallets, tab: "send") }
                    walletAction("Swap", "arrow.left.arrow.right", soon: true) {}
                    walletAction("Receive", "arrow.down.left") { model.open(.wallets, tab: "receive") }
                    walletAction("Buy", "creditcard", soon: true) {}
                }
                .padding(.top, 22)
            }
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
            ForEach(Self.suggestions, id: \.0) { s in
                Button(s.0) { model.send(s.1) }.buttonStyle(ChipStyle())
            }
        }
        if compact {
            ScrollView(.horizontal) { row.padding(.horizontal, 16) }.scrollIndicators(.never).padding(.horizontal, -16)
        } else {
            row
        }
    }

    @ViewBuilder private var cards: some View {
        // Today only shows when there is something on it; a project's card always shows (it says when it's empty).
        let today = showToday && (model.chatProject != nil || !TodayCard.rows(model, project: nil).isEmpty)
        let both = showBalance && today
        let layout = compact || !both ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        if showBalance || today {
            layout {
                if showBalance {
                    if let p = model.project(model.chatProject) { ProjectMoneyCard(project: p) } else { HomeBalanceCard { showBalance = false } }
                }
                if today { TodayCard(project: model.chatProject) { showToday = false } }
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

    /// A round wallet shortcut. `soon` greys it out until the feature exists.
    private func walletAction(_ title: String, _ symbol: String, soon: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(soon ? Theme.faint : Theme.text)
                    .frame(width: compact ? 44 : 40, height: compact ? 44 : 40).background(Theme.hover.opacity(soon ? 0.6 : 1), in: Circle())
                Text(soon ? "\(title), soon" : title).font(.system(size: 12)).foregroundStyle(soon ? Theme.faint : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(soon)
        .help(soon ? "\(title) is coming soon" : title)
    }
}

/// The wallets' total from the wallet engine, or a way to create the first wallet. Opens Wallets.
struct HomeBalanceCard: View {
    @Environment(AppModel.self) private var model
    let hide: () -> Void
    private var wallets: WalletsViewModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Balance").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                hideButton(hide)
            }
            if wallets.loaded && wallets.wallets.isEmpty {
                Text("No wallet yet. Create one and its keys stay on this device.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.open(.wallets, tab: "create") } label: { Label("Create a wallet", systemImage: "plus") }
                    .buttonStyle(GradientPill())
            } else {
                Button { model.open(.wallets) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MoneyFmt.usdSmart(wallets.total())).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text(wallets.wallets.count == 1 ? "1 wallet" : "\(wallets.wallets.count) wallets").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                    .redacted(reason: wallets.loaded ? [] : .placeholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
    var hide: () -> Void = {}

    static func rows(_ model: AppModel, project: String?) -> [Todo] {
        if let project {
            return model.todos.filter { $0.project == project && $0.day >= 0 }.sorted { $0.day < $1.day }
        }
        return model.todos.filter { $0.day == 0 }
    }
    private var rows: [Todo] { Self.rows(model, project: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project != nil && !rows.contains { $0.day == 0 } ? "Up next" : "Today").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                hideButton(hide)
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
