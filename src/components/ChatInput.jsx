import { useEffect, useRef, useState } from 'react'
import { Plus, Paperclip, Mic, Square, ArrowUp, X, ChevronRight, ChevronLeft, Slash, FolderOpen, Plug, Puzzle, ImagePlus, Check } from 'lucide-react'
import { AttachPicker, FileIcon } from './Sheets'
import Mark from './Mark'
import { connectors, skills, projectColors } from '../data'
import { useApp } from '../App'

// The one chat box used everywhere (home, chat, projects, automations), like Claude and ChatGPT:
// + menu (files, commands, project, connectors, plugins), attach, speak, send.
const COMMANDS = [
  ['/trade', 'Open a trade with TP and SL'],
  ['/swap', 'Swap one token for another'],
  ['/pay', 'Send or schedule a payment'],
  ['/earn', 'Find yield for idle funds'],
  ['/automate', 'Turn a task into an automation'],
  ['/remember', 'Save something to long-term memory'],
]

export default function ChatInput({ onSend, autoFocus, placeholder = 'How can I help?', label = 'Local model', projectPicker = true, rows = 1, dictation = 'Long HYPE 5x on Hyperliquid, stop at $22' }) {
  const { chatProject, setChatProject, projects, go, toast } = useApp()
  const [input, setInput] = useState('')
  const [listening, setListening] = useState(false)
  const [file, setFile] = useState(null)
  const [picking, setPicking] = useState(false)
  const [menu, setMenu] = useState(null) // null | main | commands | project | connectors | plugins
  const [on, setOn] = useState(() => Object.fromEntries(connectors.map((c) => [c.name, c.on])))
  const [plug, setPlug] = useState(() => Object.fromEntries(skills.map((s) => [s.name, s.locked || s.name === 'Research analyst'])))
  const ta = useRef(null)
  const slash = /^\/\w*$/.test(input) ? input.toLowerCase() : null
  const cmds = COMMANDS.filter(([c]) => !slash || c.startsWith(slash))

  useEffect(() => { if (!menu) return; const esc = (e) => e.key === 'Escape' && setMenu(null); window.addEventListener('keydown', esc); return () => window.removeEventListener('keydown', esc) }, [menu])

  const send = () => { if (!input.trim() && !file) return; onSend({ text: input.trim(), attachment: file }); setInput(''); setFile(null); setMenu(null) }
  const dictate = () => {
    if (listening) return
    setListening(true)
    setTimeout(() => { setListening(false); setInput(dictation) }, 1800)
  }
  const useCmd = (c) => { setInput(`${c} `); setMenu(null); ta.current?.focus() }
  const back = <button className="pm-back" onClick={() => setMenu('main')}><ChevronLeft size={14} /> Back</button>
  const Row = ({ icon, label: l, sub, onClick, right }) => (
    <button className="pm-row" onClick={onClick}>{icon}<span className="grow"><span>{l}</span>{sub && <small>{sub}</small>}</span>{right}</button>
  )

  return (
    <div className="composer">
      {file && (
        <div className="attach-chip"><FileIcon name={file.name} size={28} /><span className="grow ellipsis">{file.name}</span>
          <button className="icon-btn" style={{ width: 24, height: 24 }} onClick={() => setFile(null)} aria-label="Remove file"><X size={13} /></button></div>
      )}
      {picking && <AttachPicker onPick={setFile} onClose={() => setPicking(false)} />}
      <textarea ref={ta} rows={rows} value={input} autoFocus={autoFocus} placeholder={listening ? 'Listening…' : placeholder}
        onChange={(e) => setInput(e.target.value)}
        onKeyDown={(e) => {
          if (slash && e.key === 'Enter' && cmds.length) { e.preventDefault(); return useCmd(cmds[0][0]) }
          if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
        }} />

      {(menu || slash) && <div className="menu-backdrop" onClick={() => { setMenu(null); if (slash) setInput('') }} />}
      {slash && !menu && cmds.length > 0 && (
        <div className="plus-menu">
          {cmds.map(([c, d]) => <Row key={c} icon={<span className="pm-ico mono">/</span>} label={c} sub={d} onClick={() => useCmd(c)} />)}
        </div>
      )}
      {menu && (
        <div className="plus-menu" role="menu">
          {menu === 'main' && <>
            <Row icon={<span className="pm-ico"><ImagePlus size={15} /></span>} label="Add files or photos" onClick={() => { setMenu(null); setPicking(true) }} />
            <div className="pm-sep" />
            <Row icon={<span className="pm-ico"><Slash size={14} /></span>} label="Commands" onClick={() => setMenu('commands')} right={<ChevronRight size={14} color="var(--faint)" />} />
            {projectPicker && <Row icon={<span className="pm-ico"><FolderOpen size={15} /></span>} label="Project" sub={chatProject || 'None'} onClick={() => setMenu('project')} right={<ChevronRight size={14} color="var(--faint)" />} />}
            <Row icon={<span className="pm-ico"><Plug size={15} /></span>} label="Connectors" sub={`${Object.values(on).filter(Boolean).length} on`} onClick={() => setMenu('connectors')} right={<ChevronRight size={14} color="var(--faint)" />} />
            <Row icon={<span className="pm-ico"><Puzzle size={15} /></span>} label="Plugins" sub={`${Object.values(plug).filter(Boolean).length} on`} onClick={() => setMenu('plugins')} right={<ChevronRight size={14} color="var(--faint)" />} />
          </>}
          {menu === 'commands' && <>{back}{COMMANDS.map(([c, d]) => <Row key={c} icon={<span className="pm-ico mono">/</span>} label={c} sub={d} onClick={() => useCmd(c)} />)}</>}
          {menu === 'project' && <>{back}
            <Row icon={<span className="pm-ico"><X size={13} /></span>} label="No project" onClick={() => { setChatProject(null); setMenu(null) }} right={!chatProject && <Check size={14} />} />
            {projects.map((p) => <Row key={p.name} icon={<span className="pm-ico"><span className="swatch" style={{ background: projectColors[p.name] || '#8A8A8A', borderRadius: 99 }} /></span>} label={p.name} onClick={() => { setChatProject(p.name); setMenu(null) }} right={chatProject === p.name && <Check size={14} />} />)}
          </>}
          {menu === 'connectors' && <>{back}
            {connectors.slice(0, 7).map((c) => <Row key={c.name} icon={<Mark name={c.name} size={24} />} label={c.name} onClick={() => setOn({ ...on, [c.name]: !on[c.name] })} right={<span className={`toggle sm ${on[c.name] ? 'on' : ''}`} />} />)}
            <div className="pm-sep" />
            <Row icon={<span className="pm-ico"><Plug size={15} /></span>} label="Manage connectors" onClick={() => { setMenu(null); go('connectors') }} />
          </>}
          {menu === 'plugins' && <>{back}
            {skills.map((s) => <Row key={s.name} icon={<span className="pm-ico"><Puzzle size={14} /></span>} label={s.name} sub={s.desc} onClick={() => s.locked ? toast(`${s.name} is always on`) : setPlug({ ...plug, [s.name]: !plug[s.name] })} right={s.locked ? <span className="faint small">Always</span> : <span className={`toggle sm ${plug[s.name] ? 'on' : ''}`} />} />)}
            <div className="pm-sep" />
            <Row icon={<span className="pm-ico"><Puzzle size={15} /></span>} label="Browse plugins" onClick={() => { setMenu(null); go('connectors/skills') }} />
          </>}
        </div>
      )}

      <div className="composer-bar">
        <div className="composer-tools">
          <button className={`icon-btn plus-btn ${menu ? 'on' : ''}`} onClick={() => setMenu(menu ? null : 'main')} aria-label="Add files, commands, connectors and more" aria-expanded={!!menu}><Plus size={18} /></button>
          <button className="icon-btn" onClick={() => setPicking(true)} aria-label="Attach file"><Paperclip size={17} /></button>
          <button className="icon-btn" onClick={dictate} aria-label="Speak" style={listening ? { color: 'var(--red)' } : undefined}>
            {listening ? <Square size={13} fill="currentColor" /> : <Mic size={17} />}
          </button>
        </div>
        <div className="row" style={{ gap: 4, minWidth: 0 }}>
          {label && <span className="model ellipsis">{label}</span>}
          <button className="send" disabled={!input.trim() && !file} onClick={send} aria-label="Send"><ArrowUp size={17} /></button>
        </div>
      </div>
      {projectPicker && chatProject && (
        <div className="composer-project">
          <span className="swatch" style={{ background: projectColors[chatProject] || '#8A8A8A', borderRadius: 99 }} />
          <span className="ellipsis">{chatProject}</span>
          <button className="icon-btn" onClick={() => setChatProject(null)} aria-label="Remove project"><X size={12} /></button>
        </div>
      )}
    </div>
  )
}
