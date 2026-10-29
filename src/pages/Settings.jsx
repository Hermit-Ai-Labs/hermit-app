import { useState } from 'react'
import { BookMarked } from 'lucide-react'
import { ModelSheet } from '../components/Sheets'
import { useApp } from '../App'
import Tabs, { usePageTab } from '../components/Tabs'

const models = [
  { name: 'Text', d: 'Hermit 8B, 4.9 GB' },
  { name: 'Speech', d: '1.5 GB' },
  { name: 'Image & video', d: '6.2 GB' },
  { name: 'Documents', d: '2.1 GB', update: true },
]

const TABS = [['safety', 'Safety'], ['memory', 'Memory'], ['models', 'Models'], ['home', 'Home']]

export default function Settings() {
  const { settings, setSettings } = useApp()
  const [tab, setTab] = usePageTab(TABS)
  const [model, setModel] = useState(null)
  const set = (k, v) => setSettings((s) => ({ ...s, [k]: v }))

  return (
    <div className="page" style={{ maxWidth: 640 }}>
      <div className="page-head tabbed"><h1>Settings</h1></div>
      <Tabs tabs={TABS} value={tab} onChange={setTab} />

      {tab === 'safety' && (
        <>
          <div className="list-row">
            <div className="grow">Ask me before spending over</div>
            <select value={settings.askAbove} onChange={(e) => set('askAbove', +e.target.value)} className="btn sm">
              {[0, 50, 100, 500, 1000].map((v) => <option key={v} value={v}>{v === 0 ? 'Always ask' : `$${v}`}</option>)}
            </select>
          </div>
          <div className="list-row">
            <div className="grow">Daily limit</div>
            <select value={settings.daily || 2000} onChange={(e) => set('daily', +e.target.value)} className="btn sm">
              {[500, 1000, 2000, 5000, 10000].map((v) => <option key={v} value={v}>${v.toLocaleString()}</option>)}
            </select>
          </div>
          <div className="list-row"><div className="grow">Hazard scan, injection shield, approval limits</div><span className="faint small">Always on</span></div>
        </>
      )}

      {tab === 'memory' && <MemorySection />}

      {tab === 'home' && (
        <>
          <Toggle label="Balance" on={settings.showAUM} onChange={() => set('showAUM', !settings.showAUM)} />
          <Toggle label="Today" on={settings.showTodos} onChange={() => set('showTodos', !settings.showTodos)} />
        </>
      )}

      {tab === 'models' && models.map((m) => (
        <button className="list-row" key={m.name} onClick={() => setModel(m)}>
          <div className="grow"><div className="list-title">{m.name}</div><div className="list-sub">{m.d}</div></div>
          {m.update ? <span className="btn sm">Update</span> : <span className="tag green"><span className="dot" />Ready</span>}
        </button>
      ))}
      {model && <ModelSheet model={model} onClose={() => setModel(null)} />}
    </div>
  )
}

function Toggle({ label, on, onChange }) {
  return (
    <div className="list-row">
      <div className="grow">{label}</div>
      <button className={`toggle ${on ? 'on' : ''}`} onClick={onChange} aria-label={label} />
    </div>
  )
}

// Long-term memory as an editable markdown file. Chat can append to it too.
function MemorySection() {
  const { memory, setMemory, toast } = useApp()
  const toMd = (m) => m.map((x) => `- ${x}`).join('\n')
  const [text, setText] = useState(toMd(memory))
  const dirty = text !== toMd(memory)
  const save = () => { setMemory(text.split('\n').map((l) => l.replace(/^[-*]\s*/, '').trim()).filter(Boolean)); toast('Memory saved') }
  return (
    <div>
      <div className="section-title"><span className="row" style={{ gap: 6 }}><BookMarked size={14} /> Long-term memory</span><span className="faint mono">hermit.md</span></div>
      <p className="muted small" style={{ marginBottom: 10 }}>Hermit follows this in every chat. Add to it here, or say "add … to your long-term memory" in chat.</p>
      <textarea className="md-editor" value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} aria-label="Long-term memory" />
      <div className="row" style={{ justifyContent: 'flex-end', marginTop: 8, gap: 8 }}>
        {dirty && <button className="btn sm ghost" onClick={() => setText(toMd(memory))}>Discard</button>}
        <button className="btn sm primary" disabled={!dirty} onClick={save}>Save</button>
      </div>
    </div>
  )
}
