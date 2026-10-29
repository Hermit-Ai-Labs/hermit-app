import { useState } from 'react'
import { Upload, Mail } from 'lucide-react'
import Mark from '../components/Mark'
import { baseChecks } from '../components/Approval'
import { payments, fmt, liveSchedule, next7Days, contacts, wallets, bills, myApis, apiCatalog } from '../data'
import { useApp } from '../App'
import ExploreMore from '../components/ExploreMore'
import { ScheduleSheet } from '../components/Sheets'
import Tabs, { usePageTab } from '../components/Tabs'

const TABS = [['schedule', 'Schedule'], ['approvals', 'Approvals'], ['transfer', 'Transfer'], ['bills', 'Bills'], ['apis', 'APIs']]
const pending = payments.filter((p) => p.status === 'Needs approval')

export default function Payments() {
  const [tab, setTab] = usePageTab(TABS)
  const tabs = TABS.map(([k, l]) => [k, l, k === 'approvals' ? pending.length : null])
  return (
    <div className="page">
      <div className="page-head tabbed"><h1>Payments</h1><span className="muted num">$8,200 USDC</span></div>
      <Tabs tabs={tabs} value={tab} onChange={setTab} />
      {tab === 'schedule' && <Schedule />}
      {tab === 'approvals' && <Approvals />}
      {tab === 'transfer' && <Transfer />}
      {tab === 'bills' && <Bills />}
      {tab === 'apis' && <Apis />}
      {['schedule', 'apis'].includes(tab) && <ExploreMore label="services" items={[
        ...apiCatalog.map((x) => ({ name: `${x.by} ${x.name}`, logo: x.by, sub: x.price, tag: x.cat })),
        { name: 'Pay a freelancer', logo: 'USDC', sub: 'Send USDC to anyone' },
        { name: 'Mobile top-up', logo: 'USDC', sub: '150 countries' },
        { name: 'Gift cards', logo: 'USDC', sub: 'Amazon, Apple, Steam' },
        { name: 'Subscriptions', logo: 'USDC', sub: 'Netflix, Spotify, Notion' },
      ]} />}
    </div>
  )
}

function Schedule() {
  const [sched, setSched] = useState(null)
  const max = Math.max(...next7Days)
  return (
    <>
      <div className="grid g2" style={{ marginBottom: 24 }}>
        <div className="card">
          <div className="row between"><span className="stat-label">Next 7 days</span><b className="num">${next7Days.reduce((a, b) => a + b, 0).toFixed(0)}</b></div>
          <div className="row" style={{ alignItems: 'flex-end', gap: 6, height: 70, marginTop: 14 }}>
            {next7Days.map((v, i) => (
              <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
                <div style={{ width: '100%', height: Math.max(3, (v / max) * 52), background: v ? 'var(--text)' : 'var(--hover)', borderRadius: 3 }} />
                <span className="faint" style={{ fontSize: 10.5 }}>{['M', 'T', 'W', 'T', 'F', 'S', 'S'][i]}</span>
              </div>
            ))}
          </div>
        </div>
        <div className="card">
          <div className="stat-label">Pays from</div>
          <div className="row" style={{ marginTop: 8 }}><Mark name="USDC" size={28} /><div className="grow"><div style={{ fontWeight: 500 }}>USDC on Base</div><div className="muted small num">$8,200 available</div></div></div>
        </div>
      </div>
      <div className="section-title"><span>Live schedule</span><span className="tag green"><span className="dot" />Running</span></div>
      {liveSchedule.map((p) => (
        <button className="list-row" key={p.to + p.what} onClick={() => setSched(p)}>
          <Mark name={p.to} size={32} />
          <div className="grow"><div className="list-title">{p.to}</div><div className="list-sub">{p.what} with {p.rail}</div></div>
          <div className="list-end"><div>{p.amt < 1 ? `$${p.amt}` : fmt.usd(p.amt)}</div><div className={`small ${p.live ? 'up' : 'faint'}`}>{p.when}</div></div>
        </button>
      ))}
      {sched && <ScheduleSheet item={sched} onClose={() => setSched(null)} />}
    </>
  )
}

function Approvals() {
  const { approve } = useApp()
  const review = (p) => approve({
    kind: 'Payment', title: `Pay ${p.to} ${fmt.usd(p.amt)}`, success: `Paid ${p.to}`,
    lines: [['For', p.what], ['Amount', fmt.usd(p.amt, 2)], ['Method', p.method], ['Due', p.due]],
    checks: baseChecks([{ label: 'Recipient matches saved payee', status: 'pass' }]),
  })
  return (
    <>
      <p className="muted small" style={{ marginBottom: 8 }}>Above your $100 auto-pay limit, so Hermit waits for you.</p>
      {pending.map((p) => (
        <div className="list-row" key={p.to}>
          <Mark name={p.to} size={32} />
          <div className="grow"><div className="list-title">{p.to}</div><div className="list-sub">{p.what}</div></div>
          <div className="list-end"><div>{fmt.usd(p.amt)}</div><div className="faint small">{p.due}</div></div>
          <button className="btn sm primary" onClick={() => review(p)}>Review</button>
        </div>
      ))}
    </>
  )
}

function Transfer() {
  const { approve } = useApp()
  const [to, setTo] = useState('')
  const [token, setToken] = useState('USDC')
  const [amt, setAmt] = useState('')
  const own = wallets.filter((w) => w.id !== 'main')
  const saved = contacts.some((c) => c.name === to) || to.startsWith('My ')
  const send = () => approve({
    kind: 'Transfer', title: `Send ${amt} ${token}`, success: `Sent to ${to}`,
    lines: [['To', to], ['Amount', `${amt} ${token}`], ['From', 'Main'], ['Fee', '$0.01']],
    checks: baseChecks([{ label: saved ? 'Saved contact' : 'New address, double-check it', status: saved ? 'pass' : 'warn' }]),
  })
  return (
    <div className="stack" style={{ gap: 18 }}>
      <label className="field">To
        <input className="tx" style={{ height: 44, padding: '0 12px', outline: 0, fontSize: 14 }} placeholder="Address, ENS or email" value={to} onChange={(e) => setTo(e.target.value)} />
      </label>
      <div className="chips">
        {contacts.map((c) => <button key={c.name} className={`chip sm ${to === c.name ? 'on' : ''}`} onClick={() => setTo(c.name)}>{c.name}</button>)}
        {own.slice(0, 2).map((w) => <button key={w.id} className={`chip sm ${to === `My ${w.name}` ? 'on' : ''}`} onClick={() => setTo(`My ${w.name}`)}>My {w.name}</button>)}
      </div>
      <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
        <label className="field">Amount<input type="number" placeholder="0" value={amt} onChange={(e) => setAmt(e.target.value)} /></label>
        <label className="field">Token<select value={token} onChange={(e) => setToken(e.target.value)}>{['USDC', 'ETH', 'SOL', 'HYPE'].map((t) => <option key={t}>{t}</option>)}</select></label>
      </div>
      <button className="btn primary block" style={{ height: 42 }} disabled={!to || !amt} onClick={send}>Review</button>
      <div className="section">
        <div className="section-title">Recent</div>
        {[['alice.eth', '1,200 USDC', 'Oct 1'], ['My Vault', '0.5 ETH', 'Sep 28'], ['Mom', '200 USDC', 'Sep 20']].map(([n, a, w]) => (
          <div className="list-row" key={n + w}><div className="grow"><div className="list-title">{n}</div><div className="list-sub">{w}</div></div><div className="list-end">{a}</div></div>
        ))}
      </div>
    </div>
  )
}

function Bills() {
  const { approve, toast } = useApp()
  const pay = (b) => approve({
    kind: 'Bill payment', title: `Pay ${b.to} ${fmt.usd(b.amt)}`, success: `Paid ${b.to}`,
    lines: [['To', b.bank], ['Amount', fmt.usd(b.amt, 2)], ['Route', 'USDC to bank via Bridge'], ['Arrives', '1 business day']],
    checks: baseChecks([{ label: 'Bank details unchanged', status: 'pass' }]),
  })
  return (
    <>
      <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
        <button className="card row" style={{ gap: 10 }} onClick={() => toast('Drop a PDF invoice')}><Upload size={16} /><span>Upload invoice</span></button>
        <button className="card row" style={{ gap: 10 }} onClick={() => toast('Forward bills to ryan@bills.hermit.app')}><Mail size={16} /><span>Forward email</span></button>
      </div>
      <div className="section">
        <div className="section-title">Upcoming</div>
        {bills.map((b) => (
          <div className="list-row" key={b.to}>
            <Mark name={b.to} size={32} />
            <div className="grow"><div className="list-title">{b.to}</div><div className="list-sub">{b.what}</div></div>
            <div className="list-end"><div>{fmt.usd(b.amt)}</div><div className="faint small">{b.due}</div></div>
            <button className="btn sm" onClick={() => pay(b)}>Pay</button>
          </div>
        ))}
      </div>
      <p className="faint small" style={{ marginTop: 16 }}>Paid from USDC. The payee gets dollars in their bank.</p>
    </>
  )
}

function Apis() {
  const { approve } = useApp()
  const [mine, setMine] = useState(myApis)
  const [cat, setCat] = useState('All')
  const list = apiCatalog.filter((a) => cat === 'All' || a.cat === cat)
  return (
    <>
      <div className="section-title">Yours this month</div>
      {mine.map((a) => (
        <div className="list-row" key={a.name}>
          <Mark name={a.name} size={32} />
          <div className="grow">
            <div className="row between"><span className="list-title">{a.name} {a.plan}</span><span className="num small">${a.used} of ${a.cap}</span></div>
            <div className="bar-track" style={{ marginTop: 8 }}><div className="bar-fill" style={{ width: `${(a.used / a.cap) * 100}%` }} /></div>
            <div className="list-sub" style={{ marginTop: 4 }}>{a.calls}</div>
          </div>
        </div>
      ))}

      <div className="section">
        <div className="section-title">Marketplace</div>
        <div className="chips" style={{ marginBottom: 6 }}>{['All', 'AI', 'Search', 'Data', 'Crypto'].map((c) => <button key={c} className={`chip sm ${c === cat ? 'on' : ''}`} onClick={() => setCat(c)}>{c}</button>)}</div>
        {list.map((a) => {
          const owned = mine.some((m) => m.name === a.by)
          return (
            <div className="list-row" key={a.by + a.name}>
              <Mark name={a.by} size={32} />
              <div className="grow"><div className="list-title">{a.by} {a.name}</div><div className="list-sub">{a.price}</div></div>
              {owned ? <span className="faint small">Active</span> : (
                <button className="btn sm primary" onClick={() => approve({
                  kind: 'API purchase', title: `${a.by} ${a.name}`, success: `${a.by} connected`,
                  lines: [['Price', a.price], ['Pay with', 'USDC via x402'], ['Monthly cap', '$50'], ['Key', 'Stored in local vault']],
                  checks: baseChecks([{ label: 'Seller matches registry', status: 'pass' }]),
                  onSuccess: () => setMine((m) => [...m, { name: a.by, plan: a.name, used: 0, cap: 50, calls: 'Just added' }]),
                })}>Buy</button>
              )}
            </div>
          )
        })}
      </div>
    </>
  )
}
