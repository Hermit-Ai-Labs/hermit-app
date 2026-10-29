import { useState } from 'react'
import { Plus, ArrowLeft, ArrowUp, MessageCircle, ChevronRight, ScrollText, RefreshCw } from 'lucide-react'
import { NewProjectSheet, FileIcon } from '../components/Sheets'
import { AreaChart } from '../components/Charts'
import { ICONS } from '../components/icons'
import { walk, projectBurn, projectForecast, projectGains } from '../data'
import { useApp } from '../App'
import Tabs from '../components/Tabs'
import ChatInput from '../components/ChatInput'

export default function Projects() {
  const { projects, addProject, projectOpen, setProjectOpen } = useApp()
  const [creating, setCreating] = useState(false)
  const open = projects.find((p) => p.name === projectOpen)
  const create = ({ name, tpl, budget }) => {
    const icon = { 'DeFi yield': 'Sprout', 'Trading bot': 'TrendingUp', 'Airdrop farming': 'Gift', Research: 'BookOpen', 'Dev tool': 'Code2' }[tpl] || 'Folder'
    addProject({ name, icon, desc: tpl, status: 'Draft', pnl: '—', money: budget, cost: 0, gain: 0, gainLabel: 'Gain', gainNote: 'Just created', chats: [], fileList: ['project.md'] })
    setProjectOpen(name)
  }
  if (open) return <ProjectView p={open} onBack={() => setProjectOpen(null)} />

  return (
    <div className="page">
      <div className="page-head">
        <h1>Projects</h1>
        <button className="btn primary" onClick={() => setCreating(true)}><Plus size={15} /> New</button>
      </div>
      <div className="grid g3">
        {projects.map((p) => {
          const Ic = ICONS[p.icon] || ICONS.Folder
          return (
            <button key={p.name} className="card stack" style={{ gap: 14 }} onClick={() => setProjectOpen(p.name)}>
              <div className="row between">
                <Ic size={18} strokeWidth={1.75} />
                {p.status !== 'Running' && <span className="faint small">{p.status}</span>}
              </div>
              <div>
                <div style={{ fontWeight: 500 }}>{p.name}</div>
                <div className="muted small" style={{ marginTop: 2 }}>{p.desc}</div>
              </div>
              <div className="row between small" style={{ marginTop: 'auto' }}><span className={`num ${p.gain > 0 ? 'up' : p.gain < 0 ? 'down' : 'faint'}`}>{p.pnl}</span><span className="faint">{p.chats.length} chats</span></div>
            </button>
          )
        })}
      </div>
      {creating && <NewProjectSheet onCreate={create} onClose={() => setCreating(false)} />}
    </div>
  )
}

function ProjectView({ p, onBack }) {
  const { openThread, newChat, openFile, costsOff, toggleCost, toast } = useApp()
  const [tab, setTab] = useState('overview')
  const burn = projectBurn[p.name]
  const burnTotal = burn ? burn.filter(([w]) => !costsOff[`${p.name}/${w}`]).reduce((a, [, x]) => a + x, 0) : 0
  const gains = projectGains[p.name]
  const fc = projectForecast[p.name]
  const files = p.fileList || ['strategy.ts', 'backtest.csv', 'notes.md']
  const usd = (n) => (n < 0 ? '−' : '') + '$' + Math.abs(n).toLocaleString()
  // Gain history for the chart: a smooth climb (or slide) to today's recorded gain.
  const series = walk(30, 100, 0.06, p.name.length, p.gain >= 0 ? 0.1 : -0.1).map((v, i) => v + i * (p.gain >= 0 ? 4 : -4))
  return (
    <div className="page" style={{ maxWidth: 760 }}>
      <div className="page-head tabbed">
        <div className="row" style={{ minWidth: 0 }}><button className="icon-btn" onClick={onBack} aria-label="Back"><ArrowLeft size={18} /></button><h1>{p.name}</h1></div>
      </div>

      <div className="project-composer"><ChatInput rows={2} projectPicker={false} label="Uses this project's files" placeholder={`Start a chat in ${p.name}`} onSend={(msg) => { newChat(p.name); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: msg })), 60) }} /></div>
      <Tabs tabs={[['overview', 'Overview'], ['chats', 'Chats', p.chats.length || null], ['instructions', 'Instructions'], ['files', 'Files']]} value={tab} onChange={setTab} />

      {tab === 'overview' && <>
      <div className="stats">
        <div><div className="stat-label">In operation</div><div className="stat-value">{usd(p.money)}</div></div>
        <div><div className="stat-label">Cost</div><div className="stat-value">{usd(p.cost)}</div></div>
        <div><div className="stat-label">{p.gainLabel}</div><div className={`stat-value ${p.gain > 0 ? 'up' : p.gain < 0 ? 'down' : ''}`}>{p.gain > 0 ? '+' : ''}{usd(p.gain)}</div></div>
        <div><div className="stat-label">Net</div><div className={`stat-value ${p.gain - p.cost >= 0 ? 'up' : 'down'}`}>{p.gain - p.cost >= 0 ? '+' : ''}{usd(p.gain - p.cost)}</div></div>
      </div>
      <div className="card" style={{ marginTop: 16 }}>
        <div className="row between"><span className="stat-label">Gains</span><b className={`num ${p.gain > 0 ? 'up' : p.gain < 0 ? 'down' : ''}`}>{p.gain > 0 ? '+' : ''}{usd(p.gain)}</b></div>
        {p.gain !== 0 && <div style={{ margin: '12px 0 4px' }}><AreaChart data={series} height={96} id={`proj-${p.icon}`} color={p.gain < 0 ? '#C53030' : '#121212'} /></div>}
        {(gains || []).map(([what, amt]) => (
          <div className="row between small" key={what} style={{ marginTop: 8 }}><span className="muted">{what}</span><span className={`num ${amt > 0 ? 'up' : amt < 0 ? 'down' : 'faint'}`}>{amt > 0 ? '+' : ''}{usd(amt)}</span></div>
        ))}
      </div>
      {(burn || fc) && (
        <div className="grid g2" style={{ marginTop: 16 }}>
          {burn && (
            <div className="card">
              <div className="row between"><span className="stat-label">Costs</span><b className="num down">−{usd(burnTotal)}/mo</b></div>
              {burn.map(([what, amt]) => {
                const off = costsOff[`${p.name}/${what}`]
                return (
                  <div className="row between small cost-row" key={what}>
                    <span className={off ? 'faint' : 'muted'} style={off ? { textDecoration: 'line-through' } : undefined}>{what}</span>
                    <span className="row" style={{ gap: 10 }}><span className={`num ${off ? 'faint' : ''}`}>{usd(amt)}</span>
                      <button className={`toggle sm ${off ? '' : 'on'}`} onClick={() => { toggleCost(p.name, what); toast(off ? `${what} back on` : `${what} paused, saves ${usd(amt)} a month`) }} aria-label={`Toggle ${what}`} /></span>
                  </div>
                )
              })}
              <div className="faint small" style={{ marginTop: 10 }}>{burnTotal === 0 ? 'All paused' : p.money <= 0 ? 'Auto-payments' : p.money >= burnTotal ? `Runway ${Math.floor(p.money / burnTotal)} mo` : `Runway ${Math.floor((p.money / burnTotal) * 30)} days`}</div>
            </div>
          )}
          {fc && (
            <div className="card">
              <div className="row between"><span className="stat-label">Expected / mo</span><b className={`num ${fc.monthly >= 0 ? 'up' : 'down'}`}>{fc.monthly >= 0 ? '+' : ''}{usd(fc.monthly)}</b></div>
              <div className="muted small" style={{ marginTop: 8 }}>{fc.basis}</div>
              {burn && <div className="row between small" style={{ marginTop: 8 }}><span className="muted">After costs</span><span className={`num ${fc.monthly - burnTotal >= 0 ? 'up' : 'down'}`}>{fc.monthly - burnTotal >= 0 ? '+' : ''}{usd(fc.monthly - burnTotal)}</span></div>}
              <div className="faint small row" style={{ marginTop: 10, gap: 6 }}><RefreshCw size={11} /> Updates daily, next in {24 - fc.updated}h</div>
            </div>
          )}
        </div>
      )}
      </>}

      {tab === 'instructions' && <Instructions p={p} />}

      {tab === 'chats' && <div>
        {!p.chats.length && <p className="muted small" style={{ padding: '8px 0' }}>No chats yet. Start one and it will show up here.</p>}
        {p.chats.map(([id, title, when]) => (
          <button className="list-row" key={id} onClick={() => openThread(id)}>
            <MessageCircle size={16} strokeWidth={1.75} color="var(--muted)" />
            <div className="grow"><div className="list-title">{title}</div><div className="list-sub">{when}</div></div>
            <ChevronRight size={15} color="var(--faint)" />
          </button>
        ))}
      </div>}

      {tab === 'files' && <div>
        {files.map((f) => (
          <button className="list-row" key={f} onClick={() => openFile({ name: f, src: p.name, when: 'This week' })}><FileIcon name={f} size={32} /><div className="grow list-title" style={{ fontWeight: 400 }}>{f}</div><ChevronRight size={15} color="var(--faint)" /></button>
        ))}
      </div>}
    </div>
  )
}

// Project-specific instructions (project.md), like Claude's project knowledge.
function Instructions({ p }) {
  const { projectMd, setProjectMd, toast } = useApp()
  const fallback = `# ${p.name}\n\n## Goal\n${p.desc}\n\n## Rules\n- Budget: $${p.money.toLocaleString()}\n- Ask me before any single move over $500\n- Report ${p.gainLabel.toLowerCase()} every Monday`
  const saved = projectMd[p.name] ?? fallback
  const [text, setText] = useState(saved)
  const [open, setOpen] = useState(false)
  return (
    <div>
      <div className="section-title">
        <span className="row" style={{ gap: 6 }}><ScrollText size={14} /> Instructions <span className="faint mono">project.md</span></span>
        <button className="btn sm ghost" onClick={() => setOpen(!open)}>{open ? 'Close' : 'Edit'}</button>
      </div>
      {open ? (
        <>
          <textarea className="md-editor" value={text} onChange={(e) => setText(e.target.value)} spellCheck={false} aria-label="Project instructions" />
          <div className="row" style={{ justifyContent: 'flex-end', marginTop: 8 }}>
            <button className="btn sm primary" disabled={text === saved} onClick={() => { setProjectMd({ ...projectMd, [p.name]: text }); setOpen(false); toast('Instructions saved') }}>Save</button>
          </div>
        </>
      ) : (
        <p className="muted small" style={{ whiteSpace: 'pre-line', lineHeight: 1.7 }}>{saved.replace(/^#+ .*\n+/gm, '').trim()}</p>
      )}
    </div>
  )
}
