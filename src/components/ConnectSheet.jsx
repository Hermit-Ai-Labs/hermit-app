import { useEffect, useState } from 'react'
import { Check, ArrowLeftRight, Loader2, ShieldCheck, Copy } from 'lucide-react'
import { Sheet } from './Sheets'
import Mark from './Mark'
import Logo from './Logo'
import { useApp } from '../App'

// Demo sign-in for third-party accounts: consent, a short redirect, then a connected state.
const SCOPES = {
  X: { who: '@ryanchi', ok: 'Authorize app', scopes: ['Read your posts and profile', 'Read who you follow', 'Post and reply, only when you ask'], never: 'Hermit can never DM, follow or delete on its own.' },
  Discord: { who: 'ryanchi', ok: 'Authorize', scopes: ['Know your username and avatar', 'See servers you are in', 'Read roles in airdrop servers'], never: 'Hermit cannot read your DMs or send messages as you.', servers: ['Monad Community', 'Hyperliquid', 'Kaito Yappers', 'Hermit Alpha'] },
  Gmail: { who: 'ryan@hermit.app', ok: 'Allow', scopes: ['Read email', 'Create drafts'], never: 'Hermit never sends email without your approval.' },
  'Google Calendar': { who: 'ryan@hermit.app', ok: 'Allow', scopes: ['See and edit events'], never: 'Hermit asks before inviting anyone.' },
  GitHub: { who: 'RyanRuianChi', ok: 'Authorize', scopes: ['Read repositories', 'Open pull requests'], never: 'Hermit cannot delete repos or change settings.' },
}
const fallback = { who: 'ryan@hermit.app', ok: 'Allow', scopes: ['Read your data', 'Act when you ask'], never: 'Hermit asks before anything that costs money.' }

export default function ConnectSheet({ app, onDone, onClose }) {
  const { toast } = useApp()
  const [step, setStep] = useState('consent')
  const [server, setServer] = useState('Monad Community')
  const s = SCOPES[app] || fallback
  const finish = () => { setStep('wait'); setTimeout(() => setStep('done'), 1300) }
  // Telegram: the bot confirms the code by itself after a moment.
  useEffect(() => { if (app === 'Telegram' && step === 'consent') { const t = setTimeout(() => setStep('done'), 4500); return () => clearTimeout(t) } }, [app, step])
  const close = () => { if (step === 'done') onDone?.(); onClose() }

  const header = (
    <div className="connect-pair">
      <span className="connect-logo hermit"><Logo size={13} /></span>
      <ArrowLeftRight size={14} color="var(--faint)" />
      <Mark name={app} size={44} />
    </div>
  )

  if (step === 'done') return (
    <Sheet title={`Connect ${app}`} onClose={close}>
      <div className="connect">
        <span className="connect-ok"><Check size={22} /></span>
        <div className="connect-title">{app} connected</div>
        <p className="muted small">Signed in as {s.who}{app === 'Discord' ? `, added to ${server}` : ''}.</p>
        <button className="btn primary block" style={{ height: 42 }} onClick={close}>Done</button>
      </div>
    </Sheet>
  )
  if (step === 'wait') return (
    <Sheet title={`Connect ${app}`} onClose={onClose}>
      <div className="connect">{header}<Loader2 size={22} className="spin" /><p className="muted small">Returning to Hermit…</p></div>
    </Sheet>
  )
  if (app === 'Telegram') return (
    <Sheet title="Connect Telegram" onClose={onClose}>
      <div className="connect">
        {header}
        <div className="connect-title">Open @HermitBot and tap Start</div>
        <div className="connect-qr" aria-label="QR code">{Array.from({ length: 81 }, (_, i) => <i key={i} style={{ opacity: (i * 7 + (i % 9) * 3) % 5 < 2 ? 1 : 0 }} />)}</div>
        <button className="connect-code mono" onClick={() => toast('Code copied')}>HRM-4821 <Copy size={13} /></button>
        <p className="muted small">Or send this code to @HermitBot. Alerts and approvals will arrive in that chat.</p>
        <div className="row muted small" style={{ gap: 8 }}><Loader2 size={14} className="spin" /> Waiting for Telegram</div>
        <button className="btn block" style={{ height: 40 }} onClick={() => setStep('done')}>I tapped Start</button>
      </div>
    </Sheet>
  )
  return (
    <Sheet title={`Connect ${app}`} onClose={onClose}>
      <div className="connect">
        {header}
        <div className="connect-title">Hermit wants to access your {app} account</div>
        <div className="connect-who"><Mark name={app} size={20} /> {s.who}</div>
        <div className="connect-scopes">
          {s.scopes.map((x) => <div key={x}><Check size={14} color="var(--green)" /> {x}</div>)}
          <div className="faint"><ShieldCheck size={14} /> {s.never}</div>
        </div>
        {s.servers && (
          <label className="field" style={{ width: '100%', textAlign: 'left' }}>Add Hermit to a server
            <select value={server} onChange={(e) => setServer(e.target.value)}>{s.servers.map((x) => <option key={x}>{x}</option>)}</select>
          </label>
        )}
        <div className="row" style={{ gap: 8, width: '100%' }}>
          <button className="btn grow" style={{ height: 42 }} onClick={onClose}>Cancel</button>
          <button className="btn brand grow" style={{ height: 42 }} onClick={finish}>{s.ok}</button>
        </div>
      </div>
    </Sheet>
  )
}
