import { useEffect, useRef, useState } from 'react'
import { Loader2, ArrowLeft, Mail } from 'lucide-react'
import Logo from './Logo'
import { isApp } from '../native'
import { CLOUDS, STROKES, GRAIN } from './Stage'

// Demo sign-in. Nothing is sent anywhere: every path just opens the app.
const Google = () => (
  <svg width="17" height="17" viewBox="0 0 48 48" aria-hidden="true">
    <path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z" />
    <path fill="#FF3D00" d="m6.3 14.7 6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
    <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z" />
    <path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z" />
  </svg>
)
const Apple = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    <path d="M16.37 12.7c-.02-2.3 1.88-3.4 1.96-3.46-1.07-1.56-2.73-1.78-3.32-1.8-1.41-.14-2.76.83-3.48.83-.72 0-1.83-.81-3-.79-1.55.02-2.97.9-3.77 2.28-1.6 2.79-.41 6.92 1.15 9.18.76 1.11 1.67 2.35 2.86 2.31 1.15-.05 1.58-.74 2.97-.74 1.38 0 1.77.74 2.98.72 1.23-.02 2.01-1.13 2.77-2.24.87-1.28 1.23-2.52 1.25-2.59-.03-.01-2.4-.92-2.42-3.66zM14.1 5.94c.63-.77 1.06-1.83.94-2.89-.91.04-2.01.61-2.67 1.37-.58.67-1.09 1.75-.96 2.79 1.02.08 2.05-.52 2.69-1.27z" />
  </svg>
)

export default function Login({ onDone }) {
  const [step, setStep] = useState('start') // start | code | busy
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [via, setVia] = useState('')
  const [note, setNote] = useState(false)
  // Hero film for the art panel; falls back to the still illustration if it cannot play.
  const [film, setFilm] = useState(true)
  const codeRef = useRef(null)
  const go = (how) => { setVia(how); setStep('busy'); setTimeout(onDone, 1100) }
  useEffect(() => { if (step === 'code') codeRef.current?.focus() }, [step])
  useEffect(() => { if (code.length === 6) go('email') }, [code])
  const valid = /\S+@\S+\.\S+/.test(email)

  return (
    <div className="login">
      <div className="login-left">
        <div className="login-logo"><Logo size={20} /></div>
        <div className="login-main">
          <h1 className="login-title">Your almighty intern</h1>
          <p className="login-sub">Pay, earn and build in one place. Fully private.</p>

          <div className="login-card">
            {step === 'start' && (
              <>
                <button className="login-btn" onClick={() => go('Google')}><Google /> Continue with Google</button>
                <button className="login-btn" onClick={() => go('Apple')}><Apple /> Continue with Apple</button>
                <div className="login-or">OR</div>
                <form onSubmit={(e) => { e.preventDefault(); if (valid) setStep('code') }} className="stack" style={{ gap: 12 }}>
                  <input className="login-input" type="email" placeholder="Enter your email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="off" />
                  <button className="login-btn dark" disabled={!valid}>Continue with email</button>
                </form>
                <p className="login-fine">Keys stay on your device. Hermit never holds your funds.</p>
              </>
            )}
            {step === 'code' && (
              <>
                <button className="login-back" onClick={() => { setStep('start'); setCode('') }}><ArrowLeft size={14} /> Back</button>
                <span className="login-mail"><Mail size={18} /></span>
                <div style={{ fontWeight: 600, fontSize: 17, textAlign: 'center' }}>Check your email</div>
                <p className="login-fine" style={{ marginTop: -4 }}>We sent a code to <b>{email}</b></p>
                <label className="code-boxes" onClick={() => codeRef.current?.focus()}>
                  {Array.from({ length: 6 }, (_, i) => <span key={i} className={i === code.length ? 'on' : ''}>{code[i] || ''}</span>)}
                  <input ref={codeRef} inputMode="numeric" maxLength={6} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} aria-label="Sign-in code" />
                </label>
                <button className="login-link" onClick={() => setCode('482913')}>Use demo code</button>
              </>
            )}
            {step === 'busy' && (
              <div className="login-busy"><Loader2 size={20} className="spin" /><span>Signing in{via === 'email' ? '' : ` with ${via}`}…</span></div>
            )}
          </div>

          {!isApp && <button className="login-download" onClick={() => setNote(true)}><Apple /> {note ? 'Mac app ships with the beta' : 'Download desktop app'}</button>}
        </div>
      </div>

      <div className="login-art" aria-hidden="true">
        <div className="login-paint" style={{ backgroundImage: `${CLOUDS}, ${STROKES}` }} />
        <div className="login-grain" style={{ backgroundImage: GRAIN }} />
        {film ? (
          <video className="login-film" src="/login-film.mp4" poster="/login-film.jpg" autoPlay muted loop playsInline onError={() => setFilm(false)} />
        ) : <img src="/hermit-hero.png" alt="" />}
      </div>
    </div>
  )
}
