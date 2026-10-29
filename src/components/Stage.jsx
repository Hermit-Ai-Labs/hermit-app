import { useEffect, useRef, useState } from 'react'
import { Monitor, Smartphone, Puzzle, Lock, RotateCw, ArrowLeft, ArrowRight, Star, X, PanelRight } from 'lucide-react'
import Logo from './Logo'

// Demo stage: painted-purple backdrop with the app inside a desktop window or a phone frame.
// The app itself runs in an iframe (?embed=1) so its own layout and modals behave like the real thing.

const noise = (freq, octaves, matrix, seed, rotate = 0) => `url("data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns='http://www.w3.org/2000/svg' width='1200' height='800'><filter id='n' x='0' y='0' width='100%' height='100%'><feTurbulence type='fractalNoise' baseFrequency='${freq}' numOctaves='${octaves}' seed='${seed}'/><feColorMatrix values='${matrix}'/></filter><rect x='-400' y='-400' width='2000' height='1600' filter='url(#n)' transform='rotate(${rotate} 600 400)'/></svg>`,
)}")`
// Soft white clouds, faint diagonal brush strokes, and canvas grain.
export const CLOUDS = noise('0.0022 0.0034', 6, '0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 3.2 -1.45', 11)
export const STROKES = noise('0.014 0.07', 3, '0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 0.75 -0.34', 4, -28)
export const GRAIN = noise('0.9', 2, '0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.4 0.8', 2)

const readMode = () => { try { return localStorage.getItem('hermit-stage') || 'pc' } catch { return 'pc' } }

export default function Stage() {
  const [mode, setMode] = useState(readMode)
  const [win, setWin] = useState('normal') // normal | full | hidden
  const src = `/?embed=1${window.location.hash || '#/chat'}`
  useEffect(() => { try { localStorage.setItem('hermit-stage', mode) } catch { /* private mode */ } }, [mode])

  return (
    <div className="stage">
      <div className="stage-paint" style={{ backgroundImage: `${CLOUDS}, ${STROKES}` }} />
      <div className="stage-grain" style={{ backgroundImage: GRAIN }} />

      <div className="stage-modes" role="tablist" aria-label="Demo view">
        {[['pc', Monitor, 'PC app'], ['mobile', Smartphone, 'Mobile app'], ['ext', Puzzle, 'Chrome extension']].map(([k, Icon, l]) => (
          <button key={k} className={mode === k ? 'on' : ''} onClick={() => { setMode(k); setWin('normal') }} aria-label={l} title={l}><Icon size={16} /></button>
        ))}
      </div>

      {mode === 'pc' ? (
        <>
          <div className={`window ${win}`}>
            <div className="window-bar" onDoubleClick={() => setWin(win === 'full' ? 'normal' : 'full')}>
              <div className="lights">
                <button className="light close" onClick={() => setWin('hidden')} aria-label="Close" />
                <button className="light min" onClick={() => setWin('hidden')} aria-label="Minimise" />
                <button className="light max" onClick={() => setWin(win === 'full' ? 'normal' : 'full')} aria-label="Full screen" />
              </div>
              <span className="window-title"><Logo size={10} /> Hermit</span>
            </div>
            <DesktopFrame src={src} />
          </div>
          {win === 'hidden' && (
            <button className="dock-icon" onClick={() => setWin('normal')} aria-label="Open Hermit"><Logo size={22} color="#fff" /></button>
          )}
        </>
      ) : mode === 'ext' ? <BrowserDemo /> : (
        <div className="phone"><iframe title="Hermit mobile app" src={src} /></div>
      )}
    </div>
  )
}

// Keeps the desktop layout inside small windows: render at least 1100px wide, then scale to fit.
const MIN_W = 1100
function DesktopFrame({ src }) {
  const box = useRef(null)
  const [size, setSize] = useState({ w: 0, h: 0 })
  useEffect(() => {
    const ro = new ResizeObserver(([e]) => setSize({ w: e.contentRect.width, h: e.contentRect.height }))
    ro.observe(box.current)
    return () => ro.disconnect()
  }, [])
  const scale = size.w && size.w < MIN_W ? size.w / MIN_W : 1
  return (
    <div ref={box} className="window-body">
      <iframe title="Hermit desktop app" src={src}
        style={scale < 1 ? { width: MIN_W, height: size.h / scale, transform: `scale(${scale})`, transformOrigin: '0 0' } : undefined} />
    </div>
  )
}

// Chrome extension demo: a news page in a browser, with Hermit in the side panel (mobile layout).
function BrowserDemo() {
  const [open, setOpen] = useState(true)
  return (
    <div className="browser">
      <div className="browser-top">
        <div className="lights"><span className="light close" /><span className="light min" /><span className="light max" /></div>
        <div className="browser-tab"><span className="site-fav">D</span><span className="ellipsis">SEC approves staking for spot ETH ETFs</span><X size={12} /></div>
      </div>
      <div className="browser-bar">
        <ArrowLeft size={15} /><ArrowRight size={15} color="#B8B8B6" /><RotateCw size={14} />
        <div className="browser-url"><Lock size={11} /> thedailyblock.news/markets/eth-etf-staking<Star size={13} style={{ marginLeft: 'auto' }} /></div>
        <Puzzle size={15} />
        <button className={`ext-btn ${open ? 'on' : ''}`} onClick={() => setOpen(!open)} aria-label="Hermit extension"><Logo size={9} /></button>
      </div>
      <div className="browser-body">
        <article className="news-page">
          <div className="news-brand">The Daily Block</div>
          <div className="news-kicker">Markets</div>
          <h1>SEC approves staking for spot ETH ETFs</h1>
          <div className="news-meta">2 hours ago, 4 min read</div>
          <div className="news-hero"><img src="/logos/eth.svg" alt="" /></div>
          <p>US spot Ether ETFs can now stake the ETH they hold and pass the rewards to shareholders, the SEC said on Monday, ending a two-year debate.</p>
          <p>Analysts expect about 3% yearly staking income to flow to holders. ETH rose 2.4% within an hour of the filing, and open interest on major venues jumped 9%.</p>
          <p>The last comparable approval was followed by an 11% rally over the next week.</p>
        </article>
        {open && (
          <aside className="side-panel">
            <div className="side-panel-head"><span className="row" style={{ gap: 6 }}><Logo size={9} /> Hermit</span><span className="row" style={{ gap: 6 }}><PanelRight size={14} /><button onClick={() => setOpen(false)} aria-label="Close side panel"><X size={14} /></button></span></div>
            <iframe title="Hermit extension" src="/?embed=1&ext=1#/chat" />
          </aside>
        )}
      </div>
    </div>
  )
}
