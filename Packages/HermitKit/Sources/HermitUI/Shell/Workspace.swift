import SwiftUI
import HermitCore

/// A project: its own chats, files, instructions (project.md), money and costs. Claude-style.
public struct Project: Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var symbol: String
    public var desc: String
    public var status: String
    public var pnl: String
    public var money: Double
    public var cost: Double
    public var gain: Double
    public var gainLabel: String
    public var gainNote: String
    public var files: [String]
    public var hex: UInt32
    /// Monthly auto-payments (APIs, hosting, gas refills).
    public var burn: [Cost]
    public var forecast: Forecast?
    /// Where the gain came from (30 days).
    public var gains: [Cost]
    public var color: Color { Color(hex: hex) }

    public struct Cost: Equatable, Identifiable {
        public var id: String { what }
        public let what: String
        public let amount: Double
        public init(_ what: String, _ amount: Double) { self.what = what; self.amount = amount }
    }
    public struct Forecast: Equatable {
        public let monthly: Double
        public let basis: String
        public let updatedHoursAgo: Int
    }

    public init(name: String, symbol: String, desc: String, status: String, pnl: String, money: Double, cost: Double, gain: Double,
                gainLabel: String, gainNote: String, files: [String] = ["strategy.ts", "backtest.csv", "notes.md"], hex: UInt32,
                burn: [Cost] = [], forecast: Forecast? = nil, gains: [Cost] = []) {
        self.name = name; self.symbol = symbol; self.desc = desc; self.status = status; self.pnl = pnl; self.money = money
        self.cost = cost; self.gain = gain; self.gainLabel = gainLabel; self.gainNote = gainNote; self.files = files; self.hex = hex
        self.burn = burn; self.forecast = forecast; self.gains = gains
    }

    /// project.md before the user edits it.
    var defaultInstructions: String {
        "# \(name)\n\n## Goal\n\(desc)\n\n## Rules\n- Budget: \(Money.usd(money))\n- Ask me before any single move over $500\n- Report \(gainLabel.lowercased()) every Monday"
    }

    static let templates: [(String, String)] = [("DeFi yield", "leaf"), ("Trading bot", "chart.line.uptrend.xyaxis"), ("Airdrop farming", "gift"),
                                                ("Research", "book"), ("Dev tool", "chevron.left.forwardslash.chevron.right"), ("Blank", "folder")]

    static let seed: [Project] = [
        Project(name: "Dev: HYPE news bot", symbol: "chevron.left.forwardslash.chevron.right", desc: "Bot that pays for its own APIs", status: "Running", pnl: "+$120",
                money: 20, cost: 13, gain: 120, gainLabel: "Sales", gainNote: "12 friends pay $10 a month", files: ["bot.ts", "digest.prompt", "deploy.json"], hex: 0x2563EB,
                burn: [Cost("Perplexity Sonar", 20), Cost("OpenAI API", 38), Cost("Vercel hosting", 20)],
                forecast: Forecast(monthly: 120, basis: "12 subscribers at $10", updatedHoursAgo: 3), gains: [Cost("Subscriptions, 12 friends", 120)]),
        Project(name: "Stablecoin yield ladder", symbol: "leaf", desc: "Best safe yield on stables", status: "Running", pnl: "+$642",
                money: 16300, cost: 9, gain: 642, gainLabel: "Yield", gainNote: "10.6% APY blended", hex: 0x15803D,
                forecast: Forecast(monthly: 104, basis: "7.7% blended APY on $16,300", updatedHoursAgo: 5),
                gains: [Cost("Morpho USDC vault", 384), Cost("Aave USDC", 196), Cost("Pendle PT-USDe", 62)]),
        Project(name: "HYPE perp scripts", symbol: "chart.line.uptrend.xyaxis", desc: "Funding arb on Hyperliquid", status: "Running", pnl: "+$1,490",
                money: 10200, cost: 46, gain: 1490, gainLabel: "PnL", gainNote: "Arb +$1,204, breakout +$286", hex: 0x4E1F96,
                burn: [Cost("Hyperliquid data feed", 25), Cost("VPS for bots", 12)],
                forecast: Forecast(monthly: 640, basis: "30-day PnL, 78% win rate", updatedHoursAgo: 2), gains: [Cost("Funding arb", 1204), Cost("Breakout trades", 286)]),
        Project(name: "Airdrop farming S3", symbol: "gift", desc: "Monad, Berachain, MegaETH", status: "Running", pnl: "14,200 pts",
                money: 2950, cost: 18, gain: 0, gainLabel: "Claimed", gainNote: "14,200 points, est. $1.1k–3.3k", hex: 0xC2410C,
                burn: [Cost("Gas refills, 3 wallets", 45), Cost("Galxe Plus", 9)],
                forecast: Forecast(monthly: 210, basis: "Est. airdrop value over 6 months", updatedHoursAgo: 9), gains: [Cost("Claimed so far", 0), Cost("Points, est. value", 210)]),
        Project(name: "Meme auto-trader", symbol: "flame", desc: "Safe Solana meme buys", status: "Paused", pnl: "−$118",
                money: 300, cost: 6, gain: -118, gainLabel: "PnL", gainNote: "13 trades, 41 risky tokens skipped", hex: 0xA16207,
                burn: [Cost("Bubblemaps API", 15)],
                forecast: Forecast(monthly: -40, basis: "Last 30 days of trades", updatedHoursAgo: 7), gains: [Cost("Winning trades", 212), Cost("Losing trades", -330)]),
        Project(name: "Research: AI agent tokens", symbol: "book", desc: "Agent token watchlist", status: "Draft", pnl: "—",
                money: 0, cost: 12, gain: 0, gainLabel: "Gain", gainNote: "Research only, no positions", hex: 0x0E7490,
                burn: [Cost("Kaito Pro", 33)]),
        Project(name: "Presale tracker", symbol: "paperplane", desc: "Allocations and unlocks", status: "Running", pnl: "+$640",
                money: 1250, cost: 0, gain: 640, gainLabel: "Unlocked", gainNote: "2 allocations, $640 unlocked", hex: 0xBE185D,
                forecast: Forecast(monthly: 180, basis: "Vesting unlocks this month", updatedHoursAgo: 11), gains: [Cost("Kaito unlock", 640)]),
    ]
}

/// A rule that runs on its own: when, what, how much it may spend, and its run history.
public struct Automation: Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var trigger: String
    public var action: String
    public var limit: String
    public var on: Bool
    public var last: String
    public var prompt: String?
    public var asks: Bool
    /// The thread: the request, the confirmation, then every run as a reply.
    public var thread: [Message]

    public var isSchedule: Bool { trigger.range(of: "Every|Daily|day", options: .regularExpression) != nil }

    init(name: String, trigger: String, action: String, limit: String, on: Bool, last: String, prompt: String? = nil, asks: Bool = false, runs: [(String, String)]? = nil) {
        self.name = name; self.trigger = trigger; self.action = action; self.limit = limit; self.on = on; self.last = last
        self.prompt = prompt; self.asks = asks
        let history = (runs ?? Automation.runs[name] ?? [(last, "Ran as planned.")]).reversed()
        thread = [Message(role: .user, text: prompt ?? "\(trigger): \(action.prefix(1).lowercased() + action.dropFirst())"),
                  Message(role: .assistant, text: "Automation on. \(trigger), I will \(action.prefix(1).lowercased() + action.dropFirst()). Limit: \(limit).", note: true)]
            + history.map { Message(role: .assistant, text: $0.1, run: $0.0) }
    }

    static let runs: [String: [(String, String)]] = [
        "Weekly ETH DCA": [("Oct 20, 09:00", "Swapped 500 USDC for 0.143 ETH at $3,496 on Uniswap. Fee $0.41."), ("Oct 13, 09:00", "Swapped 500 USDC for 0.151 ETH at $3,311."), ("Oct 6, 09:00", "Swapped 500 USDC for 0.149 ETH at $3,355.")],
        "Best stable yield": [("Oct 22, 14:10", "Aave fell to 5.1% while Morpho paid 7.9%. Moved $4,200 to Morpho. +$118 a year."), ("Oct 9, 03:40", "Checked 14 pools. Gap under 1.5%, nothing moved.")],
        "HYPE funding arb": [("2h ago", "Funding hit 0.034%/h. Opened a $2,600 hedge: spot long, perp short. +$12.60 so far."), ("Oct 24, 18:00", "Funding dropped below 0.01%. Closed the hedge for +$41.20.")],
        "Daily quest runner": [("Today, 08:00", "Finished 6 tasks on Galxe and Layer3 across 3 wallets. Gas $0.38."), ("Yesterday, 08:00", "Finished 4 tasks. Skipped one that asked for a token approval.")],
        "Meme sniper": [("Oct 18, 22:14", "Bought $100 of GIGA after the hazard scan passed. Sold at 1.6x for +$58."), ("Oct 17, 11:02", "Skipped HERM: 61% of supply in dev-linked wallets.")],
        "Invoice payer": [("Oct 21, 10:30", "Notion invoice $10 arrived. You approved it, paid in USDC.")],
    ]

    static let seed: [Automation] = [
        Automation(name: "Weekly ETH DCA", trigger: "Every Monday 09:00", action: "Swap 500 USDC → ETH on Uniswap", limit: "$500 / week", on: true, last: "Ran Oct 20"),
        Automation(name: "Best stable yield", trigger: "When APY gap > 1.5%", action: "Rebalance stables between Aave, Pendle, Ethena", limit: "$15k cap", on: true, last: "Moved $4.2k on Oct 22"),
        Automation(name: "HYPE funding arb", trigger: "Funding > 0.03% / hr", action: "Short perp + hold spot on Hyperliquid", limit: "3x max leverage", on: true, last: "+$12.60 two hours ago"),
        Automation(name: "Daily quest runner", trigger: "Daily 08:00", action: "Complete Galxe / Layer3 tasks with X + wallet", limit: "Gas ≤ $2 / day", on: true, last: "6 tasks done today"),
        Automation(name: "Meme sniper", trigger: "New pair, liquidity > $200k", action: "Buy $100 if hazard scan passes, sell at 2x", limit: "$300 / day", on: false, last: "Paused by you"),
        Automation(name: "Invoice payer", trigger: "Invoice email received", action: "Draft USDC payment, ask me to approve", limit: "Always ask", on: true, last: "Paid Notion $10"),
    ]
}

/// A to-do or event. Home's Today card and project home cards read these.
public struct Todo: Identifiable, Equatable {
    public let id: Int
    public var title: String
    /// Days from today (0 = today, negative = past).
    public var day: Int
    public var time: String?
    public var project: String?
    /// Where the row opens.
    public var route: Route?
    /// Or a prompt it sends.
    public var ask: String?
    public var event: Bool
    public var done: Bool

    static let seed: [Todo] = [
        Todo(id: 1, title: "Approve ETH DCA", day: 0, time: "09:00", route: .automations, event: false, done: false),
        Todo(id: 2, title: "Claim HYPE rewards", day: 0, route: .earn, event: false, done: false),
        Todo(id: 13, title: "Review arb bot PnL", day: 0, time: "11:00", project: "HYPE perp scripts", event: false, done: false),
        Todo(id: 3, title: "Standup with dev team", day: 0, time: "14:30", project: "Dev: HYPE news bot", event: true, done: false),
        Todo(id: 4, title: "Pay Figma $45", day: 1, time: "10:00", route: .payments, event: false, done: false),
        Todo(id: 14, title: "MegaETH testnet tasks", day: 1, time: "16:00", project: "Airdrop farming S3", event: false, done: false),
        Todo(id: 15, title: "Backtest SOL funding arb", day: 2, time: "10:00", project: "HYPE perp scripts", event: false, done: false),
        Todo(id: 16, title: "Add SOL news to bot", day: 2, time: "15:00", project: "Dev: HYPE news bot", event: false, done: false),
        Todo(id: 5, title: "Finish Monad quests", day: 3, time: "13:00", project: "Airdrop farming S3", ask: "Farm the Monad airdrop for me", event: false, done: false),
        Todo(id: 17, title: "Legion KYC for Hermes sale", day: 3, time: "11:00", project: "Presale tracker", event: false, done: false),
        Todo(id: 18, title: "Write agent-token thesis", day: 4, time: "09:30", project: "Research: AI agent tokens", event: false, done: false),
        Todo(id: 19, title: "Restart meme sniper?", day: 10, time: "10:00", project: "Meme auto-trader", event: false, done: false),
        Todo(id: 20, title: "Pendle rollover plan", day: 25, project: "Stablecoin yield ladder", event: false, done: false),
        Todo(id: 11, title: "Presale unlock $640", day: 15, project: "Presale tracker", event: true, done: false),
    ]
}

enum Money {
    static func usd(_ v: Double, signed: Bool = false) -> String {
        let s = "$" + abs(v).formatted(.number.precision(.fractionLength(0)))
        if v < 0 { return "−" + s }
        return signed && v > 0 ? "+" + s : s
    }
}
