import { useEffect, useRef, useState } from 'react'
import { ArrowUp, Paperclip, Mic, Square, CheckCircle2, Loader2, ChevronRight, X, ArrowLeft, ArrowUpRight, ArrowDownLeft, ArrowLeftRight, ArrowDown, CreditCard } from 'lucide-react'
import Logo from '../components/Logo'
import { Donut } from '../components/Charts'
import { useApp } from '../App'
import { scenarios, matchScenario } from '../scenarios'
import { attachReply, memoryItem, memoryReply } from '../replies'
import { AttachPicker, FileIcon, Sheet } from '../components/Sheets'
import { TransferSheet, DepositSheet } from './Portfolio'
import Mark from '../components/Mark'
import ChatInput from '../components/ChatInput'
import { LiveTradeCard } from '../components/ChatCards'
import { baseChecks } from '../components/Approval'
import { allocation, totalAUM, fmt, user, projects, TODAY, projectColors, projectBurn, projectForecast } from '../data'
import { threads } from '../threads'
import { ICONS } from '../components/icons'

const HOME = ['news', 'opps-defi', 'build', 'inject']

const greeting = () => {
  const h = new Date().getHours()
  return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening'
}

export default function Chat() {
  const { messages, setMessages, settings, addMemory, chatProject } = useApp()
  const scroller = useRef(null)

  // input: a string, or { text, attachment } from the composer / file sheets.
  const ask = (input) => {
    const { text = '', attachment } = typeof input === 'string' ? { text: input } : input
    if (!text.trim() && !attachment) return
    const q = text.trim() || `What's in ${attachment.name}?`
    const mem = !attachment && memoryItem(q)
    if (mem) addMemory(mem)
    // A wallet spreadsheet plus "send" runs the batch-send flow instead of a file summary.
    const sheetSend = attachment && /\.xlsx$|\.csv$/i.test(attachment.name) && /send|pay|distribute|airdrop/i.test(q)
    const reply = sheetSend ? { id: 'multisend' } : attachment ? { inline: attachReply(attachment) } : mem ? { inline: memoryReply(mem) } : { id: matchScenario(q)?.id }
    setMessages((m) => [...m, { role: 'user', text: q, attachment }, { role: 'ai', progress: 0, ...reply }])
  }

  // Sidebar "recent" items dispatch this event.
  useEffect(() => {
    const on = (e) => ask(e.detail)
    window.addEventListener('hermit:ask', on)
    return () => window.removeEventListener('hermit:ask', on)
  })

  // Reveal the latest agent reply step by step (tools first, then cards).
  const last = messages[messages.length - 1]
  useEffect(() => {
    if (!last || last.role !== 'ai' || last.receipt) return
    const sc = last.inline || scenarios.find((s) => s.id === last.id)
    const total = sc ? sc.tools.length + sc.blocks.length : 1
    if (last.progress >= total) return
    const delay = sc && last.progress < sc.tools.length ? 550 : 380
    const t = setTimeout(() => setMessages((m) => m.map((x, i) => (i === m.length - 1 ? { ...x, progress: x.progress + 1 } : x))), delay)
    return () => clearTimeout(t)
  }, [last, setMessages])

  useEffect(() => {
    const el = scroller.current
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
  }, [messages])

  if (messages.length === 0) {
    return (
      <div className="chat-scroll" style={{ height: '100%' }}>
        <div className="home">
          {chatProject && <ProjectBack />}
          {EXT ? <PageContext onAsk={ask} /> : <HomeArt />}
          <h1>{greeting()}, {user.name}</h1>
          <HomeActions />
          <ChatInput onSend={ask} autoFocus />
          <div className="chips one-line home-chips">
            {HOME.map((id) => scenarios.find((s) => s.id === id)).map((s) => (
              <button key={s.id} className="chip sm" onClick={() => ask(s.prompt)}>{s.chip}</button>
            ))}
          </div>
          {(settings.showAUM || settings.showTodos) && (
            <div className="glance" style={settings.showAUM && settings.showTodos ? undefined : { gridTemplateColumns: '1fr' }}>
              {settings.showAUM && (chatProject ? <ProjectAum name={chatProject} /> : <AumWidget />)}
              {settings.showTodos && <TodoWidget project={chatProject} />}
            </div>
          )}
          {!chatProject && <HomeProjects />}
        </div>
      </div>
    )
  }

  return (
    <div className="chat">
      <div className="chat-scroll" ref={scroller}>
        <div className="chat-inner">
          <ThreadCrumb />
          <MessageList messages={messages} onAsk={ask} />
        </div>
      </div>
      <div className="composer-wrap"><ChatInput onSend={ask} /></div>
    </div>
  )
}


// Back to the project this chat belongs to (Claude-style project chats).
function ProjectBack() {
  const { chatProject, openProject } = useApp()
  return (
    <button className="proj-back" onClick={() => openProject(chatProject)}>
      <ArrowLeft size={14} /><span className="swatch" style={{ background: projectColors[chatProject] || '#8A8A8A', borderRadius: 99 }} /><span className="ellipsis">{chatProject}</span>
    </button>
  )
}

// Breadcrumb back to the project when a project chat is open.
function ThreadCrumb() {
  const { threadId, openProject, chatProject, messages } = useApp()
  const t = (threadId && threads[threadId]) || (chatProject && { project: chatProject, title: messages.find((m) => m.role === 'user')?.text || 'New chat' })
  if (!t?.project) return null
  return (
    <button className="row small muted" style={{ gap: 6, marginBottom: 6, maxWidth: '100%' }} onClick={() => openProject(t.project)}>
      <ArrowLeft size={13} style={{ flexShrink: 0 }} /><span className="swatch" style={{ background: projectColors[t.project], borderRadius: 99 }} /><span style={{ flexShrink: 0 }}>{t.project}</span><ChevronRight size={13} style={{ flexShrink: 0 }} /><span className="ellipsis" style={{ color: 'var(--text)' }}>{t.title}</span>
    </button>
  )
}

// Shared with project pages, which show a project's chat history.
export function MessageList({ messages, onAsk }) {
  return messages.map((m, i) => (m.role === 'user'
    ? <div key={i} className="msg-user fade-in"><div className="bubble">{m.attachment && <div className="attach-chip" style={{ background: 'var(--bg)', marginBottom: 6 }}><FileIcon name={m.attachment.name} size={26} /><span className="ellipsis">{m.attachment.name}</span></div>}{m.text}</div></div>
    : <AiMessage key={i} msg={m} onAsk={onAsk} />))
}

function AiMessage({ msg, onAsk }) {
  const [open, setOpen] = useState(false)
  if (msg.receipt) return <div className="msg-ai fade-in"><Receipt r={msg.receipt} /></div>
  if (msg.live) return <div className="msg-ai fade-in"><LiveTradeCard t={msg.live} /></div>
  if (msg.note) return <div className="msg-ai fade-in"><div className="ai-note"><CheckCircle2 size={15} color="var(--green)" /><p>{msg.note}</p></div></div>
  const sc = msg.inline || scenarios.find((s) => s.id === msg.id)
  if (!sc) {
    return (
      <div className="msg-ai fade-in">
        <div className="ai-text"><p>This demo runs scripted examples. Try one:</p></div>
        <div className="chips">{scenarios.map((s) => <button key={s.id} className="chip" onClick={() => onAsk(s.prompt)}>{s.chip}</button>)}</div>
      </div>
    )
  }
  const toolsDone = Math.min(msg.progress, sc.tools.length)
  const finished = toolsDone === sc.tools.length
  const blocksShown = Math.max(0, msg.progress - sc.tools.length)
  return (
    <div className="msg-ai">
      {finished ? (
        <div>
          <button className="steps-toggle" onClick={() => setOpen(!open)}>
            <CheckCircle2 size={14} color="var(--green)" /> {sc.tools.length} steps
            <ChevronRight size={14} style={{ transform: open ? 'rotate(90deg)' : 'none', transition: 'transform .15s' }} />
          </button>
          {open && <div className="tool-steps" style={{ marginTop: 8 }}>{sc.tools.map((t) => <div key={t} className="tool-step"><CheckCircle2 size={13} /> {t}</div>)}</div>}
        </div>
      ) : (
        <div className="tool-step fade-in"><Loader2 size={14} className="spin" /> {sc.tools[toolsDone]}…</div>
      )}
      {sc.blocks.slice(0, blocksShown).map((B, i) => <div key={i} className="fade-in"><B /></div>)}
    </div>
  )
}

function Receipt({ r }) {
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 8, fontWeight: 500 }}><CheckCircle2 size={16} color="var(--green)" /> {r.title}</span>
        <span className="faint small mono">0x8f2c…a91d</span>
      </div>
      <div className="ccard-body" style={{ paddingTop: 6 }}>
        {r.alloc && (
          <div className="row" style={{ gap: 18, padding: '8px 0 12px' }}>
            <Donut data={r.alloc} size={76} thickness={10} />
            <div className="legend grow">{r.alloc.map((a) => <div className="legend-row" key={a.label}><span className="swatch" style={{ background: a.color }} /><span className="grow">{a.label}</span><span className="muted num">${a.value.toLocaleString()}</span></div>)}</div>
          </div>
        )}
        {!r.alloc && r.rows.map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span>{v}</span></div>)}
        {r.stats && <div className="kv" style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid var(--border)' }}>{r.stats.map(([k, v]) => <div key={k}><span>{k}</span><b>{v}</b></div>)}</div>}
      </div>
      {r.note && <div className="ccard-foot" style={{ justifyContent: 'flex-start' }}><span className="muted small">{r.note}</span></div>}
    </div>
  )
}

// Hermit illustration above the greeting; falls back to the logo until /hermit-hero.png exists.
function HomeArt() {
  const [ok, setOk] = useState(true)
  return ok
    ? <img className="home-art" src="/hermit-hero.png" alt="" onError={() => setOk(false)} />
    : <div style={{ textAlign: 'center' }}><Logo size={28} /></div>
}

// Phones have no sidebar, so projects sit at the bottom of home.
function HomeProjects() {
  const { openProject, projects } = useApp()
  return (
    <div className="hide-d" style={{ marginTop: 32 }}>
      <div className="section-title">Projects</div>
      {projects.map((p) => {
        const Ic = ICONS[p.icon] || ICONS.Folder
        return (
          <button className="list-row" key={p.name} onClick={() => openProject(p.name)}>
            <span className="mark app" style={{ width: 32, height: 32 }}><Ic size={15} strokeWidth={1.75} /></span>
            <div className="grow"><div className="list-title">{p.name}</div><div className="list-sub">{p.desc}</div></div>
            <ChevronRight size={15} color="var(--faint)" />
          </button>
        )
      })}
    </div>
  )
}

function AumWidget() {
  const { setSettings, go } = useApp()
  return (
    <div className="card">
      <div className="glance-head">
        <span>Managed by agent</span>
        <button className="icon-btn" onClick={() => setSettings((s) => ({ ...s, showAUM: false }))} aria-label="Hide"><X size={13} /></button>
      </div>
      <button className="row" style={{ gap: 16, width: '100%' }} onClick={() => go('portfolio')}>
        <Donut data={allocation} size={84} thickness={10} />
        <div className="grow">
          <div className="stat-value" style={{ fontSize: 22, margin: 0 }}>{fmt.usd(totalAUM)}</div>
          <div className="up small">+2.6% this week</div>
        </div>
      </button>
    </div>
  )
}

// The project's own money: what the agent manages for it and how it is doing.
function ProjectAum({ name }) {
  const { projects, openProject, costsOff } = useApp()
  const p = projects.find((x) => x.name === name)
  if (!p) return null
  const fc = projectForecast[name]
  const burn = (projectBurn[name] || []).filter(([w]) => !costsOff[`${name}/${w}`]).reduce((a, [, x]) => a + x, 0)
  return (
    <div className="card">
      <div className="glance-head"><span>Managed by agent</span></div>
      <button className="stack" style={{ gap: 8, width: '100%', textAlign: 'left' }} onClick={() => openProject(name)}>
        <div><div className="stat-value" style={{ fontSize: 22, margin: 0 }}>{fmt.usd(p.money)}</div><div className={`small ${p.gain >= 0 ? 'up' : 'down'}`}>{p.gain >= 0 ? '+' : '−'}{fmt.usd(Math.abs(p.gain))} {p.gainLabel.toLowerCase()}</div></div>
        <div className="row between small"><span className="muted">Expected per month</span><span className={`num ${(fc?.monthly || 0) >= 0 ? 'up' : 'down'}`}>{fc ? `${fc.monthly >= 0 ? '+' : '−'}${fmt.usd(Math.abs(fc.monthly))}` : '—'}</span></div>
        {burn > 0 && <div className="row between small"><span className="muted">Burn rate</span><span className="num down">−{fmt.usd(burn)}/mo</span></div>}
      </button>
    </div>
  )
}

function TodoWidget({ project }) {
  const { setSettings, todos, toggleTodo } = useApp()
  const mine = project ? todos.filter((t) => t.project === project && t.date >= TODAY) : todos.filter((t) => t.date === TODAY)
  const today = project ? [...mine.filter((t) => t.date === TODAY), ...mine.filter((t) => t.date !== TODAY)] : mine
  return (
    <div className="card">
      <div className="glance-head">
        <span>{project && !mine.some((t) => t.date === TODAY) ? 'Up next' : 'Today'}</span>
        <button className="icon-btn" onClick={() => setSettings((s) => ({ ...s, showTodos: false }))} aria-label="Hide"><X size={13} /></button>
      </div>
      {today.slice(0, 5).map((t) => <TodoRow key={t.id} t={t} onToggle={() => toggleTodo(t.id)} />)}
      {!today.length && <p className="muted small" style={{ padding: '4px 0' }}>Nothing scheduled for this project.</p>}
    </div>
  )
}

// One to-do line: checkbox to finish it, the rest opens the task where it lives.
export function TodoRow({ t, onToggle }) {
  const { go } = useApp()
  const open = () => (t.ask ? (go('chat'), setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: t.ask })), 50)) : t.to && go(t.to))
  return (
    <div className="row" style={{ padding: '3px 0', gap: 10, fontSize: 13 }}>
      {t.event ? <span style={{ width: 13, height: 13, margin: '3px 3px 3px 4px', borderRadius: 4, background: 'var(--hover)', flexShrink: 0 }} /> : <input type="checkbox" checked={t.status === 'done'} onChange={onToggle} aria-label={`Done: ${t.t}`} />}
      <button className="todo-link grow row" onClick={open}>
        <span className="ellipsis grow" style={{ textDecoration: t.status === 'done' ? 'line-through' : 'none', color: t.status === 'done' ? 'var(--faint)' : undefined }}>{t.t}</span>
        {t.time && <span className="faint small">{t.time}</span>}
        {(t.to || t.ask) && <ChevronRight size={14} color="var(--faint)" />}
      </button>
    </div>
  )
}

// Phantom-style wallet actions on the home screen: money moves sit right next to the AI.
const PX = { USDC: 1, ETH: 3498, SOL: 186.6, HYPE: 24.06 }

function HomeActions() {
  const [open, setOpen] = useState(null)
  const acts = [['send', 'Send', ArrowUpRight], ['swap', 'Swap', ArrowLeftRight], ['receive', 'Receive', ArrowDownLeft], ['buy', 'Buy', CreditCard]]
  return (
    <>
      <div className="home-acts">
        {acts.map(([k, l, Icon]) => <button key={k} onClick={() => setOpen(k)} aria-label={l}><span className="home-act-ico"><Icon size={17} strokeWidth={1.75} /></span>{l}</button>)}
      </div>
      {open === 'send' && <TransferSheet init={{ external: true }} onClose={() => setOpen(null)} />}
      {open === 'receive' && <DepositSheet title="Receive" onClose={() => setOpen(null)} />}
      {open === 'swap' && <SwapSheet onClose={() => setOpen(null)} />}
      {open === 'buy' && <BuySheet onClose={() => setOpen(null)} />}
    </>
  )
}

const SwapRow = ({ label, token, setToken, children }) => (
  <div className="tx" style={{ padding: 14 }}>
    <div className="muted small">{label}</div>
    <div className="row between" style={{ marginTop: 4, gap: 10 }}>
      {children}
      <span className="row" style={{ gap: 6, flexShrink: 0 }}><Mark name={token} size={22} />
        <select className="swap-token" value={token} onChange={(e) => setToken(e.target.value)}>{Object.keys(PX).map((t) => <option key={t}>{t}</option>)}</select></span>
    </div>
  </div>
)

function SwapSheet({ onClose }) {
  const { approve } = useApp()
  const [from, setFrom] = useState('USDC')
  const [to, setTo] = useState('ETH')
  const [amt, setAmt] = useState(500)
  const out = (amt * PX[from]) / PX[to]
  const fmtOut = out < 1 ? out.toFixed(4) : out.toLocaleString(undefined, { maximumFractionDigits: 2 })
  const flip = () => { setFrom(to); setTo(from) }
  const review = () => { onClose(); approve({
    kind: 'Swap', title: `Swap ${amt.toLocaleString()} ${from} to ${to}`, success: `Got ${fmtOut} ${to}`,
    lines: [['Pay', `${amt.toLocaleString()} ${from}`], ['Receive', `≈ ${fmtOut} ${to}`], ['Route', 'Best of 6 DEXs'], ['Fee', '$0.04']],
    checks: baseChecks([{ label: 'Price impact under 0.1%', status: 'pass' }]),
  }) }
  return (
    <Sheet title="Swap" onClose={onClose} foot={<button className="btn primary block" style={{ height: 42 }} disabled={!amt || from === to} onClick={review}>Review</button>}>
      <SwapRow label="You pay" token={from} setToken={setFrom}>
        <input type="number" value={amt} onChange={(e) => setAmt(+e.target.value)} className="swap-amt" />
      </SwapRow>
      <div style={{ display: 'grid', placeItems: 'center', margin: '-6px 0' }}><button className="swap-flip" onClick={flip} aria-label="Flip"><ArrowDown size={14} /></button></div>
      <SwapRow label="You receive" token={to} setToken={setTo}><span className="num swap-amt">{fmtOut}</span></SwapRow>
      <div className="row between small muted" style={{ padding: '10px 2px 0' }}><span>1 {from} = {(PX[from] / PX[to]).toPrecision(4)} {to}</span><span>Fee $0.04</span></div>
    </Sheet>
  )
}

function BuySheet({ onClose }) {
  const { approve } = useApp()
  const [usd, setUsd] = useState(100)
  const [token, setToken] = useState('USDC')
  const [pay, setPay] = useState('apple')
  const get = usd / PX[token]
  const review = () => { onClose(); approve({
    kind: 'Buy crypto', title: `Buy $${usd} of ${token}`, success: `${token} is in Main`,
    lines: [['Pay', `$${usd.toFixed(2)} with ${pay === 'apple' ? 'Apple Pay' : 'Visa ending 4242'}`], ['Get', `≈ ${get < 1 ? get.toFixed(4) : get.toFixed(2)} ${token}`], ['To', 'Main wallet'], ['Fee', token === 'USDC' ? '$0' : `$${(usd * 0.01).toFixed(2)}`]],
    checks: baseChecks([{ label: 'Delivered to your own wallet', status: 'pass' }]),
  }) }
  return (
    <Sheet title="Buy" onClose={onClose} foot={<button className="btn primary block" style={{ height: 42 }} disabled={!usd} onClick={review}>Review</button>}>
      <div className="buy-amt num">$<input type="number" value={usd} onChange={(e) => setUsd(+e.target.value)} aria-label="Amount in dollars" /></div>
      <div className="chips" style={{ justifyContent: 'center', marginBottom: 16 }}>{[50, 100, 250, 500].map((v) => <button key={v} className={`chip sm ${usd === v ? 'on' : ''}`} onClick={() => setUsd(v)}>${v}</button>)}</div>
      <div className="topup-amts" style={{ gridTemplateColumns: 'repeat(4, 1fr)', margin: '0 0 12px' }}>
        {Object.keys(PX).map((t) => <button key={t} className={token === t ? 'on' : ''} onClick={() => setToken(t)}><Mark name={t} size={22} /><span>{t}</span></button>)}
      </div>
      {[['apple', 'Apple Pay', 'Instant'], ['card', 'Visa ending 4242', 'Instant, 1% fee']].map(([k, t, d]) => (
        <button key={k} className={`topup-src ${pay === k ? 'on' : ''}`} onClick={() => setPay(k)}>
          <span className="wallet-ico"><CreditCard size={13} /></span><span className="grow"><b>{t}</b><small>{d}</small></span>
        </button>
      ))}
      <p className="faint small" style={{ marginTop: 12, textAlign: 'center' }}>Lands in Main. USDC has no fee.</p>
    </Sheet>
  )
}

// In the Chrome extension, Hermit knows the page you're reading.
const EXT = new URLSearchParams(window.location.search).has('ext')
function PageContext({ onAsk }) {
  return (
    <div className="page-ctx">
      <div className="faint small">On this page</div>
      <div className="row" style={{ gap: 10, marginTop: 8 }}>
        <span className="site-fav lg">D</span>
        <div style={{ minWidth: 0 }}><div className="ellipsis" style={{ fontWeight: 500 }}>SEC approves staking for spot ETH ETFs</div><div className="faint small ellipsis">thedailyblock.news</div></div>
      </div>
      <div className="chips" style={{ marginTop: 12 }}>
        <button className="chip sm" onClick={() => onAsk('Tell me more about the ETH ETF staking approval')}>Summarize this page</button>
        <button className="chip sm on" onClick={() => onAsk('What news is moving the market today?')}>Trade this news</button>
      </div>
    </div>
  )
}
