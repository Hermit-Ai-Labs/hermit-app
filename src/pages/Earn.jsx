import { useState } from 'react'
import { Tag, Bug, ShieldQuestion, ChevronRight, ChevronDown, Sparkles } from 'lucide-react'
import Mark from '../components/Mark'
import StrategySheet from '../components/StrategySheet'
import { baseChecks } from '../components/Approval'
import { earnOpps, arbStrategies, arbOpps, airdrops, airdropOpps, oppDetails } from '../data'
import { AreaChart } from '../components/Charts'
import { useApp } from '../App'
import { threadFor } from '../threads'
import ExploreMore from '../components/ExploreMore'
import Tabs, { usePageTab } from '../components/Tabs'
import { oppCatalog } from '../data'

const TABS = [['positions', 'Positions'], ['defi', 'DeFi'], ['arb', 'Arbitrage'], ['airdrops', 'Airdrops'], ['reverse', 'Reverse']]

export default function Earn() {
  const { earnPos } = useApp()
  const [tab, setTab] = usePageTab(TABS)
  const tabs = TABS.map(([k, l]) => [k, l, k === 'positions' ? earnPos.length + arbStrategies.length + airdrops.length : null])
  return (
    <div className="page">
      <div className="page-head tabbed"><h1>Earn</h1></div>
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'positions' && <Positions />}
      {tab === 'defi' && <DeFi />}
      {tab === 'arb' && <Arbitrage />}
      {tab === 'airdrops' && <Airdrops />}
      {tab === 'reverse' && <ReverseBox />}
      {['defi', 'arb', 'airdrops'].includes(tab) && <ExploreMore label="opportunities" items={Object.entries(oppCatalog).flatMap(([g, list]) => list.map((o) => ({ name: o.name, logo: o.logo, sub: o.ex, metric: o.ret, tag: g })))} />}
    </div>
  )
}

const FILTERS = { All: () => true, Stables: (o) => ['USDC', 'USDe', 'USDf'].includes(o.asset), ETH: (o) => o.asset === 'ETH', 'Low risk': (o) => o.risk === 'Low' }

// Everything that is already earning: deposits, arbitrage bots and airdrop farms.
function Positions() {
  const { approve, earnPos, openThread } = useApp()
  const [open, setOpen] = useState(null)
  const total = earnPos.reduce((a, p) => a + p.usd, 0)
  const apy = earnPos.reduce((a, p) => a + p.usd * p.apy, 0) / total
  return (
    <>
      <div className="stats">
        <div><div className="stat-label">Earning</div><div className="stat-value">${total.toLocaleString()}</div></div>
        <div><div className="stat-label">APY</div><div className="stat-value up">{apy.toFixed(1)}%</div></div>
        <div><div className="stat-label">Per month</div><div className="stat-value">${Math.round(total * apy / 1200).toLocaleString()}</div></div>
        <div><div className="stat-label">Earned (24h)</div><div className="stat-value up">+${(total * apy / 36500).toFixed(2)}</div></div>
      </div>

      <div className="section">
        <div className="section-title">DeFi</div>
        {earnPos.map((p, i) => (
          <div className="list-row fade-in" key={p.name + p.when + i}>
            <Mark name={p.proto} size={32} />
            <div className="grow">
              <div className="list-title">{p.name}</div>
              <div className="list-sub">{p.by} on {p.when}</div>
            </div>
            <div className="list-end"><div>${p.usd.toLocaleString()}</div><div className="small up">{p.apy}%</div></div>
            <button className="btn sm hide-m" onClick={() => approve({ kind: 'Withdraw', title: `Withdraw from ${p.name}`, success: 'Withdrawn to Main', lines: [['From', `${p.proto} ${p.name}`], ['Amount', `$${p.usd.toLocaleString()}`], ['To', 'Main wallet'], ['Arrives', p.note || 'Now']], checks: baseChecks() })}>Withdraw</button>
          </div>
        ))}
      </div>

      <div className="section">
        <div className="section-title">Arbitrage</div>
        {arbStrategies.map((st) => (
          <button className="list-row" key={st.id} onClick={() => setOpen(st)}>
            <Mark name={st.sym} size={32} />
            <div className="grow"><div className="list-title">{st.name}</div><div className="list-sub">{st.source}</div></div>
            <div className="list-end"><div className="up">+${st.pnl.toLocaleString()}</div><div className="faint small">${st.capital.toLocaleString()}</div></div>
            <ChevronRight size={16} color="var(--faint)" />
          </button>
        ))}
      </div>

      <div className="section">
        <div className="section-title">Airdrops</div>
        {airdrops.map((a) => (
          <button className="list-row" key={a.name} onClick={() => openThread(threadFor[a.name])}>
            <Mark name={a.name} size={32} />
            <div className="grow">
              <div className="list-title">{a.name}</div>
              <div className="list-sub">{a.wallets} wallets, ${a.funds.toLocaleString()} in use</div>
              <div className="bar-track" style={{ marginTop: 8, maxWidth: 220 }}><div className="bar-fill" style={{ width: `${(a.done / a.total) * 100}%` }} /></div>
            </div>
            <div className="list-end"><div>{a.done}/{a.total}</div><div className="small down">−${a.loss}</div></div>
            <ChevronRight size={16} color="var(--faint)" />
          </button>
        ))}
      </div>
      {open && <StrategySheet st={open} onClose={() => setOpen(null)} />}
    </>
  )
}

function DeFi() {
  const { approve } = useApp()
  const [f, setF] = useState('All')
  return (
    <>
      <div className="seg" style={{ marginBottom: 12 }}>{Object.keys(FILTERS).map((k) => <button key={k} className={k === f ? 'on' : ''} onClick={() => setF(k)}>{k}</button>)}</div>
      {earnOpps.filter(FILTERS[f]).map((o) => (
        <OppRow key={o.name} logo={o.proto} title={`${o.proto} ${o.name}`} isNew={o.isNew} metric={`${o.apy}%`} d={oppDetails[o.name]}
          sub={<span className={o.risk === 'Low' ? 'up' : o.risk === 'High' ? 'down' : ''} style={o.risk === 'Medium' ? { color: 'var(--amber)' } : undefined}>{o.risk} risk</span>}
          action="Deposit" onAction={() => approve({
            kind: 'Deposit', title: `Deposit into ${o.name}`, success: `Earning ${o.apy}%`,
            lines: [['Amount', `1,000 ${o.asset === 'Basket' ? 'USDC' : o.asset}`], ['APY', `${o.apy}%`], ['Withdraw', oppDetails[o.name]?.exit || 'Anytime']],
            checks: baseChecks(o.risk === 'High' ? [{ label: 'Impermanent loss', detail: 'LP can lose value versus holding', status: 'warn' }] : []),
            adds: { earn: [{ proto: o.proto, name: o.name, usd: 1000, apy: o.apy, earned: 0, by: 'You', when: 'just now' }] },
          })} />
      ))}
    </>
  )
}

function Arbitrage() {
  const { approve } = useApp()
  const capital = arbStrategies.reduce((a, s) => a + s.capital, 0)
  const pnl = arbStrategies.reduce((a, s) => a + s.pnl, 0)
  return (
    <>
      <div className="stats">
        <div><div className="stat-label">Deployed</div><div className="stat-value">${capital.toLocaleString()}</div></div>
        <div><div className="stat-label">Profit 30d</div><div className="stat-value up">+${pnl.toLocaleString()}</div></div>
        <div><div className="stat-label">Annualized</div><div className="stat-value up">{((pnl / capital) * 1200).toFixed(1)}%</div></div>
        <div><div className="stat-label">Live spreads</div><div className="stat-value">{arbOpps.length}</div></div>
      </div>
      <div className="section">
        {arbOpps.map((o) => (
          <OppRow key={o.name} logo={o.sym} title={o.name} sub={o.note} metric={`${o.apr}%`} d={oppDetails[o.name]}
            action="Start" onAction={() => approve({
              kind: 'Start strategy', title: o.name, success: 'Strategy running',
              lines: [['Capital', '2,000 USDC'], ['Est. APR', `${o.apr}%`], ['Exit', 'Automatic when the spread closes']],
              checks: baseChecks([{ label: 'Delta-neutral', detail: 'Price moves net to zero', status: 'pass' }]),
            })} />
        ))}
      </div>
    </>
  )
}

const pointTasks = [
  { icon: Tag, t: 'Label wallets', pts: '+120' },
  { icon: Bug, t: 'Report bugs', pts: 'Up to 2,000' },
  { icon: ShieldQuestion, t: 'Red-team the agent', pts: 'Up to 5,000' },
]

function Airdrops() {
  const { toast } = useApp()
  const sum = (k) => airdrops.reduce((a, x) => a + x[k], 0)
  return (
    <>
      <div className="stats">
        <div><div className="stat-label">Wallets running</div><div className="stat-value">{sum('wallets')}</div></div>
        <div><div className="stat-label">Funds in use</div><div className="stat-value">${sum('funds').toLocaleString()}</div></div>
        <div><div className="stat-label">Current loss</div><div className="stat-value down">−${sum('loss')}</div></div>
        <div><div className="stat-label">Est. value</div><div className="stat-value up">$1.1k–3.3k</div></div>
      </div>

      <div className="section">
        {airdropOpps.map((o) => (
          <OppRow key={o.name} logo={o.logo} title={o.name} sub={o.note} metric={o.est} d={o.d}
            action="Farm" onAction={() => toast(`Farming ${o.name}. Find it in Automations`)} />
        ))}
      </div>

      <div className="section">
        <div className="section-title">Hermit points</div>
        <div className="grid g3">
          {pointTasks.map((p) => (
            <button key={p.t} className="card row" style={{ gap: 12 }} onClick={() => toast(`${p.t}: ${p.pts} pts`)}>
              <p.icon size={18} strokeWidth={1.75} />
              <div className="grow"><div style={{ fontWeight: 500 }}>{p.t}</div><div className="muted small">{p.pts} pts</div></div>
            </button>
          ))}
        </div>
      </div>
    </>
  )
}

// Expandable opportunity row: tap to see public stats and history, then act or ask about it.
function OppRow({ logo, title, sub, metric, d, action, onAction, isNew }) {
  const { askAbout } = useApp()
  const [open, setOpen] = useState(false)
  return (
    <div className="opp">
      <button className="list-row" onClick={() => setOpen(!open)} aria-expanded={open}>
        <Mark name={logo} size={32} />
        <div className="grow"><div className="list-title">{title}{isNew && <span className="new-tag">New</span>}</div><div className="list-sub">{sub}</div></div>
        <div className="list-end" style={{ fontWeight: 500 }}>{metric}</div>
        <ChevronDown size={16} color="var(--faint)" style={{ transform: open ? 'rotate(180deg)' : 'none', transition: 'transform .15s' }} />
      </button>
      {open && d && (
        <div className="opp-detail fade-in">
          {d.hist && (
            <div>
              <div className="row between small" style={{ marginBottom: 6 }}><span className="muted">{d.histLabel || 'APY, last 90 days'}</span><span className="num">Avg {d.avg}</span></div>
              <AreaChart data={expand(d.hist)} height={80} id={`h-${title.replace(/\W/g, '')}`} />
            </div>
          )}
          <div className="kv" style={{ marginTop: 14 }}>
            {d.stats ? d.stats.map(([k, v]) => <div key={k}><span>{k}</span><b>{v}</b></div>) : <>
              <div><span>Max drawdown</span><b>{d.dd}</b></div>
              <div><span>TVL</span><b>{d.tvl}</b></div>
              <div><span>Live for</span><b>{d.age}</b></div>
              <div><span>Withdraw</span><b>{d.exit}</b></div>
              <div><span>Audits</span><b>{d.audits}</b></div>
              <div><span>Fees</span><b>{d.fee}</b></div>
            </>}
          </div>
          <p className="muted small" style={{ marginTop: 12 }}>{d.note}</p>
          <div className="row" style={{ marginTop: 14, gap: 8 }}>
            <button className="btn sm primary" onClick={onAction}>{action}</button>
            <button className="btn sm brand" onClick={() => askAbout({ q: `Is ${title} a good fit for me?`, a: `${title}: ${d.note} 90-day average ${d.avg || metric}, worst drawdown ${d.dd || 'none recorded'}. With $8,200 idle, I would keep it under 20% of your stablecoins.` })}><Sparkles size={13} /> Ask</button>
          </div>
          <div className="faint small" style={{ marginTop: 10 }}>Illustrative figures for the demo</div>
        </div>
      )}
    </div>
  )
}

// Smooth a few points into a 90-day series for the mini chart.
function expand(pts) {
  const out = []
  for (let i = 0; i < pts.length - 1; i++) for (let k = 0; k < 30; k++) out.push(pts[i] + (pts[i + 1] - pts[i]) * (k / 30) + Math.sin((i * 30 + k) / 3) * 0.4)
  return out
}

// Paste any vault or wallet to see how its yield is actually made.
const SAMPLE_VAULTS = [
  { proto: 'Morpho', name: 'Gauntlet USDC Prime', addr: '0x9c4e…a71b', apy: '24.1%' },
  { proto: 'Pendle', name: 'sUSDe Dec 26 loop', addr: '0x3f81…02cd', apy: '31.6%' },
  { proto: 'Hyperliquid', name: 'HLP vault', addr: '0xdfc2…7a10', apy: '18.4%' },
  { proto: 'Ethena', name: 'USDe basis vault', addr: '0x77a0…e14f', apy: '12.9%' },
]

// Paste any vault or wallet and Hermit explains where the yield comes from, then rebuilds it safer.
function ReverseBox() {
  const { go } = useApp()
  const [v, setV] = useState('')
  const run = (addr) => { go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: `Reverse engineer this 24% USDC vault: ${addr || v || '0x9c4e…a71b'}` })), 50) }
  return (
    <>
      <p className="muted" style={{ marginBottom: 14, lineHeight: 1.6 }}>Paste a vault or wallet. Hermit splits the yield by source, stress-tests it and rebuilds it with less risk.</p>
      <div className="row" style={{ gap: 8 }}>
        <input className="tx grow" style={{ height: 40, padding: '0 12px', outline: 0, fontSize: 14, minWidth: 0 }} placeholder="Paste a vault or wallet address" value={v}
          onChange={(e) => setV(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && run()} />
        <button className="btn brand" style={{ height: 40 }} onClick={() => run()}>Analyze</button>
      </div>
      <div className="section">
        <div className="section-title">High-yield vaults to try</div>
        {SAMPLE_VAULTS.map((x) => (
          <button className="list-row" key={x.addr} onClick={() => run(x.addr)}>
            <Mark name={x.proto} size={32} />
            <div className="grow"><div className="list-title">{x.name}</div><div className="list-sub mono">{x.addr}</div></div>
            <div className="list-end up">{x.apy}</div>
            <ChevronRight size={16} color="var(--faint)" />
          </button>
        ))}
      </div>
    </>
  )
}
