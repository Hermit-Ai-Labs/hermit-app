import { useState } from 'react'
import { Search, Check } from 'lucide-react'
import Mark from '../components/Mark'
import { dapps } from '../data'
import { useApp } from '../App'
import Tabs, { usePageTab } from '../components/Tabs'

const TABS = [['new', 'New'], ['trending', 'Trending'], ['all', 'All']]
const CATS = ['All', 'New', 'Perps', 'DEX', 'Lending', 'Yield', 'Stablecoin', 'Staking', 'RWA', 'Prediction', 'Presale', 'Launchpad', 'AI agents', 'Wallet']

export default function Explore() {
  const { toast } = useApp()
  const [q, setQ] = useState('')
  const [cat, setCat] = useState('All')
  const [tab, setTab] = usePageTab(TABS)
  const [conn, setConn] = useState(Object.fromEntries(dapps.map((d) => [d.name, d.conn])))
  const list = dapps.filter((d) => (cat === 'All' || d.cat === cat || (cat === 'New' && d.isNew)) && `${d.name} ${d.desc} ${d.cat}`.toLowerCase().includes(q.toLowerCase()))
  const hot = dapps.filter((d) => d.hot)

  const toggle = (d) => {
    setConn({ ...conn, [d.name]: !conn[d.name] })
    toast(conn[d.name] ? `${d.name} disconnected` : `${d.name} connected`)
  }

  // Claude-style connect control: Connect, or Connected that turns into Disconnect on hover.
  const ConnBtn = ({ d, block }) => conn[d.name]
    ? <button className={`conn-btn on ${block ? 'block' : ''}`} onClick={() => toggle(d)} aria-label={`Disconnect ${d.name}`}><span className="c-on"><Check size={13} /> Connected</span><span className="c-off">Disconnect</span></button>
    : <button className={`conn-btn ${block ? 'block' : ''}`} onClick={() => toggle(d)}>Connect</button>
  const card = (d) => (
    <div key={d.name} className="card dapp-card">
      <div className="row" style={{ gap: 10 }}><Mark name={d.name} size={36} /><div style={{ minWidth: 0 }}><div style={{ fontWeight: 500 }} className="ellipsis">{d.name}</div><div className="faint small ellipsis">{d.cat}</div></div></div>
      <div className="muted small dapp-desc">{d.desc}</div>
      <ConnBtn d={d} block />
    </div>
  )

  return (
    <div className="page">
      <div className="page-head tabbed">
        <h1>Explore</h1>
        <div className="search"><Search size={15} color="var(--faint)" /><input placeholder="Search" value={q} onChange={(e) => { setQ(e.target.value); if (e.target.value) setTab('all') }} /></div>
      </div>
      <Tabs tabs={TABS} value={tab} onChange={setTab} />

      {tab === 'new' && <div className="grid g4">{dapps.filter((d) => d.isNew).map(card)}</div>}
      {tab === 'trending' && <div className="grid g4">{hot.map(card)}</div>}

      {tab === 'all' && <>
        <div className="chips one-line" style={{ marginBottom: 8 }}>
          {CATS.map((c) => <button key={c} className={`chip sm ${c === cat ? 'on' : ''}`} onClick={() => setCat(c)}>{c}</button>)}
        </div>
        {list.map((d) => (
          <div className="list-row" key={d.name}>
            <Mark name={d.name} size={32} />
            <div className="grow"><div className="list-title">{d.name}{d.isNew && <span className="new-tag">New</span>}</div><div className="list-sub">{d.desc}<span className="hide-m">, {d.chain}</span></div></div>
            <ConnBtn d={d} />
          </div>
        ))}
        {!list.length && <p className="muted" style={{ padding: 24, textAlign: 'center' }}>No results</p>}
      </>}
    </div>
  )
}
