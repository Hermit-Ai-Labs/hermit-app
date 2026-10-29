import { useState } from 'react'
import { Mic, Mail, FileText, BookOpen, Search, Upload } from 'lucide-react'
import { files as seedFiles } from '../data'
import { RecordSheet, AttachPicker } from '../components/Sheets'
import { useApp } from '../App'

const TYPES = ['All', 'Meeting notes', 'Email', 'Doc', 'Research']
const ICON = { 'Meeting notes': Mic, Email: Mail, Doc: FileText, Research: BookOpen }

export default function Files() {
  const { toast, openFile } = useApp()
  const [files, setFiles] = useState(seedFiles)
  const [sheet, setSheet] = useState(null)
  const add = (f) => { setFiles((l) => [f, ...l]); toast(`${f.name} added`) }
  const [type, setType] = useState('All')
  const [q, setQ] = useState('')
  const list = files.filter((f) => (type === 'All' || f.type === type) && f.name.toLowerCase().includes(q.toLowerCase()))

  return (
    <div className="page" style={{ maxWidth: 720 }}>
      <div className="page-head">
        <h1>Files</h1>
        <div className="row">
          <button className="btn" onClick={() => setSheet('record')}><Mic size={15} /> Record</button>
          <button className="btn" onClick={() => setSheet('upload')}><Upload size={15} /> Upload</button>
        </div>
      </div>
      <div className="search" style={{ width: '100%', marginBottom: 12 }}><Search size={15} color="var(--faint)" /><input placeholder="Search files" value={q} onChange={(e) => setQ(e.target.value)} /></div>
      <div className="chips" style={{ marginBottom: 8 }}>{TYPES.map((t) => <button key={t} className={`chip sm ${t === type ? 'on' : ''}`} onClick={() => setType(t)}>{t}</button>)}</div>
      {list.map((f) => {
        const Ic = ICON[f.type] || FileText
        return (
          <button className="list-row" key={f.name} onClick={() => openFile(f)}>
            <span className="mark app" style={{ width: 34, height: 34 }}><Ic size={15} strokeWidth={1.75} /></span>
            <div className="grow"><div className="list-title">{f.name}</div><div className="list-sub">{f.src}</div></div>
            <span className="faint small">{f.when}</span>
          </button>
        )
      })}
      {sheet === 'record' && <RecordSheet onSave={add} onClose={() => setSheet(null)} />}
      {sheet === 'upload' && <AttachPicker onPick={(f) => add({ name: f.name, type: f.kind === 'csv' || f.kind === 'paper' ? 'Doc' : 'Doc', src: f.src, when: 'Just now', size: f.size })} onClose={() => setSheet(null)} />}
    </div>
  )
}
