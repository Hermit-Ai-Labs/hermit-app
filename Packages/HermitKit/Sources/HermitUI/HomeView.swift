import SwiftUI
import HermitCore

/// New chat: the crab, the greeting, wallet actions, the chat box, then the balance and today's to-dos.
/// A new chat inside a project shows a back link and that project's money and to-dos instead.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    @State private var appeared = SnapshotMode.active
    // Off by default: the balance stays private unless you turn it on in Settings. Markets takes its place.
    @AppStorage("home.balanceOn") private var showBalance = false
    @AppStorage("home.showMarkets") private var showMarkets = true
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
                ScrollViewReader { proxy in
                    ScrollView { content }.scrollIndicators(.never).scrollDismissesKeyboard(.interactively)
                        #if DEBUG
                        .task {
                            // Screenshots of the cards under the composer.
                            guard UserDefaults.standard.bool(forKey: "hermitScrollEnd") else { return }
                            try? await Task.sleep(for: .seconds(1)); withAnimation { proxy.scrollTo("home-end", anchor: .bottom) }
                        }
                        #endif
                }
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
                HoloPromptCard(image: "crab-faceid", title: "Create your wallet", subtitle: "Keys made on \(Device.here)",
                               symbol: "plus") { model.open(.wallets, tab: "create") }
                    .frame(maxWidth: 460)
                    .padding(.top, 22)
            } else {
                HStack(spacing: compact ? 28 : 22) {
                    walletAction("Send", "arrow.up.right") { model.open(.wallets, tab: "send") }
                    if wallets.hasFunds { walletAction("Swap", "arrow.triangle.2.circlepath") { model.open(.wallets, tab: "swap") } }
                    else { walletAction("Quote", "sparkle.magnifyingglass") { model.open(.wallets, tab: "quote") } }
                    walletAction("Receive", "arrow.down.left") { model.open(.wallets, tab: "receive") }
                }
                .padding(.top, 22)
            }
            Composer().padding(.top, 26)
            chips.padding(.top, 14)
            cards.padding(.top, compact ? 28 : 48)
            if compact && model.chatProject == nil && !model.projectList.isEmpty { projects.padding(.top, 32) }
            // Room for the floating tab bar, so the last card can scroll fully into view.
            Color.clear.frame(height: compact ? 110 : 40).id("home-end")
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
        // With no wallet yet, the Create your wallet card above already says it: no second prompt here.
        let balance = showBalance && (model.chatProject != nil || !(wallets.loaded && wallets.wallets.isEmpty))
        let markets = showMarkets && !balance && model.chatProject == nil
        let both = (balance || markets) && today
        let layout = compact || !both ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        if balance || markets || today {
            layout {
                if balance {
                    if let p = model.project(model.chatProject) { ProjectMoneyCard(project: p) } else { HomeBalanceCard { showBalance = false } }
                } else if markets {
                    HomeMarketsCard { showMarkets = false }
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
                        // Only a known total: a price that didn't load never shows as $0.
                        Group {
                            if let t = wallets.totalUSD { Text(MoneyFmt.usdSmart(t)) }
                            else if wallets.loaded { Text("Unavailable").foregroundStyle(Theme.muted) }
                            else { Text(MoneyFmt.usdSmart(0)).redacted(reason: .placeholder) }
                        }
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                        Text(wallets.wallets.count == 1 ? "1 wallet" : "\(wallets.wallets.count) wallets").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
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

/// Half dial with ticks, Fear on the left and Greed on the right. ±6% average move swings the needle to the ends.
struct MoodDial: View, Animatable {
    var value: Double
    var animatableData: Double { get { value } set { value = newValue } }

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height - 2)
            let r = min(size.width / 2 - 34, size.height - 6)
            for i in 0...40 {
                let a = Double.pi + Double(i) / 40 * .pi
                let long = i % 5 == 0
                let inner = r - (long ? 11 : 6)
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                ctx.stroke(p, with: .color(long ? Theme.text : Theme.text.opacity(0.22)), lineWidth: long ? 1.3 : 1)
            }
            let t = max(-1, min(1, value / 6))
            let a = -Double.pi / 2 + t * (80 * .pi / 180)
            var n = Path()
            n.move(to: c)
            n.addLine(to: CGPoint(x: c.x + cos(a) * (r - 16), y: c.y + sin(a) * (r - 16)))
            ctx.stroke(n, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(Theme.accent))
            let label = { (s: String) in Text(s).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Theme.hint) }
            ctx.draw(label("FEAR"), at: CGPoint(x: c.x - r - 4, y: c.y - 4), anchor: .trailing)
            ctx.draw(label("GREED"), at: CGPoint(x: c.x + r + 4, y: c.y - 4), anchor: .leading)
        }
        .accessibilityHidden(true)
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

    /// Tasks from the Calendar page: today's, or for a project everything from today on.
    static func rows(_ model: AppModel, project: String?) -> [CalItem] {
        let tasks = CalendarStore.shared.items.filter { !$0.event && (project == nil || $0.project == project) }
        if project != nil {
            let today = CalendarData.cal.startOfDay(for: Date())
            return tasks.filter { $0.date >= today }.sorted { ($0.date, $0.time ?? -1) < ($1.date, $1.time ?? -1) }
        }
        return tasks.filter { CalendarData.same($0.date, Date()) }.sorted { ($0.time ?? -1) < ($1.time ?? -1) }
    }
    private var rows: [CalItem] { Self.rows(model, project: project) }

    private func open(_ t: CalItem) {
        if let q = t.ask { model.newChat(project: t.project); model.send(q) }
        else if let to = t.to, let r = Route(rawValue: to) { model.open(r) }
        else if let p = t.project { model.openProject(p) }
        else { model.open(.calendar) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project != nil && !rows.contains { CalendarData.same($0.date, Date()) } ? "Up next" : "Today").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Spacer()
                hideButton(hide)
            }
            ForEach(rows.prefix(5)) { t in
                let done = t.status == .done
                HStack(spacing: 9) {
                    Button { CalendarStore.shared.setStatus(t.id, done ? .todo : .done) } label: {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done ? Theme.accent : Theme.faint).font(.system(size: 13))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(done ? "Mark not done" : "Mark done")
                    Button { open(t) } label: {
                        HStack(spacing: 8) {
                            Text(t.t).font(.system(size: 13)).strikethrough(done, color: Theme.faint)
                                .foregroundStyle(done ? Theme.hint : Theme.text).lineLimit(1)
                            Spacer()
                            if let time = t.timeText { Text(time).font(.system(size: 12)).foregroundStyle(Theme.hint).monospacedDigit() }
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

func hideButton(_ action: @escaping () -> Void) -> some View {
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
