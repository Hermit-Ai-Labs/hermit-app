import { BookMarked } from 'lucide-react'
import { useApp } from '../App'

// Confirmation shown in chat after saving something to long-term memory.
export default function MemoryCard({ item }) {
  const { go } = useApp()
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 8, fontWeight: 500 }}><BookMarked size={15} color="var(--accent)" /> hermit.md</span>
        <button className="btn sm" onClick={() => go('settings/memory')}>View memory</button>
      </div>
      <div className="ccard-body">
        <div className="tx mono" style={{ padding: '10px 14px', fontSize: 12.5 }}><span className="up">+ </span>{item}</div>
      </div>
    </div>
  )
}
