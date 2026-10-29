import { useEffect, useState } from 'react'
import { ShieldCheck, ShieldAlert, CheckCircle2, AlertTriangle, XCircle, Loader2, Fingerprint, X } from 'lucide-react'

// Every action that moves funds opens this sheet: summary -> hazard scan -> passkey approval.
// spec: { kind, title, lines: [[label, value]], checks: [{label, detail, status}], note, success }
export default function Approval({ spec, onClose, onDone }) {
  const [done, setDone] = useState(0)
  const [stage, setStage] = useState('scan') // scan | ready | signing | sent
  const checks = spec.checks
  const fails = checks.filter((c) => c.status === 'fail').length
  const warns = checks.filter((c) => c.status === 'warn').length

  useEffect(() => {
    if (done < checks.length) {
      const t = setTimeout(() => setDone(done + 1), 280)
      return () => clearTimeout(t)
    }
    setStage('ready')
  }, [done, checks.length])

  const approve = () => {
    setStage('signing')
    setTimeout(() => { setStage('sent'); onDone?.() }, 1200)
  }

  if (stage === 'sent') {
    return (
      <div className="modal-backdrop" onClick={onClose}>
        <div className="modal" onClick={(e) => e.stopPropagation()}>
          <div className="modal-body" style={{ textAlign: 'center', padding: '36px 24px 24px' }}>
            <CheckCircle2 size={40} color="var(--green)" strokeWidth={1.5} />
            <h3 style={{ marginTop: 12, fontSize: 17 }}>{spec.success || 'Done'}</h3>
            <p className="muted small mono" style={{ marginTop: 6 }}>0x8f2c…a91d</p>
            <button className="btn primary block" style={{ marginTop: 24 }} onClick={onClose}>Close</button>
          </div>
        </div>
      </div>
    )
  }

  const level = fails ? 'red' : warns ? 'amber' : 'green'
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="muted small">{spec.kind}</div>
            <div style={{ fontSize: 17, fontWeight: 600, marginTop: 2, letterSpacing: '-.01em' }}>{spec.title}</div>
          </div>
          <button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
        </div>
        <div className="modal-body stack" style={{ gap: 16 }}>
          <div className="tx">
            {spec.lines.map(([k, v]) => <div className="tx-line" key={k}><span>{k}</span><span style={{ textAlign: 'right' }}>{v}</span></div>)}
          </div>
          <div>
            <div className="row between small" style={{ marginBottom: 4 }}>
              <span className="row" style={{ gap: 6, fontWeight: 500 }}><ShieldCheck size={14} /> Hazard scan</span>
              <span className="faint num">{done}/{checks.length}</span>
            </div>
            {checks.map((c, i) => (
              <div className="check-row" key={c.label} style={{ opacity: i < done ? 1 : 0.35 }}>
                <span className="ic">
                  {i >= done ? <Loader2 size={15} className={i === done ? 'spin' : ''} color="var(--faint)" />
                    : c.status === 'pass' ? <CheckCircle2 size={15} color="var(--green)" />
                      : c.status === 'warn' ? <AlertTriangle size={15} color="var(--amber)" />
                        : <XCircle size={15} color="var(--red)" />}
                </span>
                <div>
                  <div>{c.label}</div>
                  {i < done && c.status !== 'pass' && c.detail && <div className="muted small">{c.detail}</div>}
                </div>
              </div>
            ))}
          </div>
          {stage !== 'scan' && (fails || warns || spec.note) ? (
            <div className="notice fade-in" style={{ background: `var(--${level}-soft)` }}>
              <ShieldAlert size={15} color={`var(--${level})`} style={{ flexShrink: 0, marginTop: 2 }} />
              <span>{spec.note || (fails ? 'Blocked.' : 'Review the warning before approving.')}</span>
            </div>
          ) : null}
        </div>
        <div className="modal-foot">
          <button className="btn" style={{ flex: 1 }} onClick={onClose}>{fails ? 'Close' : 'Cancel'}</button>
          {!fails && (
            <button className="btn brand" style={{ flex: 2 }} disabled={stage !== 'ready'} onClick={approve}>
              {stage === 'signing' ? <><Loader2 size={15} className="spin" /> Signing</> : <><Fingerprint size={15} /> Approve</>}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

// Reusable check set so every scenario reads consistently.
export const baseChecks = (extra = []) => [
  { label: 'Requested by you, not by a web page or email', status: 'pass' },
  { label: 'Simulation matches summary', status: 'pass' },
  { label: 'Contract verified and audited', status: 'pass' },
  { label: 'Exact-amount token approval', status: 'pass' },
  ...extra,
  { label: 'Within daily limit', status: 'pass' },
]
