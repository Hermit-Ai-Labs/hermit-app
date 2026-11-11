import SwiftUI
import HermitCore

/// Cards the agent posts under its answers. Numbers always come with a chart.
/// Cards that only the scripted demo produces (sample prices, approvals with nothing behind them, and the live trade
/// card, since no order is placed yet) are wrapped in DemoOnly so a release build never shows them as real.
struct CardView: View {
    let card: Card
    var body: some View {
        switch card {
        case .bars(let title, let rows): BarsCard(title: title, rows: rows)
        case .receipt(let title, let rows): ReceiptCard(title: title, rows: rows)
        case .result(let r): ResultCard(receipt: r)
        case .token(let t): DemoOnly { TokenCard(spec: t) }
        case .price(let title, let total, let days, let seed): DemoOnly { PriceCard(title: title, total: total, days: days, seed: seed) }
        case .pnl(let title, let total, let days, let seed): DemoOnly { PnlCard(title: title, total: total, days: days, seed: seed) }
        case .holders(let verdict, let clusters, let legend): DemoOnly { HoldersCard(verdict: verdict, clusters: clusters, legend: legend) }
        case .kols(let n, let rows): DemoOnly { KolCard(onboarded: n, rows: rows) }
        case .perpTicket(let a): DemoOnly { PerpTicket(base: a) }
        case .flow(let title, let steps): FlowCard(title: title, steps: steps)
        case .news(let items): DemoOnly { NewsCard(items: items) }
        case .opportunities(let title, let items): DemoOnly { OpportunitiesCard(title: title, items: items) }
        case .catalog(let group): DemoOnly { CatalogCard(group: group) }
        case .agentPaid(let to, let amount, let what, let budget): DemoOnly { AgentPaidCard(to: to, amount: amount, what: what, budget: budget) }
        case .code(let code): CodeCard(code: code)
        case .quests(let q): DemoOnly { QuestCard(quests: q) }
        case .inbox(let items, let approval): DemoOnly { InboxCard(items: items, approval: approval) }
        case .injection(let source, let quote): DemoOnly { InjectionCard(source: source, quote: quote) }
        case .apiBuy(let a): DemoOnly { ApiBuyCard(approval: a) }
        case .buildProgress: DemoOnly { BuildProgressCard() }
        case .apiCheckout: DemoOnly { ApiCheckoutCard() }
        case .batchSend(let id): BatchSendCard(id: id)
        case .flapLaunch: DemoOnly { FlapLaunchCard() }
        case .memory(let item): MemoryCard(item: item)
        case .liveTrade(let t): DemoOnly { LiveTradeCard(trade: t) }
        case .suggestions(let prompts): SuggestionsCard(prompts: prompts)
        case .confirm(let c): ToolConfirmCard(card: c)
        }
    }
}

struct BarsCard: View {
    let title: String
    let rows: [BarRow]
    @State private var grown = SnapshotMode.active

    var body: some View {
        let top = max(rows.map(\.value).max() ?? 1, 0.0001)
        ChatCard {
            CardTitle(title)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(r.label).foregroundStyle(Theme.text).lineLimit(1)
                            if let sub = r.sub { Text(sub).foregroundStyle(Theme.hint).lineLimit(1) }
                            Spacer(minLength: 8)
                            Text(r.display).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                        }
                        .font(.system(size: 12.5))
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hover)
                                Capsule().fill(r.tone.color)
                                    .frame(width: grown ? max(4, g.size.width * r.value / top) : 0)
                                    .animation(.smooth(duration: 0.7).delay(Double(i) * 0.08), value: grown)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
        .onAppear { grown = true }
    }
}

struct ReceiptCard: View {
    let title: String
    let rows: [[String]]
    var body: some View {
        ResultCard(receipt: Receipt(title: title, rows: rows))
    }
}

/// Posted after an approval: what happened, the numbers, and where to track it.
struct ResultCard: View {
    let receipt: Receipt
    var body: some View {
        ChatCard {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).font(.system(size: 15))
            CardTitle(receipt.title)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if !receipt.alloc.isEmpty {
                    HStack(spacing: 18) {
                        let total = receipt.alloc.reduce(0) { $0 + $1.value }
                        Donut(parts: receipt.alloc.map { ($0.value / total, Color(hex: $0.hex)) }).frame(width: 76, height: 76)
                        VStack(spacing: 6) {
                            ForEach(receipt.alloc) { s in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: s.hex)).frame(width: 8, height: 8)
                                    Text(s.label)
                                    Spacer()
                                    Text(Money.usd(s.value)).foregroundStyle(Theme.muted).monospacedDigit()
                                }
                                .font(.system(size: 13))
                            }
                        }
                    }
                    .padding(.bottom, 8)
                } else {
                    ForEach(receipt.rows, id: \.self) { r in TxLine(r.first ?? "", r.last ?? "") }
                }
                if !receipt.stats.isEmpty {
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 10)
                    KVGrid(pairs: receipt.stats)
                }
                if let note = receipt.note {
                    Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.muted).padding(.top, 10)
                }
            }
        }
    }
}

/// A minimal timeline: a dot per step, a shield for the safety check. Across on wide screens, down on phones.
struct FlowCard: View {
    let title: String
    let steps: [FlowStep]
    var body: some View {
        ChatCard {
            CardTitle(title)
        } content: {
            ViewThatFits(in: .horizontal) {
                across
                down
            }
        }
    }

    private func dot(_ s: FlowStep) -> some View {
        ZStack {
            if s.isGuard {
                Circle().fill(Theme.accent).frame(width: 20, height: 20)
                Image(systemName: "checkmark.shield.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            } else {
                Circle().fill(Theme.bg).frame(width: 12, height: 12)
                Circle().strokeBorder(Theme.text, lineWidth: 2).frame(width: 12, height: 12)
            }
        }
        .frame(width: 20, height: 20)
    }

    private var across: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        dot(s)
                        if i < steps.count - 1 { Rectangle().fill(Theme.border).frame(height: 1.5) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(s.isGuard ? Theme.accent : Theme.text)
                        Text(s.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                    .fixedSize()
                    .padding(.trailing, 10)
                }
                .frame(minWidth: 96, alignment: .leading)
            }
        }
    }

    private var down: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        dot(s)
                        if i < steps.count - 1 { Rectangle().fill(Theme.border).frame(width: 1.5).frame(minHeight: 18) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.system(size: 13, weight: .medium)).foregroundStyle(s.isGuard ? Theme.accent : Theme.text)
                        Text(s.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 12)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct CodeCard: View {
    let code: String
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 12, design: .monospaced)).lineSpacing(5).foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(.leading, 16).padding(.trailing, 44).padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtle)
            Button {
                Clipboard.copy(code); model.toast("Copied")
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28).background(Theme.bg.opacity(0.9), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(PressStyle()).padding(6)
            .help("Copy")
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

/// When the agent paid for something itself, inside a budget the user set.
struct AgentPaidCard: View {
    let to, amount, what, budget: String
    var body: some View {
        ChatCard {
            LogoMark(to, size: 22)
            CardTitle("Paid \(to) \(amount)")
            Spacer()
            StatusTag(text: "Auto-approved")
        } content: {
            VStack(spacing: 0) {
                TxLine("For", what)
                TxLine("Paid with", "USDC via x402")
                TxLine("Dev budget left", budget)
                TxLine("API key", "Saved to local vault")
            }
        }
    }
}

struct QuestCard: View {
    let quests: [Quest]
    @Environment(AppModel.self) private var model
    var body: some View {
        ChatCard {
            CardTitle("Monad quests")
            Spacer()
            Text("600 of 2,400 pts").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hover)
                        Capsule().fill(Theme.text).frame(width: g.size.width * 0.25)
                    }
                }
                .frame(height: 6).padding(.bottom, 8)
                ForEach(Array(quests.enumerated()), id: \.offset) { i, q in
                    HStack(spacing: 12) {
                        Image(systemName: q.done ? "checkmark.circle" : "circle")
                            .font(.system(size: 15)).foregroundStyle(q.done ? Theme.green : Theme.faint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.title).font(.system(size: 13.5)).foregroundStyle(q.done ? Theme.muted : Theme.text).lineLimit(1)
                            if let d = q.detail { Text(d).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                        }
                        Spacer()
                        Text(q.points).font(.system(size: 12)).foregroundStyle(Theme.hint).monospacedDigit()
                    }
                    .padding(.vertical, 9)
                    if i < quests.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        } foot: {
            Button("Review post") {
                model.react("Review post", "Draft for X: \"Testing @monad_xyz with Hermit. 3 wallets, 12 quests, $0.40 in gas. Who else is farming?\" Say \"post it\" and I will publish it.")
            }
            .buttonStyle(PlainCardButton())
            Button {
                // Saved paused: it only runs on its schedule once the user switches it on.
                model.addAutomation(Automation(name: "Monad quests", trigger: "Every day 08:00", action: "Finish open Monad quests", limit: "$1 gas / day",
                                               on: false, last: "Not run yet"))
                model.react("Save to Automations", "Saved to Automations, paused. Switch it on there to run it every day at 08:00.")
            } label: {
                Label("Save to Automations", systemImage: "plus")
            }
            .buttonStyle(BlackButton())
        }
    }
}

struct InboxCard: View {
    let items: [InboxItem]
    let approval: Approval
    @Environment(AppModel.self) private var model
    var body: some View {
        ChatCard {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(spacing: 12) {
                        if let logo = item.logo { LogoMark(logo, size: 32) } else { SymbolTile(symbol: item.calendar ? "calendar" : "envelope") }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.from).font(.system(size: 13.5, weight: .medium))
                            Text(item.subject).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        if let pay = item.pay {
                            let paid = model.approvedIDs.contains(approval.title)
                            Button(paid ? "Paid" : "Pay $\(pay)") { model.approval = approval }
                                .buttonStyle(BlackButton()).disabled(paid)
                        } else if let w = item.when {
                            Text(w).font(.system(size: 12)).foregroundStyle(Theme.hint)
                        }
                    }
                    .padding(.vertical, 9)
                    if i < items.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
    }
}

struct InjectionCard: View {
    let source: String
    let quote: String
    var body: some View {
        ChatCard {
            Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.red)
            Text("Prompt injection blocked").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.red)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(source).font(Theme.mono).foregroundStyle(Theme.muted)
                Text(quote).font(Theme.mono).foregroundStyle(Theme.red).lineSpacing(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 10))
                Text("Funds untouched. Destination 0x9f…41c is a known drainer.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Saved to long-term memory (hermit.md).
struct MemoryCard: View {
    let item: String
    @Environment(AppModel.self) private var model
    var body: some View {
        ChatCard {
            Image(systemName: "book.closed").foregroundStyle(Theme.accent).font(.system(size: 13))
            Text("hermit.md").font(.system(size: 13.5, weight: .medium))
            Spacer()
            Button("View memory") { model.open(.settings, tab: "memory") }.buttonStyle(PlainCardButton())
        } content: {
            (Text("+ ").foregroundStyle(Theme.green) + Text(item))
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }
}

/// Opportunities with a ready action each: deposit (approval) or a follow-up question.
struct OpportunitiesCard: View {
    let title: String
    let items: [Opportunity]
    @Environment(AppModel.self) private var model
    var body: some View {
        ChatCard {
            CardTitle(title)
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, o in
                    HStack(alignment: .top, spacing: 12) {
                        LogoMark(o.logo, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(o.name).font(.system(size: 13.5, weight: .medium))
                                Spacer()
                                Text(o.metric).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(o.up ? Theme.green : Theme.text)
                            }
                            Text(o.why).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            Flow(spacing: 6) {
                                ForEach(o.tags, id: \.label) { t in
                                    Button(t.label) {
                                        if let a = t.approval { model.approval = a } else if let q = t.ask { model.ask(q) }
                                    }
                                    .buttonStyle(SmallChip(on: t.approval != nil))
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 10)
                    if i < items.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
    }
}

/// Every kind of opportunity Hermit can act on, by group.
struct CatalogCard: View {
    @State var group: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ChatCard {
            CardTitle("All opportunities")
            Spacer(minLength: 8)
            Menu {
                ForEach(Catalog.groups, id: \.self) { g in Button(g) { withAnimation(.snappy) { group = g } } }
            } label: {
                HStack(spacing: 4) {
                    Text(group)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
        } content: {
            VStack(spacing: 0) {
                let rows = Catalog.items[group] ?? []
                ForEach(Array(rows.enumerated()), id: \.element.name) { i, o in
                    HStack(alignment: .top, spacing: 12) {
                        LogoMark(o.logo, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(o.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(o.ret).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            }
                            HStack {
                                Text(o.ex).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                Spacer()
                                Text(o.risk).font(.system(size: 12.5)).foregroundStyle(o.risk == "Low" ? Theme.green : o.risk == "Medium" ? Theme.amber : Theme.red)
                            }
                            HStack(spacing: 6) {
                                // Nothing runs behind Start yet, so it opens no approval: greyed out until it is built.
                                if o.start {
                                    Button("Start, coming soon") {}
                                        .buttonStyle(SmallChip()).comingSoon().opacity(0.5)
                                }
                                Button("Explain") { model.ask("How does \(o.name.lowercased()) work?") }.buttonStyle(SmallChip())
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 10)
                    if i < rows.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            .id(group)
            .transition(.opacity)
        }
    }
}

enum Catalog {
    struct Item { let name, ex, logo, ret, risk: String; let start: Bool }
    static let groups = ["Yield", "Trading", "Arbitrage", "Airdrops"]
    static let items: [String: [Item]] = [
        "Yield": [
            Item(name: "Stablecoin savings", ex: "Sky sUSDS, Spark", logo: "USDC", ret: "~3.5%", risk: "Low", start: true),
            Item(name: "Stablecoin lending", ex: "Aave, Morpho, Compound", logo: "Aave", ret: "3.5–9%", risk: "Low", start: true),
            Item(name: "Tokenized treasuries", ex: "Ondo USDY, BlackRock BUIDL", logo: "Ondo", ret: "3.5–4.7%", risk: "Low", start: true),
            Item(name: "Liquid staking", ex: "Lido, Jito", logo: "Lido", ret: "2.5–8%", risk: "Low", start: true),
            Item(name: "Synthetic dollar", ex: "Ethena sUSDe", logo: "Ethena", ret: "Varies", risk: "Medium", start: true),
            Item(name: "Restaking", ex: "EigenLayer, ether.fi", logo: "EigenLayer", ret: "2–5% + points", risk: "Medium", start: true),
            Item(name: "Fixed yield", ex: "Pendle PT", logo: "Pendle", ret: "5–20%", risk: "Medium", start: true),
            Item(name: "Perp LP vaults", ex: "Hyperliquid HLP, GMX", logo: "Hyperliquid", ret: "10–20%", risk: "Medium", start: true),
            Item(name: "Concentrated LP", ex: "Uniswap, Aerodrome, Meteora", logo: "Uniswap", ret: "5–50%", risk: "High", start: true),
            Item(name: "Options vaults", ex: "Derive", logo: "Derive", ret: "5–20%", risk: "High", start: false),
            Item(name: "Lending loops", ex: "Morpho + Pendle loops", logo: "Morpho", ret: "Up to ~25%", risk: "High", start: false),
            Item(name: "Validator nodes", ex: "ETH validators, DePIN", logo: "ETH", ret: "~3%", risk: "Medium", start: false),
        ],
        "Trading": [
            Item(name: "Perps", ex: "Hyperliquid, GMX, Jupiter", logo: "Hyperliquid", ret: "Unbounded", risk: "High", start: true),
            Item(name: "Spot DCA", ex: "Jupiter, CoW Swap", logo: "Jupiter", ret: "Market", risk: "Medium", start: true),
            Item(name: "Copy trading", ex: "Hyperliquid vaults", logo: "Hyperliquid", ret: "Varies", risk: "High", start: false),
            Item(name: "Prediction markets", ex: "Polymarket, Kalshi", logo: "Polymarket", ret: "Event odds", risk: "Medium", start: false),
            Item(name: "Rate trading", ex: "Pendle Boros", logo: "Pendle", ret: "Rate based", risk: "Medium", start: false),
            Item(name: "Meme launches", ex: "Pump.fun, LetsBonk, Zora", logo: "Pump.fun", ret: "Extreme", risk: "High", start: false),
        ],
        "Arbitrage": [
            Item(name: "Cash and carry", ex: "Long spot, short perp", logo: "HYPE", ret: "5–15%", risk: "Low", start: true),
            Item(name: "Cross-venue funding", ex: "Hyperliquid vs Binance", logo: "Hyperliquid", ret: "Small spreads", risk: "Medium", start: false),
            Item(name: "DEX price gaps", ex: "Uniswap, Aerodrome, Jupiter", logo: "Uniswap", ret: "bps per trade", risk: "Medium", start: false),
            Item(name: "Stablecoin depeg", ex: "Curve, issuer redemptions", logo: "USDC", ret: "On events", risk: "Medium", start: false),
            Item(name: "Prediction market gaps", ex: "Polymarket vs Kalshi", logo: "Polymarket", ret: "Few %", risk: "Medium", start: false),
            Item(name: "Liquidations", ex: "Aave, Morpho", logo: "Aave", ret: "5–10% bonus", risk: "Medium", start: false),
        ],
        "Airdrops": [
            Item(name: "Points programs", ex: "Symbiotic, ether.fi", logo: "Symbiotic", ret: "Unknown", risk: "Medium", start: true),
            Item(name: "Retro farming", ex: "New chains and bridges", logo: "Monad", ret: "Varies", risk: "Medium", start: true),
            Item(name: "Token sales", ex: "Legion, Echo, MetaDAO", logo: "Legion", ret: "Varies", risk: "High", start: false),
            Item(name: "Launchpad whitelists", ex: "Legion Score, Kaito", logo: "Kaito", ret: "Varies", risk: "High", start: false),
            Item(name: "Attention mining", ex: "Kaito, Galxe", logo: "Kaito", ret: "Points", risk: "Low", start: false),
            Item(name: "Bug bounties", ex: "Immunefi, Code4rena", logo: "Immunefi", ret: "Bounties", risk: "Low", start: false),
            Item(name: "AI data for points", ex: "Label data, red-team agents", logo: "Hermit", ret: "Points", risk: "Low", start: false),
        ],
    ]
}

/// Prompts to try, as chips.
struct SuggestionsCard: View {
    let prompts: [String]
    @Environment(AppModel.self) private var model
    var body: some View {
        Flow(spacing: 8) {
            ForEach(prompts, id: \.self) { p in
                Button(Scenario.all.first { $0.prompt == p }?.chip ?? p) { model.send(p) }.buttonStyle(ChipStyle())
            }
        }
    }
}

enum Clipboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}
