import { useState } from 'react'
import { Plus } from 'lucide-react'
import Mark from '../components/Mark'
import { baseChecks } from '../components/Approval'
import { connectors as seedConnectors, skills, apiMarket } from '../data'
import { AddMcpSheet } from '../components/Sheets'
import { useApp } from '../App'
import Tabs, { usePageTab } from '../components/Tabs'
import ConnectSheet from '../components/ConnectSheet'

const TABS = [['apps', 'Apps'], ['apis', 'Buy APIs'], ['skills', 'Skills']]

export default function Connectors() {
  const { approve, toast } = useApp()
  const [tab, setTab] = usePageTab(TABS)
  const [connecting, setConnecting] = useState(null)
  const [enabled, setEnabled] = useState({})
  const [connectors, setConnectors] = useState(seedConnectors)
  const [adding, setAdding] = useState(false)
  const [on, setOn] = useState(Object.fromEntries(seedConnectors.map((c) => [c.name, c.on])))
  const addMcp = (c) => { setConnectors((l) => [c, ...l]); setOn((o) => ({ ...o, [c.name]: true })); setTab('apps'); toast(`${c.name} connected`) }

  return (
    <div className="page" style={{ maxWidth: 720 }}>
      <div className="page-head tabbed">
        <h1>Connectors</h1>
        <button className="btn" onClick={() => setAdding(true)}><Plus size={15} /> MCP</button>
      </div>
      <Tabs tabs={TABS} value={tab} onChange={setTab} />

      {tab === 'apps' && connectors.map((c) => (
        <div className="list-row" key={c.name}>
          <Mark name={c.name} size={34} />
          <div className="grow"><div className="list-title">{c.name}</div><div className="list-sub">{c.desc}</div></div>
          <button className={`toggle ${on[c.name] ? 'on' : ''}`} onClick={() => (on[c.name] ? (setOn({ ...on, [c.name]: false }), toast(`${c.name} disconnected`)) : /OAuth|MCP/.test(c.kind) ? setConnecting(c.name) : (setOn({ ...on, [c.name]: true }), toast(`${c.name} on`)))} aria-label={`Toggle ${c.name}`} />
        </div>
      ))}

      {tab === 'apis' && apiMarket.map((a) => (
        <div className="list-row" key={a.name}>
          <Mark name={a.by} size={34} />
          <div className="grow"><div className="list-title">{a.name}</div><div className="list-sub">{a.price}</div></div>
          <button className="btn sm primary" onClick={() => approve({
            kind: 'API purchase', title: a.name, success: `${a.name} connected`,
            lines: [['Seller', a.by], ['Price', a.price], ['Pay with', 'USDC'], ['Monthly cap', '$100']],
            checks: baseChecks([{ label: 'Seller matches registry', status: 'pass' }]),
          })}>Buy</button>
        </div>
      ))}

      {tab === 'skills' && skills.map((s) => (
        <div className="list-row" key={s.name}>
          <div className="grow"><div className="list-title">{s.name}</div><div className="list-sub">{s.desc}</div></div>
          {s.locked ? <span className="faint small">Always on</span> : enabled[s.name] ? <button className="tag green" onClick={() => { setEnabled({ ...enabled, [s.name]: false }); toast(`${s.name} off`) }}><span className="dot" />On</button> : <button className="btn sm" onClick={() => { setEnabled({ ...enabled, [s.name]: true }); toast(`${s.name} enabled`) }}>Enable</button>}
        </div>
      ))}
      {connecting && <ConnectSheet app={connecting} onDone={() => setOn((o) => ({ ...o, [connecting]: true }))} onClose={() => setConnecting(null)} />}
      {adding && <AddMcpSheet onAdd={addMcp} onClose={() => setAdding(false)} />}
    </div>
  )
}
