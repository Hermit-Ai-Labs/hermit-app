import { useEffect, useState } from 'react'
import { Fingerprint, Sparkles, ArrowDown, ChevronRight, ChevronDown, Plus, Search, ArrowUp } from 'lucide-react'
import { CandleChart, MiniCandles, BubbleMap, FlowDiagram } from '../components/Charts'
import Mark from '../components/Mark'
import { baseChecks } from '../components/Approval'
import { perpMarkets, memeMarkets, candles, walk, strategies, predictions, perpVenues } from '../data'
import { useApp } from '../App'
import StrategySheet from '../components/StrategySheet'
import ExploreMore from '../components/ExploreMore'
import Tabs, { usePageTab } from '../components/Tabs'

const TABS = [['positions', 'Positions'], ['markets', 'Markets'], ['strategies', 'Strategies']]
const KINDS = { perps: 'Perps', spot: 'Spot', memes: 'Memes', predict: 'Predictions' }

export default function Trade() {
  const { chartMarks, tradePos } = useApp()
  const [tab, setTab] = usePageTab(TABS)
  const [kind, setKind] = useState('perps')
  // When the assistant draws on the chart, bring the chart into view.
  useEffect(() => { if (chartMarks.length) { setTab('markets'); setKind('perps') } }, [chartMarks])
  const tabs = TABS.map(([k, l]) => [k, l, k === 'positions' ? tradePos.length : k === 'strategies' ? strategies.filter((s) => s.status === 'Running').length : null])
  return (
    <div className={`page ${tab === 'markets' ? 'wide' : ''}`}>
      <div className="page-head tabbed"><h1>Trade</h1><span className="muted num">$14,010 <span className="up">+$740</span></span></div>
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'positions' && <TradingPortfolio />}
      {tab === 'strategies' && <Strategies />}
      {tab === 'markets' && (
        <>
          <div className="seg" style={{ marginBottom: 16 }}>{Object.entries(KINDS).map(([k, v]) => <button key={k} className={kind === k ? 'on' : ''} onClick={() => setKind(k)}>{v}</button>)}</div>
          {kind === 'spot' ? <Spot /> : kind === 'perps' ? <Perps /> : kind === 'memes' ? <Memes /> : <Predictions />}
          <ExploreMore label="markets" items={MORE_MARKETS} />
        </>
      )}
    </div>
  )
}

const ORDERS = [
  { sym: 'HYPE', what: 'Limit buy 120 HYPE', px: '$22.80', by: 'Agent', when: 'Oct 26' },
  { sym: 'BTC', what: 'Stop sell 0.02 BTC', px: '$108,500', by: 'You', when: 'Oct 21' },
]
const FILLS = [
  { sym: 'HYPE', what: 'Bought 210 HYPE', px: '$22.41', pnl: null, when: 'Oct 24' },
  { sym: 'ETH', what: 'Sold 0.6 ETH short', px: '$3,520', pnl: null, when: 'Oct 25' },
  { sym: 'SOL', what: 'Closed SOL long', px: '$191.20', pnl: 212, when: 'Oct 19' },
  { sym: 'BTC', what: 'Closed BTC short', px: '$111,900', pnl: -64, when: 'Oct 15' },
]

function TradingPortfolio() {
  const { approve, tradePos } = useApp()
  const pct = (v, p) => `${v > p.mark ? '+' : '−'}${Math.abs(((v - p.mark) / p.mark) * 100).toFixed(1)}%`
  const editStops = (p) => approve({
    kind: 'Update orders', title: `Move ${p.title} stop to breakeven`, success: 'Stop updated',
    lines: [['Stop-loss', `$${p.sl} → $${p.entry}`], ['Take-profit', p.tp ? `$${p.tp}` : 'None'], ['Type', 'Reduce-only']],
    checks: baseChecks(), result: { title: `${p.title} stop at breakeven`, rows: [['Stop-loss', `$${p.entry}`], ['Locked in', 'No loss possible']] },
  })
  return (
    <>
      <div className="stats">
        <div><div className="stat-label">Trading balance</div><div className="stat-value">$14,010</div></div>
        <div><div className="stat-label">Unrealized</div><div className="stat-value up">+$740</div></div>
        <div><div className="stat-label">Today</div><div className="stat-value up">+$126</div></div>
        <div><div className="stat-label">Margin used</div><div className="stat-value">38%</div></div>
      </div>
      <div className="section">
        <div className="section-title">Open positions</div>
        {tradePos.map((p) => (
          <div className="list-row" key={p.title} style={{ alignItems: 'flex-start' }}>
            <Mark name={p.sym} size={32} />
            <div className="grow">
              <div className="list-title">{p.title} <span className="muted" style={{ fontWeight: 400 }}>{p.side}</span></div>
              <div className="list-sub num">Entry ${p.entry}{p.liq ? `, liq $${p.liq}` : ''}</div>
              <div className="list-sub">{p.by} on {p.when}</div>
              <div className="row wrap" style={{ gap: 6, marginTop: 8 }}>
                <span className={`stop ${p.tp ? 'tp' : 'none'}`}>{p.tp ? `TP $${p.tp} (${pct(p.tp, p)})` : 'No TP'}</span>
                <span className={`stop ${p.sl ? 'sl' : 'none'}`}>{p.sl ? `SL $${p.sl} (${pct(p.sl, p)})` : 'No SL'}</span>
              </div>
            </div>
            <div className="stack" style={{ gap: 8, alignItems: 'flex-end' }}>
              <div className={`list-end ${p.pnl >= 0 ? 'up' : 'down'}`}>{p.pnl >= 0 ? '+' : '−'}${Math.abs(p.pnl)}</div>
              <button className="btn sm" onClick={() => editStops(p)}>Edit</button>
            </div>
          </div>
        ))}
      </div>
      <div className="section">
        <div className="section-title">Open orders</div>
        {ORDERS.map((o) => (
          <div className="list-row" key={o.what}>
            <Mark name={o.sym} size={28} />
            <div className="grow"><div className="list-title">{o.what}</div><div className="list-sub">{o.by} on {o.when}</div></div>
            <div className="list-end num">{o.px}</div>
            <button className="btn sm" onClick={() => approve({ kind: 'Cancel order', title: o.what, success: 'Order cancelled', lines: [['Price', o.px]], checks: baseChecks() })}>Cancel</button>
          </div>
        ))}
      </div>
      <div className="section">
        <div className="section-title">History</div>
        {FILLS.map((f) => (
          <div className="list-row" key={f.what}>
            <Mark name={f.sym} size={28} />
            <div className="grow"><div className="list-title">{f.what}</div><div className="list-sub">{f.when}</div></div>
            <div className="list-end"><div className="num">{f.px}</div>{f.pnl != null && <div className={`small ${f.pnl >= 0 ? 'up' : 'down'}`}>{f.pnl >= 0 ? '+' : '−'}${Math.abs(f.pnl)}</div>}</div>
          </div>
        ))}
      </div>
    </>
  )
}

const MORE_MARKETS = [
  ['TSLA', 'Tesla', 'Stock perps on trade.xyz'], ['GOLD', 'Gold', 'Perps on trade.xyz'], ['NVDA', 'Nvidia', 'Tokenized on Ondo'], ['MON', 'Monad', 'Spot on Kuru'], ['LIT', 'Lighter', 'Spot and perps'], ['ASTER', 'Aster', 'Spot and perps'], ['XPL', 'Plasma', 'Spot'], ['KHYPE', 'Kinetiq HYPE', 'Spot'],
  ['BTC', 'Bitcoin', 'Spot and perps'], ['ETH', 'Ethereum', 'Spot and perps'], ['SOL', 'Solana', 'Spot and perps'], ['HYPE', 'Hyperliquid', 'Spot and perps'],
  ['PEPE', 'Pepe', 'Meme'], ['WIF', 'dogwifhat', 'Meme'], ['PENGU', 'Pudgy Penguins', 'Meme'], ['BNB', 'BNB', 'Perps'], ['XRP', 'XRP', 'Perps'],
  ['DOGE', 'Dogecoin', 'Perps'], ['SUI', 'Sui', 'Perps'], ['TIA', 'Celestia', 'Perps'], ['JUP', 'Jupiter', 'Spot'], ['ENA', 'Ethena', 'Spot and perps'],
].map(([sym, name, sub]) => ({ name, logo: sym, sub, metric: sym }))

function Strategies() {
  const { go } = useApp()
  const [open, setOpen] = useState(null)
  return (
    <div>
      <div className="section-title"><span>Running</span><button className="btn sm" onClick={() => { go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: 'Set up a funding arb strategy' })), 50) }}><Plus size={14} /> New</button></div>
      {strategies.map((st) => (
        <button className="list-row" key={st.id} onClick={() => setOpen(st)}>
          <Mark name={st.sym} size={32} />
          <div className="grow">
            <div className="list-title">{st.name}{st.status !== 'Running' && <span className="faint" style={{ fontWeight: 400 }}> (paused)</span>}</div>
            <div className="list-sub">{st.source}</div>
          </div>
          <div className="list-end"><div className={st.pnl >= 0 ? 'up' : 'down'}>{st.pnl >= 0 ? '+' : '−'}${Math.abs(st.pnl).toLocaleString()}</div><div className="faint small">${st.capital.toLocaleString()}</div></div>
          <ChevronRight size={16} color="var(--faint)" />
        </button>
      ))}
      {open && <StrategySheet st={open} onClose={() => setOpen(null)} />}
    </div>
  )
}

const SPOT = [
  { sym: 'ETH', name: 'Ethereum', px: 3498, ch: 2.4 },
  { sym: 'BTC', name: 'Bitcoin', px: 114280, ch: 1.8 },
  { sym: 'SOL', name: 'Solana', px: 186.6, ch: -1.1 },
  { sym: 'HYPE', name: 'Hyperliquid', px: 24.06, ch: 5.8 },
]

function Spot() {
  const { approve } = useApp()
  const [to, setTo] = useState(SPOT[0])
  const [amt, setAmt] = useState(1000)
  const out = amt / to.px
  const fmtOut = out < 1 ? out.toFixed(4) : out.toLocaleString(undefined, { maximumFractionDigits: 2 })
  const swap = (t, side) => approve({
    kind: 'Swap', title: `${side} ${t.sym}`, success: `Bought ${fmtOut} ${t.sym}`,
    lines: [['Pay', `${amt.toLocaleString()} USDC`], ['Receive', `≈ ${fmtOut} ${t.sym}`], ['Route', t.sym === 'SOL' ? 'Jupiter' : t.sym === 'HYPE' ? 'Hyperliquid' : 'Uniswap via 1inch'], ['Price impact', '0.02%']],
    checks: baseChecks(),
    result: { title: `Bought ${fmtOut} ${t.sym}`, rows: [['Paid', `${amt.toLocaleString()} USDC`], ['Price', `$${t.px.toLocaleString()}`], ['Wallet', 'Main']] },
  })
  return (
    <div className="grid split" style={{ gap: 32 }}>
      <div>
        {SPOT.map((t, i) => (
          <div className="list-row" key={t.sym} onClick={() => setTo(t)} style={{ cursor: 'pointer' }}>
            <Mark name={t.sym} size={32} />
            <div className="grow"><div className="list-title">{t.name}</div><div className="list-sub">{t.sym}</div></div>
            <span className="hide-m"><MiniCandles data={candles(22, t.px, 0.03, 70 + i, t.ch > 0 ? 0.05 : -0.04)} /></span>
            <div className="list-end"><div>${t.px.toLocaleString()}</div><div className={`small ${t.ch >= 0 ? 'up' : 'down'}`}>{t.ch > 0 ? '+' : ''}{t.ch}%</div></div>
          </div>
        ))}
      </div>
      <div className="stack" style={{ gap: 8 }}>
        <div className="tx" style={{ padding: 14 }}>
          <div className="muted small">You pay</div>
          <div className="row between" style={{ marginTop: 4 }}>
            <input type="number" value={amt} onChange={(e) => setAmt(+e.target.value)} style={{ border: 0, outline: 0, background: 'transparent', fontSize: 24, fontWeight: 600, width: '100%', minWidth: 0 }} />
            <span className="row" style={{ gap: 6, flexShrink: 0 }}><Mark name="USDC" size={20} /> USDC</span>
          </div>
        </div>
        <div style={{ display: 'grid', placeItems: 'center', margin: '-14px 0', zIndex: 1 }}><span className="mark app" style={{ width: 28, height: 28 }}><ArrowDown size={14} /></span></div>
        <div className="tx" style={{ padding: 14 }}>
          <div className="muted small">You receive</div>
          <div className="row between" style={{ marginTop: 4 }}>
            <span className="num" style={{ fontSize: 24, fontWeight: 600 }}>{fmtOut}</span>
            <span className="row" style={{ gap: 6, flexShrink: 0 }}><Mark name={to.sym} size={20} /> {to.sym}</span>
          </div>
        </div>
        <div className="row between small muted" style={{ padding: '4px 2px' }}><span>Best route across 6 DEXs</span><span>Fee $0.04</span></div>
        <button className="btn primary block" style={{ height: 40 }} onClick={() => swap(to, 'Buy')}><Fingerprint size={15} /> Swap</button>
      </div>
    </div>
  )
}

const TF = { '15m': [0.012, 3], '1H': [0.022, 5], '4H': [0.045, 9], '1D': [0.09, 13] }
const vol = { BTC: '$4.2B', ETH: '$2.1B', SOL: '$880M', HYPE: '$1.3B', TSLA: '$240M', GOLD: '$96M' }

// Order book around the mark price, deterministic so it renders the same every time.
function book(px, seed) {
  const r = (i) => (Math.sin(seed * 9.3 + i * 12.9898) * 43758.5453) % 1
  const tick = px > 1000 ? px * 0.0001 : px > 50 ? px * 0.0002 : px * 0.0004
  const lvl = (side, i) => ({ px: px + side * tick * (i + 0.5), sz: +(Math.abs(r(i * side + 3)) * 40 + 4).toFixed(1) })
  const asks = Array.from({ length: 7 }, (_, i) => lvl(1, i)).reverse()
  const bids = Array.from({ length: 7 }, (_, i) => lvl(-1, i))
  return { asks, bids, max: Math.max(...asks.map((a) => a.sz), ...bids.map((b) => b.sz)) }
}

// Hermit's suggestions on the market screen. Each one answers and acts on the chart or order form.
const AI = [
  { q: 'Draw key levels', run: (m, set) => { set.marks([{ v: +(m.px * 0.93).toFixed(m.dp), label: `Support ${(m.px * 0.93).toFixed(m.dp)}`, color: '#2563EB' }, { v: +(m.px * 1.085).toFixed(m.dp), label: `Resistance ${(m.px * 1.085).toFixed(m.dp)}`, color: '#7C3AED' }]); return `Support at $${(m.px * 0.93).toFixed(m.dp)} (last week's breakout), resistance at $${(m.px * 1.085).toFixed(m.dp)} (October high). Both are on the chart.` } },
  { q: 'Why is it moving?', run: (m) => m.ch >= 0 ? `${m.sym} is up ${m.ch}% on rising open interest and positive funding (${m.fund}%/h). Longs are paying, so the move is crowded. Late longs risk a flush back to support.` : `${m.sym} is down ${Math.abs(m.ch)}%. Funding turned negative, so shorts are paying. Spot selling, not liquidations, is driving it.` },
  { q: 'Plan a trade', run: (m, set) => { set.plan(); return `Long at 3x with a stop just under support and take-profit below resistance. Risk is about 1% of your trading balance. I filled the order form; check it and tap Long.` } },
  { q: 'Size to 1% risk', run: (m, set) => { set.margin(460); return `Risking $140 (1% of $14,010) with your stop 8% away means $1,750 size: $460 margin at about 4x. Margin is set.` } },
]

function Perps() {
  const { approve, chartMarks, go } = useApp()
  const [mkt, setMkt] = useState(perpMarkets[3])
  const [pickOpen, setPickOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [venue, setVenue] = useState('Best price')
  const route = mkt.venue || (venue === 'Best price' ? 'Hyperliquid' : venue)
  const [tf, setTf] = useState('1H')
  const [side, setSide] = useState('long')
  const [type, setType] = useState('Market')
  const [lev, setLev] = useState(5)
  const [margin, setMargin] = useState(500)
  const [panel, setPanel] = useState('book')
  const [aiMarks, setAiMarks] = useState([])
  const [answer, setAnswer] = useState(null)
  const [ask, setAsk] = useState('')
  const dp = mkt.px < 100 ? 2 : 0
  const def = (s, m) => ({ tp: +(m.px * (s === 'long' ? 1.14 : 0.86)).toFixed(dp), sl: +(m.px * (s === 'long' ? 0.92 : 1.08)).toFixed(dp) })
  const [stops, setStops] = useState(def('long', perpMarkets[3]))
  const pick = (m, s = side) => { setMkt(m); setSide(s); setStops(def(s, m)); setAiMarks([]); setAnswer(null); setPickOpen(false) }
  const liq = side === 'long' ? mkt.px * (1 - 0.9 / lev) : mkt.px * (1 + 0.9 / lev)
  const size = margin * lev
  const gain = Math.abs(stops.tp - mkt.px) / mkt.px * size
  const loss = Math.abs(stops.sl - mkt.px) / mkt.px * size
  const ob = book(mkt.px, mkt.sym.charCodeAt(0))
  const fmt = (v) => v.toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp })
  // The book needs finer prices than the headline (Hyperliquid shows 3 decimals on HYPE).
  const bdp = mkt.px >= 10000 ? 0 : mkt.px >= 1000 ? 1 : mkt.px >= 100 ? 2 : 3
  const bfmt = (v) => v.toLocaleString(undefined, { minimumFractionDigits: bdp, maximumFractionDigits: bdp })
  const marks = [
    { v: stops.tp, label: `TP ${stops.tp}`, color: '#15803D' },
    { v: mkt.px, label: `Entry ${mkt.px}`, color: '#121212' },
    { v: stops.sl, label: `SL ${stops.sl}`, color: '#C53030' },
    ...aiMarks,
    ...(mkt.sym === 'HYPE' ? chartMarks : []),
  ]
  const [vol0, seed0] = TF[tf]
  const runAi = (a) => setAnswer({ q: a.q, a: a.run({ ...mkt, dp }, {
    marks: setAiMarks,
    plan: () => { setSide('long'); setLev(3); setStops({ tp: +(mkt.px * 1.08).toFixed(dp), sl: +(mkt.px * 0.925).toFixed(dp) }); setAiMarks([{ v: +(mkt.px * 0.93).toFixed(dp), label: 'Support', color: '#2563EB' }]) },
    margin: (v) => { setMargin(v); setLev(4) },
  }) })
  const list = perpMarkets.filter((m) => m.sym.toLowerCase().includes(query.toLowerCase()))

  return (
    <div className="term">
      <div className="term-bar">
        <div style={{ position: 'relative' }}>
          <button className="mkt-pick" onClick={() => setPickOpen(!pickOpen)}><Mark name={mkt.sym} size={22} /><b>{mkt.sym}-USD</b><ChevronDown size={15} /></button>
          {pickOpen && (
            <div className="mkt-menu">
              <label className="mkt-search"><Search size={14} /><input autoFocus placeholder="Search markets" value={query} onChange={(e) => setQuery(e.target.value)} /></label>
              <div className="mkt-head"><span>Market</span><span>Price</span><span>24h</span><span className="hide-m">Funding</span></div>
              {list.map((m) => (
                <button key={m.sym} className={`mkt-item ${m.sym === mkt.sym ? 'on' : ''}`} onClick={() => pick(m)}>
                  <span className="row" style={{ gap: 8 }}><Mark name={m.sym} size={18} />{m.sym}{m.venue && <span className="faint small">{m.venue}</span>}</span>
                  <span className="num">${m.px.toLocaleString()}</span>
                  <span className={`num ${m.ch >= 0 ? 'up' : 'down'}`}>{m.ch > 0 ? '+' : ''}{m.ch}%</span>
                  <span className="num hide-m muted">{m.fund}%</span>
                </button>
              ))}
            </div>
          )}
        </div>
        <div className="term-stats">
          <div><span>Mark</span><b className="num">${fmt(mkt.px)}</b></div>
          <div><span>24h</span><b className={`num ${mkt.ch >= 0 ? 'up' : 'down'}`}>{mkt.ch > 0 ? '+' : ''}{mkt.ch}%</b></div>
          <div><span>Volume</span><b className="num">{vol[mkt.sym]}</b></div>
          <div><span>Open interest</span><b className="num">{mkt.oi}</b></div>
          <div><span>Funding</span><b className={`num ${mkt.fund >= 0 ? 'up' : 'down'}`}>{mkt.fund}%</b></div>
          <div><span>Venue</span><b>{route}</b></div>
        </div>
      </div>

      <div className="ai-bar">
        <span className="ai-mark"><Sparkles size={13} /></span>
        <div className="ai-chips">{AI.map((a) => <button key={a.q} className={`chip sm ${answer?.q === a.q ? 'on' : ''}`} onClick={() => runAi(a)}>{a.q}</button>)}</div>
      </div>
      {answer && <div className="ai-answer"><b>{answer.q}</b><p>{answer.a}</p></div>}

      <div className="term-grid">
        <div className="term-chart">
          <div className="row between" style={{ marginBottom: 8 }}>
            <div className="seg">{Object.keys(TF).map((k) => <button key={k} className={tf === k ? 'on' : ''} onClick={() => setTf(k)}>{k}</button>)}</div>
            <select className="venue-select" value={mkt.venue ? mkt.venue : venue} disabled={!!mkt.venue} onChange={(e) => setVenue(e.target.value)}>
              {['Best price', ...perpVenues].map((v) => <option key={v}>{v}</option>)}
            </select>
          </div>
          <CandleChart data={candles(54, mkt.px * (1 - vol0 * 4), vol0, mkt.sym.charCodeAt(0) + seed0, mkt.ch > 0 ? 0.06 : -0.03)} height={280} marks={marks} padTo={[stops.tp, stops.sl]} />
        </div>

        <div className="term-form stack" style={{ gap: 14 }}>
          <div className="seg" style={{ width: '100%' }}>{['Market', 'Limit'].map((t) => <button key={t} style={{ flex: 1 }} className={type === t ? 'on' : ''} onClick={() => setType(t)}>{t}</button>)}</div>
          <div className="side-toggle">
            <button className={side === 'long' ? 'long on' : 'long'} onClick={() => pick(mkt, 'long')}>Long</button>
            <button className={side === 'short' ? 'short on' : 'short'} onClick={() => pick(mkt, 'short')}>Short</button>
          </div>
          {type === 'Limit' && <label className="field"><span>Limit price</span><input type="number" step="any" defaultValue={mkt.px} /></label>}
          <label className="field"><span className="row between"><span>Margin</span><b className="num" style={{ color: 'var(--text)' }}>${margin}</b></span>
            <input type="range" min="50" max="5000" step="10" value={margin} onChange={(e) => setMargin(+e.target.value)} /></label>
          <label className="field"><span className="row between"><span>Leverage</span><b className="num" style={{ color: 'var(--text)' }}>{lev}x</b></span>
            <input type="range" min="1" max="25" value={lev} onChange={(e) => setLev(+e.target.value)} /></label>
          <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <label className="field"><span style={{ color: 'var(--green)' }}>Take profit</span><input type="number" step="any" value={stops.tp} onChange={(e) => setStops({ ...stops, tp: +e.target.value })} /></label>
            <label className="field"><span style={{ color: 'var(--red)' }}>Stop loss</span><input type="number" step="any" value={stops.sl} onChange={(e) => setStops({ ...stops, sl: +e.target.value })} /></label>
          </div>
          <div className="tx">
            <div className="tx-line"><span>Size</span><span>${size.toLocaleString()}</span></div>
            <div className="tx-line"><span>At TP / SL</span><span><span className="up">+${Math.round(gain)}</span> / <span className="down">−${Math.round(loss)}</span></span></div>
            <div className="tx-line"><span>Liquidation</span><span>${liq.toFixed(dp)}</span></div>
            <div className="tx-line"><span>Risk</span><span>{((loss / 14010) * 100).toFixed(1)}% of balance</span></div>
          </div>
          {lev > 10 && <div className="notice" style={{ background: 'var(--amber-soft)' }}><Sparkles size={14} color="var(--amber)" style={{ flexShrink: 0, marginTop: 3 }} /><span>A {(90 / lev).toFixed(1)}% move liquidates you. 5x or less is safer.</span></div>}
          <button className={`btn block ${side === 'long' ? 'green' : 'red'}`} style={{ height: 42 }} onClick={() => approve({
            kind: `Perp order on ${route}`, title: `${side === 'long' ? 'Long' : 'Short'} ${mkt.sym} ${lev}x`, success: 'Order filled',
            lines: [['Type', type], ['Margin', `$${margin}`], ['Size', `$${size.toLocaleString()}`], ['Take profit', `$${stops.tp}`], ['Stop loss', `$${stops.sl}`], ['Liquidation', `$${liq.toFixed(dp)}`]],
            checks: baseChecks([{ label: 'Leverage within your limit', detail: 'Your limit is 10x', status: lev > 10 ? 'warn' : 'pass' }, { label: 'Stop triggers before liquidation', status: 'pass' }]),
            adds: { trade: [{ sym: mkt.sym, title: `${mkt.sym}-PERP`, side: `${side === 'long' ? 'Long' : 'Short'} ${lev}x`, entry: mkt.px, mark: mkt.px, liq: +liq.toFixed(dp), tp: stops.tp, sl: stops.sl, pnl: 0, by: 'You', when: 'just now' }] },
          })}><Fingerprint size={15} /> {side === 'long' ? 'Long' : 'Short'} {mkt.sym}</button>
          <form className="ai-ask" onSubmit={(e) => { e.preventDefault(); if (!ask.trim()) return; go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: ask })), 50) }}>
            <input placeholder={`Ask Hermit about ${mkt.sym}`} value={ask} onChange={(e) => setAsk(e.target.value)} />
            <button className="send" aria-label="Ask" disabled={!ask.trim()}><ArrowUp size={14} /></button>
          </form>
        </div>
        <div className="term-book">
          <div className="seg" style={{ marginTop: 0 }}><button className={panel === 'book' ? 'on' : ''} onClick={() => setPanel('book')}>Order book</button><button className={panel === 'trades' ? 'on' : ''} onClick={() => setPanel('trades')}>Trades</button></div>
          {panel === 'book' ? (
            <div className="book">
              <div className="book-row head"><span>Price</span><span>Size ({mkt.sym})</span></div>
              {ob.asks.map((a, i) => <div className="book-row sell" key={'a' + i}><i style={{ width: `${(a.sz / ob.max) * 100}%` }} /><span className="num">{bfmt(a.px)}</span><span className="num">{a.sz}</span></div>)}
              <div className="book-mid num">{fmt(mkt.px)} <span className="faint small">spread {(((ob.asks[6].px - ob.bids[0].px) / mkt.px) * 100).toFixed(3)}%</span></div>
              {ob.bids.map((b, i) => <div className="book-row buy" key={'b' + i}><i style={{ width: `${(b.sz / ob.max) * 100}%` }} /><span className="num">{bfmt(b.px)}</span><span className="num">{b.sz}</span></div>)}
            </div>
          ) : (
            <div className="book">
              <div className="book-row three head"><span>Price</span><span>Size</span><span>Time</span></div>
              {ob.bids.concat(ob.asks).slice(0, 12).map((t, i) => <div className={`book-row three ${i % 3 ? "buy" : "sell"}`} key={i}><span className="num">{bfmt(t.px)}</span><span className="num">{t.sz}</span><span className="faint num">15:{String(42 - i).padStart(2, '0')}</span></div>)}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

function MemeMap({ sel }) {
  const clusters = sel.score === 'Fail'
    ? [{ x: 0.35, y: 0.5, n: 14, size: 34, color: '#C53030', linked: true, label: 'Dev-linked 61%' }, { x: 0.75, y: 0.45, n: 4, size: 12, color: '#A16207', linked: true, label: 'Snipers 8%' }]
    : [{ x: 0.22, y: 0.45, n: 8, size: 26, color: '#121212', linked: true, label: 'Exchanges' }, { x: 0.55, y: 0.5, n: 6, size: 16, color: '#15803D', linked: true, label: 'Smart money' }, { x: 0.82, y: 0.45, n: 4, size: 12, color: '#8E73CF', linked: true, label: 'Team' }]
  return (
    <>
      <BubbleMap seed={sel.sym.length * 3} height={220} clusters={clusters} />
      <div className="row wrap small" style={{ gap: 16, marginTop: 10, rowGap: 6 }}>
        {clusters.map((c) => <span key={c.label} className="row" style={{ gap: 6 }}><span className="swatch" style={{ background: c.color }} />{c.label}</span>)}
      </div>
    </>
  )
}

function Memes() {
  const { approve } = useApp()
  const [sel, setSel] = useState(memeMarkets[0])
  const scoreClass = { Pass: 'green', Warn: 'amber', Fail: 'red' }
  return (
    <>
      {memeMarkets.map((m, i) => (
        <div className="list-row" key={m.sym} onClick={() => setSel(m)} style={{ cursor: 'pointer' }}>
          <Mark name={m.sym} size={32} />
          <div className="grow">
            <div className="list-title">{m.sym} <span className={`tag ${scoreClass[m.score]}`} style={{ marginLeft: 6 }}><span className="dot" />{m.score === 'Pass' ? 'Safe' : m.score === 'Warn' ? 'Caution' : 'Risky'}</span></div>
            <div className="list-sub">{m.holders} holders</div>
          </div>
          <span className="hide-m"><MiniCandles data={candles(22, 1, 0.08, 40 + i, m.ch > 0 ? 0.08 : -0.06)} /></span>
          <div className={`list-end ${m.ch >= 0 ? 'up' : 'down'}`} style={{ minWidth: 56 }}>{m.ch > 0 ? '+' : ''}{m.ch}%</div>
          <button className="btn sm" disabled={m.score === 'Fail'} onClick={(e) => { e.stopPropagation(); approve({
            kind: 'Swap', title: `Buy $100 of ${m.sym}`, success: `Bought ${m.sym}`,
            lines: [['Pay', '100 USDC'], ['Route', 'Jupiter'], ['Take profit', '2x']],
            checks: baseChecks([{ label: 'Holder concentration', detail: 'Top 10 hold 38%', status: m.score === 'Warn' ? 'warn' : 'pass' }]),
          }) }}>Buy</button>
        </div>
      ))}

      <div className="grid g2 section" style={{ gap: 28 }}>
        <div>
          <div className="section-title">{sel.sym} holders</div>
          <MemeMap sel={sel} />
        </div>
        <div>
          <div className="section-title">Hermit's take</div>
          <p style={{ lineHeight: 1.7 }}>
            {sel.score === 'Fail'
              ? <>Avoid. <b>61% of supply sits with deployer-funded wallets</b>, and liquidity is unlocked. Automations won't buy it.</>
              : sel.score === 'Warn'
                ? <>Crowded. The top 10 hold 38% and KOLs are selling. Keep it small.</>
                : <>Healthy holders and deep liquidity. KOLs have pushed it, so expect swings.</>}
          </p>
        </div>
      </div>
    </>
  )
}

function Predictions() {
  const { approve } = useApp()
  const bet = (m, side) => approve({
    kind: `Prediction on ${m.venue}`, title: `${side} on "${m.q}"`, success: 'Position placed',
    lines: [['Stake', '100 USDC'], ['Price', `${side === 'Yes' ? m.yes : 100 - m.yes}¢`], ['Pays if right', `$${Math.round(10000 / (side === 'Yes' ? m.yes : 100 - m.yes))}`], ['Resolves', m.ends]],
    checks: baseChecks([{ label: 'Market resolution source checked', status: 'pass' }]),
  })
  return (
    <>
      {predictions.map((m) => (
        <div className="list-row" key={m.q} style={{ alignItems: 'flex-start' }}>
          <Mark name={m.venue} size={30} />
          <div className="grow">
            <div style={{ fontWeight: 500, lineHeight: 1.4 }}>{m.q}</div>
            <div className="row between list-sub" style={{ marginTop: 4 }}><span>{m.venue}, ends {m.ends}</span><span>{m.vol}</span></div>
            <div className="bar-track" style={{ marginTop: 8, height: 6 }}><div className="bar-fill" style={{ width: `${m.yes}%`, background: 'var(--green)' }} /></div>
            <div className="row" style={{ gap: 8, marginTop: 10 }}>
              <button className="btn sm" style={{ color: 'var(--green)' }} onClick={() => bet(m, 'Yes')}>Yes {m.yes}¢</button>
              <button className="btn sm" style={{ color: 'var(--red)' }} onClick={() => bet(m, 'No')}>No {100 - m.yes}¢</button>
            </div>
          </div>
        </div>
      ))}
    </>
  )
}
