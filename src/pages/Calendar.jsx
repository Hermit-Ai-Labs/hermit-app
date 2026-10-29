import { useEffect, useState } from 'react'
import { ChevronLeft, ChevronRight, Plus, X, Trash2, Sparkles, ArrowUpRight } from 'lucide-react'
import { TODAY, projects, projectColors } from '../data'
import { useApp } from '../App'

// Notion-Calendar-style planner: week (day on phones), month and board views over one list of items.
// Items: { id, t, date, time?, dur?, project?, status?: todo|doing|done, event?, to?, ask? }

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
const START = 8, END = 20, ROW = 48
const STATUS = { todo: 'To do', doing: 'In progress', done: 'Done' }

const toIso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
const fromIso = (s) => new Date(s + 'T00:00')
const addDays = (s, n) => { const d = fromIso(s); d.setDate(d.getDate() + n); return toIso(d) }
const monday = (s) => addDays(s, -((fromIso(s).getDay() + 6) % 7))
const mins = (t) => { const [h, m] = t.split(':').map(Number); return h * 60 + m }
const color = (t) => projectColors[t.project] || (t.event ? '#8A8A8A' : '#121212')

function useNarrow() {
  const q = '(max-width: 860px)'
  const [n, setN] = useState(() => window.matchMedia(q).matches)
  useEffect(() => { const m = window.matchMedia(q); const on = () => setN(m.matches); m.addEventListener('change', on); return () => m.removeEventListener('change', on) }, [])
  return n
}

export default function Calendar() {
  const { todos } = useApp()
  const narrow = useNarrow()
  const [view, setView] = useState('week')
  const [cursor, setCursor] = useState(TODAY)
  const [filter, setFilter] = useState(null)
  const [edit, setEdit] = useState(null) // item being viewed, or a draft { date, time } for a new one

  const items = todos.filter((t) => !filter || t.project === filter)
  const days = narrow ? [cursor] : Array.from({ length: 7 }, (_, i) => addDays(monday(cursor), i))
  const step = view === 'month' ? 'month' : narrow ? 1 : 7
  const move = (dir) => {
    if (step === 'month') { const d = fromIso(cursor); d.setMonth(d.getMonth() + dir, 1); setCursor(toIso(d)) } else setCursor(addDays(cursor, dir * step))
  }
  const c = fromIso(cursor)
  const label = view === 'month' || !narrow ? `${MONTHS[c.getMonth()]} ${c.getFullYear()}` : c.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })

  return (
    <div className="page cal-page">
      <div className="page-head">
        <h1>Calendar</h1>
        <div className="row wrap" style={{ gap: 8 }}>
          <div className="seg">{['week', 'month', 'board'].map((v) => <button key={v} className={v === view ? 'on' : ''} onClick={() => setView(v)}>{v === 'week' ? (narrow ? 'Day' : 'Week') : v === 'month' ? 'Month' : 'Board'}</button>)}</div>
          <button className="btn primary" onClick={() => setEdit({ date: cursor, time: '10:00' })}><Plus size={15} /> New</button>
        </div>
      </div>

      <div className="chips" style={{ marginBottom: 16 }}>
        <button className={`chip sm ${!filter ? 'on' : ''}`} onClick={() => setFilter(null)}>All</button>
        {projects.map((p) => (
          <button key={p.name} className={`chip sm ${filter === p.name ? 'on' : ''}`} onClick={() => setFilter(filter === p.name ? null : p.name)}>
            <span className="swatch" style={{ background: projectColors[p.name], borderRadius: 99 }} />{p.name.replace('Research: ', '').replace('Dev: ', '')}
          </button>
        ))}
      </div>

      {view !== 'board' && (
        <div className="row between" style={{ marginBottom: 10 }}>
          <span style={{ fontWeight: 500 }}>{label}</span>
          <div className="row" style={{ gap: 2 }}>
            <button className="btn sm ghost" onClick={() => setCursor(TODAY)}>Today</button>
            <button className="icon-btn" onClick={() => move(-1)} aria-label="Previous"><ChevronLeft size={18} /></button>
            <button className="icon-btn" onClick={() => move(1)} aria-label="Next"><ChevronRight size={18} /></button>
          </div>
        </div>
      )}

      {view === 'week' && <WeekView days={days} items={items} narrow={narrow} onPick={setCursor} onOpen={setEdit} />}
      {view === 'month' && <MonthView cursor={cursor} items={items} onDay={(d) => { setCursor(d); setView('week') }} onOpen={setEdit} />}
      {view === 'board' && <Board items={items} onOpen={setEdit} />}

      {edit && <ItemSheet item={edit} defaultProject={filter} onClose={() => setEdit(null)} />}
    </div>
  )
}

function WeekView({ days, items, narrow, onPick, onOpen }) {
  const hours = Array.from({ length: END - START }, (_, i) => START + i)
  const strip = narrow ? Array.from({ length: 7 }, (_, i) => addDays(monday(days[0]), i)) : null
  return (
    <>
      {narrow && (
        <div className="cal-strip">
          {strip.map((d, i) => (
            <button key={d} className={`${d === days[0] ? 'on' : ''} ${d === TODAY ? 'today' : ''}`} onClick={() => onPick(d)}>
              <span>{DOW[i][0]}</span><b>{fromIso(d).getDate()}</b>
            </button>
          ))}
        </div>
      )}
      <div className="week" style={{ '--cols': days.length }}>
        <div className="week-head">
          <span />
          {days.map((d, i) => (
            <div key={d} className={d === TODAY ? 'today' : ''}>{!narrow && <><span>{DOW[i]}</span> <b>{fromIso(d).getDate()}</b></>}</div>
          ))}
        </div>
        <div className="week-allday">
          <span className="faint">All day</span>
          {days.map((d) => (
            <div key={d}>{items.filter((t) => t.date === d && !t.time).map((t) => <Chip key={t.id} t={t} onOpen={onOpen} />)}</div>
          ))}
        </div>
        <div className="week-body">
          <div className="week-hours">{hours.map((h) => <span key={h} style={{ height: ROW }}>{h}:00</span>)}</div>
          {days.map((d) => (
            <div key={d} className="week-col" style={{ height: hours.length * ROW }}>
              {hours.map((h) => <button key={h} className="week-slot" style={{ top: (h - START) * ROW, height: ROW }} onClick={() => onOpen({ date: d, time: `${String(h).padStart(2, '0')}:00` })} aria-label={`New at ${h}:00`} />)}
              {items.filter((t) => t.date === d && t.time).map((t) => {
                const top = ((mins(t.time) - START * 60) / 60) * ROW
                const h = Math.max(22, ((t.dur || 30) / 60) * ROW - 2)
                return (
                  <button key={t.id} className={`week-ev ${t.status === 'done' ? 'done' : ''}`} style={{ top, height: h, '--c': color(t) }} onClick={() => onOpen(t)}>
                    <b>{t.t}</b>{h > 30 && <span>{t.time}</span>}
                  </button>
                )
              })}
              {d === TODAY && <div className="now" style={{ top: ((10 * 60 + 40 - START * 60) / 60) * ROW }} />}
            </div>
          ))}
        </div>
      </div>
    </>
  )
}

function Chip({ t, onOpen }) {
  return <button className={`cal-chip ${t.status === 'done' ? 'done' : ''}`} style={{ '--c': color(t) }} onClick={() => onOpen(t)}>{t.t}</button>
}

function MonthView({ cursor, items, onDay, onOpen }) {
  const c = fromIso(cursor)
  const first = toIso(new Date(c.getFullYear(), c.getMonth(), 1))
  const start = monday(first)
  const cells = Array.from({ length: 42 }, (_, i) => addDays(start, i))
  return (
    <div className="month">
      {DOW.map((d) => <span key={d} className="month-dow">{d}</span>)}
      {cells.map((d) => {
        const list = items.filter((t) => t.date === d)
        const out = fromIso(d).getMonth() !== c.getMonth()
        return (
          <div key={d} className={`month-cell ${out ? 'out' : ''} ${d === TODAY ? 'today' : ''}`} onClick={() => onDay(d)}>
            <span className="month-n">{fromIso(d).getDate()}</span>
            {list.slice(0, 2).map((t) => <span key={t.id} onClick={(e) => { e.stopPropagation(); onOpen(t) }}><Chip t={t} onOpen={() => {}} /></span>)}
            {list.length > 2 && <span className="faint" style={{ fontSize: 11 }}>+{list.length - 2}</span>}
          </div>
        )
      })}
    </div>
  )
}

function Board({ items, onOpen }) {
  const { updateTodo } = useApp()
  const tasks = items.filter((t) => !t.event)
  return (
    <div className="board">
      {Object.entries(STATUS).map(([k, label]) => {
        const col = tasks.filter((t) => (t.status || 'todo') === k).sort((a, b) => a.date.localeCompare(b.date))
        return (
          <div key={k} className="board-col">
            <div className="section-title"><span>{label}</span><span className="faint">{col.length}</span></div>
            {col.map((t) => (
              <div key={t.id} className="board-card" onClick={() => onOpen(t)}>
                <div style={{ fontWeight: 500, textDecoration: k === 'done' ? 'line-through' : 'none' }}>{t.t}</div>
                <div className="row between small" style={{ marginTop: 8 }}>
                  <span className="row" style={{ gap: 6, minWidth: 0 }}>{t.project && <span className="swatch" style={{ background: projectColors[t.project], borderRadius: 99 }} />}<span className="muted ellipsis">{t.project ? t.project.replace('Research: ', '').replace('Dev: ', '') : 'Personal'}</span></span>
                  <span className="faint" style={{ flexShrink: 0 }}>{fromIso(t.date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
                </div>
                {k !== 'done' && (
                  <button className="btn sm" style={{ marginTop: 10 }} onClick={(e) => { e.stopPropagation(); updateTodo(t.id, { status: k === 'todo' ? 'doing' : 'done' }) }}>
                    {k === 'todo' ? 'Start' : 'Mark done'}
                  </button>
                )}
              </div>
            ))}
          </div>
        )
      })}
    </div>
  )
}

function ItemSheet({ item, defaultProject, onClose }) {
  const { addTodo, updateTodo, removeTodo, openProject, go, askAbout } = useApp()
  const isNew = !item.id
  const [f, setF] = useState({ t: '', dur: 30, project: defaultProject || '', status: 'todo', event: false, ...item })
  const set = (k, v) => setF((x) => ({ ...x, [k]: v }))
  const save = () => {
    const clean = { ...f, time: f.time || undefined, project: f.project || undefined }
    isNew ? addTodo(clean) : updateTodo(item.id, clean)
    onClose()
  }
  const open = () => { onClose(); f.ask ? (go('chat'), setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: f.ask })), 50)) : go(f.to) }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={{ maxWidth: 440 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <input className="cal-title" autoFocus={isNew} placeholder={isNew ? 'New task or event' : ''} value={f.t} onChange={(e) => set('t', e.target.value)} />
          <button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
        </div>
        <div className="modal-body stack" style={{ gap: 14 }}>
          <div className="seg" style={{ width: '100%' }}>
            <button style={{ flex: 1 }} className={!f.event ? 'on' : ''} onClick={() => set('event', false)}>Task</button>
            <button style={{ flex: 1 }} className={f.event ? 'on' : ''} onClick={() => set('event', true)}>Event</button>
          </div>
          <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <label className="field">Date<input type="date" className="cal-input" value={f.date} onChange={(e) => set('date', e.target.value)} /></label>
            <label className="field">Time<input type="time" className="cal-input" value={f.time || ''} onChange={(e) => set('time', e.target.value)} /></label>
          </div>
          <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <label className="field">Length<select value={f.dur} onChange={(e) => set('dur', +e.target.value)}>{[15, 30, 60, 90, 120].map((m) => <option key={m} value={m}>{m < 60 ? `${m} min` : `${m / 60} h`}</option>)}</select></label>
            <label className="field">Project<select value={f.project || ''} onChange={(e) => set('project', e.target.value)}><option value="">None</option>{projects.map((p) => <option key={p.name} value={p.name}>{p.name}</option>)}</select></label>
          </div>
          {!f.event && (
            <div className="field">Status
              <div className="seg" style={{ width: '100%' }}>{Object.entries(STATUS).map(([k, l]) => <button key={k} style={{ flex: 1 }} className={(f.status || 'todo') === k ? 'on' : ''} onClick={() => set('status', k)}>{l}</button>)}</div>
            </div>
          )}
          {!isNew && (
            <div className="row wrap" style={{ gap: 8 }}>
              {f.project && <button className="btn sm" onClick={() => { onClose(); openProject(f.project) }}><span className="swatch" style={{ background: projectColors[f.project], borderRadius: 99 }} /> Open project</button>}
              {(f.to || f.ask) && <button className="btn sm" onClick={open}><ArrowUpRight size={13} /> Open</button>}
              <button className="btn sm brand" onClick={() => { onClose(); askAbout({ q: `Help me with "${f.t}"`, a: f.project ? `"${f.t}" is part of ${f.project}. I can draft the next steps, block time before ${f.date.slice(5)}, and remind you an hour before.` : `I can block time for "${f.t}" and remind you an hour before.` }) }}><Sparkles size={13} /> Ask</button>
            </div>
          )}
        </div>
        <div className="modal-foot">
          {!isNew && <button className="btn" onClick={() => { removeTodo(item.id); onClose() }} aria-label="Delete"><Trash2 size={15} /></button>}
          <button className="btn primary grow" disabled={!f.t.trim() || !f.date} onClick={save}>{isNew ? 'Add' : 'Save'}</button>
        </div>
      </div>
    </div>
  )
}
