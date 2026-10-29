import { useState } from 'react'
import { X } from 'lucide-react'
import { FlowDiagram } from './Charts'
import { useApp } from '../App'
import { threadFor, threads } from '../threads'

// Detail view for a running strategy (Trade and Earn). Strategies come from chat or projects.
export default function StrategySheet({ st, onClose }) {
  const { toast, openThread, openProject } = useApp()
  const [running, setRunning] = useState(st.status === 'Running')
  const fromChat = st.source === 'From chat'
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{ maxWidth: 560 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div><div className="muted small">{st.source}</div><div style={{ fontSize: 17, fontWeight: 600 }}>{st.name}</div></div>
          <button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
        </div>
        <div className="modal-body stack" style={{ gap: 18 }}>
          <div className="kv">
            <div><span>PnL 30d</span><b className={st.pnl >= 0 ? 'up' : 'down'}>{st.pnl >= 0 ? '+' : '−'}${Math.abs(st.pnl).toLocaleString()}</b></div>
            <div><span>Capital</span><b>${st.capital.toLocaleString()}</b></div>
            <div><span>Win rate</span><b>{st.win}</b></div>
            <div><span>Status</span><b>{running ? 'Running' : 'Paused'}</b></div>
          </div>
          <FlowDiagram steps={st.steps} />
          <div>
            <div className="section-title">Recent</div>
            {st.trades.map(([t, w, p]) => (
              <div className="list-row" key={t + w} style={{ padding: '9px 0' }}>
                <div className="grow"><div className="ellipsis">{t}</div><div className="list-sub">{w}</div></div>
                {p && <div className={`list-end ${p.startsWith('+') ? 'up' : 'down'}`}>{p}</div>}
              </div>
            ))}
          </div>
        </div>
        <div className="modal-foot">
          <button className="btn" style={{ flex: 1 }} onClick={() => { setRunning(!running); toast(running ? 'Strategy paused' : 'Strategy resumed') }}>{running ? 'Pause' : 'Resume'}</button>
          <button className="btn primary" style={{ flex: 1 }} onClick={() => { const t = threads[threadFor[st.id]]; t.project ? openProject(t.project) : openThread(threadFor[st.id]) }}>{fromChat ? 'Open chat' : 'Open project'}</button>
        </div>
      </div>
    </div>
  )
}
