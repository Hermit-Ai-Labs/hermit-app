import { useState, useEffect } from 'react'
import { ShieldAlert, Fingerprint, CheckCircle2, Circle, Zap, Copy, Mail, Calendar } from 'lucide-react'
import { CandleChart, BubbleMap, HBars, FlowDiagram, AreaChart } from './Charts'
import Mark from './Mark'
import { candles, walk, oppCatalog, perpMarkets } from '../data'
import { useApp } from '../App'
import { baseChecks } from './Approval'

const TF = ['1H', '4H', '1D', '1W']

// Shows the indicators the user asked for in long-term memory (Settings > Memory).
function Indicators() {
  const { memory } = useApp()
  if (!memory.some((m) => /RSI|MACD|EMA/i.test(m))) return null
  return (
    <div className="row wrap small" style={{ gap: 6, marginTop: 10 }}>
      <span className="new-tag" style={{ margin: 0 }}>From memory</span>
      <span className="chip sm">RSI 64</span><span className="chip sm">MACD rising</span><span className="chip sm">EMA 50 above 200</span>
    </div>
  )
}

export function TokenCard({ sym, name, price, change, seed, stats, marks }) {
  const [tf, setTf] = useState('4H')
  const data = candles(48, price * 0.78, 0.06, seed + TF.indexOf(tf), 0.04)
  return (
    <div className="ccard">
      <div className="ccard-head">
        <div className="row">
          <Mark name={sym} size={32} />
          <div>
            <div style={{ fontWeight: 500 }}>{name}</div>
            <div className="small num"><span>${price}</span> <span className={change >= 0 ? 'up' : 'down'}>{change >= 0 ? '+' : ''}{change}%</span></div>
          </div>
        </div>
        <div className="seg">{TF.map((t) => <button key={t} className={t === tf ? 'on' : ''} onClick={() => setTf(t)}>{t}</button>)}</div>
      </div>
      <div className="ccard-body">
        <CandleChart data={data} marks={marks} />
        <Indicators />
        <div className="kv" style={{ marginTop: 14 }}>
          {stats.map(([k, v]) => <div key={k}><span>{k}</span><b>{v}</b></div>)}
        </div>
      </div>
    </div>
  )
}

export function HolderMapCard({ clusters, verdict, summary }) {
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span style={{ fontWeight: 500 }}>Holders</span>
        <span className={`tag ${verdict === 'Healthy' ? 'green' : 'amber'}`}><span className="dot" />{verdict}</span>
      </div>
      <div className="ccard-body">
        <BubbleMap clusters={clusters} />
        <div className="row wrap" style={{ gap: 16, marginTop: 12, rowGap: 6 }}>
          {summary.map(([c, l]) => <span key={l} className="row small" style={{ gap: 6 }}><span className="swatch" style={{ background: c }} />{l}</span>)}
        </div>
      </div>
    </div>
  )
}

export function KolCard({ kols, onboarded }) {
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span style={{ fontWeight: 500 }}>KOLs & smart money</span>
        <span className="muted small">{onboarded} onboarded</span>
      </div>
      <div className="ccard-body" style={{ paddingTop: 4, paddingBottom: 4 }}>
        {kols.map((k) => (
          <div className="list-row" key={k.h}>
            <span className="avatar" style={{ background: k.c }}>{k.h.replace('@', '')[0].toUpperCase()}</span>
            <div className="grow"><div className="list-title">{k.h} <span className="faint small" style={{ fontWeight: 400 }}>{k.f}</span></div><div className="list-sub">{k.note}</div></div>
            <span className={`tag ${k.s === 'Bought' ? 'green' : k.s === 'Sold' ? 'red' : ''}`}>{k.s}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

export function ActionRow({ actions }) {
  const { approve, react } = useApp()
  return (
    <div className="row wrap" style={{ gap: 8 }}>
      {actions.map((a) => (
        <button key={a.label} className={`btn ${a.primary ? 'primary' : ''}`} onClick={() => (a.approval ? approve(a.approval) : a.ask ? window.dispatchEvent(new CustomEvent('hermit:ask', { detail: a.ask })) : react(a.label, a.reply || a.toast || 'Done.'))}>
          {a.label}
        </button>
      ))}
    </div>
  )
}

export function PerpTicket({ approval }) {
  const { approve } = useApp()
  const [lev, setLev] = useState(5)
  const [size, setSize] = useState(1000)
  const entry = 24.06
  const liq = (entry * (1 - 0.9 / lev)).toFixed(2)
  return (
    <div className="ccard">
      <div className="ccard-head">
        <div className="row"><Mark name="HYPE" size={32} /><div><div style={{ fontWeight: 500 }}>Long HYPE</div><div className="small muted num">${entry}</div></div></div>
      </div>
      <div className="ccard-body">
        <CandleChart data={candles(48, 19.5, 0.05, 31, 0.06)} height={190} marks={[
          { v: 24.06, label: 'Entry', color: '#121212' },
          { v: 22, label: 'Stop', color: '#C53030' },
          { v: 27.5, label: 'Target', color: '#15803D' },
        ]} />
        <div className="grid g2" style={{ marginTop: 16, gap: 16 }}>
          <label className="field"><span className="row between"><span>Margin</span><b className="num" style={{ color: 'var(--text)' }}>${size.toLocaleString()}</b></span>
            <input type="range" min="100" max="5000" step="100" value={size} onChange={(e) => setSize(+e.target.value)} /></label>
          <label className="field"><span className="row between"><span>Leverage</span><b className="num" style={{ color: 'var(--text)' }}>{lev}x</b></span>
            <input type="range" min="1" max="20" value={lev} onChange={(e) => setLev(+e.target.value)} /></label>
        </div>
        <div className="kv" style={{ marginTop: 16 }}>
          <div><span>Size</span><b>${(size * lev).toLocaleString()}</b></div>
          <div><span>Liquidation</span><b className="down">${liq}</b></div>
          <div><span>Loss at stop</span><b>${Math.round(size * lev * (2.06 / entry))}</b></div>
          <div><span>Reward / risk</span><b>1.67</b></div>
        </div>
      </div>
      <div className="ccard-foot">
        <button className="btn primary" onClick={() => approve({ ...approval, lines: [['Margin', `$${size.toLocaleString()}`], ['Leverage', `${lev}x`], ['Liquidation', `$${liq}`], ['Stop / target', '$22.00 / $27.50']],
          adds: { trade: [{ sym: 'HYPE', title: 'HYPE-PERP', side: `Long ${lev}x`, entry, mark: entry, liq: +liq, tp: 27.5, sl: 22, pnl: 0, size: size * lev, by: 'You', when: 'just now' }] } })}>
          <Fingerprint size={14} /> Place order
        </button>
      </div>
    </div>
  )
}

export function YieldCompare({ rows }) {
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>USDC yield</span><span className="faint small">APY</span></div>
      <div className="ccard-body"><HBars data={rows} /></div>
    </div>
  )
}

// Generic chart cards so any reply with numbers can show them visually.
export function BarsCard({ title, rows, suffix = '', prefix = '', note }) {
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>{title}</span>{note && <span className="faint small">{note}</span>}</div>
      <div className="ccard-body"><HBars data={rows} suffix={suffix} prefix={prefix} /></div>
    </div>
  )
}

// Price over time, as candles.
export function PriceCard({ title, total, days = 30, seed = 3, drift = 0.05 }) {
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>{title}</span><span className={`num ${drift >= 0 ? 'up' : 'down'}`}>{total}</span></div>
      <div className="ccard-body"><CandleChart data={candles(days * 2, 100, 0.025, seed, drift)} height={160} /><div className="row between faint small" style={{ marginTop: 6 }}><span>{days} days ago</span><span>Today</span></div></div>
    </div>
  )
}

export function PnlCard({ title, total, days = 30, seed = 3 }) {
  const series = walk(days, 100, 0.05, seed, 0.12).map((v, i) => v + i * 6)
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>{title}</span><span className="up num">{total}</span></div>
      <div className="ccard-body"><AreaChart data={series} height={120} id={`pnl-${seed}`} /><div className="row between faint small" style={{ marginTop: 6 }}><span>{days} days ago</span><span>Today</span></div></div>
    </div>
  )
}

// Opportunity list for open questions; each tag either opens an approval or asks a follow-up.
export function OppList({ title, items }) {
  const { approve } = useApp()
  const ask = (q) => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: q }))
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>{title}</span></div>
      <div className="ccard-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {items.map((o) => (
          <div className="list-row" key={o.name} style={{ alignItems: 'flex-start' }}>
            <Mark name={o.logo} size={32} />
            <div className="grow">
              <div className="row between"><span className="list-title">{o.name}</span><span className={`num ${o.metricClass || ''}`} style={{ fontWeight: 500 }}>{o.metric}</span></div>
              <div className="list-sub">{o.why}</div>
              <div className="chips" style={{ marginTop: 8 }}>
                {o.tags.map((t) => (
                  <button key={t.label} className={`chip sm ${t.approval ? 'on' : ''}`} onClick={() => (t.approval ? approve(t.approval) : ask(t.ask))}>{t.label}</button>
                ))}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

// Full catalog of opportunity types, grouped; tags start one or ask about it.
export function OppCatalog({ group = 'Yield' }) {
  const { approve } = useApp()
  const [g, setG] = useState(group)
  const ask = (q) => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: q }))
  const riskColor = { Low: 'var(--green)', Medium: 'var(--amber)', High: 'var(--red)' }
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span style={{ fontWeight: 500 }}>All opportunities</span>
        <div className="seg">{Object.keys(oppCatalog).map((k) => <button key={k} className={k === g ? 'on' : ''} onClick={() => setG(k)}>{k}</button>)}</div>
      </div>
      <div className="ccard-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {oppCatalog[g].map((o) => (
          <div className="list-row" key={o.name} style={{ alignItems: 'flex-start' }}>
            <Mark name={o.logo} size={30} />
            <div className="grow">
              <div className="row between"><span className="list-title">{o.name}</span><span className="num small" style={{ fontWeight: 500, flexShrink: 0 }}>{o.ret}</span></div>
              <div className="row between"><span className="list-sub">{o.ex}</span><span className="small" style={{ color: riskColor[o.risk], flexShrink: 0 }}>{o.risk}</span></div>
              <div className="chips" style={{ marginTop: 8 }}>
                {o.start && <button className="chip sm on" onClick={() => approve({
                  kind: g, title: `Start ${o.name.toLowerCase()}`, success: 'Started',
                  lines: [['Using', o.ex.split(',')[0]], ['Amount', '1,000 USDC'], ['Expected', o.ret]], checks: baseChecks(),
                })}>Start</button>}
                <button className="chip sm" onClick={() => ask(`How does ${o.name.toLowerCase()} work?`)}>Explain</button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

// Shown when the agent pays for something itself, inside a budget the user set.
export function AgentPaid({ to, amount, what, budget }) {
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 8, fontWeight: 500 }}><Mark name={to} size={22} /> Paid {to} {amount}</span>
        <span className="tag green"><span className="dot" />Auto-approved</span>
      </div>
      <div className="ccard-body" style={{ paddingTop: 8 }}>
        <div className="tx-line"><span>For</span><span>{what}</span></div>
        <div className="tx-line"><span>Paid with</span><span>USDC via x402</span></div>
        <div className="tx-line"><span>Dev budget left</span><span>{budget}</span></div>
        <div className="tx-line"><span>API key</span><span>Saved to local vault</span></div>
      </div>
    </div>
  )
}

// Ranked headlines with the asset each one moves; tags open details or a trade.
export function NewsList({ items }) {
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>Top stories</span><span className="faint small">Last 6 hours</span></div>
      <div className="ccard-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {items.map((n) => <NewsRow key={n.title} n={n} />)}
      </div>
    </div>
  )
}

// Every story carries a ready trade: side, leverage and suggested TP/SL the user can edit before approving.
function NewsRow({ n }) {
  const { approve } = useApp()
  const ask = (q) => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: q }))
  const color = { High: 'var(--red)', Medium: 'var(--amber)', Low: 'var(--faint)' }
  const px = perpMarkets.find((m) => m.sym === n.sym)?.px || 100
  const dp = px < 100 ? 2 : 0
  const long = n.move >= 0
  const [lev, setLev] = useState(n.impact === 'High' ? 3 : 2)
  const [tp, setTp] = useState(+(px * (long ? 1.08 : 0.94)).toFixed(dp))
  const [sl, setSl] = useState(+(px * (long ? 0.97 : 1.03)).toFixed(dp))
  const [edit, setEdit] = useState(false)
  const pct = (v) => `${v > px ? '+' : '−'}${Math.abs(((v - px) / px) * 100).toFixed(1)}%`
  const side = long ? 'Long' : 'Short'
  const trade = () => approve({
    kind: 'Perp order on Hyperliquid', title: `${side} ${n.sym} ${lev}x`, success: 'Order filled',
    lines: [['Margin', '$500'], ['Size', `$${(500 * lev).toLocaleString()}`], ['Entry', `$${px.toLocaleString()}`], ['Take profit', `$${tp.toLocaleString()} (${pct(tp)})`], ['Stop loss', `$${sl.toLocaleString()} (${pct(sl)})`]],
    checks: baseChecks([{ label: 'Stop triggers before liquidation', status: 'pass' }, { label: 'News confirmed by 3+ sources', status: n.impact === 'High' ? 'pass' : 'warn', detail: n.impact === 'High' ? undefined : 'Single-source story' }]),
    adds: { trade: [{ sym: n.sym, title: `${n.sym}-PERP`, side: `${side} ${lev}x`, entry: px, mark: px, liq: +(px * (long ? 1 - 0.9 / lev : 1 + 0.9 / lev)).toFixed(dp), tp, sl, pnl: 0, by: 'You', when: 'just now' }] },
  })
  return (
    <div className="list-row" style={{ alignItems: 'flex-start' }}>
      <Mark name={n.sym} size={30} />
      <div className="grow" style={{ minWidth: 0 }}>
        <div style={{ fontWeight: 500, lineHeight: 1.4 }}>{n.title}</div>
        <div className="list-sub" style={{ marginTop: 2 }}>{n.source}, {n.ago}</div>
        <div className="row wrap small" style={{ gap: 12, marginTop: 6 }}>
          <span style={{ color: color[n.impact] }}>{n.impact} impact</span>
          <span className={n.move >= 0 ? 'up' : 'down'}>{n.sym} {n.move >= 0 ? '+' : ''}{n.move}%</span>
        </div>
        <div className="news-trade">
          {edit ? (
            <div className="news-edit">
              <label>Leverage<select value={lev} onChange={(e) => setLev(+e.target.value)}>{[1, 2, 3, 5].map((x) => <option key={x} value={x}>{x}x</option>)}</select></label>
              <label className="up">TP<input type="number" step="any" value={tp} onChange={(e) => setTp(+e.target.value)} /></label>
              <label className="down">SL<input type="number" step="any" value={sl} onChange={(e) => setSl(+e.target.value)} /></label>
            </div>
          ) : (
            <span className="small num"><span className="muted">{side} {lev}x</span>  <span className="stop tp">TP ${tp.toLocaleString()} ({pct(tp)})</span> <span className="stop sl">SL ${sl.toLocaleString()} ({pct(sl)})</span></span>
          )}
          <button className="news-edit-btn small" onClick={() => setEdit(!edit)}>{edit ? 'Done' : 'Edit'}</button>
        </div>
        <div className="chips" style={{ marginTop: 8 }}>
          <button className="chip sm" onClick={() => ask(n.ask)}>Details</button>
          <button className={`chip sm on ${long ? '' : 'short'}`} onClick={trade}>{side} {n.sym} {lev}x</button>
        </div>
      </div>
    </div>
  )
}

export function FlowCard({ title, steps }) {
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>{title}</span></div>
      <div className="ccard-body"><FlowDiagram steps={steps} /></div>
    </div>
  )
}

export function ApiBuyCard({ approval }) {
  const { approve } = useApp()
  return (
    <div className="ccard">
      <div className="ccard-head">
        <div className="row"><Mark name="OpenAI" size={32} /><div><div style={{ fontWeight: 500 }}>OpenAI GPT-5</div><div className="small muted">$20 in credits</div></div></div>
      </div>
      <div className="ccard-body">
        <div className="tx mono" style={{ fontSize: 12, padding: '10px 14px' }}>hermit.tools.add("openai", key=vault://openai)</div>
      </div>
      <div className="ccard-foot">
        <button className="btn primary" onClick={() => approve(approval)}><Fingerprint size={14} /> Buy and connect</button>
      </div>
    </div>
  )
}

export function QuestList({ quests }) {
  const { react, addAutomation } = useApp()
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>Monad quests</span><span className="muted small num">600 of 2,400 pts</span></div>
      <div style={{ padding: '12px 16px 0' }}><div className="bar-track" style={{ height: 6 }}><div className="bar-fill" style={{ width: '25%' }} /></div></div>
      <div className="ccard-body" style={{ paddingTop: 4, paddingBottom: 4 }}>
        {quests.map((q) => (
          <div className="list-row" key={q.t}>
            {q.done ? <CheckCircle2 size={17} color="var(--green)" /> : <Circle size={17} color="var(--faint)" />}
            <div className="grow"><div className="ellipsis" style={{ color: q.done ? 'var(--muted)' : undefined }}>{q.t}</div>{q.d && <div className="list-sub">{q.d}</div>}</div>
            <span className="faint small num">{q.pts}</span>
          </div>
        ))}
      </div>
      <div className="ccard-foot">
        <button className="btn" onClick={() => react('Review post', 'Draft for X: "Testing @monad_xyz with Hermit. 3 wallets, 12 quests, $0.40 in gas. Who else is farming?" Say "post it" and I will publish it.')}>Review post</button>
        <button className="btn primary" onClick={() => { addAutomation({ name: 'Monad quests', trigger: 'Daily 08:00', action: 'Finish open Monad quests', limit: '$1 gas / day', on: true, last: 'Just created' }); react('Run daily', 'Run daily set. I will finish open Monad quests every day at 08:00 with gas capped at $1 a day. It is in Automations, and you can pause it anytime.') }}>
          <Zap size={14} /> Run daily
        </button>
      </div>
    </div>
  )
}

export function InboxCard({ items, approval }) {
  const { approve } = useApp()
  return (
    <div className="ccard">
      <div className="ccard-body" style={{ paddingTop: 4, paddingBottom: 4 }}>
        {items.map((i) => (
          <div className="list-row" key={i.t}>
            {i.logo ? <Mark name={i.logo} size={32} /> : <span className="mark app" style={{ width: 32, height: 32 }}>{i.k === 'cal' ? <Calendar size={15} /> : <Mail size={15} />}</span>}
            <div className="grow"><div className="list-title">{i.from}</div><div className="list-sub">{i.s}</div></div>
            {i.pay ? <button className="btn sm primary" onClick={() => approve(approval)}>Pay ${i.pay}</button> : <span className="faint small">{i.when}</span>}
          </div>
        ))}
      </div>
    </div>
  )
}

export function InjectionAlert({ source, quote }) {
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 8, color: 'var(--red)', fontWeight: 500 }}><ShieldAlert size={16} /> Prompt injection blocked</span>
      </div>
      <div className="ccard-body stack" style={{ gap: 10 }}>
        <div className="muted small mono">{source}</div>
        <div className="tx mono" style={{ fontSize: 12, padding: '10px 14px', color: 'var(--red)', background: 'var(--red-soft)', borderColor: 'transparent' }}>{quote}</div>
        <div className="small muted">Funds untouched. Destination 0x9f…41c is a known drainer.</div>
      </div>
    </div>
  )
}

export function CodeCard({ code }) {
  const { toast } = useApp()
  return (
    <div className="ccard" style={{ position: 'relative' }}>
      <button className="icon-btn" style={{ position: 'absolute', top: 6, right: 6 }} onClick={() => toast('Copied')} aria-label="Copy"><Copy size={14} /></button>
      <pre className="mono" style={{ margin: 0, padding: '14px 40px 14px 16px', whiteSpace: 'pre-wrap', wordBreak: 'break-word', background: 'var(--subtle)', fontSize: 12, lineHeight: 1.7 }}>{code}</pre>
    </div>
  )
}

// Shown after a trade is approved: candles with entry, TP and SL, ticking live.
export function LiveTradeCard({ t }) {
  const long = !/short/i.test(t.side)
  const vol = t.entry < 1 ? 0.012 : 0.006
  const [data, setData] = useState(() => {
    const base = candles(40, t.entry * (long ? 0.96 : 1.04), vol, t.sym.length * 7, long ? 0.04 : -0.04)
    const k = t.entry / base[base.length - 1].c
    return base.map((d) => ({ o: d.o * k, h: d.h * k, l: d.l * k, c: d.c * k }))
  })
  useEffect(() => {
    const id = setInterval(() => setData((d) => {
      const last = d[d.length - 1]
      const drift = (long ? 1 : -1) * t.entry * vol * 0.12
      const c = last.c + drift + (Math.random() - 0.5) * t.entry * vol
      const nxt = { o: last.c, c, h: Math.max(last.c, c) + Math.random() * t.entry * vol * 0.4, l: Math.min(last.c, c) - Math.random() * t.entry * vol * 0.4 }
      return [...d.slice(1), nxt]
    }), 1000)
    return () => clearInterval(id)
  }, [])
  const px = data[data.length - 1].c
  const dp = t.entry < 1 ? 4 : t.entry < 100 ? 2 : 0
  const size = t.size || (t.entry < 1 ? 100 : 3000)
  const pnl = ((px - t.entry) / t.entry) * size * (long ? 1 : -1)
  const fmtP = (v) => `$${(+v).toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp })}`
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 8, fontWeight: 500 }}><Mark name={t.sym} size={24} /> {t.title} <span className="muted" style={{ fontWeight: 400 }}>{t.side}</span></span>
        <span className="row small" style={{ gap: 6 }}><span className="live-dot" /> Live</span>
      </div>
      <div className="ccard-body">
        <div className="row between" style={{ alignItems: 'baseline', marginBottom: 8 }}>
          <span className="num" style={{ fontSize: 20, fontWeight: 600 }}>{fmtP(px)}</span>
          <span className={`num ${pnl >= 0 ? 'up' : 'down'}`} style={{ fontWeight: 500 }}>{pnl >= 0 ? '+' : '−'}${Math.abs(pnl).toFixed(2)}</span>
        </div>
        <CandleChart data={data} height={200} padTo={[t.tp, t.sl].filter(Boolean)} marks={[
          ...(t.tp ? [{ v: t.tp, label: `TP ${fmtP(t.tp)}`, color: '#15803D' }] : []),
          { v: t.entry, label: `Entry ${fmtP(t.entry)}`, color: '#121212' },
          ...(t.sl ? [{ v: t.sl, label: `SL ${fmtP(t.sl)}`, color: '#C53030' }] : []),
        ]} />
        <div className="kv" style={{ marginTop: 12 }}>
          <div><span>To TP</span><b className="up">{t.tp ? `${(Math.abs(t.tp - px) / px * 100).toFixed(1)}%` : '—'}</b></div>
          <div><span>To SL</span><b className="down">{t.sl ? `${(Math.abs(px - t.sl) / px * 100).toFixed(1)}%` : '—'}</b></div>
          <div><span>Liquidation</span><b>{t.liq ? fmtP(t.liq) : 'None'}</b></div>
        </div>
      </div>
    </div>
  )
}
