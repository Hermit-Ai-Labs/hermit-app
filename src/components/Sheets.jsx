import { useEffect, useState } from 'react'
import { X, FileText, Image, Table, Upload, Mic, Square, Download, Sparkles, KeyRound, HardDrive, Plus, Mail, Smartphone, Fingerprint } from 'lucide-react'
import Mark from './Mark'
import { CandleChart, AreaChart } from './Charts'
import { baseChecks } from './Approval'
import { candles, walk, files as hermitFiles } from '../data'
import { useApp } from '../App'

// Bottom sheet on phones, centered dialog on desktop (styles: .modal-backdrop / .modal).
export function Sheet({ title, onClose, children, foot, wide }) {
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" style={wide ? { maxWidth: 560 } : undefined} onClick={(e) => e.stopPropagation()}>
        <div className="modal-head" style={{ alignItems: 'center' }}>
          <div className="grow ellipsis" style={{ fontSize: 17, fontWeight: 600 }}>{title}</div>
          <button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
        </div>
        <div className="modal-body stack" style={{ gap: 14 }}>{children}</div>
        {foot && <div className="modal-foot">{foot}</div>}
      </div>
    </div>
  )
}

// ---------- Files ----------

// Sample files the attach picker offers, by source. kind decides how Hermit reads it in chat.
export const SAMPLE_FILES = [
  { name: 'wallets.xlsx', kind: 'csv', size: '49 rows', src: 'Device' },
  { name: 'Invoice_Figma_2291.pdf', kind: 'invoice', size: '84 KB', src: 'Device' },
  { name: 'trades_Q3.csv', kind: 'csv', size: '412 rows', src: 'Device' },
  { name: 'Monad_whitepaper.pdf', kind: 'paper', size: '38 pages', src: 'Drive' },
  { name: 'PENGU_4H_chart.png', kind: 'chart', size: '1.2 MB', src: 'Photos' },
]

const kindOf = (name) => {
  const n = name.toLowerCase()
  if (n.endsWith('.png') || n.endsWith('.jpg')) return 'chart'
  if (n.endsWith('.csv')) return 'csv'
  if (n.includes('invoice')) return 'invoice'
  if (/\.(ts|js|json|prompt)$/.test(n)) return 'code'
  if (n.endsWith('.pdf')) return 'paper'
  return 'doc'
}
const iconFor = (kind) => ({ chart: Image, csv: Table }[kind] || FileText)

export function FileIcon({ name, size = 34 }) {
  const Ic = iconFor(kindOf(name))
  return <span className="mark app" style={{ width: size, height: size }}><Ic size={size * 0.44} strokeWidth={1.75} /></span>
}

// Preview body for any file, by type. Content is illustrative.
function Preview({ file }) {
  const kind = file.kind || kindOf(file.name)
  if (kind === 'chart') return <CandleChart data={candles(40, 0.026, 0.06, 11, 0.05)} height={200} />
  if (kind === 'csv') {
    const rows = [['Date', 'Pair', 'Side', 'PnL'], ['Sep 30', 'HYPE-PERP', 'Long', '+$212'], ['Sep 28', 'PENGU', 'Buy', '−$64'], ['Sep 27', 'ETH-PERP', 'Short', '+$88'], ['Sep 25', 'SOL', 'Buy', '+$41']]
    return <div className="tx" style={{ padding: '6px 14px' }}>{rows.map((r, i) => <div key={i} className="tx-line" style={i === 0 ? { color: 'var(--faint)' } : undefined}>{r.map((c, j) => <span key={j} style={{ flex: 1, textAlign: j === 3 ? 'right' : 'left', color: i === 0 ? 'var(--faint)' : undefined }}>{c}</span>)}</div>)}</div>
  }
  if (kind === 'invoice') return <div className="tx">{[['From', 'Figma, Inc.'], ['Invoice', '#2291'], ['Plan', 'Professional'], ['Amount', '$45.00'], ['Due', 'Oct 27']].map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span>{v}</span></div>)}</div>
  if (kind === 'code') return <pre className="mono tx" style={{ margin: 0, padding: 14, whiteSpace: 'pre-wrap', fontSize: 12, lineHeight: 1.7 }}>{file.name.endsWith('.json') ? '{\n  "schedule": "0 8 * * *",\n  "budget": 20,\n  "pay": "x402"\n}' : 'const news = hermit.tool("perplexity")\ncron("0 8 * * *", async () => {\n  const digest = await news.search("HYPE news")\n  await telegram.send(me, digest.summary)\n})'}</pre>
  return <div className="stack" style={{ gap: 8, lineHeight: 1.6 }}><b>Summary</b><p className="muted">Key points, decisions and next steps from {file.name}, pulled out by Hermit on your device.</p><b>Action items</b><p className="muted">Ship wallet onboarding by Nov 8. Compare Privy with a local key. Send the Pendle deck.</p></div>
}

export function FileSheet({ file, onClose }) {
  const { go, toast } = useApp()
  const ask = () => { onClose(); go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: { text: `What's in ${file.name}?`, attachment: { ...file, kind: file.kind || kindOf(file.name) } } })), 50) }
  return (
    <Sheet title={file.name} onClose={onClose} wide
      foot={<><button className="btn" onClick={() => toast('Saved to Downloads')}><Download size={15} /></button><button className="btn brand grow" onClick={ask}><Sparkles size={14} /> Ask about this file</button></>}>
      <div className="muted small">{[file.size, file.src, file.when].filter(Boolean).join(', ')}</div>
      <Preview file={file} />
    </Sheet>
  )
}

const SOURCES = ['Device', 'Photos', 'Hermit files', 'Drive']

export function AttachPicker({ onPick, onClose }) {
  const [src, setSrc] = useState('Device')
  const list = src === 'Hermit files'
    ? hermitFiles.map((f) => ({ name: f.name, kind: kindOf(f.name), size: f.size, src: f.src }))
    : SAMPLE_FILES.filter((f) => f.src === src || (src === 'Device' && f.src !== 'Drive' && f.src !== 'Photos'))
  return (
    <Sheet title="Attach" onClose={onClose}>
      <div className="seg" style={{ width: '100%' }}>{SOURCES.map((s) => <button key={s} style={{ flex: 1 }} className={s === src ? 'on' : ''} onClick={() => setSrc(s)}>{s}</button>)}</div>
      <div>
        {list.map((f) => (
          <button className="list-row" key={f.name} onClick={() => { onPick(f); onClose() }}>
            <FileIcon name={f.name} />
            <div className="grow"><div className="list-title">{f.name}</div><div className="list-sub">{f.size}</div></div>
            <Plus size={16} color="var(--faint)" />
          </button>
        ))}
      </div>
      <p className="faint small">Files are read on your device. Nothing is uploaded.</p>
    </Sheet>
  )
}

export function RecordSheet({ onSave, onClose }) {
  const [secs, setSecs] = useState(0)
  const [on, setOn] = useState(true)
  useEffect(() => { if (!on) return; const t = setInterval(() => setSecs((s) => s + 1), 1000); return () => clearInterval(t) }, [on])
  const mm = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`
  return (
    <Sheet title="Record" onClose={onClose}
      foot={<button className="btn primary block" disabled={on} onClick={() => { onSave({ name: `Voice memo ${mm}`, type: 'Meeting notes', src: 'Dictation', when: 'Just now', size: `${Math.max(1, Math.round(secs / 60))} min` }); onClose() }}>Save to Files</button>}>
      <div style={{ textAlign: 'center', padding: '12px 0' }}>
        <div className="big num">{mm}</div>
        <div className="rec-wave">{Array.from({ length: 28 }, (_, i) => <i key={i} style={{ animationDelay: `${(i % 7) * 0.08}s`, animationPlayState: on ? 'running' : 'paused' }} />)}</div>
        <button className="rec-btn" onClick={() => setOn(!on)} aria-label={on ? 'Stop' : 'Resume'}>{on ? <Square size={18} fill="currentColor" /> : <Mic size={20} />}</button>
        <p className="muted small" style={{ marginTop: 10 }}>{on ? 'Transcribing on device' : 'Stopped. Save it or keep recording.'}</p>
      </div>
    </Sheet>
  )
}

// ---------- Projects ----------

const TEMPLATES = ['DeFi yield', 'Trading bot', 'Airdrop farming', 'Research', 'Dev tool', 'Blank']

export function NewProjectSheet({ onCreate, onClose }) {
  const [name, setName] = useState('')
  const [tpl, setTpl] = useState('DeFi yield')
  const [budget, setBudget] = useState(1000)
  return (
    <Sheet title="New project" onClose={onClose}
      foot={<button className="btn primary block" disabled={!name.trim()} onClick={() => { onCreate({ name: name.trim(), tpl, budget }); onClose() }}>Create</button>}>
      <label className="field">Name<input className="cal-input" autoFocus placeholder="e.g. ETH staking ladder" value={name} onChange={(e) => setName(e.target.value)} /></label>
      <div className="field">Template<div className="chips" style={{ marginTop: 4 }}>{TEMPLATES.map((t) => <button key={t} className={`chip sm ${t === tpl ? 'on' : ''}`} onClick={() => setTpl(t)}>{t}</button>)}</div></div>
      <label className="field"><span className="row between"><span>Budget the agent can use</span><b className="num" style={{ color: 'var(--text)' }}>${budget.toLocaleString()}</b></span>
        <input type="range" min="0" max="20000" step="250" value={budget} onChange={(e) => setBudget(+e.target.value)} /></label>
      <p className="faint small">The project gets its own chats, files, instructions and spending limit.</p>
    </Sheet>
  )
}

// ---------- Wallet ----------

export function AddWalletSheet({ type = 'local', onAdd, onClose }) {
  const local = [
    { id: 'new', icon: Plus, t: 'Create a local wallet', d: 'Keys stay in Secure Enclave', w: { name: 'New wallet', kind: 'Local' } },
    { id: 'import', icon: KeyRound, t: 'Import with recovery phrase', d: 'Entered on device only', w: { name: 'Imported', kind: 'Local' } },
    { id: 'ledger', icon: HardDrive, t: 'Connect a hardware wallet', d: 'Ledger or Trezor', w: { name: 'Ledger 2', kind: 'Ledger' } },
  ]
  // Privy wallets are keyless: the user proves who they are and Privy splits the key.
  const privy = [
    { id: 'email', icon: Mail, t: 'Continue with email', d: 'ryan@hermit.app', w: { name: 'Privy wallet', kind: 'Privy, email' } },
    { id: 'google', logo: 'gmail', t: 'Continue with Google', d: 'One-tap sign in', w: { name: 'Privy wallet', kind: 'Privy, Google' } },
    { id: 'apple', icon: Smartphone, t: 'Continue with Apple', d: 'Face ID', w: { name: 'Privy wallet', kind: 'Privy, Apple' } },
    { id: 'passkey', icon: Fingerprint, t: 'Use a passkey', d: 'No password, no seed phrase', w: { name: 'Privy wallet', kind: 'Privy, passkey' } },
  ]
  const [step, setStep] = useState(null)
  const finish = (o) => { onAdd({ id: `w${Date.now()}`, type, addr: '0x' + Math.random().toString(16).slice(2, 6) + '…' + Math.random().toString(16).slice(2, 6), usd: 0, ...o.w }); onClose() }
  const pick = (o) => (type === 'privy' ? setStep(o) : finish(o))
  if (step) return (
    <Sheet title="Create Privy wallet" onClose={onClose}>
      <div className="stack" style={{ gap: 14, alignItems: 'center', textAlign: 'center', padding: '8px 0' }}>
        <span className="wallet-ico" style={{ width: 48, height: 48, borderRadius: 14 }}><Fingerprint size={22} /></span>
        <div><div style={{ fontWeight: 600 }}>Confirm with {step.t.replace('Continue with ', '').replace('Use a ', '')}</div><div className="muted small" style={{ marginTop: 4 }}>Privy creates a wallet only you can sign for. Hermit never sees the key.</div></div>
        <div className="tx" style={{ width: '100%', textAlign: 'left' }}>
          <div className="tx-line"><span>Recovery</span><span>{step.d}</span></div>
          <div className="tx-line"><span>Chains</span><span>EVM and Solana</span></div>
          <div className="tx-line"><span>Agent spending</span><span>Within your limits</span></div>
        </div>
        <button className="btn brand block" style={{ height: 42 }} onClick={() => finish(step)}><Fingerprint size={15} /> Create wallet</button>
      </div>
    </Sheet>
  )
  return (
    <Sheet title={type === 'privy' ? 'Create Privy wallet' : 'Add local wallet'} onClose={onClose}>
      <p className="muted small" style={{ marginBottom: 6 }}>{type === 'privy' ? 'Keyless. Sign in to create and recover it, no seed phrase.' : 'Keys are created and stored on this device.'}</p>
      {(type === 'privy' ? privy : local).map((o) => (
        <button key={o.id} className="list-row" onClick={() => pick(o)}>
          {o.logo ? <Mark name={o.logo} size={34} /> : <span className="mark app" style={{ width: 34, height: 34 }}><o.icon size={15} /></span>}
          <div className="grow"><div className="list-title">{o.t}</div><div className="list-sub">{o.d}</div></div>
        </button>
      ))}
    </Sheet>
  )
}

export function TokenSheet({ token, onClose, onAction }) {
  const up = token.ch >= 0
  return (
    <Sheet title={token.sym} onClose={onClose} wide>
      <div className="row"><Mark name={token.sym} size={36} /><div><div className="stat-value" style={{ margin: 0 }}>${token.usd.toLocaleString()}</div><div className={`small ${up ? 'up' : 'down'}`}>{up ? '+' : ''}{token.ch}% today, {token.amt.toLocaleString()} {token.sym}</div></div></div>
      <CandleChart data={candles(48, token.usd / Math.max(token.amt, 1) * 0.9, 0.035, token.sym.length * 3, up ? 0.06 : -0.06)} height={160} />
      <div className="quick" style={{ maxWidth: 'none', margin: 0 }}>
        {[['Send', 'send'], ['Swap', 'swap'], ['Bridge', 'bridge'], ['Earn', 'earn']].map(([l, a]) => (
          <button key={a} onClick={() => { onClose(); onAction(a, token) }}><span>{l[0]}</span>{l}</button>
        ))}
      </div>
    </Sheet>
  )
}

// ---------- Payments ----------

export function ScheduleSheet({ item, onClose }) {
  const { approve, toast } = useApp()
  const [amt, setAmt] = useState(item.amt)
  const [paused, setPaused] = useState(false)
  return (
    <Sheet title={item.to} onClose={onClose}
      foot={<><button className="btn" onClick={() => { setPaused(!paused); toast(paused ? 'Resumed' : 'Paused') }}>{paused ? 'Resume' : 'Pause'}</button><button className="btn primary grow" onClick={() => { onClose(); approve({ kind: 'Payment', title: `Pay ${item.to} now`, success: `Paid ${item.to}`, lines: [['For', item.what], ['Amount', `$${amt}`], ['Route', item.rail]], checks: baseChecks() }) }}>Pay now</button></>}>
      <div className="tx">{[['For', item.what], ['Next', item.when], ['Paid with', item.rail], ['Status', paused ? 'Paused' : 'Scheduled']].map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span>{v}</span></div>)}</div>
      <label className="field">Amount<input type="number" value={amt} onChange={(e) => setAmt(+e.target.value)} /></label>
      <button className="btn ghost sm" style={{ color: 'var(--red)', alignSelf: 'flex-start' }} onClick={() => { onClose(); toast('Payment cancelled') }}>Cancel this payment</button>
    </Sheet>
  )
}

// ---------- Connectors ----------

export function AddMcpSheet({ onAdd, onClose }) {
  const [url, setUrl] = useState('')
  const [name, setName] = useState('')
  return (
    <Sheet title="Add MCP server" onClose={onClose}
      foot={<button className="btn primary block" disabled={!url.trim()} onClick={() => { onAdd({ name: name.trim() || url.replace(/^https?:\/\//, '').split('/')[0], kind: 'MCP', desc: 'Custom server', on: true }); onClose() }}>Connect</button>}>
      <label className="field">Server URL or command<input className="cal-input" autoFocus placeholder="https://mcp.example.com or npx my-server" value={url} onChange={(e) => setUrl(e.target.value)} /></label>
      <label className="field">Name<input className="cal-input" placeholder="Optional" value={name} onChange={(e) => setName(e.target.value)} /></label>
      <p className="faint small">Hermit asks before any tool from this server moves money.</p>
    </Sheet>
  )
}

// ---------- Details ----------

export function ActivitySheet({ item, onClose }) {
  const { toast } = useApp()
  const inflow = item.amt > 0
  return (
    <Sheet title={item.what} onClose={onClose} foot={<button className="btn block" onClick={() => toast('Opened in block explorer')}>View on explorer</button>}>
      <div className={`big num ${inflow ? 'up' : ''}`}>{inflow ? '+' : '−'}${Math.abs(item.amt).toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
      <div className="tx">{[['Type', item.cat], ['Route', item.via], ['When', item.when], ['Status', 'Confirmed'], ['Tx', '0x8f2c…a91d']].map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span className={k === 'Tx' ? 'mono' : undefined}>{v}</span></div>)}</div>
    </Sheet>
  )
}

export function ModelSheet({ model, onClose }) {
  const { toast } = useApp()
  const [on, setOn] = useState(true)
  return (
    <Sheet title={`${model.name} model`} onClose={onClose} foot={<button className="btn block" onClick={() => { onClose(); toast(model.update ? 'Updating…' : 'Re-downloading…') }}>{model.update ? 'Update' : 'Re-download'}</button>}>
      <div className="tx">{[['Size', model.d], ['Runs', 'On this device'], ['Last updated', model.update ? '2 months ago' : 'Oct 20']].map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span>{v}</span></div>)}</div>
      <div className="row between"><span>Use this model</span><button className={`toggle ${on ? 'on' : ''}`} onClick={() => setOn(!on)} aria-label="Use this model" /></div>
    </Sheet>
  )
}
