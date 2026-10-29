// All demo data lives here so devs can see what each screen expects from the backend.

export const user = {
  name: 'Ryan',
  email: 'ryan@hermit.app',
  wallet: '0x7a3F…9c2E',
  walletType: 'Local wallet (Secure Enclave)',
}

// Seeded random so charts look the same on every load.
export function rng(seed = 1) {
  let s = seed
  return () => ((s = (s * 16807) % 2147483647) - 1) / 2147483646
}
export function walk(n, start, vol, seed, drift = 0) {
  const r = rng(seed)
  const out = [start]
  for (let i = 1; i < n; i++) out.push(Math.max(0.0001, out[i - 1] * (1 + (r() - 0.5 + drift) * vol)))
  return out
}
export function candles(n, start, vol, seed, drift = 0.02) {
  const r = rng(seed)
  let o = start
  return Array.from({ length: n }, () => {
    const c = o * (1 + (r() - 0.5 + drift) * vol)
    const h = Math.max(o, c) * (1 + r() * vol * 0.4)
    const l = Math.min(o, c) * (1 - r() * vol * 0.4)
    const bar = { o, h, l, c }
    o = c
    return bar
  })
}

export const fmt = {
  usd: (n, d = 0) => '$' + n.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }),
  pct: (n) => (n > 0 ? '+' : '') + n.toFixed(2) + '%',
}

// Assets under agent management (home pie chart + portfolio)
export const allocation = [
  { label: 'Yield', value: 14800, color: '#121212' },
  { label: 'Perps', value: 12400, color: '#4E1F96' },
  { label: 'Spot', value: 9000, color: '#8E73CF' },
  { label: 'Idle stables', value: 8200, color: '#C9BFE6' },
  { label: 'Memes', value: 3920, color: '#E4E4E2' },
]
export const totalAUM = allocation.reduce((a, b) => a + b.value, 0)

// Demo "today". To-dos and events share one list so home and Calendar stay in sync.
export const TODAY = '2026-10-26'
export const todos = [
  { id: 1, t: 'Approve ETH DCA', date: '2026-10-26', time: '09:00', dur: 30, to: 'automations', status: 'todo' },
  { id: 2, t: 'Claim HYPE rewards', date: '2026-10-26', to: 'earn', status: 'todo' },
  { id: 3, t: 'Standup with dev team', date: '2026-10-26', time: '14:30', dur: 30, event: true, project: 'Dev: HYPE news bot' },
  { id: 13, t: 'Review arb bot PnL', date: '2026-10-26', time: '11:00', dur: 60, project: 'HYPE perp scripts', status: 'doing' },
  { id: 4, t: 'Pay Figma $45', date: '2026-10-27', time: '10:00', dur: 15, to: 'payments', status: 'todo' },
  { id: 14, t: 'MegaETH testnet tasks', date: '2026-10-27', time: '16:00', dur: 45, project: 'Airdrop farming S3', status: 'todo' },
  { id: 15, t: 'Backtest SOL funding arb', date: '2026-10-28', time: '10:00', dur: 90, project: 'HYPE perp scripts', status: 'todo' },
  { id: 16, t: 'Add SOL news to bot', date: '2026-10-28', time: '15:00', dur: 60, project: 'Dev: HYPE news bot', status: 'doing' },
  { id: 5, t: 'Finish Monad quests', date: '2026-10-29', time: '13:00', dur: 30, project: 'Airdrop farming S3', ask: 'Farm the Monad airdrop for me', status: 'todo' },
  { id: 17, t: 'Legion KYC for Hermes sale', date: '2026-10-29', time: '11:00', dur: 30, project: 'Presale tracker', status: 'todo' },
  { id: 6, t: 'Vercel renews $20', date: '2026-10-30', to: 'payments', event: true },
  { id: 18, t: 'Write agent-token thesis', date: '2026-10-30', time: '09:30', dur: 120, project: 'Research: AI agent tokens', status: 'doing' },
  { id: 7, t: 'Pay alice.eth $1,200', date: '2026-11-01', to: 'payments', status: 'todo' },
  { id: 9, t: 'ETH DCA buy', date: '2026-11-02', time: '09:00', dur: 15, to: 'automations', event: true },
  { id: 8, t: 'Rent $2,400', date: '2026-11-03', to: 'payments', event: true },
  { id: 10, t: 'Berachain claim opens', date: '2026-11-04', event: true, project: 'Airdrop farming S3' },
  { id: 19, t: 'Restart meme sniper?', date: '2026-11-05', time: '10:00', dur: 30, project: 'Meme auto-trader', status: 'todo' },
  { id: 11, t: 'Presale unlock $640', date: '2026-11-10', event: true, project: 'Presale tracker' },
  { id: 20, t: 'Pendle rollover plan', date: '2026-11-20', project: 'Stablecoin yield ladder', status: 'todo' },
  { id: 21, t: 'Ship news bot v1', date: '2026-10-24', project: 'Dev: HYPE news bot', status: 'done' },
  { id: 22, t: 'Deploy arb bot', date: '2026-10-12', project: 'HYPE perp scripts', status: 'done' },
  { id: 12, t: 'Pendle PT matures', date: '2026-12-26', event: true, project: 'Stablecoin yield ladder' },
]

export const projectColors = {
  'Dev: HYPE news bot': '#2563EB', 'Stablecoin yield ladder': '#15803D', 'HYPE perp scripts': '#4E1F96',
  'Airdrop farming S3': '#C2410C', 'Meme auto-trader': '#A16207', 'Research: AI agent tokens': '#0E7490', 'Presale tracker': '#BE185D',
}

// Wallets the user controls; balances sum to totalAUM.
export const wallets = [
  // type: 'local' keeps keys on this device; 'privy' is a keyless wallet recovered with email or passkey.
  { id: 'main', name: 'Main', kind: 'Local', type: 'local', addr: '0x7a3F…9c2E', usd: 21400 },
  { id: 'trading', name: 'Trading', kind: 'Hyperliquid', type: 'local', addr: '0x51b0…77Ad', usd: 12400 },
  { id: 'vault', name: 'Vault', kind: 'Ledger', type: 'local', addr: '0xF09e…13B4', usd: 7150 },
  { id: 'sol', name: 'Solana', kind: 'Privy, email', type: 'privy', addr: '7xKp…Qm2a', usd: 6550 },
  { id: 'farm', name: 'Airdrop farm', kind: 'Privy, 3 wallets', type: 'privy', addr: '0x1c4d…, +2', usd: 820 },
]

export const holdings = [
  { sym: 'USDC', name: 'USD Coin', chain: 'Base', amt: 8200, usd: 8200, ch: 0 },
  { sym: 'ETH', name: 'Ethereum', chain: 'Ethereum', amt: 1.82, usd: 6370, ch: 2.41 },
  { sym: 'SOL', name: 'Solana', chain: 'Solana', amt: 14.1, usd: 2630, ch: -1.12 },
  { sym: 'HYPE', name: 'Hyperliquid', chain: 'HyperEVM', amt: 96, usd: 2310, ch: 5.8 },
  { sym: 'PEPE', name: 'Pepe', chain: 'Ethereum', amt: 84000000, usd: 1610, ch: 12.4 },
  { sym: 'WIF', name: 'dogwifhat', chain: 'Solana', amt: 820, usd: 0, ch: -3.2 },
]

// Where the money sits, by DApp
export const dappExposure = [
  { name: 'Hyperliquid', type: 'Perps', usd: 12400, liq: 'Instant', pnl: 842, risk: 'Medium' },
  { name: 'Pendle', type: 'Fixed yield', usd: 6200, liq: 'Maturity 26 Dec', pnl: 214, risk: 'Low' },
  { name: 'Aave v3', type: 'Lending', usd: 5100, liq: 'Instant', pnl: 96, risk: 'Low' },
  { name: 'Ethena', type: 'Staked USDe', usd: 3500, liq: '7-day cooldown', pnl: 118, risk: 'Medium' },
  { name: 'Jupiter', type: 'Spot (SOL)', usd: 2630, liq: 'Instant', pnl: -31, risk: 'Low' },
  { name: 'Wallet', type: 'Idle', usd: 18490, liq: 'Instant', pnl: 0, risk: '—' },
]

export const spending = [
  { what: 'OpenAI API credits', cat: 'API', amt: -20, via: 'x402', when: 'Today 10:12' },
  { what: 'Swap 1,000 USDC → PEPE', cat: 'Trade', amt: -1000, via: 'Jupiter', when: 'Today 09:40' },
  { what: 'Gas sponsorship', cat: 'Network', amt: -1.84, via: 'Base', when: 'Today 09:40' },
  { what: 'Pendle PT-USDe yield', cat: 'Earn', amt: 38.2, via: 'Auto-claim', when: 'Yesterday' },
  { what: 'Notion subscription', cat: 'Payment', amt: -10, via: 'USDC → bank', when: 'Oct 24' },
  { what: 'Perplexity API (pay-per-call)', cat: 'API', amt: -3.41, via: 'x402', when: 'Oct 23' },
  { what: 'Hyperliquid funding received', cat: 'Trade', amt: 12.6, via: 'Hyperliquid', when: 'Oct 23' },
]

export const connectors = [
  { name: 'Gmail', kind: 'MCP', desc: 'Email', on: true },
  { name: 'Google Calendar', kind: 'MCP', desc: 'Calendar', on: true },
  { name: 'Notion', kind: 'MCP', desc: 'Notes and docs', on: true },
  { name: 'X', kind: 'OAuth', desc: 'Posts and quests', on: true },
  { name: 'Telegram', kind: 'MCP', desc: 'Alpha groups, alerts', on: false },
  { name: 'Discord', kind: 'OAuth', desc: 'Airdrop roles', on: false },
  { name: 'OpenAI', kind: 'Paid API', desc: 'Billed per call in USDC', on: true },
  { name: 'Perplexity', kind: 'Paid API', desc: 'Web research', on: true },
  { name: 'GitHub', kind: 'MCP', desc: 'Repos and scripts', on: false },
  { name: 'Dune', kind: 'API', desc: 'On-chain queries', on: true },
  { name: 'Bubblemaps', kind: 'API', desc: 'Holder clusters', on: true },
]

export const skills = [
  { name: 'Hazard scan', desc: 'Checks every transaction', locked: true },
  { name: 'Injection shield', desc: 'Ignores instructions in web pages and email', locked: true },
  { name: 'Browser takeover', desc: 'Uses websites for you', locked: false },
  { name: 'Meme sniper', desc: 'Screens new pairs', locked: false },
  { name: 'Airdrop farmer', desc: 'Completes quests', locked: false },
  { name: 'Research analyst', desc: 'Token reports', locked: false },
]

export const apiMarket = [
  { name: 'GPT-5', by: 'OpenAI', price: '$20 credits' },
  { name: 'Sonar', by: 'Perplexity', price: '$0.005 / call' },
  { name: 'Birdeye Pro', by: 'Birdeye', price: '$49 / mo' },
  { name: 'Flux', by: 'Black Forest Labs', price: '$0.03 / image' },
]

export const dapps = [
  { name: 'Hyperliquid', cat: 'Perps', tvl: '$5.1B', chain: 'HyperEVM', conn: true, hot: true, desc: 'Perps' },
  { name: 'Aave', cat: 'Lending', tvl: '$38.2B', chain: 'Multi-chain', conn: true, hot: false, desc: 'Lending' },
  { name: 'Pendle', cat: 'Yield', tvl: '$6.4B', chain: 'Multi-chain', conn: true, hot: true, desc: 'Fixed yield' },
  { name: 'Ethena', cat: 'Yield', tvl: '$11.8B', chain: 'Ethereum', conn: true, hot: false, desc: 'Synthetic dollar' },
  { name: 'Jupiter', cat: 'DEX', tvl: '$2.9B', chain: 'Solana', conn: true, hot: false, desc: 'Swaps' },
  { name: 'Uniswap', cat: 'DEX', tvl: '$5.6B', chain: 'Multi-chain', conn: false, hot: false, desc: 'Swaps & LP' },
  { name: 'Lido', cat: 'Staking', tvl: '$27.5B', chain: 'Ethereum', conn: false, hot: false, desc: 'ETH staking' },
  { name: 'Pump.fun', cat: 'Launchpad', tvl: '$0.4B', chain: 'Solana', conn: false, hot: true, desc: 'Meme launches' },
  { name: 'Morpho', cat: 'Lending', tvl: '$9.3B', chain: 'Multi-chain', conn: false, hot: true, desc: 'Lending vaults' },
  { name: 'Kamino', cat: 'Yield', tvl: '$2.2B', chain: 'Solana', conn: false, hot: false, desc: 'Liquidity vaults' },
  { name: 'Polymarket', cat: 'Prediction', tvl: '$0.6B', chain: 'Polygon', conn: false, hot: true, desc: 'Predictions' },
  { name: 'Legion', cat: 'Presale', tvl: '—', chain: 'Multi-chain', conn: false, hot: true, desc: 'Token sales' },
  { name: 'Lighter', cat: 'Perps', tvl: '$1.4B OI', chain: 'Ethereum zk', conn: false, hot: true, isNew: true, desc: 'Zero-fee zk perps' },
  { name: 'trade.xyz', cat: 'Perps', tvl: '$4B OI', chain: 'Hyperliquid', conn: false, hot: true, isNew: true, desc: 'Stock and gold perps' },
  { name: 'Aster', cat: 'Perps', tvl: '15% share', chain: 'BNB', conn: false, hot: false, desc: 'Multichain perps' },
  { name: 'Paradex', cat: 'Perps', tvl: '$289M / day', chain: 'Starknet', conn: false, hot: false, desc: 'Private perps' },
  { name: 'Extended', cat: 'Perps', tvl: '$6.4B / mo', chain: 'Starknet', conn: false, hot: false, desc: 'Starknet perps' },
  { name: 'Variational', cat: 'Perps', tvl: '$16B / mo', chain: 'Arbitrum', conn: false, hot: false, desc: 'Zero-fee RFQ perps' },
  { name: 'Kalshi', cat: 'Prediction', tvl: '$5.4B / mo', chain: 'Regulated', conn: false, hot: true, desc: 'Regulated predictions' },
  { name: 'Predict.fun', cat: 'Prediction', tvl: '$579M / mo', chain: 'BNB', conn: false, hot: false, isNew: true, desc: 'Yield-bearing bets' },
  { name: 'Opinion', cat: 'Prediction', tvl: '$376M / mo', chain: 'BNB', conn: false, hot: false, isNew: true, desc: 'Macro predictions' },
  { name: 'Limitless', cat: 'Prediction', tvl: '$205M / mo', chain: 'Base', conn: false, hot: false, desc: 'Short-term price markets' },
  { name: 'Coinbase Sales', cat: 'Presale', tvl: '$188M sale', chain: 'Multichain', conn: false, hot: true, isNew: true, desc: 'Public token sales' },
  { name: 'MetaDAO', cat: 'Presale', tvl: '$100M+ raised', chain: 'Solana', conn: false, hot: false, desc: 'Futarchy ICOs' },
  { name: 'Echo', cat: 'Presale', tvl: 'n/a', chain: 'Multichain', conn: false, hot: false, desc: 'Token sales' },
  { name: 'Jupiter Lend', cat: 'Lending', tvl: '$2.6B', chain: 'Solana', conn: false, hot: false, isNew: true, desc: 'Solana lending' },
  { name: 'Curvance', cat: 'Lending', tvl: '$75M', chain: 'Monad', conn: false, hot: false, isNew: true, desc: 'Lend yield assets' },
  { name: 'Kuru', cat: 'DEX', tvl: '$380M / mo', chain: 'Monad', conn: false, hot: false, isNew: true, desc: 'Order book DEX' },
  { name: 'Aerodrome', cat: 'DEX', tvl: '$9.5B / mo', chain: 'Base', conn: false, hot: false, desc: 'Base swaps and LP' },
  { name: 'USD.AI', cat: 'Yield', tvl: '$491M', chain: 'Arbitrum', conn: false, hot: true, isNew: true, desc: 'Yield from GPU loans' },
  { name: 'Falcon', cat: 'Stablecoin', tvl: '$1.8B', chain: 'Ethereum', conn: false, hot: false, desc: 'Synthetic dollar USDf' },
  { name: 'Maple', cat: 'Yield', tvl: 'n/a', chain: 'Multichain', conn: false, hot: false, desc: 'Institutional credit yield' },
  { name: 'Plasma', cat: 'Stablecoin', tvl: '$5.7B', chain: 'Plasma', conn: false, hot: false, isNew: true, desc: 'Zero-fee USDT chain' },
  { name: 'Kinetiq', cat: 'Staking', tvl: '$1.0B', chain: 'HyperEVM', conn: false, hot: false, isNew: true, desc: 'HYPE liquid staking' },
  { name: 'Infrared', cat: 'Staking', tvl: '$1.5B', chain: 'Berachain', conn: false, hot: false, desc: 'Berachain staking' },
  { name: 'Ondo', cat: 'RWA', tvl: '$1B', chain: 'Multichain', conn: false, hot: true, isNew: true, desc: 'Tokenized US stocks' },
  { name: 'xStocks', cat: 'RWA', tvl: '$700M', chain: 'Solana', conn: false, hot: false, desc: 'Tokenized stocks' },
  { name: 'BUIDL', cat: 'RWA', tvl: '$2.8B', chain: 'Ethereum', conn: false, hot: false, desc: 'BlackRock treasury fund' },
  { name: 'Virtuals', cat: 'AI agents', tvl: '$621M', chain: 'Base', conn: false, hot: true, desc: 'AI agent launchpad' },
  { name: 'x402', cat: 'AI agents', tvl: '100M+ payments', chain: 'Base', conn: true, hot: false, isNew: true, desc: 'Agent payments' },
  { name: 'Infinex', cat: 'Wallet', tvl: 'n/a', chain: '20+ chains', conn: false, hot: false, isNew: true, desc: 'Passkey wallet app' },
]

// Each project records money at work, what it cost, and what it gained, plus its chats (thread ids in threads.jsx).
export const projects = [
  { name: 'Dev: HYPE news bot', icon: 'Code2', desc: 'Bot that pays for its own APIs', status: 'Running', pnl: '+$120',
    money: 20, cost: 13, gain: 120, gainLabel: 'Sales', gainNote: '12 friends pay $10 a month', fileList: ['bot.ts', 'digest.prompt', 'deploy.json'],
    chats: [['news-bot', 'Build the news bot', 'Oct 24'], ['news-cost', 'What does the bot cost?', 'Oct 25'], ['news-sell', 'Sell access to friends', 'Oct 25']] },
  { name: 'Stablecoin yield ladder', icon: 'Sprout', desc: 'Best safe yield on stables', status: 'Running', pnl: '+$642',
    money: 16300, cost: 9, gain: 642, gainLabel: 'Yield', gainNote: '10.6% APY blended',
    chats: [['p-reverse', 'Reverse engineer a 24% vault', 'Today'], ['p-yield', 'Best safe yield for 10k USDC', 'Oct 22'], ['dex-spread', 'Stablecoin DEX spread', 'Oct 8'], ['p-defi', 'What DeFi ideas are new?', 'Oct 3']] },
  { name: 'HYPE perp scripts', icon: 'TrendingUp', desc: 'Funding arb on Hyperliquid', status: 'Running', pnl: '+$1,490',
    money: 10200, cost: 46, gain: 1490, gainLabel: 'PnL', gainNote: 'Arb +$1,204, breakout +$286',
    chats: [['hype-arb', 'Build the funding arb bot', 'Oct 12'], ['p-arbflow', 'Draw how the bot works', 'Oct 18'], ['p-hype', 'Long HYPE 5x, stop at $22', 'Oct 24']] },
  { name: 'Airdrop farming S3', icon: 'Gift', desc: 'Monad, Berachain, MegaETH', status: 'Running', pnl: '14,200 pts',
    money: 2950, cost: 18, gain: 0, gainLabel: 'Claimed', gainNote: '14,200 points, est. $1.1k–3.3k',
    chats: [['airdrops-s3', 'Which airdrops to farm', 'Sep 15'], ['monad', 'Farm Monad for me', 'Oct 21']] },
  { name: 'Meme auto-trader', icon: 'Flame', desc: 'Safe Solana meme buys', status: 'Paused', pnl: '−$118',
    money: 300, cost: 6, gain: -118, gainLabel: 'PnL', gainNote: '13 trades, 41 risky tokens skipped',
    chats: [['meme-sniper', 'Build the meme sniper', 'Oct 5'], ['p-pengu', 'Should I buy $PENGU?', 'Oct 25'], ['p-vol', 'Most volatile coins', 'Oct 20']] },
  { name: 'Research: AI agent tokens', icon: 'BookOpen', desc: 'Agent token watchlist', status: 'Draft', pnl: '—',
    money: 0, cost: 12, gain: 0, gainLabel: 'Gain', gainNote: 'Research only, no positions',
    chats: [['research-agents', 'Which agent tokens have usage?', 'Oct 20'], ['p-news', 'What news is moving markets?', 'Oct 26']] },
  { name: 'Presale tracker', icon: 'Rocket', desc: 'Allocations and unlocks', status: 'Running', pnl: '+$640',
    money: 1250, cost: 0, gain: 640, gainLabel: 'Unlocked', gainNote: '2 allocations, $640 unlocked',
    chats: [['presales', 'Track my presales', 'Oct 2'], ['p-legion', 'Join the Hermes presale', 'Oct 25']] },
]

// Chats that don't belong to a project, newest first (sidebar Recents).
export const recentThreads = [
  ['r-budget', 'AI budgeting app: get API key'], ['r-multisend', 'Send USDC to 48 wallets'], ['r-flap', 'Launch $HERMIT on flap.sh'],
  ['r-news', 'What news is moving markets?'], ['eth-breakout', 'ETH breakout strategy'], ['r-pay', 'Pay alice.eth 200 USDC'],
  ['susde-loop', 'sUSDe loop'], ['r-inbox', 'Summarize my inbox'], ['eth-dca', 'Weekly ETH DCA'], ['r-api', 'Buy GPT API credits'],
]

export const automations = [
  { name: 'Weekly ETH DCA', trigger: 'Every Monday 09:00', action: 'Swap 500 USDC → ETH on Uniswap', limit: '$500 / week', on: true, last: 'Ran Oct 20' },
  { name: 'Best stable yield', trigger: 'When APY gap > 1.5%', action: 'Rebalance stables between Aave, Pendle, Ethena', limit: '$15k cap', on: true, last: 'Moved $4.2k on Oct 22' },
  { name: 'HYPE funding arb', trigger: 'Funding > 0.03% / hr', action: 'Short perp + hold spot on Hyperliquid', limit: '3x max leverage', on: true, last: '+$12.60 two hours ago' },
  { name: 'Daily quest runner', trigger: 'Daily 08:00', action: 'Complete Galxe / Layer3 tasks with X + wallet', limit: 'Gas ≤ $2 / day', on: true, last: '6 tasks done today' },
  { name: 'Meme sniper', trigger: 'New pair, liquidity > $200k', action: 'Buy $100 if hazard scan passes, sell at 2x', limit: '$300 / day', on: false, last: 'Paused by you' },
  { name: 'Invoice payer', trigger: 'Invoice email received', action: 'Draft USDC payment, ask me to approve', limit: 'Always ask', on: true, last: 'Paid Notion $10' },
]

export const earnOpps = [
  { name: 'PT-USDe', proto: 'Pendle', asset: 'USDe', apy: 18.4, tvl: '$1.2B', risk: 'Medium', type: 'Fixed', chain: 'Ethereum' },
  { name: 'sUSDe', proto: 'Ethena', asset: 'USDe', apy: 11.2, tvl: '$5.3B', risk: 'Medium', type: 'Variable', chain: 'Ethereum' },
  { name: 'HLP vault', proto: 'Hyperliquid', asset: 'USDC', apy: 14.7, tvl: '$410M', risk: 'Medium', type: 'Market-making', chain: 'HyperEVM' },
  { name: 'USDC vault', proto: 'Morpho', asset: 'USDC', apy: 7.9, tvl: '$1.6B', risk: 'Low', type: 'Lending', chain: 'Base' },
  { name: 'USDC supply', proto: 'Aave v3', asset: 'USDC', apy: 5.6, tvl: '$4.1B', risk: 'Low', type: 'Lending', chain: 'Arbitrum' },
  { name: 'stETH', proto: 'Lido', asset: 'ETH', apy: 3.1, tvl: '$27B', risk: 'Low', type: 'Staking', chain: 'Ethereum' },
  { name: 'JLP', proto: 'Jupiter', asset: 'Basket', apy: 32.5, tvl: '$1.4B', risk: 'High', type: 'LP', chain: 'Solana' },
  { name: 'staking', proto: 'Hyperliquid', asset: 'HYPE', apy: 2.4, tvl: '$9B', risk: 'Low', type: 'Staking', chain: 'HyperEVM' },
  { name: 'kHYPE', proto: 'Kinetiq', asset: 'HYPE', apy: 2.9, tvl: '$1.0B', risk: 'Low', type: 'Staking', chain: 'HyperEVM', isNew: true },
  { name: 'sUSDai', proto: 'USD.AI', asset: 'USDC', apy: 12.4, tvl: '$491M', risk: 'Medium', type: 'Credit', chain: 'Arbitrum', isNew: true },
  { name: 'sUSDf', proto: 'Falcon', asset: 'USDf', apy: 9.0, tvl: '$1.8B', risk: 'Medium', type: 'Variable', chain: 'Ethereum' },
  { name: 'syrupUSDC', proto: 'Maple', asset: 'USDC', apy: 8.6, tvl: '$1.5B', risk: 'Medium', type: 'Credit', chain: 'Ethereum' },
  { name: 'USDC lending', proto: 'Jupiter Lend', asset: 'USDC', apy: 6.8, tvl: '$2.6B', risk: 'Low', type: 'Lending', chain: 'Solana', isNew: true },
  { name: 'USDC market', proto: 'Curvance', asset: 'USDC', apy: 9.6, tvl: '$75M', risk: 'Medium', type: 'Lending', chain: 'Monad', isNew: true },
  { name: 'iBERA', proto: 'Infrared', asset: 'BERA', apy: 11.8, tvl: '$1.5B', risk: 'Medium', type: 'Staking', chain: 'Berachain' },
  { name: 'USDY', proto: 'Ondo', asset: 'USDC', apy: 4.2, tvl: '$1B', risk: 'Low', type: 'Treasuries', chain: 'Multichain' },
]

export const payments = [
  { to: 'Figma', what: 'Pro plan', amt: 45, due: 'Tomorrow', method: 'USDC → bank', status: 'Scheduled' },
  { to: 'Vercel', what: 'Pro team', amt: 20, due: 'Oct 30', method: 'USDC → bank', status: 'Scheduled' },
  { to: 'alice.eth', what: 'Design milestone 2', amt: 1200, due: 'Nov 1', method: 'USDC', status: 'Needs approval' },
  { to: 'OpenAI', what: 'API top-up', amt: 20, due: 'When low', method: 'x402', status: 'Auto' },
  { to: 'Landlord', what: 'November rent', amt: 2400, due: 'Nov 3', method: 'USDC → bank', status: 'Needs approval' },
  { to: 'Hyperliquid', what: 'Margin top-up', amt: 500, due: 'Conditional', method: 'USDC', status: 'Auto' },
]

export const files = [
  { name: 'Weekly sync — dev team', type: 'Meeting notes', src: 'Dictation', when: 'Today', size: '4 min read' },
  { name: 'Re: Partnership with Pendle', type: 'Email', src: 'Gmail', when: 'Today', size: '3 messages' },
  { name: 'Hermit PRD v0.3', type: 'Doc', src: 'Notion', when: 'Yesterday', size: '12 pages' },
  { name: 'HYPE thesis', type: 'Research', src: 'Hermit', when: 'Yesterday', size: '6 pages' },
  { name: 'Invoice #2291 — Figma', type: 'Email', src: 'Gmail', when: 'Oct 24', size: 'PDF' },
  { name: 'Voice memo — airdrop ideas', type: 'Meeting notes', src: 'Dictation', when: 'Oct 23', size: '2 min' },
  { name: 'Q4 trading journal', type: 'Doc', src: 'Hermit', when: 'Oct 21', size: '18 entries' },
  { name: 'Ethena docs — sUSDe risks', type: 'Doc', src: 'Web clip', when: 'Oct 20', size: '9 pages' },
]

export const recentChatsOld = [
  'What news is moving the market today?',
  'Is $PENGU worth buying?',
  'Best yield for 10k USDC',
  'Long HYPE 5x with stop',
  'Build a Telegram bot that sends me HYPE news every morning',
  'What DeFi opportunities should I look at?',
  'Which coins are volatile enough to trade right now?',
  'Summarize my inbox',
]

export const perpMarkets = [
  { sym: 'BTC', px: 114280, ch: 1.8, fund: 0.0012, oi: '$3.1B' },
  { sym: 'ETH', px: 3498, ch: 2.4, fund: 0.0019, oi: '$1.7B' },
  { sym: 'SOL', px: 186.6, ch: -1.1, fund: -0.0004, oi: '$612M' },
  { sym: 'HYPE', px: 24.06, ch: 5.8, fund: 0.0031, oi: '$904M' },
  { sym: 'TSLA', px: 412.5, ch: 3.1, fund: 0.0008, oi: '$620M', venue: 'trade.xyz' },
  { sym: 'GOLD', px: 2748, ch: 0.4, fund: 0.0002, oi: '$310M', venue: 'trade.xyz' },
]
export const memeMarkets = [
  { sym: 'PENGU', mc: '$2.1B', px: 0.0334, ch: 18.2, holders: '712k', age: '11mo', score: 'Pass' },
  { sym: 'PEPE', mc: '$8.0B', px: 0.0000191, ch: 12.4, holders: '421k', age: '2y', score: 'Pass' },
  { sym: 'WIF', mc: '$1.4B', px: 1.42, ch: -3.2, holders: '201k', age: '1.9y', score: 'Pass' },
  { sym: 'GIGA', mc: '$312M', px: 0.031, ch: 41.0, holders: '58k', age: '1.2y', score: 'Warn' },
  { sym: 'HERM', mc: '$4.2M', px: 0.0042, ch: 212.0, holders: '1.9k', age: '6h', score: 'Fail' },
]

// Positions shown at the top of Earn and Trade. Actions approved in chat prepend to these.
export const earnPositionsSeed = [
  { proto: 'Pendle', name: 'PT-USDe Dec-26', usd: 6200, apy: 18.4, earned: 214, by: 'Agent', when: 'Oct 22', },
  { proto: 'Aave', name: 'USDC supply', usd: 5100, apy: 5.6, earned: 96, by: 'Agent', when: 'Oct 9' },
  { proto: 'Ethena', name: 'sUSDe', usd: 3500, apy: 11.2, earned: 118, by: 'You', when: 'Sep 30' },
]

export const tradePositionsSeed = [
  { sym: 'HYPE', title: 'HYPE-PERP', side: 'Long 3x', entry: 22.41, mark: 24.06, liq: 15.68, tp: 27.5, sl: 21, pnl: 530, by: 'Agent', when: 'Oct 24' },
  { sym: 'ETH', title: 'ETH-PERP', side: 'Short 1x', entry: 3520, mark: 3498, liq: null, tp: null, sl: 3650, pnl: 32, by: 'Agent', when: 'Oct 25' },
  { sym: 'SOL', title: 'SOL', side: 'Spot', entry: 172.4, mark: 186.6, liq: null, tp: 220, sl: 160, pnl: 178, by: 'You', when: 'Oct 2' },
]

// Trading strategies running for the user; created in chat or inside a project.
export const strategies = [
  { id: 'arb', name: 'HYPE funding arb', sym: 'HYPE', status: 'Running', capital: 5200, pnl: 1204, win: '78%', source: 'From HYPE perp scripts',
    steps: [{ t: 'Watch', d: 'Every 60s' }, { t: 'Trigger', d: 'Funding > 0.03%/h' }, { t: 'Spot + short', d: 'Same size' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }, { t: 'Exit', d: 'Funding < 0.01%' }],
    trades: [['Opened hedge 2,600 HYPE', '2h ago', '+$12.60'], ['Closed hedge', 'Oct 24', '+$41.20'], ['Opened hedge 2,400 HYPE', 'Oct 23', '+$38.90']] },
  { id: 'breakout', name: 'ETH breakout', sym: 'ETH', status: 'Running', capital: 3000, pnl: 286, win: '54%', source: 'From chat',
    steps: [{ t: 'Watch 4H', d: 'Range high' }, { t: 'Breakout', d: 'Close above + volume' }, { t: 'Long 3x', d: 'TP +6%, SL −2%' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }],
    trades: [['Long ETH 3x', 'Oct 25', '+$182'], ['Stopped out', 'Oct 21', '−$64']] },
  { id: 'dca', name: 'Weekly ETH DCA', sym: 'ETH', status: 'Running', capital: 2000, pnl: 96, win: '—', source: 'From chat',
    steps: [{ t: 'Every Monday', d: '09:00' }, { t: 'Swap 500 USDC', d: 'Best route' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }, { t: 'Hold', d: 'Vault wallet' }],
    trades: [['Bought 0.143 ETH', 'Oct 20', ''], ['Bought 0.146 ETH', 'Oct 13', '']] },
  { id: 'sniper', name: 'Meme sniper', sym: 'PENGU', status: 'Paused', capital: 300, pnl: -118, win: '31%', source: 'From Meme auto-trader',
    steps: [{ t: 'New pair', d: 'Liquidity > $200k' }, { t: 'Holder check', d: 'Bubble map' }, { t: 'Hazard scan', d: 'Every order', kind: 'guard' }, { t: 'Buy $100', d: 'Sell at 2x' }],
    trades: [['Sold GIGA', 'Oct 18', '−$42'], ['Skipped HERM: dev cluster 61%', 'Oct 17', '']] },
]

export const arbStrategies = [
  strategies[0],
  { id: 'loop', name: 'sUSDe / USDC loop', sym: 'USDe', status: 'Running', capital: 4000, pnl: 162, win: '—', source: 'From chat',
    steps: [{ t: 'Supply sUSDe', d: 'Aave' }, { t: 'Borrow USDC', d: '70% LTV' }, { t: 'Buy sUSDe', d: 'Repeat 2x' }, { t: 'Hazard scan', d: 'Health > 1.3', kind: 'guard' }, { t: 'Unwind', d: 'If spread < 3%' }],
    trades: [['Rebalanced loop', 'Oct 24', ''], ['Opened 2x loop', 'Oct 15', '']] },
  { id: 'dex', name: 'Stablecoin DEX spread', sym: 'USDC', status: 'Running', capital: 1500, pnl: 58, win: '91%', source: 'From Yield ladder',
    steps: [{ t: 'Scan', d: '6 DEXs, every block' }, { t: 'Spread > 0.15%', d: 'After gas' }, { t: 'Buy + sell', d: 'One transaction' }, { t: 'Hazard scan', d: 'Simulate first', kind: 'guard' }],
    trades: [['USDC→USDT→USDC', '1h ago', '+$2.10'], ['USDC→DAI→USDC', '5h ago', '+$1.40']] },
]

export const arbOpps = [
  { name: 'SOL funding arb', sym: 'SOL', apr: 21.4, note: 'Funding 0.024%/h' },
  { name: 'PT-USDe basis', sym: 'USDe', apr: 9.8, note: '18.4% fixed vs 8.6% borrow' },
  { name: 'ETH CEX–DEX spread', sym: 'ETH', apr: 6.2, note: '0.08% avg spread' },
]

export const airdrops = [
  { name: 'Monad', done: 3, total: 7, pts: '1,000', est: '$400–1,200', wallets: 3, funds: 450, loss: 6, status: 'Farming', from: 'From chat' },
  { name: 'MegaETH', done: 5, total: 6, pts: '8,400', est: '$300–900', wallets: 3, funds: 1800, loss: 9, status: 'Farming', from: 'From Airdrops S3' },
  { name: 'Berachain', done: 4, total: 4, pts: '4,800', est: 'Claim Nov 4', wallets: 2, funds: 700, loss: 3, status: 'Claimable soon', from: 'From Airdrops S3' },
]

export const airdropOpps = [
  { name: 'Hyperliquid S3', logo: 'Hyperliquid', note: 'Volume and HLP', est: '$200–800',
    d: { histLabel: 'Points per week, all users (M)', hist: [12, 18, 15, 21], avg: '16.5M', stats: [['Est. value', '$200–800'], ['Cost', '~$40 in fees'], ['Ends', 'Dec 31'], ['Sybil checks', 'Strict']], note: 'Rewards real volume. Wash trading gets filtered out.' } },
  { name: 'Polymarket', logo: 'Polymarket', note: 'Weekly predictions', est: 'Unknown',
    d: { histLabel: 'Weekly volume ($M)', hist: [1800, 2600, 2100, 2400], avg: '$2.2B', stats: [['Est. value', 'Unknown'], ['Cost', 'Your bets'], ['Ends', 'Not announced'], ['Sybil checks', 'Unknown']], note: 'No token is confirmed. Activity is the only signal.' } },
  { name: 'Kamino season 4', logo: 'Kamino', note: 'Supply on Solana', est: '$100–400',
    d: { histLabel: 'Points per week (M)', hist: [5, 7, 6, 8], avg: '6.5M', stats: [['Est. value', '$100–400'], ['Cost', 'Gas only'], ['Ends', 'Jan 15'], ['Sybil checks', 'Moderate']], note: 'Earn yield and points at the same time. Low effort.' } },
]

// Every kind of opportunity Hermit can find or act on (researched Oct 2026; returns are approximate).
export const oppCatalog = {
  Yield: [
    { name: 'Stablecoin savings', ex: 'Sky sUSDS, Spark', logo: 'USDC', ret: '~3.5%', risk: 'Low', start: true },
    { name: 'Stablecoin lending', ex: 'Aave, Morpho, Compound', logo: 'Aave', ret: '3.5–9%', risk: 'Low', start: true },
    { name: 'Tokenized treasuries', ex: 'Ondo USDY, BlackRock BUIDL', logo: 'Ondo', ret: '3.5–4.7%', risk: 'Low', start: true },
    { name: 'Liquid staking', ex: 'Lido, Jito', logo: 'Lido', ret: '2.5–8%', risk: 'Low', start: true },
    { name: 'Synthetic dollar', ex: 'Ethena sUSDe', logo: 'Ethena', ret: 'Varies', risk: 'Medium', start: true },
    { name: 'Restaking', ex: 'EigenLayer, ether.fi', logo: 'EigenLayer', ret: '2–5% + points', risk: 'Medium', start: true },
    { name: 'Fixed yield', ex: 'Pendle PT', logo: 'Pendle', ret: '5–20%', risk: 'Medium', start: true },
    { name: 'Perp LP vaults', ex: 'Hyperliquid HLP, GMX', logo: 'Hyperliquid', ret: '10–20%', risk: 'Medium', start: true },
    { name: 'Concentrated LP', ex: 'Uniswap, Aerodrome, Meteora', logo: 'Uniswap', ret: '5–50%', risk: 'High', start: true },
    { name: 'Options vaults', ex: 'Derive', logo: 'Derive', ret: '5–20%', risk: 'High' },
    { name: 'Lending loops', ex: 'Morpho + Pendle loops', logo: 'Morpho', ret: 'Up to ~25%', risk: 'High' },
    { name: 'Validator nodes', ex: 'ETH validators, DePIN', logo: 'ETH', ret: '~3%', risk: 'Medium' },
  ],
  Trading: [
    { name: 'Perps', ex: 'Hyperliquid, GMX, Jupiter', logo: 'Hyperliquid', ret: 'Unbounded', risk: 'High', start: true },
    { name: 'Spot DCA', ex: 'Jupiter, CoW Swap', logo: 'Jupiter', ret: 'Market', risk: 'Medium', start: true },
    { name: 'Copy trading', ex: 'Hyperliquid vaults', logo: 'Hyperliquid', ret: 'Varies', risk: 'High' },
    { name: 'Prediction markets', ex: 'Polymarket, Kalshi', logo: 'Polymarket', ret: 'Event odds', risk: 'Medium' },
    { name: 'Rate trading', ex: 'Pendle Boros', logo: 'Pendle', ret: 'Rate based', risk: 'Medium' },
    { name: 'Meme launches', ex: 'Pump.fun, LetsBonk, Zora', logo: 'Pump.fun', ret: 'Extreme', risk: 'High' },
  ],
  Arbitrage: [
    { name: 'Cash and carry', ex: 'Long spot, short perp', logo: 'HYPE', ret: '5–15%', risk: 'Low', start: true },
    { name: 'Cross-venue funding', ex: 'Hyperliquid vs Binance', logo: 'Hyperliquid', ret: 'Small spreads', risk: 'Medium' },
    { name: 'DEX price gaps', ex: 'Uniswap, Aerodrome, Jupiter', logo: 'Uniswap', ret: 'bps per trade', risk: 'Medium' },
    { name: 'Stablecoin depeg', ex: 'Curve, issuer redemptions', logo: 'USDC', ret: 'On events', risk: 'Medium' },
    { name: 'Prediction market gaps', ex: 'Polymarket vs Kalshi', logo: 'Polymarket', ret: 'Few %', risk: 'Medium' },
    { name: 'Liquidations', ex: 'Aave, Morpho', logo: 'Aave', ret: '5–10% bonus', risk: 'Medium' },
  ],
  Airdrops: [
    { name: 'Points programs', ex: 'Symbiotic, ether.fi', logo: 'Symbiotic', ret: 'Unknown', risk: 'Medium', start: true },
    { name: 'Retro farming', ex: 'New chains and bridges', logo: 'Monad', ret: 'Varies', risk: 'Medium', start: true },
    { name: 'Token sales', ex: 'Legion, Echo, MetaDAO', logo: 'Legion', ret: 'Varies', risk: 'High' },
    { name: 'Launchpad whitelists', ex: 'Legion Score, Kaito', logo: 'Kaito', ret: 'Varies', risk: 'High' },
    { name: 'Attention mining', ex: 'Kaito, Galxe', logo: 'Kaito', ret: 'Points', risk: 'Low' },
    { name: 'Bug bounties', ex: 'Immunefi, Code4rena', logo: 'Immunefi', ret: 'Bounties', risk: 'Low' },
    { name: 'AI data for points', ex: 'Label data, red-team agents', logo: 'Hermit', ret: 'Points', risk: 'Low' },
  ],
}

// Public stats shown when an Earn opportunity is expanded (illustrative, modeled on DefiLlama-style data).
export const oppDetails = {
  'PT-USDe': { hist: [16.1, 18.9, 17.2, 18.4], avg: '17.6%', dd: '−1.2%', tvl: '$1.2B', age: '2.4 yrs', audits: 'Ackee, Dedaub', exit: 'At maturity or sell PT', fee: 'None', note: 'Fixed rate. Price can dip before maturity if USDe wobbles.' },
  sUSDe: { hist: [27, 9.5, 14.1, 11.2], avg: '12.8%', dd: '−0.4%', tvl: '$5.3B', age: '2.6 yrs', audits: 'Spearbit, Pashov', exit: '7-day cooldown', fee: 'None', note: 'Yield follows perp funding and drops when markets cool.' },
  'HLP vault': { hist: [22, 11, 18, 14.7], avg: '15.9%', dd: '−6.8%', tvl: '$410M', age: '2.8 yrs', audits: 'Zellic', exit: '4-day lockup', fee: 'None', note: 'Market-making vault. Lost 6.8% in one bad week in 2025.' },
  'USDC vault': { hist: [6.8, 7.4, 8.2, 7.9], avg: '7.5%', dd: '0%', tvl: '$1.6B', age: '2.1 yrs', audits: 'Spearbit, Cantina', exit: 'Anytime', fee: '10% of yield', note: 'Curated lending. No losses since launch.' },
  'USDC supply': { hist: [4.2, 5.1, 6.3, 5.6], avg: '5.4%', dd: '0%', tvl: '$4.1B', age: '3.5 yrs', audits: '9 firms', exit: 'Anytime', fee: 'None', note: 'The longest-running lending market. Lowest risk here.' },
  kHYPE: { hist: [2.6, 2.8, 3.0, 2.9], avg: '2.8%', dd: 'Tracks HYPE', tvl: '$1.0B', age: '1.1 yrs', audits: 'Spearbit', exit: 'Swap or 7-day unstake', fee: '10% of rewards', note: 'About 80% of all HYPE staking. Rewards paid in HYPE.' },
  sUSDai: { hist: [9.8, 11.5, 13.1, 12.4], avg: '11.7%', dd: '0%', tvl: '$491M', age: '0.9 yrs', audits: 'Sherlock', exit: '30-day queue', fee: 'None', note: 'Lends against GPUs. Newer, with credit risk on the borrowers.' },
  sUSDf: { hist: [10.2, 9.4, 8.8, 9.0], avg: '9.3%', dd: '−0.6%', tvl: '$1.8B', age: '1.4 yrs', audits: 'Zellic, Pashov', exit: '7-day cooldown', fee: 'None', note: 'Overcollateralized dollar. Yield from basis and staking.' },
  syrupUSDC: { hist: [8.1, 8.9, 8.4, 8.6], avg: '8.5%', dd: '0%', tvl: '$1.5B', age: '1.8 yrs', audits: 'Spearbit, Three Sigma', exit: 'Queue, days', fee: 'In rate', note: 'Loans to trading firms. Overcollateralized, but still credit risk.' },
  'USDC lending': { hist: [5.9, 6.4, 7.2, 6.8], avg: '6.6%', dd: '0%', tvl: '$2.6B', age: '0.8 yrs', audits: 'Fluid, OtterSec', exit: 'Anytime', fee: 'None', note: 'Built on Fluid. The biggest Solana lender by borrows.' },
  'USDC market': { hist: [12.5, 10.8, 9.1, 9.6], avg: '10.5%', dd: '0%', tvl: '$75M', age: '0.9 yrs', audits: 'Trail of Bits', exit: 'Anytime', fee: 'None', note: 'Leading Monad lender. Small TVL, so rates move fast.' },
  iBERA: { hist: [18, 14, 12.5, 11.8], avg: '14.1%', dd: 'Tracks BERA', tvl: '$1.5B', age: '1.7 yrs', audits: 'Spearbit', exit: 'Swap or unstake', fee: '5% of rewards', note: 'Berachain TVL is down about 70% from its peak.' },
  USDY: { hist: [4.4, 4.3, 4.2, 4.2], avg: '4.3%', dd: '0%', tvl: '$1B', age: '2.6 yrs', audits: 'Code4rena, Cyfrin', exit: 'Daily redemption', fee: 'In rate', note: 'Backed by short-term US treasuries.' },
  stETH: { hist: [3.4, 3.2, 3.0, 3.1], avg: '3.2%', dd: '−7% vs ETH (2022)', tvl: '$27B', age: '5 yrs', audits: '15+ firms', exit: 'Queue, 1 to 5 days', fee: '10% of rewards', note: 'Tracks ETH price. Depegged briefly in 2022.' },
  JLP: { hist: [55, 28, 41, 32.5], avg: '38.1%', dd: '−22%', tvl: '$1.4B', age: '2.7 yrs', audits: 'OtterSec, Offside', exit: 'Anytime', fee: 'Mint/burn fee', note: 'Holds SOL, ETH and BTC. Falls when crypto falls.' },
  staking: { hist: [2.6, 2.5, 2.4, 2.4], avg: '2.5%', dd: 'Tracks HYPE', tvl: '$9B', age: '1.6 yrs', audits: 'Zellic', exit: '7-day unstake', fee: 'Validator fee', note: 'Rewards are paid in HYPE, so the value moves with its price.' },
  'SOL funding arb': { hist: [18, 26, 15, 21.4], avg: '19.8%', dd: '−1.1%', tvl: 'Capacity $2M', age: 'Live 41 days', audits: 'Hyperliquid', exit: 'Anytime', fee: 'Trading fees', note: 'Turns negative when funding flips. Exits on its own.' },
  'PT-USDe basis': { hist: [8.1, 10.4, 9.2, 9.8], avg: '9.4%', dd: '−0.9%', tvl: 'Capacity $5M', age: 'Live 22 days', audits: 'Pendle, Aave', exit: 'At maturity', fee: 'Borrow interest', note: 'Earns the gap between fixed yield and borrow cost.' },
  'ETH CEX–DEX spread': { hist: [4.8, 7.1, 5.5, 6.2], avg: '5.9%', dd: '−0.3%', tvl: 'Capacity $500k', age: 'Live 63 days', audits: 'Uniswap', exit: 'Anytime', fee: 'Gas', note: 'Small, steady trades. Competes with MEV bots.' },
}

// Payments running on autopilot, soonest first.
export const liveSchedule = [
  { to: 'Perplexity', what: 'Per call', when: 'Now', amt: 0.41, rail: 'x402', live: true },
  { to: 'OpenAI', what: 'API top-up', when: 'In 2 days', amt: 20, rail: 'x402' },
  { to: 'Figma', what: 'Pro plan', when: 'Tomorrow', amt: 45, rail: 'Bank' },
  { to: 'Vercel', what: 'Pro team', when: 'Oct 30', amt: 20, rail: 'Bank' },
  { to: 'Hyperliquid', what: 'Margin top-up', when: 'If needed', amt: 500, rail: 'USDC' },
]
export const next7Days = [0.4, 45, 0, 20, 20, 0, 0]

export const contacts = [
  { name: 'alice.eth', addr: '0x2b9…e04' },
  { name: 'bob.base.eth', addr: '0x91c…7aa' },
  { name: 'Mom', addr: 'mom@gmail.com' },
]

export const bills = [
  { to: 'Figma', what: 'Pro plan', amt: 45, due: 'Tomorrow', bank: 'Figma, Inc.' },
  { to: 'Vercel', what: 'Pro team', amt: 20, due: 'Oct 30', bank: 'Vercel Inc.' },
  { to: 'Landlord', what: 'November rent', amt: 2400, due: 'Nov 3', bank: 'Chase 4821' },
  { to: 'Notion', what: 'Plus plan', amt: 10, due: 'Nov 24', bank: 'Notion Labs' },
]

export const myApis = [
  { name: 'OpenAI', plan: 'GPT-5', used: 16.6, cap: 100, calls: '6,640 calls' },
  { name: 'Perplexity', plan: 'Sonar', used: 7.8, cap: 50, calls: '1,560 calls' },
]

export const apiCatalog = [
  { name: 'GPT-5', by: 'OpenAI', price: '$20 credits', cat: 'AI' },
  { name: 'Sonar', by: 'Perplexity', price: '$0.005 / call', cat: 'Search' },
  { name: 'Flux', by: 'Black Forest Labs', price: '$0.03 / image', cat: 'AI' },
  { name: 'Voice', by: 'ElevenLabs', price: '$5 / month', cat: 'AI' },
  { name: 'Scrape', by: 'Firecrawl', price: '$0.001 / page', cat: 'Data' },
  { name: 'Token data', by: 'Birdeye', price: '$49 / month', cat: 'Crypto' },
  { name: 'Smart money', by: 'Nansen', price: '$0.02 / call', cat: 'Crypto' },
  { name: 'SQL', by: 'Dune', price: '$0.01 / query', cat: 'Crypto' },
]

// Native gas on each chain the agent uses. txs = rough transactions left at current fees.
export const gas = [
  { chain: 'Ethereum', token: 'ETH', amt: 0.042, usd: 147, txs: 85, level: 0.55 },
  { chain: 'Base', token: 'ETH', amt: 0.006, usd: 21, txs: 2100, level: 0.9 },
  { chain: 'Arbitrum', token: 'ETH', amt: 0.0009, usd: 3, txs: 40, level: 0.12, low: true },
  { chain: 'Solana', token: 'SOL', amt: 0.35, usd: 65, txs: 70000, level: 0.8 },
  { chain: 'HyperEVM', token: 'HYPE', amt: 0.8, usd: 19, txs: 900, level: 0.6 },
  { chain: 'Polygon', token: 'POL', amt: 0.4, usd: 0.1, txs: 6, level: 0.05, low: true },
]
export const chains = ['Ethereum', 'Base', 'Arbitrum', 'Solana', 'HyperEVM', 'Polygon']

// Prediction markets shown in Trade. yes = price of a Yes share (probability).
export const predictions = [
  { q: 'Fed cuts rates in December?', venue: 'Kalshi', yes: 62, vol: '$48M', ends: 'Dec 10' },
  { q: 'BTC above $120k on Dec 31?', venue: 'Polymarket', yes: 41, vol: '$22M', ends: 'Dec 31' },
  { q: 'ETH ETF staking inflows over $1B in November?', venue: 'Opinion', yes: 55, vol: '$3.1M', ends: 'Nov 30' },
  { q: 'HYPE in the top 10 by market cap this year?', venue: 'Predict.fun', yes: 33, vol: '$1.2M', ends: 'Dec 31' },
  { q: 'SOL above $200 this Friday?', venue: 'Limitless', yes: 28, vol: '$0.4M', ends: 'Fri' },
]
export const perpVenues = ['Hyperliquid', 'Lighter', 'Aster', 'Paradex', 'Extended', 'trade.xyz']

// Long-term memory (hermit.md). Edited in Settings, or from chat: "add … to your long-term memory".
export const memorySeed = [
  'Show RSI, MACD and the 50/200 EMA on every chart',
  'Never use more than 5x leverage',
  'Prefer audited protocols for stablecoin yield',
  'Keep replies short, numbers first',
]

// Monthly burn per project: auto-payments the user set up (APIs, subscriptions, gas refills).
export const projectBurn = {
  'Dev: HYPE news bot': [['Perplexity Sonar', 20], ['OpenAI API', 38], ['Vercel hosting', 20]],
  'HYPE perp scripts': [['Hyperliquid data feed', 25], ['VPS for bots', 12]],
  'Airdrop farming S3': [['Gas refills, 3 wallets', 45], ['Galxe Plus', 9]],
  'Meme auto-trader': [['Bubblemaps API', 15]],
  'Research: AI agent tokens': [['Kaito Pro', 33]],
}

// Expected monthly gain, re-estimated by Hermit every 24 hours from the last 30 days.
export const projectForecast = {
  'Dev: HYPE news bot': { monthly: 120, basis: '12 subscribers at $10', updated: 3 },
  'Stablecoin yield ladder': { monthly: 104, basis: '7.7% blended APY on $16,300', updated: 5 },
  'HYPE perp scripts': { monthly: 640, basis: '30-day PnL, 78% win rate', updated: 2 },
  'Airdrop farming S3': { monthly: 210, basis: 'Est. airdrop value over 6 months', updated: 9 },
  'Meme auto-trader': { monthly: -40, basis: 'Last 30 days of trades', updated: 7 },
  'Presale tracker': { monthly: 180, basis: 'Vesting unlocks this month', updated: 11 },
}

// Where each project's gain comes from (30 days).
export const projectGains = {
  'Dev: HYPE news bot': [['Subscriptions, 12 friends', 120]],
  'Stablecoin yield ladder': [['Morpho USDC vault', 384], ['Aave USDC', 196], ['Pendle PT-USDe', 62]],
  'HYPE perp scripts': [['Funding arb', 1204], ['Breakout trades', 286]],
  'Airdrop farming S3': [['Claimed so far', 0], ['Points, est. value', 210]],
  'Meme auto-trader': [['Winning trades', 212], ['Losing trades', -330]],
  'Presale tracker': [['Kaito unlock', 640]],
}

// What the agent manages, two ways: by underlying asset, or by the project the money sits in.
export const aumByAsset = [
  { label: 'USDC', value: 22400, color: '#2775CA', logo: 'USDC' },
  { label: 'ETH', value: 9950, color: '#121212', logo: 'ETH' },
  { label: 'SOL', value: 6550, color: '#8E73CF', logo: 'SOL' },
  { label: 'HYPE', value: 6200, color: '#4E1F96', logo: 'HYPE' },
  { label: 'Memes', value: 1900, color: '#C9BFE6', logo: 'PEPE' },
  { label: 'Other', value: 1320, color: '#E4E4E2' },
]
export const aumByProject = [
  { label: 'Stablecoin yield ladder', value: 16300, color: '#121212' },
  { label: 'HYPE perp scripts', value: 10200, color: '#4E1F96' },
  { label: 'Airdrop farming S3', value: 2950, color: '#8E73CF' },
  { label: 'Presale tracker', value: 1250, color: '#B7A6E8' },
  { label: 'Meme auto-trader', value: 320, color: '#C9BFE6' },
  { label: 'Not in a project', value: 17300, color: '#E4E4E2' },
]
