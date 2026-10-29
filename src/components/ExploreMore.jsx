import { useState } from 'react'
import { Search, X, ChevronRight } from 'lucide-react'
import Mark from './Mark'
import { useApp } from '../App'

// "Explore more" + search, at the bottom of Earn, Trade and Payments. Picking an item asks Hermit about it.
export default function ExploreMore({ label, items }) {
  const { go } = useApp()
  const [open, setOpen] = useState(false)
  const [q, setQ] = useState('')
  const list = items.filter((i) => `${i.name} ${i.sub} ${i.tag || ''}`.toLowerCase().includes(q.toLowerCase()))
  const pick = (i) => { setOpen(false); go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: `Tell me about ${i.name}` })), 50) }
  return (
    <>
      <div className="row" style={{ marginTop: 36, gap: 8 }}>
        <button className="btn grow" style={{ height: 40 }} onClick={() => setOpen(true)}>Explore more {label}</button>
        <button className="btn" style={{ height: 40, width: 40, padding: 0 }} onClick={() => setOpen(true)} aria-label={`Search ${label}`}><Search size={16} /></button>
      </div>
      {open && (
        <div className="modal-backdrop" onClick={() => setOpen(false)}>
          <div className="modal" style={{ maxWidth: 520, height: '80vh', display: 'flex', flexDirection: 'column' }} onClick={(e) => e.stopPropagation()}>
            <div className="modal-head" style={{ alignItems: 'center' }}>
              <div className="search grow" style={{ width: 'auto' }}><Search size={15} color="var(--faint)" /><input autoFocus placeholder={`Search ${label}`} value={q} onChange={(e) => setQ(e.target.value)} /></div>
              <button className="icon-btn" onClick={() => setOpen(false)} aria-label="Close"><X size={16} /></button>
            </div>
            <div className="modal-body" style={{ overflowY: 'auto', flex: 1 }}>
              {list.map((i) => (
                <button className="list-row" key={i.name + (i.tag || '')} onClick={() => pick(i)}>
                  <Mark name={i.logo || i.name} size={30} />
                  <div className="grow"><div className="list-title">{i.name}</div><div className="list-sub">{i.sub}</div></div>
                  {i.metric && <div className="list-end small">{i.metric}</div>}
                  <ChevronRight size={15} color="var(--faint)" />
                </button>
              ))}
              {!list.length && <p className="muted" style={{ textAlign: 'center', padding: 24 }}>No results</p>}
            </div>
          </div>
        </div>
      )}
    </>
  )
}
