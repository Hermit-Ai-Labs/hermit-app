import { PnlCard, FlowCard, CodeCard, BarsCard, OppList } from './components/ChatCards'

// Past conversations behind each strategy and project, so opening one shows how it was built.
// ai messages: { tools, blocks } render like live replies; { receipt } renders a result card.

const u = (text) => ({ role: 'user', text })
const ai = (tools, ...blocks) => ({ role: 'ai', inline: { tools, blocks }, progress: 99 })
const done = (title, rows, stats) => ({ role: 'ai', receipt: { title, rows, stats } })
const txt = (html) => () => <div className="ai-text"><p dangerouslySetInnerHTML={{ __html: html }} /></div>

// A chat that replays one of the scripted scenarios.
const sc = (id, prompt, when, project) => ({ title: prompt, when, project, messages: [u(prompt), { role: 'ai', id, progress: 99 }] })

export const threads = {
  'news-cost': { title: 'What does the bot cost?', project: 'Dev: HYPE news bot', when: 'Oct 25', messages: [
    u('What does the news bot cost me each month?'),
    ai(['Reading x402 receipts', 'Adding hosting'], txt('About <b>$8 a month</b>. Perplexity bills per search, so it moves with news volume.'),
      () => <BarsCard title="Monthly cost" prefix="$" rows={[{ label: 'Hosting', value: 5 }, { label: 'Perplexity', value: 3 }, { label: 'Telegram', value: 0 }]} />),
  ] },
  'news-sell': { title: 'Sell access to friends', project: 'Dev: HYPE news bot', when: 'Oct 25', messages: [
    u('Can my friends pay to get the digest too?'),
    ai(['Setting up a USDC paywall', 'Creating invite link'], txt('Done. Friends pay <b>$10 a month in USDC</b> to join the channel. 12 joined so far, so the bot makes <b>$112 a month</b> after its own costs.'),
      () => <BarsCard title="This month" prefix="$" rows={[{ label: 'Sales', value: 120 }, { label: 'Costs', value: 8, color: 'var(--red)' }, { label: 'Profit', value: 112, color: 'var(--green)' }]} />),
  ] },
  'p-yield': sc('yield', 'Best safe yield for 10k USDC?', 'Oct 22', 'Stablecoin yield ladder'),
  'p-reverse': sc('reverse', 'Reverse engineer this 24% USDC vault: 0x9c4e…a71b', 'Oct 26', 'Stablecoin yield ladder'),
  'p-defi': sc('opps-defi', 'What DeFi opportunities should I look at?', 'Oct 3', 'Stablecoin yield ladder'),
  'p-arbflow': sc('arb', 'Draw how my funding-rate arb bot works', 'Oct 18', 'HYPE perp scripts'),
  'p-hype': sc('perp', 'Long HYPE 5x on Hyperliquid, stop at $22', 'Oct 24', 'HYPE perp scripts'),
  'p-pengu': sc('meme', 'Should I buy $PENGU?', 'Oct 25', 'Meme auto-trader'),
  'p-vol': sc('opps-vol', 'Which coins are volatile enough to trade right now?', 'Oct 20', 'Meme auto-trader'),
  'p-news': sc('news', 'What news is moving the market today?', 'Oct 26', 'Research: AI agent tokens'),
  'p-legion': sc('inject', 'Join the presale at legion-sale.xyz/hermes', 'Oct 25', 'Presale tracker'),
  'r-news': sc('news', 'What news is moving the market today?', 'Today'),
  'r-pay': sc('pay', 'Pay alice.eth 200 USDC on Friday', 'Today'),
  'r-inbox': sc('inbox', 'Summarize my inbox and pay what is due', 'Yesterday'),
  'r-budget': sc('budget-api', 'The budgeting app frontend is done. Wire up the APIs.', 'Today'),
  'r-multisend': { title: 'Send USDC to 48 wallets', when: 'Today', messages: [{ role: 'user', text: 'Send USDC to every wallet in this spreadsheet', attachment: { name: 'wallets.xlsx', kind: 'sheet' } }, { role: 'ai', id: 'multisend', progress: 99 }] },
  'r-flap': sc('flap', 'Launch my token $HERMIT on flap.sh', 'Today'),
  'r-api': sc('dev', 'Buy GPT API credits and add it to my tools', 'Oct 23'),
  'news-bot': {
    title: 'HYPE news bot',
    project: 'Dev: HYPE news bot',
    when: 'Oct 24',
    messages: [u('Build a Telegram bot that sends me HYPE news every morning'), { role: 'ai', id: 'build', progress: 99 }],
  },
  'hype-arb': {
    title: 'HYPE funding arbitrage',
    project: 'HYPE perp scripts',
    when: 'Oct 12',
    messages: [
      u('I want to earn from HYPE funding without taking price risk'),
      ai(['Pulling 90 days of HYPE funding', 'Checking spot liquidity'],
        txt('Longs have paid shorts on <b>84 of the last 90 days</b>. If you hold spot HYPE and short the same amount, price moves cancel out and you keep the funding.'),
        () => <BarsCard title="Avg funding by month" suffix="%/h" rows={[{ label: 'Aug', value: 0.021 }, { label: 'Sep', value: 0.034 }, { label: 'Oct', value: 0.029 }]} />),
      u('Write the bot. Enter above 0.03% an hour, exit below 0.01%'),
      ai(['Writing strategy', 'Adding safety checks'],
        txt('Here is the logic. Every order goes through the hazard scan, and it never uses more than 1x.'),
        () => <FlowCard title="Bot logic" steps={[{ t: 'Watch', d: 'Every 60s' }, { t: 'Enter', d: 'Funding > 0.03%/h' }, { t: 'Spot + short', d: 'Same size' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }, { t: 'Exit', d: 'Funding < 0.01%/h' }]} />,
        () => <CodeCard code={`every("60s", async () => {
  const f = await hl.funding("HYPE")
  if (!open && f > 0.0003) await hedge.open("HYPE", size)
  if (open && f < 0.0001) await hedge.close("HYPE")
})`} />),
      u('Backtest 90 days with $5,000'),
      ai(['Replaying 90 days of fills', 'Adding fees and slippage'],
        txt('<b>+$3,480</b> over 90 days after fees, or about 28% a year. Worst drawdown was 1.8%, during the Sep 3 funding flip.'),
        () => <PnlCard title="Backtest, 90 days" total="+$3,480" days={90} seed={21} />,
        () => <BarsCard title="Results" rows={[{ label: 'Win rate', value: 78, sub: '%' }, { label: 'Trades', value: 46 }, { label: 'Max drawdown', value: 1.8, sub: '%' }]} suffix="" />),
      u('Deploy it with $5,200'),
      done('Strategy deployed', [['Strategy', 'HYPE funding arb'], ['Capital', '$5,200'], ['Leverage', '1x max'], ['Status', 'Running']], [['Since', 'Oct 12'], ['Profit', '+$1,204'], ['Trades', '19'], ['Drawdown', '0.9%']]),
    ],
  },
  'eth-breakout': {
    title: 'ETH breakout',
    when: 'Oct 19',
    messages: [
      u('Buy ETH when it breaks out of its range, with a tight stop'),
      ai(['Finding the 4H range', 'Testing breakout rules'],
        txt('ETH has ranged between <b>$3,180 and $3,520</b> for 3 weeks. A 4H close above the range on 1.5x volume has worked 54% of the time since 2023, and winners are 3x bigger than losers.'),
        () => <PnlCard title="Backtest, 2 years" total="+38%" days={60} seed={33} />),
      u('Use 3x, take profit at 6%, stop at 2%. $3,000'),
      ai(['Building strategy'],
        () => <FlowCard title="Rules" steps={[{ t: 'Watch 4H', d: 'Range high $3,520' }, { t: 'Breakout', d: 'Close above, 1.5x vol' }, { t: 'Long 3x', d: 'TP +6%, SL −2%' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }]} />),
      u('Go'),
      done('Strategy running', [['Capital', '$3,000'], ['Leverage', '3x'], ['TP / SL', '+6% / −2%']], [['Trades', '2'], ['Profit', '+$286'], ['Win rate', '50%'], ['Open', 'Long']]),
    ],
  },
  'eth-dca': {
    title: 'Weekly ETH DCA',
    when: 'Sep 30',
    messages: [
      u('Buy $500 of ETH every Monday and send it to my Vault'),
      ai(['Comparing routes', 'Checking Vault address'],
        txt('Best route is Uniswap through 1inch, about $0.40 per buy. Each purchase goes straight to your Ledger Vault, so nothing sits in a hot wallet.'),
        () => <BarsCard title="Cost per $500 buy" prefix="$" rows={[{ label: '1inch', value: 0.4 }, { label: 'Uniswap direct', value: 0.9 }, { label: 'Exchange', value: 3 }]} />),
      u('Do it'),
      done('DCA scheduled', [['Amount', '$500 a week'], ['Day', 'Monday 09:00'], ['To', 'Vault']], [['Buys', '4'], ['ETH bought', '0.58'], ['Avg price', '$3,430'], ['Profit', '+$96']]),
    ],
  },
  'meme-sniper': {
    title: 'Meme sniper',
    project: 'Meme auto-trader',
    when: 'Oct 5',
    messages: [
      u('Snipe new Solana memes, but only safe ones'),
      ai(['Scanning 30 days of launches', 'Scoring holder maps'],
        txt('Of 1,240 launches with over $200k liquidity, <b>71% failed my holder check</b> (deployer clusters, unlocked liquidity). The ones that passed returned 2x four times as often.'),
        () => <BarsCard title="Launches, 30 days" rows={[{ label: 'Failed holder check', value: 881 }, { label: 'Passed', value: 359 }, { label: 'Hit 2x', value: 74 }]} suffix="" />),
      u('Buy $100 each, sell at 2x, max $300 a day'),
      ai(['Building strategy'], () => <FlowCard title="Rules" steps={[{ t: 'New pair', d: 'Liquidity > $200k' }, { t: 'Holder check', d: 'Bubble map' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }, { t: 'Buy $100', d: 'Sell at 2x' }]} />),
      u('Pause it, memes are slow this week'),
      done('Strategy paused', [['Trades', '13'], ['Result', '−$118'], ['Skipped', '41 risky tokens']]),
    ],
  },
  'susde-loop': {
    title: 'sUSDe / USDC loop',
    when: 'Oct 15',
    messages: [
      u('Can I get more than 15% on stables safely?'),
      ai(['Comparing loop strategies', 'Stress-testing a depeg'],
        txt('Looping sUSDe on Aave 2x earns about <b>16%</b>. It unwinds automatically if health falls below 1.3. That covers a 9% depeg before any risk of liquidation.'),
        () => <BarsCard title="APY" suffix="%" rows={[{ label: 'sUSDe 2x loop', value: 16.2 }, { label: 'sUSDe', value: 11.2 }, { label: 'Aave USDC', value: 5.6 }]} />),
      u('Start with $4,000'),
      done('Loop opened', [['Capital', '$4,000'], ['Loops', '2x'], ['Health', '1.62']], [['APY', '16.2%'], ['Profit', '+$162'], ['Health', '1.58'], ['Unwind at', '1.30']]),
    ],
  },
  'dex-spread': {
    title: 'Stablecoin DEX spread',
    project: 'Stablecoin yield ladder',
    when: 'Oct 8',
    messages: [
      u('Find risk-free spreads between stablecoins'),
      ai(['Watching 6 DEXs for 24h'],
        txt('USDC, USDT and DAI drift apart by <b>0.15% or more about 40 times a day</b>. Buying and selling in one transaction locks in the gap with no price risk.'),
        () => <PnlCard title="Simulated, 30 days" total="+$61" days={30} seed={44} />),
      u('Run it with $1,500'),
      done('Strategy running', [['Capital', '$1,500'], ['Min spread', '0.15% after gas']], [['Trades', '212'], ['Profit', '+$58'], ['Win rate', '91%'], ['Gas', '$9']]),
    ],
  },
  'airdrops-s3': {
    title: 'Airdrop farming S3',
    project: 'Airdrop farming S3',
    when: 'Sep 15',
    messages: [
      u('Which airdrops are worth farming this season?'),
      ai(['Ranking 40 campaigns', 'Estimating value per hour'],
        txt('Three stand out on value per hour of effort.'),
        () => <BarsCard title="Est. value per hour" prefix="$" rows={[{ label: 'MegaETH', value: 85 }, { label: 'Berachain', value: 70 }, { label: 'Monad', value: 60 }]} />),
      u('Farm all three across 3 wallets, gas under $2 a day'),
      done('Farming started', [['Campaigns', 'MegaETH, Berachain, Monad'], ['Wallets', '3'], ['Gas cap', '$2 a day']], [['Points', '14,200'], ['Gas spent', '$18'], ['Done', '12 of 17'], ['Est. value', '$1.1k–3.3k']]),
    ],
  },
  'research-agents': {
    title: 'AI agent tokens',
    project: 'Research: AI agent tokens',
    when: 'Oct 20',
    messages: [
      u('Which AI agent tokens have real usage?'),
      ai(['Pulling on-chain activity', 'Reading docs and X'],
        txt('Most have little usage. These three have paying users.'),
        () => <OppList title="Watchlist" items={[
          { logo: 'Virtuals', name: 'Virtuals', metric: '$4.1M', why: 'Agent fees, 30 days', tags: [{ label: 'Deep dive', ask: 'Deep dive on Virtuals' }] },
          { logo: 'Kaito', name: 'Kaito', metric: '$2.3M', why: 'Subscription revenue, 30 days', tags: [{ label: 'Deep dive', ask: 'Deep dive on Kaito' }] },
        ]} />),
    ],
  },
  presales: {
    title: 'Presale tracker',
    project: 'Presale tracker',
    when: 'Oct 2',
    messages: [
      u('Track presales I’m whitelisted for and their unlocks'),
      ai(['Reading Legion and Echo accounts', 'Pulling vesting schedules'],
        txt('You have <b>2 allocations</b>. $640 unlocks in the next 30 days.'),
        () => <BarsCard title="Unlocks, next 90 days" prefix="$" rows={[{ label: 'Nov', value: 640 }, { label: 'Dec', value: 320 }, { label: 'Jan', value: 320 }]} />),
    ],
  },
  monad: {
    title: 'Monad airdrop',
    project: 'Airdrop farming S3',
    when: 'Oct 21',
    messages: [
      u('Farm the Monad airdrop for me'),
      { role: 'ai', id: 'airdrop', progress: 99 },
    ],
  },
}

// Which thread explains each strategy, project and airdrop.
export const threadFor = {
  'Dev: HYPE news bot': 'news-bot',
  arb: 'hype-arb', breakout: 'eth-breakout', dca: 'eth-dca', sniper: 'meme-sniper', loop: 'susde-loop', dex: 'dex-spread',
  'Stablecoin yield ladder': 'dex-spread', 'HYPE perp scripts': 'hype-arb', 'Airdrop farming S3': 'airdrops-s3',
  'Meme auto-trader': 'meme-sniper', 'Research: AI agent tokens': 'research-agents', 'Presale tracker': 'presales',
  Monad: 'monad', MegaETH: 'airdrops-s3', Berachain: 'airdrops-s3',
}
