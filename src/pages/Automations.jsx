import { useEffect, useRef, useState } from 'react'
import { Plus, ArrowLeft, ArrowUp, Zap, Clock, CheckCircle2, ChevronRight } from 'lucide-react'
import Logo from '../components/Logo'
import ChatInput from '../components/ChatInput'
import { useApp } from '../App'

// Like Claude's automations: describe it in chat, Hermit drafts the rule, you turn it on.
// Each automation is a conversation: what you asked for, then every run as a reply.
const EXAMPLES = [
  'Every morning at 8, send me HYPE news on Telegram',
  'Buy $50 of ETH every Monday',
  'Alert me when HYPE funding goes above 0.03%',
  'Pay invoices from my inbox under $100',
]

const RUNS = {
  'Weekly ETH DCA': [['Oct 20, 09:00', 'Swapped 500 USDC for 0.143 ETH at $3,496 on Uniswap. Fee $0.41.'], ['Oct 13, 09:00', 'Swapped 500 USDC for 0.151 ETH at $3,311.'], ['Oct 6, 09:00', 'Swapped 500 USDC for 0.149 ETH at $3,355.']],
  'Best stable yield': [['Oct 22, 14:10', 'Aave fell to 5.1% while Morpho paid 7.9%. Moved $4,200 to Morpho. +$118 a year.'], ['Oct 9, 03:40', 'Checked 14 pools. Gap under 1.5%, nothing moved.']],
  'HYPE funding arb': [['2h ago', 'Funding hit 0.034%/h. Opened a $2,600 hedge: spot long, perp short. +$12.60 so far.'], ['Oct 24, 18:00', 'Funding dropped below 0.01%. Closed the hedge for +$41.20.']],
  'Daily quest runner': [['Today, 08:00', 'Finished 6 tasks on Galxe and Layer3 across 3 wallets. Gas $0.38.'], ['Yesterday, 08:00', 'Finished 4 tasks. Skipped one that asked for a token approval.']],
  'Meme sniper': [['Oct 18, 22:14', 'Bought $100 of GIGA after the hazard scan passed. Sold at 1.6x for +$58.'], ['Oct 17, 11:02', 'Skipped HERM: 61% of supply in dev-linked wallets.']],
  'Invoice payer': [['Oct 21, 10:30', 'Notion invoice $10 arrived. You approved it, paid in USDC.']],
}

// Demo stand-in for the model reading a sentence and drafting a rule.
function draft(text) {
  const t = text.toLowerCase()
  const amt = text.match(/\$\s?([\d,.]+)/)?.[1]
  const days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'].find((d) => t.includes(d))
  const time = text.match(/\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/i)
  const hh = time && !/\$/.test(text.slice(Math.max(0, time.index - 1), time.index)) ? String((+time[1] % 12) + (time[3]?.toLowerCase() === 'pm' ? 12 : 0)).padStart(2, '0') + ':' + (time[2] || '00') : '09:00'
  const token = (text.match(/\b(ETH|BTC|SOL|HYPE|PENGU|USDC)\b/i)?.[1] || 'ETH').toUpperCase()
  const trigger = /funding/.test(t) ? `${token} funding > ${text.match(/0\.\d+%/)?.[0] || '0.03%'}/h`
    : /below|drops|under \$/.test(t) && /buy/.test(t) ? `${token} below $${amt || '3,200'}`
    : /above|over \$/.test(t) && !/invoice/.test(t) ? `${token} above $${amt || '27'}`
    : /invoice|bill/.test(t) ? 'Invoice email arrives'
    : days ? `Every ${days[0].toUpperCase() + days.slice(1)} ${hh}`
    : /hour/.test(t) ? 'Every hour' : `Every day ${/morning/.test(t) && !time ? '08:00' : hh}`
  const action = /news|digest|brief/.test(t) ? `Send a ${token} news digest${/telegram/.test(t) ? ' on Telegram' : ''}`
    : /alert|tell me|notify/.test(t) ? 'Send me an alert'
    : /invoice|bill|pay/.test(t) ? `Pay the invoice${amt ? ` if under $${amt}` : ''} in USDC`
    : /sell|profit/.test(t) ? `Sell ${text.match(/\d+%/)?.[0] || '20%'} of ${token}`
    : /buy|dca/.test(t) ? `Buy ${amt ? `$${amt}` : '$100'} of ${token} with USDC` : 'Run the task and report back'
  const spends = /buy|sell|pay|invoice/.test(t)
  const name = action.replace(/ with USDC| in USDC| on Telegram/, '').replace(/^Send (me )?(a |an )?/, '').replace(/^\w/, (c) => c.toUpperCase())
  return { name, trigger, action, limit: spends ? `$${amt || 100} per run` : 'No spending', ask: spends && !/under/.test(t), prompt: text }
}

const next = (trigger) => (/Every hour/.test(trigger) ? 'in 1 hour' : /Every day/.test(trigger) ? `tomorrow at ${trigger.slice(-5)}` : /Every \w+day/.test(trigger) ? trigger.replace('Every ', 'next ') : 'when it happens')

export default function Automations() {
  const { automations, setAutomations } = useApp()
  const [open, setOpen] = useState(null)
  const toggle = (name) => setAutomations((a) => a.map((x) => (x.name === name ? { ...x, on: !x.on } : x)))
  if (open) return <Thread start={open} onBack={() => setOpen(null)} />
  return (
    <div className="page" style={{ maxWidth: 720 }}>
      <div className="page-head">
        <h1>Automations</h1>
        <button className="btn primary" onClick={() => setOpen({ text: '' })}><Plus size={15} /> New</button>
      </div>
      <ChatInput projectPicker={false} label="Automation" placeholder="Describe an automation" dictation="Every morning at 8, send me HYPE news on Telegram" onSend={({ text }) => text && setOpen({ text })} />
      <div className="chips" style={{ margin: '10px 0 28px' }}>{EXAMPLES.map((e) => <button key={e} className="chip sm wrap" onClick={() => setOpen({ text: e })}>{e}</button>)}</div>
      {automations.map((a) => (
        <div className="list-row fade-in auto-row" key={a.name} role="button" tabIndex={0} onClick={() => setOpen({ name: a.name })}>
          <span className="mark app" style={{ width: 34, height: 34, color: a.on ? 'var(--accent)' : 'var(--faint)' }}>{/Every|Daily|day/.test(a.trigger) ? <Clock size={15} /> : <Zap size={15} />}</span>
          <div className="grow">
            <div className="list-title" style={{ color: a.on ? undefined : 'var(--faint)' }}>{a.name}</div>
            <div className="list-sub">{a.trigger}</div>
            <div className="list-sub">{a.last}</div>
          </div>
          <button className={`toggle ${a.on ? 'on' : ''}`} onClick={(e) => { e.stopPropagation(); toggle(a.name) }} aria-label={`Toggle ${a.name}`} />
          <ChevronRight size={15} color="var(--faint)" />
        </div>
      ))}
    </div>
  )
}


function Thread({ start, onBack }) {
  const { automations, setAutomations, addAutomation } = useApp()
  const [name, setName] = useState(start.name || null)
  const a = automations.find((x) => x.name === name)
  const [msgs, setMsgs] = useState(() => {
    if (!a) return []
    const runs = (RUNS[a.name] || [[a.last, 'Ran as planned.']]).slice().reverse()
    return [
      { role: 'user', text: a.prompt || `${a.trigger}: ${a.action.toLowerCase()}` },
      { role: 'ai', note: `Automation on. ${a.trigger}, I will ${a.action.charAt(0).toLowerCase() + a.action.slice(1)}. Limit: ${a.limit}.` },
      ...runs.map(([when, text]) => ({ role: 'ai', run: when, text })),
    ]
  })
  const [typing, setTyping] = useState(false)
  const end = useRef(null)
  useEffect(() => { end.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }) }, [msgs, typing])
  const say = (m, delay = 700) => { setTyping(true); setTimeout(() => { setTyping(false); setMsgs((l) => [...l, m]) }, delay) }

  const send = (text) => {
    setMsgs((l) => [...l, { role: 'user', text }])
    const t = text.toLowerCase()
    if (!a) return say({ role: 'ai', draft: draft(text) })
    if (/pause|stop|turn off/.test(t)) { setAutomations((l) => l.map((x) => (x.name === a.name ? { ...x, on: false } : x))); return say({ role: 'ai', note: `Paused. ${a.name} will not run until you turn it back on.` }) }
    if (/resume|turn on|start/.test(t)) { setAutomations((l) => l.map((x) => (x.name === a.name ? { ...x, on: true } : x))); return say({ role: 'ai', note: `Back on. Next run ${next(a.trigger)}.` }) }
    if (/run (it )?now|test/.test(t)) return say({ role: 'ai', run: 'Just now', text: (RUNS[a.name] || [['', 'Ran as planned. Nothing needed your approval.']])[0][1] }, 1200)
    const d = draft(text)
    if (/every|daily|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}(am|pm|:)/.test(t)) {
      setAutomations((l) => l.map((x) => (x.name === a.name ? { ...x, trigger: d.trigger } : x)))
      return say({ role: 'ai', note: `Updated. Now runs ${d.trigger.charAt(0).toLowerCase() + d.trigger.slice(1)}. Next run ${next(d.trigger)}.` })
    }
    return say({ role: 'ai', note: 'Got it. I will apply that from the next run and tell you what changed.' })
  }
  const turnOn = (d) => {
    addAutomation({ name: d.name, trigger: d.trigger, action: d.action, limit: d.limit, on: true, last: 'Just created', prompt: d.prompt })
    setName(d.name)
    say({ role: 'ai', note: `Automation on. Next run ${next(d.trigger)}. ${d.ask ? 'I will ask you before each one that spends money.' : 'Reply here to change it, or say "run it now" to test.'}` }, 400)
  }
  useEffect(() => { if (start.text) send(start.text) }, [])

  return (
    <div className="auto-thread">
      <div className="auto-head">
        <button className="icon-btn" onClick={onBack} aria-label="Back"><ArrowLeft size={18} /></button>
        <div className="grow" style={{ minWidth: 0 }}>
          <div className="ellipsis" style={{ fontWeight: 600 }}>{a ? a.name : 'New automation'}</div>
          {a && <div className="faint small ellipsis">{a.trigger}{a.on ? '' : ', paused'}</div>}
        </div>
        {a && <button className={`toggle ${a.on ? 'on' : ''}`} onClick={() => setAutomations((l) => l.map((x) => (x.name === a.name ? { ...x, on: !x.on } : x)))} aria-label="Turn automation on or off" />}
      </div>
      <div className="auto-msgs">
        <div className="auto-inner">
          {!msgs.length && (
            <div className="auto-empty">
              <Logo size={18} />
              <p>Tell Hermit what to do and when. It drafts the rule, you turn it on.</p>
              <div className="chips" style={{ justifyContent: 'center' }}>{EXAMPLES.map((e) => <button key={e} className="chip sm wrap" onClick={() => send(e)}>{e}</button>)}</div>
            </div>
          )}
          {msgs.map((m, i) => m.role === 'user'
            ? <div key={i} className="msg-user fade-in"><div className="bubble">{m.text}</div></div>
            : m.draft ? <Draft key={i} d={m.draft} done={!!a} onOn={() => turnOn(m.draft)} onEdit={() => say({ role: 'ai', note: 'Tell me what to change: the time, the amount, or what it does.' }, 300)} />
            : m.run ? <div key={i} className="msg-ai fade-in"><div className="auto-run"><span className="faint small row" style={{ gap: 6 }}><Clock size={12} /> Run {m.run}</span><p>{m.text}</p></div></div>
            : <div key={i} className="msg-ai fade-in"><div className="ai-note"><CheckCircle2 size={15} color="var(--green)" /><p>{m.note}</p></div></div>)}
          {typing && <div className="msg-ai"><span className="typing"><i /><i /><i /></span></div>}
          <div ref={end} />
        </div>
      </div>
      <div className="composer-wrap"><div className="auto-inner"><ChatInput autoFocus projectPicker={false} label="Automation" placeholder={a ? 'Change it, pause it, or "run it now"' : 'Describe an automation'} dictation={a ? 'Run it now' : 'Buy $50 of ETH every Monday'} onSend={({ text }) => text && send(text)} /></div></div>
    </div>
  )
}

function Draft({ d, done, onOn, onEdit }) {
  return (
    <div className="msg-ai fade-in">
      <p style={{ marginBottom: 10 }}>Here is the automation. Check it, then turn it on.</p>
      <div className="ccard">
        <div className="ccard-head"><span className="row" style={{ gap: 8, fontWeight: 500 }}><Zap size={14} color="var(--accent)" /> {d.name}</span></div>
        <div className="ccard-body">
          {[['When', d.trigger], ['Do', d.action], ['Spending', d.limit], ['Approval', d.ask ? 'Ask me each time' : 'Runs on its own']].map(([k, v]) => (
            <div className="tx-line" key={k}><span>{k}</span><span>{v}</span></div>
          ))}
        </div>
        <div className="ccard-foot">
          <button className="btn" onClick={onEdit} disabled={done}>Edit</button>
          <button className="btn brand" onClick={onOn} disabled={done}><Zap size={14} /> {done ? 'On' : 'Turn on'}</button>
        </div>
      </div>
    </div>
  )
}
