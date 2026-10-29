import { useEffect, useState } from 'react'
import { Lock, X, Copy, Fingerprint, Check, ShieldCheck, Loader2, ExternalLink, FileSpreadsheet } from 'lucide-react'
import Mark from './Mark'
import { baseChecks } from './Approval'
import { useApp } from '../App'

// A website opened inside Hermit, so the user never leaves the app (checkout pages, launchpads…).
export function InAppTab({ url, title, onClose, children }) {
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal inapp" onClick={(e) => e.stopPropagation()}>
        <div className="inapp-bar">
          <span className="inapp-dots"><i /><i /><i /></span>
          <span className="inapp-url"><Lock size={11} /> {url}</span>
          <button className="icon-btn" onClick={onClose} aria-label={`Close ${title}`}><X size={15} /></button>
        </div>
        <div className="inapp-body">{children}</div>
      </div>
    </div>
  )
}

/* ---------- 1. Developer buys an API key without leaving Hermit ---------- */

export function BuildProgress() {
  const steps = [['Frontend', '12 screens, React + Tailwind', true], ['Bank sync', 'CSV import, Plaid later', true], ['AI categorizer', 'Needs an LLM API key', false], ['Budgets and alerts', 'Next', false]]
  return (
    <div className="ccard">
      <div className="ccard-head"><span style={{ fontWeight: 500 }}>Budgeting app</span><span className="faint small">2 of 4 done</span></div>
      <div className="ccard-body" style={{ paddingTop: 6 }}>
        {steps.map(([t, d, ok], i) => (
          <div className="row" key={t} style={{ gap: 10, padding: '7px 0' }}>
            {ok ? <span className="step-dot ok"><Check size={11} /></span> : <span className={`step-dot ${i === 2 ? 'now' : ''}`} />}
            <div className="grow"><div style={{ fontWeight: ok || i === 2 ? 500 : 400, color: ok || i === 2 ? undefined : 'var(--faint)' }}>{t}</div><div className="list-sub">{d}</div></div>
          </div>
        ))}
      </div>
    </div>
  )
}

export function ApiCheckout() {
  const { approve, toast } = useApp()
  const [open, setOpen] = useState(false)
  const [plan, setPlan] = useState(25)
  const [key, setKey] = useState(null)
  const pay = () => {
    setOpen(false)
    approve({
      kind: 'API purchase', title: `OpenAI $${plan} credits`, success: 'Key added to your project',
      lines: [['Seller', 'OpenAI (verified)'], ['Amount', `${plan} USDC`], ['Pay with', 'USDC via x402'], ['Key goes to', 'Local vault and .env.local']],
      checks: baseChecks([{ label: 'Seller matches registry', status: 'pass' }, { label: 'Within dev budget ($60 left)', status: 'pass' }]),
      onSuccess: () => setKey('sk-proj-7Hq2…a8F2'),
    })
  }
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 10 }}><Mark name="OpenAI" size={28} /><span><div style={{ fontWeight: 500 }}>OpenAI API</div><div className="small muted">{key ? 'Connected' : 'Needed for the categorizer'}</div></span></span>
        {key && <span className="tag green"><span className="dot" />Active</span>}
      </div>
      <div className="ccard-body">
        {key ? (
          <>
            <div className="key-row mono"><span className="grow">{key}</span><button className="icon-btn" onClick={() => toast('Key copied')} aria-label="Copy key"><Copy size={14} /></button></div>
            <div className="tx-line"><span>Saved to</span><span>.env.local, local vault</span></div>
            <div className="tx-line"><span>Credits</span><span>${plan}, auto top-up off</span></div>
          </>
        ) : <p className="muted small">You don't have an OpenAI key yet. Buy credits here, no need to visit their site.</p>}
      </div>
      {!key && <div className="ccard-foot"><button className="btn brand" onClick={() => setOpen(true)}><ExternalLink size={14} /> Get API key</button></div>}
      {open && (
        <InAppTab url="platform.openai.com/settings/billing" title="OpenAI billing" onClose={() => setOpen(false)}>
          <div className="row" style={{ gap: 10, marginBottom: 16 }}><Mark name="OpenAI" size={30} /><div><div style={{ fontWeight: 600 }}>Add API credits</div><div className="small muted">Project: budget-app</div></div></div>
          <div className="topup-amts" style={{ margin: '0 0 14px' }}>
            {[10, 25, 50].map((v) => <button key={v} className={plan === v ? 'on' : ''} onClick={() => setPlan(v)}><b>${v}</b><span>≈ {(v * 4000).toLocaleString()} calls</span></button>)}
          </div>
          <div className="tx" style={{ marginBottom: 14 }}>
            <div className="tx-line"><span>Model</span><span>gpt-5-mini</span></div>
            <div className="tx-line"><span>Key scope</span><span>budget-app only</span></div>
          </div>
          <button className="btn brand block" style={{ height: 44 }} onClick={pay}><Fingerprint size={15} /> Pay ${plan} with Hermit</button>
          <p className="faint small" style={{ textAlign: 'center', marginTop: 10 }}>USDC via x402. No card, no account.</p>
        </InAppTab>
      )}
    </div>
  )
}

/* ---------- 2. Send to many wallets from a spreadsheet, privately ---------- */

const RECIPIENTS = Array.from({ length: 48 }, (_, i) => {
  const h = (n) => (((i + 7) * 2654435761 + n * 40503) >>> 0).toString(16).padStart(8, "0")
  return { addr: `0x${h(1).slice(0, 4)}…${h(2).slice(0, 4)}`, amt: [500, 250, 1000, 300, 750][i % 5] }
})
const TOTAL = RECIPIENTS.reduce((a, r) => a + r.amt, 0)

export function MultiSendCard() {
  const { approve } = useApp()
  const [relay, setRelay] = useState(true)
  const [sent, setSent] = useState(-1)
  useEffect(() => {
    if (sent < 0 || sent >= RECIPIENTS.length) return
    const t = setTimeout(() => setSent((n) => Math.min(RECIPIENTS.length, n + 3)), 120)
    return () => clearTimeout(t)
  }, [sent])
  const run = () => approve({
    kind: 'Batch send', title: `Send ${TOTAL.toLocaleString()} USDC to 48 wallets`, success: 'All 48 transfers sent',
    lines: [['Recipients', '48 (1 invalid removed)'], ['Total', `${TOTAL.toLocaleString()} USDC`], ['Network', 'Base'], ['Route', relay ? 'Private, via Relay' : 'Direct'], ['Fee', relay ? '$2.88' : '$0.48']],
    checks: baseChecks([{ label: 'No sanctioned addresses', status: 'pass' }, { label: 'No duplicate recipients', status: 'pass' }, { label: relay ? 'Sender not linked on-chain' : 'Sender visible on-chain', status: relay ? 'pass' : 'warn' }]),
    onSuccess: () => setSent(0),
  })
  const done = sent >= RECIPIENTS.length
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 8, fontWeight: 500 }}><FileSpreadsheet size={16} color="#15803D" /> wallets.xlsx</span>
        <span className="faint small">49 rows</span>
      </div>
      <div className="ccard-body" style={{ paddingTop: 6 }}>
        <div className="kv" style={{ marginBottom: 12 }}>
          <div><span>Recipients</span><b>48</b></div>
          <div><span>Total</span><b>{TOTAL.toLocaleString()} USDC</b></div>
          <div><span>Removed</span><b className="down">1 invalid</b></div>
        </div>
        <div className="ms-list">
          {RECIPIENTS.slice(0, 8).map((r, i) => (
            <div className="ms-row" key={i}>
              <span className="faint num" style={{ width: 22 }}>{i + 1}</span>
              <span className="mono grow">{r.addr}</span>
              <span className="num">{r.amt.toLocaleString()} USDC</span>
              <span className={`ms-st ${i < sent ? 'ok' : sent >= 0 ? 'wait' : ''}`}>{i < sent ? <Check size={12} /> : sent >= 0 ? <Loader2 size={12} className="spin" /> : null}</span>
            </div>
          ))}
          <div className="faint small" style={{ padding: '6px 0 0 30px' }}>+ 40 more</div>
        </div>
        {sent >= 0 && (
          <div style={{ marginTop: 12 }}>
            <div className="row between small"><span>{done ? 'All sent' : 'Sending…'}</span><span className="num">{Math.min(sent, 48)} / 48</span></div>
            <div className="bar-track" style={{ marginTop: 6 }}><div className="bar-fill" style={{ width: `${(Math.min(sent, 48) / 48) * 100}%`, background: 'var(--green)' }} /></div>
          </div>
        )}
        {sent < 0 && (
          <div className="row between" style={{ marginTop: 14, gap: 10 }}>
            <span className="row small" style={{ gap: 8 }}><ShieldCheck size={15} color="var(--accent)" /><span><b style={{ fontWeight: 500 }}>Private send via Relay</b><br /><span className="muted">Recipients can't trace it back to you</span></span></span>
            <button className={`toggle ${relay ? 'on' : ''}`} onClick={() => setRelay(!relay)} aria-label="Private send via Relay" />
          </div>
        )}
      </div>
      <div className="ccard-foot">
        {done ? <span className="small up row" style={{ gap: 6 }}><Check size={14} /> Done in 41s. Receipts saved to Files.</span>
          : <button className="btn brand" disabled={sent >= 0} onClick={run}><Fingerprint size={14} /> Send to 48 wallets</button>}
      </div>
    </div>
  )
}

/* ---------- 3. Launch a token on flap.sh in one tap ---------- */

const TOKEN = { name: 'Hermit Crab', ticker: 'HERMIT', supply: '1,000,000,000', desc: 'The crab that runs your money. Community token for Hermit builders.', buy: '0.5 BNB' }

function TokenArt({ size = 44 }) {
  return <span className="token-art" style={{ width: size, height: size }}><img src="/hermit-hero.png" alt="" /></span>
}

export function FlapLaunchCard() {
  const { approve, react } = useApp()
  const [linked, setLinked] = useState(false)
  const [linking, setLinking] = useState(false)
  const [open, setOpen] = useState(false)
  const [live, setLive] = useState(false)
  const connect = () => { setLinking(true); setTimeout(() => { setLinking(false); setLinked(true) }, 1100) }
  const deploy = () => {
    setOpen(false)
    approve({
      kind: 'Token launch on flap.sh', title: `Deploy $${TOKEN.ticker}`, success: `$${TOKEN.ticker} is live`,
      lines: [['Network', 'BNB Chain'], ['Supply', TOKEN.supply], ['Initial buy', TOKEN.buy], ['Launch fee', '0.01 BNB'], ['Curve', 'flap.sh bonding curve']],
      checks: baseChecks([{ label: 'Contract is flap.sh factory', status: 'pass' }, { label: 'No mint or freeze authority', status: 'pass' }]),
      onSuccess: () => setLive(true),
    })
  }
  return (
    <div className="ccard">
      <div className="ccard-head">
        <span className="row" style={{ gap: 10 }}><TokenArt size={34} /><span><div style={{ fontWeight: 500 }}>{TOKEN.name} <span className="muted" style={{ fontWeight: 400 }}>${TOKEN.ticker}</span></div><div className="small muted">{live ? 'Live on flap.sh' : 'Ready to launch'}</div></span></span>
        {live ? <span className="tag green"><span className="dot" />Live</span> : <Mark name="flap.sh" size={24} />}
      </div>
      <div className="ccard-body" style={{ paddingTop: 6 }}>
        {live ? (
          <>
            <div className="kv" style={{ marginBottom: 10 }}><div><span>Market cap</span><b>$18.4k</b></div><div><span>Holders</span><b>37</b></div><div><span>Curve</span><b>6%</b></div></div>
            <div className="tx-line"><span>Contract</span><span className="mono">0x9a4f…flap</span></div>
            <div className="tx-line"><span>Your buy</span><span>0.5 BNB, 28.1M HERMIT</span></div>
          </>
        ) : (
          <>
            {[['Name', TOKEN.name], ['Ticker', `$${TOKEN.ticker}`], ['Supply', TOKEN.supply], ['Initial buy', TOKEN.buy], ['Links', 'hermit.my, @hermit']].map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span>{v}</span></div>)}
            <p className="small muted" style={{ marginTop: 8 }}>{TOKEN.desc}</p>
          </>
        )}
      </div>
      <div className="ccard-foot">
        {live ? <>
          <button className="btn" onClick={() => setOpen(true)}><ExternalLink size={14} /> View on flap.sh</button>
          <button className="btn primary" onClick={() => react('Share on X', 'Draft posted to your X queue: "$HERMIT is live on @flapdotsh. The crab that runs your money." Say "post it" to publish.')}>Share on X</button>
        </> : !linked ? (
          <button className="btn brand" onClick={connect} disabled={linking}>{linking ? <><Loader2 size={14} className="spin" /> Connecting</> : <><Mark name="flap.sh" size={16} /> Connect flap.sh</>}</button>
        ) : (
          <button className="btn brand" onClick={() => setOpen(true)}><ExternalLink size={14} /> Open launch page</button>
        )}
      </div>
      {open && (
        <InAppTab url={live ? 'flap.sh/token/0x9a4f…flap' : 'flap.sh/create'} title="flap.sh" onClose={() => setOpen(false)}>
          <div className="row between" style={{ marginBottom: 14 }}>
            <span className="row" style={{ gap: 8, fontWeight: 600 }}><Mark name="flap.sh" size={24} /> flap.sh</span>
            <span className="tag green small"><span className="dot" />Connected as Main</span>
          </div>
          <div className="flap-preview">
            <TokenArt size={64} />
            <div style={{ minWidth: 0 }}><div style={{ fontWeight: 600, fontSize: 17 }}>{TOKEN.name}</div><div className="muted">${TOKEN.ticker}</div><div className="small muted" style={{ marginTop: 4 }}>{TOKEN.desc}</div></div>
          </div>
          <div className="tx" style={{ margin: '14px 0' }}>
            <div className="tx-line"><span>Supply</span><span>{TOKEN.supply}</span></div>
            <div className="tx-line"><span>Initial buy</span><span>{TOKEN.buy}</span></div>
            <div className="tx-line"><span>Graduates at</span><span>$69k market cap</span></div>
          </div>
          {live
            ? <p className="small up row" style={{ gap: 6, justifyContent: 'center' }}><Check size={14} /> Deployed. Trading is open.</p>
            : <button className="btn brand block" style={{ height: 44 }} onClick={deploy}><Fingerprint size={15} /> Deploy</button>}
          <p className="faint small" style={{ textAlign: 'center', marginTop: 10 }}>Details filled in by Hermit. Signed with your passkey.</p>
        </InAppTab>
      )}
    </div>
  )
}
