import Foundation

/// Past conversations behind each project and the sidebar Recents (hermit-demo/src/threads.jsx),
/// so opening one shows how it was built.
public enum Threads {
    static func u(_ text: String, _ attachment: Attachment? = nil) -> Message { Message(role: .user, text: text, attachment: attachment) }
    static func ai(_ tools: [String], _ blocks: Block...) -> Message {
        Message(role: .assistant, steps: tools.count, tools: tools, blocks: blocks)
    }
    static func reply(_ s: Scenario) -> Message { Message(role: .assistant, steps: s.tools.count, tools: s.tools, blocks: s.blocks) }
    static func done(_ title: String, _ rows: [[String]], _ stats: [[String]] = []) -> Message {
        Message(role: .assistant, blocks: [.card(.result(Receipt(title: title, rows: rows, stats: stats)))])
    }
    /// A chat that replays one of the scripted scenarios.
    static func sc(_ id: String, _ scenario: Scenario, _ when: String, _ project: String? = nil, title: String? = nil) -> Conversation {
        Conversation(id: id, title: title ?? scenario.prompt, project: project, when: when, messages: [u(scenario.prompt), reply(scenario)])
    }
    static func t(_ s: String) -> Block { .text(s) }
    static func bars(_ title: String, _ rows: [BarRow]) -> Block { .card(.bars(title: title, rows: rows)) }

    public static let all: [Conversation] = [
        // Not in a project, newest first: these are the sidebar Recents.
        sc("r-budget", .budgetAPI, "Today", title: "AI budgeting app: get API key"),
        Conversation(id: "r-multisend", title: "Send USDC to 48 wallets", when: "Today", messages: [
            u("Send USDC to every wallet in this spreadsheet", Attachment("wallets.xlsx", kind: .sheet, size: "49 rows")), reply(.multisend)]),
        sc("r-flap", .flap, "Today", title: "Launch $HERMIT on flap.sh"),
        sc("r-news", .news, "Today", title: "What news is moving markets?"),
        Conversation(id: "eth-breakout", title: "ETH breakout strategy", when: "Oct 19", messages: [
            u("Buy ETH when it breaks out of its range, with a tight stop"),
            ai(["Finding the 4H range", "Testing breakout rules"],
               t("ETH has ranged between **$3,180 and $3,520** for 3 weeks. A 4H close above the range on 1.5x volume has worked 54% of the time since 2023, and winners are 3x bigger than losers."),
               .card(.pnl(title: "Backtest, 2 years", total: "+38%", days: 60, seed: 33))),
            u("Use 3x, take profit at 6%, stop at 2%. $3,000"),
            ai(["Building strategy"], .card(.flow(title: "Rules", steps: [FlowStep("Watch 4H", "Range high $3,520"), FlowStep("Breakout", "Close above, 1.5x vol"),
                                                                         FlowStep("Long 3x", "TP +6%, SL −2%"), FlowStep("Hazard scan", "Every order", guard: true)]))),
            u("Go"),
            done("Strategy running", [["Capital", "$3,000"], ["Leverage", "3x"], ["TP / SL", "+6% / −2%"]], [["Trades", "2"], ["Profit", "+$286"], ["Win rate", "50%"], ["Open", "Long"]]),
        ]),
        sc("r-pay", .pay, "Today", title: "Pay alice.eth 200 USDC"),
        Conversation(id: "susde-loop", title: "sUSDe loop", when: "Oct 15", messages: [
            u("Can I get more than 15% on stables safely?"),
            ai(["Comparing loop strategies", "Stress-testing a depeg"],
               t("Looping sUSDe on Aave 2x earns about **16%**. It unwinds automatically if health falls below 1.3. That covers a 9% depeg before any risk of liquidation."),
               bars("APY", [BarRow("sUSDe 2x loop", 16.2, "16.2%"), BarRow("sUSDe", 11.2, "11.2%"), BarRow("Aave USDC", 5.6, "5.6%")])),
            u("Start with $4,000"),
            done("Loop opened", [["Capital", "$4,000"], ["Loops", "2x"], ["Health", "1.62"]], [["APY", "16.2%"], ["Profit", "+$162"], ["Health", "1.58"], ["Unwind at", "1.30"]]),
        ]),
        sc("r-inbox", .inbox, "Yesterday", title: "Summarize my inbox"),
        Conversation(id: "eth-dca", title: "Weekly ETH DCA", when: "Sep 30", messages: [
            u("Buy $500 of ETH every Monday and send it to my Vault"),
            ai(["Comparing routes", "Checking Vault address"],
               t("Best route is Uniswap through 1inch, about $0.40 per buy. Each purchase goes straight to your Ledger Vault, so nothing sits in a hot wallet."),
               bars("Cost per $500 buy", [BarRow("1inch", 0.4, "$0.40"), BarRow("Uniswap direct", 0.9, "$0.90"), BarRow("Exchange", 3, "$3")])),
            u("Do it"),
            done("DCA scheduled", [["Amount", "$500 a week"], ["Day", "Monday 09:00"], ["To", "Vault"]], [["Buys", "4"], ["ETH bought", "0.58"], ["Avg price", "$3,430"], ["Profit", "+$96"]]),
        ]),
        sc("r-api", .dev, "Oct 23", title: "Buy GPT API credits"),

        // Project chats.
        Conversation(id: "news-bot", title: "Build the news bot", project: "Dev: HYPE news bot", when: "Oct 24",
                     messages: [u(Scenario.build.prompt), reply(.build)]),
        Conversation(id: "news-cost", title: "What does the bot cost?", project: "Dev: HYPE news bot", when: "Oct 25", messages: [
            u("What does the news bot cost me each month?"),
            ai(["Reading x402 receipts", "Adding hosting"], t("About **$8 a month**. Perplexity bills per search, so it moves with news volume."),
               bars("Monthly cost", [BarRow("Hosting", 5, "$5"), BarRow("Perplexity", 3, "$3"), BarRow("Telegram", 0, "$0")])),
        ]),
        Conversation(id: "news-sell", title: "Sell access to friends", project: "Dev: HYPE news bot", when: "Oct 25", messages: [
            u("Can my friends pay to get the digest too?"),
            ai(["Setting up a USDC paywall", "Creating invite link"],
               t("Done. Friends pay **$10 a month in USDC** to join the channel. 12 joined so far, so the bot makes **$112 a month** after its own costs."),
               bars("This month", [BarRow("Sales", 120, "$120"), BarRow("Costs", 8, "$8", tone: .red), BarRow("Profit", 112, "$112", tone: .green)])),
        ]),
        sc("p-reverse", .reverse, "Today", "Stablecoin yield ladder", title: "Reverse engineer a 24% vault"),
        sc("p-yield", .yield, "Oct 22", "Stablecoin yield ladder", title: "Best safe yield for 10k USDC"),
        Conversation(id: "dex-spread", title: "Stablecoin DEX spread", project: "Stablecoin yield ladder", when: "Oct 8", messages: [
            u("Find risk-free spreads between stablecoins"),
            ai(["Watching 6 DEXs for 24h"],
               t("USDC, USDT and DAI drift apart by **0.15% or more about 40 times a day**. Buying and selling in one transaction locks in the gap with no price risk."),
               .card(.pnl(title: "Simulated, 30 days", total: "+$61", days: 30, seed: 44))),
            u("Run it with $1,500"),
            done("Strategy running", [["Capital", "$1,500"], ["Min spread", "0.15% after gas"]], [["Trades", "212"], ["Profit", "+$58"], ["Win rate", "91%"], ["Gas", "$9"]]),
        ]),
        sc("p-defi", .oppsDefi, "Oct 3", "Stablecoin yield ladder", title: "What DeFi ideas are new?"),
        Conversation(id: "hype-arb", title: "Build the funding arb bot", project: "HYPE perp scripts", when: "Oct 12", messages: [
            u("I want to earn from HYPE funding without taking price risk"),
            ai(["Pulling 90 days of HYPE funding", "Checking spot liquidity"],
               t("Longs have paid shorts on **84 of the last 90 days**. If you hold spot HYPE and short the same amount, price moves cancel out and you keep the funding."),
               bars("Avg funding by month", [BarRow("Aug", 0.021, "0.021%/h"), BarRow("Sep", 0.034, "0.034%/h"), BarRow("Oct", 0.029, "0.029%/h")])),
            u("Write the bot. Enter above 0.03% an hour, exit below 0.01%"),
            ai(["Writing strategy", "Adding safety checks"],
               t("Here is the logic. Every order goes through the hazard scan, and it never uses more than 1x."),
               .card(.flow(title: "Bot logic", steps: [FlowStep("Watch", "Every 60s"), FlowStep("Enter", "Funding > 0.03%/h"), FlowStep("Spot + short", "Same size"),
                                                       FlowStep("Hazard scan", "Every order", guard: true), FlowStep("Exit", "Funding < 0.01%/h")])),
               .card(.code("""
               every("60s", async () => {
                 const f = await hl.funding("HYPE")
                 if (!open && f > 0.0003) await hedge.open("HYPE", size)
                 if (open && f < 0.0001) await hedge.close("HYPE")
               })
               """))),
            u("Backtest 90 days with $5,000"),
            ai(["Replaying 90 days of fills", "Adding fees and slippage"],
               t("**+$3,480** over 90 days after fees, or about 28% a year. Worst drawdown was 1.8%, during the Sep 3 funding flip."),
               .card(.pnl(title: "Backtest, 90 days", total: "+$3,480", days: 90, seed: 21)),
               bars("Results", [BarRow("Win rate", 78, "78%"), BarRow("Trades", 46, "46"), BarRow("Max drawdown", 1.8, "1.8%")])),
            u("Deploy it with $5,200"),
            done("Strategy deployed", [["Strategy", "HYPE funding arb"], ["Capital", "$5,200"], ["Leverage", "1x max"], ["Status", "Running"]],
                 [["Since", "Oct 12"], ["Profit", "+$1,204"], ["Trades", "19"], ["Drawdown", "0.9%"]]),
        ]),
        sc("p-arbflow", .arb, "Oct 18", "HYPE perp scripts", title: "Draw how the bot works"),
        sc("p-hype", .perpHYPE, "Oct 24", "HYPE perp scripts", title: "Long HYPE 5x, stop at $22"),
        Conversation(id: "airdrops-s3", title: "Which airdrops to farm", project: "Airdrop farming S3", when: "Sep 15", messages: [
            u("Which airdrops are worth farming this season?"),
            ai(["Ranking 40 campaigns", "Estimating value per hour"], t("Three stand out on value per hour of effort."),
               bars("Est. value per hour", [BarRow("MegaETH", 85, "$85"), BarRow("Berachain", 70, "$70"), BarRow("Monad", 60, "$60")])),
            u("Farm all three across 3 wallets, gas under $2 a day"),
            done("Farming started", [["Campaigns", "MegaETH, Berachain, Monad"], ["Wallets", "3"], ["Gas cap", "$2 a day"]],
                 [["Points", "14,200"], ["Gas spent", "$18"], ["Done", "12 of 17"], ["Est. value", "$1.1k–3.3k"]]),
        ]),
        Conversation(id: "monad", title: "Farm Monad for me", project: "Airdrop farming S3", when: "Oct 21",
                     messages: [u(Scenario.airdrop.prompt), reply(.airdrop)]),
        Conversation(id: "meme-sniper", title: "Build the meme sniper", project: "Meme auto-trader", when: "Oct 5", messages: [
            u("Snipe new Solana memes, but only safe ones"),
            ai(["Scanning 30 days of launches", "Scoring holder maps"],
               t("Of 1,240 launches with over $200k liquidity, **71% failed my holder check** (deployer clusters, unlocked liquidity). The ones that passed returned 2x four times as often."),
               bars("Launches, 30 days", [BarRow("Failed holder check", 881, "881"), BarRow("Passed", 359, "359"), BarRow("Hit 2x", 74, "74")])),
            u("Buy $100 each, sell at 2x, max $300 a day"),
            ai(["Building strategy"], .card(.flow(title: "Rules", steps: [FlowStep("New pair", "Liquidity > $200k"), FlowStep("Holder check", "Bubble map"),
                                                                         FlowStep("Hazard scan", "Every order", guard: true), FlowStep("Buy $100", "Sell at 2x")]))),
            u("Pause it, memes are slow this week"),
            done("Strategy paused", [["Trades", "13"], ["Result", "−$118"], ["Skipped", "41 risky tokens"]]),
        ]),
        sc("p-pengu", .meme, "Oct 25", "Meme auto-trader", title: "Should I buy $PENGU?"),
        sc("p-vol", .oppsVol, "Oct 20", "Meme auto-trader", title: "Most volatile coins"),
        Conversation(id: "research-agents", title: "Which agent tokens have usage?", project: "Research: AI agent tokens", when: "Oct 20", messages: [
            u("Which AI agent tokens have real usage?"),
            ai(["Pulling on-chain activity", "Reading docs and X"], t("Most have little usage. These three have paying users."),
               .card(.opportunities(title: "Watchlist", items: [
                   Opportunity(logo: "Virtuals", name: "Virtuals", metric: "$4.1M", why: "Agent fees, 30 days", up: false, tags: [Tag("Deep dive", ask: "Deep dive on Virtuals")]),
                   Opportunity(logo: "Kaito", name: "Kaito", metric: "$2.3M", why: "Subscription revenue, 30 days", up: false, tags: [Tag("Deep dive", ask: "Deep dive on Kaito")]),
               ]))),
        ]),
        sc("p-news", .news, "Oct 26", "Research: AI agent tokens", title: "What news is moving markets?"),
        Conversation(id: "presales", title: "Track my presales", project: "Presale tracker", when: "Oct 2", messages: [
            u("Track presales I'm whitelisted for and their unlocks"),
            ai(["Reading Legion and Echo accounts", "Pulling vesting schedules"], t("You have **2 allocations**. $640 unlocks in the next 30 days."),
               bars("Unlocks, next 90 days", [BarRow("Nov", 640, "$640"), BarRow("Dec", 320, "$320"), BarRow("Jan", 320, "$320")])),
        ]),
        sc("p-legion", .inject, "Oct 25", "Presale tracker", title: "Join the Hermes presale"),
    ]
}
