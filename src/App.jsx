import { createContext, useContext, useEffect, useState } from 'react'
import {
  MessageCircle, FolderKanban, Zap, CandlestickChart, Sprout, Receipt, Compass, Plug, FileText, Wallet,
  Settings as SettingsIcon, SquarePen, Menu, Sparkles, CalendarDays, ChevronRight, ChevronsUpDown, CircleHelp, LogOut, Plus,
} from 'lucide-react'
import Logo from './components/Logo'
import Approval from './components/Approval'
import FileViewer from './components/FileViewer'
import Login from './components/Login'
import AskPanel from './components/AskPanel'
import Stage from './components/Stage'
import { isApp } from './native'
import { threads } from './threads'
import { recentThreads, projects, projectColors, memorySeed, totalAUM, fmt, automations as seedAutomations, user, earnPositionsSeed, tradePositionsSeed, todos as todosSeed } from './data'
import Calendar from './pages/Calendar'
import Chat from './pages/Chat'
import Projects from './pages/Projects'
import Automations from './pages/Automations'
import Trade from './pages/Trade'
import Earn from './pages/Earn'
import Payments from './pages/Payments'
import Explore from './pages/Explore'
import Connectors from './pages/Connectors'
import Files from './pages/Files'
import Portfolio from './pages/Portfolio'
import Settings from './pages/Settings'

const AppCtx = createContext(null)
export const useApp = () => useContext(AppCtx)

const NAV = [
  { id: 'chat', label: 'Chat', icon: MessageCircle, el: Chat },
  { id: 'projects', label: 'Projects', icon: FolderKanban, el: Projects },
  { id: 'automations', label: 'Automations', icon: Zap, el: Automations },
  { id: 'trade', label: 'Trade', icon: CandlestickChart, el: Trade },
  { id: 'earn', label: 'Earn', icon: Sprout, el: Earn },
  { id: 'payments', label: 'Payments', icon: Receipt, el: Payments, count: 2 },
  { id: 'explore', label: 'Explore', icon: Compass, el: Explore },
  { foot: true, id: 'connectors', label: 'Connectors', icon: Plug, el: Connectors },
  { id: 'calendar', label: 'Calendar', icon: CalendarDays, el: Calendar },
  { foot: true, id: 'files', label: 'Files', icon: FileText, el: Files },
  { foot: true, id: 'portfolio', label: 'Wallets', icon: Wallet, el: Portfolio },
  { foot: true, id: 'settings', label: 'Settings', icon: SettingsIcon, el: Settings },
]
const TABS = ['chat', 'trade', 'earn', 'payments', 'portfolio']

// Hash is #/page or #/page/tab, so every tab can be linked to directly.
const readHash = () => (window.location.hash.replace('#/', '') || 'chat').split('?')[0].split('/')
const readRoute = () => readHash()[0]
const readSub = () => readHash()[1] || null

// Wide screens get the demo stage (app inside a window or phone); phones and the embedded app render directly.
export default function Root() {
  const embedded = isApp || new URLSearchParams(window.location.search).has('embed')
  const [wide, setWide] = useState(() => window.matchMedia('(min-width: 861px)').matches)
  useEffect(() => {
    const m = window.matchMedia('(min-width: 861px)')
    const on = () => setWide(m.matches)
    m.addEventListener('change', on)
    return () => m.removeEventListener('change', on)
  }, [])
  if (!embedded && wide) return <Stage />
  // in the desktop app, the strip under the macOS traffic lights drags the window
  return isApp ? <><div className="titlebar" data-tauri-drag-region /><App /></> : <App />
}

// Demo sign-in is remembered per browser; ?skiplogin opens the app directly (screenshots, handoff links).
const readAuth = () => { if (new URLSearchParams(window.location.search).has('skiplogin')) return true; try { return localStorage.getItem('hermit-auth') === '1' } catch { return false } }
const saveAuth = (v) => { try { v ? localStorage.setItem('hermit-auth', '1') : localStorage.removeItem('hermit-auth') } catch { /* private mode */ } }

function App() {
  const [authed, setAuthed] = useState(readAuth)
  const [route, setRoute] = useState(readRoute())
  const [sub, setSub] = useState(readSub())
  const [drawer, setDrawer] = useState(false)
  const [approval, setApproval] = useState(null)
  const [toastMsg, setToastMsg] = useState(null)
  const [messages, setMessages] = useState([])
  const [autos, setAutos] = useState(seedAutomations)
  const [askOpen, setAskOpen] = useState(false)
  const [askSeed, setAskSeed] = useState(null)
  const [projectOpen, setProjectOpen] = useState(null)
  const [todoList, setTodoList] = useState(todosSeed)
  const [threadId, setThreadId] = useState(null)
  const [expanded, setExpanded] = useState({})
  const [memory, setMemory] = useState(memorySeed)
  const [projectList, setProjectList] = useState(projects)
  const [projectMd, setProjectMd] = useState({})
  const [chartMarks, setChartMarks] = useState([])
  const [openFiles, setOpenFiles] = useState([])
  const [chatProject, setChatProject] = useState(null)
  const [costsOff, setCostsOff] = useState({})
  const [activeFile, setActiveFile] = useState(null)
  const [earnPos, setEarnPos] = useState(earnPositionsSeed)
  const [tradePos, setTradePos] = useState(tradePositionsSeed)
  const [settings, setSettings] = useState({ showAUM: true, showTodos: true, wallet: 'local', askAbove: 100 })

  useEffect(() => {
    const on = () => { setRoute(readRoute()); setSub(readSub()); setDrawer(false); setOpenFiles([]); setActiveFile(null) }
    window.addEventListener('hashchange', on)
    return () => window.removeEventListener('hashchange', on)
  }, [])

  const go = (id) => { window.location.hash = '/' + id }
  const toast = (m) => { setToastMsg(m); clearTimeout(window.__t); window.__t = setTimeout(() => setToastMsg(null), 2400) }
  const ctx = {
    route, go, toast, sub,
    // Switch a page's top tab without a new history entry, and start it from the top.
    setTab: (k) => { history.replaceState(null, '', `#/${route}/${k}`); setSub(k); document.querySelector('.content')?.scrollTo(0, 0) }, settings, setSettings, messages, setMessages,
    approve: (spec) => setApproval(spec),
    automations: autos, setAutomations: setAutos, chartMarks, setChartMarks, earnPos, tradePos,
    askAbout: (seed) => { setAskSeed(seed); setAskOpen(true) },
    memory, setMemory, addMemory: (item) => setMemory((m) => [...m, item]),
    projects: projectList, addProject: (p) => setProjectList((l) => [p, ...l]),
    projectMd, setProjectMd,
    // Load a past conversation into chat (strategies, airdrops and projects link here).
    openThread: (id) => { setMessages(threads[id].messages.map((m) => ({ ...m }))); setThreadId(id); setChatProject(threads[id].project || null); setAskOpen(false); go('chat') },
    threadId,
    openProject: (name) => { setProjectOpen(name); go('projects') },
    projectOpen, setProjectOpen,
    todos: todoList,
    addTodo: (t) => setTodoList((l) => [...l, { id: Date.now(), ...t }]),
    toggleTodo: (id) => setTodoList((l) => l.map((t) => (t.id === id ? { ...t, status: t.status === 'done' ? 'todo' : 'done' } : t))),
    updateTodo: (id, patch) => setTodoList((l) => l.map((t) => (t.id === id ? { ...t, ...patch } : t))),
    removeTodo: (id) => setTodoList((l) => l.filter((t) => t.id !== id)),
    addAutomation: (a) => setAutos((x) => [a, ...x]),
    // File viewer: each opened file becomes a tab; closing the last one closes the viewer.
    openFiles, activeFile, setActiveFile,
    openFile: (f) => { setOpenFiles((l) => (l.some((x) => x.name === f.name) ? l : [...l, f])); setActiveFile(f.name) },
    closeFile: (name) => setOpenFiles((l) => { const rest = l.filter((x) => x.name !== name); if (activeFile === name) setActiveFile(rest[rest.length - 1]?.name || null); return rest }),
    closeAllFiles: () => { setOpenFiles([]); setActiveFile(null) },
    // A button's outcome: in chat it shows as your action plus Hermit's reply; elsewhere as a toast.
    react: (label, reply) => {
      if (readRoute() === 'chat') setMessages((m) => [...m, { role: 'user', text: label }, { role: 'ai', note: reply }])
      else toast(reply)
    },
    // A new chat can belong to a project: the chat box, header and home cards then follow that project.
    logout: () => { saveAuth(false); setAuthed(false); setMessages([]); setThreadId(null); setChatProject(null); go('chat') },
    newChat: (project = null) => { setMessages([]); setThreadId(null); setChatProject(typeof project === 'string' ? project : null); go('chat') },
    chatProject, setChatProject,
    // Project cost items the user switched off (key: "project/item").
    costsOff, toggleCost: (project, item) => setCostsOff((c) => ({ ...c, [`${project}/${item}`]: !c[`${project}/${item}`] })),
  }

  const Page = (NAV.find((n) => n.id === route) || NAV[0]).el
  if (!authed) return <Login onDone={() => { saveAuth(true); setAuthed(true) }} />

  return (
    <AppCtx.Provider value={ctx}>
      <div className="app">
        <aside className={`sidebar ${drawer ? 'open' : ''}`}>
          <div className="side-top">
            <Logo size={17} />
          </div>
          <button className="side-aum" onClick={() => go('portfolio')} title="All wallets">
            <span className="faint">Under management</span>
            <span className="row between"><b className="num">{fmt.usd(totalAUM)}</b><span className="up small num">+2.6%</span></span>
          </button>
          <button className={`nav-item new-chat ${route === 'chat' && !threadId && !chatProject ? 'active' : ''}`} onClick={() => ctx.newChat()}>
            <span className="new-ico"><Plus size={13} strokeWidth={2.4} /></span> New chat
          </button>
          {NAV.filter((n) => !n.foot && n.id !== 'chat').map((n) => (
            <button key={n.id} className={`nav-item ${route === n.id ? 'active' : ''}`} onClick={() => { if (n.id === 'projects') setProjectOpen(null); go(n.id) }}>
              <n.icon size={16} strokeWidth={1.75} /> {n.label}
              {n.count && <span className="nav-count">{n.count}</span>}
            </button>
          ))}
          {/* Like Claude: chats live inside projects; standalone chats sit under Recents. */}
          <div className="side-scroll">
          <div className="nav-label">Projects</div>
          {projectList.map((p) => {
            const isOpen = expanded[p.name] ?? (threadId && threads[threadId]?.project === p.name)
            return (
              <div key={p.name}>
                <div className={`side-proj ${route === 'projects' && projectOpen === p.name ? 'active' : ''}`}>
                  <button className="side-chev" onClick={() => setExpanded({ ...expanded, [p.name]: !isOpen })} aria-label={isOpen ? 'Collapse' : 'Expand'}>
                    <ChevronRight size={13} style={{ transform: isOpen ? 'rotate(90deg)' : 'none', transition: 'transform .15s' }} />
                  </button>
                  <button className="row grow" style={{ gap: 8, minWidth: 0 }} onClick={() => ctx.openProject(p.name)}>
                    <span className="swatch" style={{ background: projectColors[p.name] || '#8A8A8A', borderRadius: 99 }} /><span className="ellipsis">{p.name}</span>
                  </button>
                </div>
                {isOpen && p.chats.map(([id, title]) => (
                  <button key={id} className={`recent side-chat ${route === 'chat' && threadId === id ? 'active' : ''}`} onClick={() => ctx.openThread(id)}>{title}</button>
                ))}
              </div>
            )
          })}
          <div className="nav-label">Recents</div>
          {recentThreads.map(([id, title]) => (
            <button key={id} className="recent" onClick={() => ctx.openThread(id)}>{title}</button>
          ))}
          </div>
          <SideFooter />
        </aside>
        <div className={`drawer-backdrop ${drawer ? 'open' : ''}`} onClick={() => setDrawer(false)} />

        <main className="main">
          {openFiles.length > 0 && <FileViewer />}
          <header className="topbar">
            <button className="icon-btn" onClick={() => setDrawer(true)} aria-label="Menu"><Menu size={20} /></button>
            <Logo size={15} />
            <span className="row" style={{ gap: 0 }}>
              <button className="icon-btn" onClick={() => ctx.newChat()} aria-label="New chat"><SquarePen size={18} /></button>
            </span>
          </header>
          <div className="content" style={route === 'chat' ? { overflow: 'hidden' } : undefined}>
            <Page />
          </div>
          {route !== 'chat' && !askOpen && (
            <button className="ask-fab" onClick={() => setAskOpen(true)} aria-label="Ask Hermit" title="Ask Hermit"><Sparkles size={18} /></button>
          )}
          <nav className="tabbar">
            {TABS.map((id) => {
              const n = NAV.find((x) => x.id === id)
              return <button key={id} className={route === id ? 'on' : ''} onClick={() => go(id)} aria-label={n.label}><n.icon size={22} strokeWidth={1.75} /></button>
            })}
          </nav>
        </main>
        {askOpen && route !== 'chat' && <AskPanel key={route + (askSeed?.q || '')} seed={askSeed} onClose={() => { setAskOpen(false); setAskSeed(null) }} />}
      </div>

      {approval && <Approval spec={approval} onClose={() => setApproval(null)} onDone={() => {
        // Executions land in the Earn / Trade portfolios, and a receipt posts into chat.
        if (approval.adds?.earn) setEarnPos((p) => [...approval.adds.earn, ...p])
        if (approval.adds?.trade) setTradePos((p) => [...approval.adds.trade, ...p])
        approval.onSuccess?.()
        if (route === 'chat' && messages.length) setMessages((m) => [...m, { role: 'ai', receipt: approval.result || { title: approval.success, rows: approval.lines } },
          ...(approval.adds?.trade || []).map((t) => ({ role: 'ai', live: t }))])
      }} />}
      {toastMsg && (
        <div className="fade-in" style={{ position: 'fixed', bottom: 80, left: '50%', transform: 'translateX(-50%)', background: 'var(--text)', color: '#fff', padding: '9px 16px', borderRadius: 10, fontSize: 13, zIndex: 60, maxWidth: 'calc(100vw - 32px)', textAlign: 'center' }}>
          {toastMsg}
        </div>
      )}
    </AppCtx.Provider>
  )
}

// Claude-style account footer: pinned to the bottom, opens a menu with the less-used pages.
function SideFooter() {
  const { route, go, askAbout, logout } = useApp()
  const [open, setOpen] = useState(false)
  useEffect(() => {
    const on = (e) => { if ((e.metaKey || e.ctrlKey) && e.key === ',') { e.preventDefault(); go('settings') } }
    window.addEventListener('keydown', on)
    return () => window.removeEventListener('keydown', on)
  }, [])
  const pick = (fn) => { setOpen(false); fn() }
  return (
    <div className="side-foot">
      {open && <div className="menu-backdrop" onClick={() => setOpen(false)} />}
      {open && (
        <div className="foot-menu" role="menu">
          <div className="foot-email">{user.email}</div>
          {['portfolio', 'files', 'connectors', 'settings'].map((id) => NAV.find((n) => n.id === id)).map((n) => (
            <button key={n.id} role="menuitem" className={route === n.id ? 'on' : ''} onClick={() => pick(() => go(n.id))}>
              <n.icon size={16} strokeWidth={1.75} /><span className="grow">{n.label}</span>
              {n.id === 'portfolio' && <span className="faint num">{fmt.usd(totalAUM)}</span>}
              {n.id === 'settings' && <span className="faint">⌘,</span>}
            </button>
          ))}
          <div className="foot-sep" />
          <button role="menuitem" onClick={() => pick(() => askAbout({ q: 'How do I get started?', a: 'Ask anything in chat. Try "best safe yield for 10k USDC" or "what news is moving the market". Anything that moves money shows an approval first.' }))}><CircleHelp size={16} strokeWidth={1.75} /><span className="grow">Get help</span></button>
          <div className="foot-sep" />
          <button role="menuitem" onClick={() => pick(logout)}><LogOut size={16} strokeWidth={1.75} /><span className="grow">Log out</span></button>
        </div>
      )}
      <button className={`foot-account ${open ? 'on' : ''}`} onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="avatar">{user.name[0]}</span>
        <span className="grow ellipsis"><b>{user.name}</b> <span className="faint">Local</span></span>
        <ChevronsUpDown size={14} color="var(--faint)" />
      </button>
      <button className={`icon-btn ${route === 'portfolio' ? 'on' : ''}`} onClick={() => go('portfolio')} aria-label="Wallets" title="Wallets"><Wallet size={17} strokeWidth={1.75} /></button>
    </div>
  )
}
