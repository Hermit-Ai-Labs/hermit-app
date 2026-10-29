import { useEffect, useState } from 'react'
import { X, ZoomIn, ZoomOut, Maximize2, Download, Sparkles, FileText, Mail, Mic, BookOpen, Table, Image, Code2, Receipt } from 'lucide-react'
import { CandleChart } from './Charts'
import { candles } from '../data'
import { useApp } from '../App'

// Full-area file reader, like Claude's file pane: open files sit in tabs, with zoom and a Notion-style page.
const KIND_ICON = { notes: Mic, email: Mail, doc: FileText, research: BookOpen, csv: Table, chart: Image, code: Code2, invoice: Receipt, paper: FileText }

export const fileKind = (f) => {
  const n = f.name.toLowerCase()
  if (f.kind) return f.kind
  if (/\.(png|jpg)$/.test(n)) return 'chart'
  if (n.endsWith('.csv')) return 'csv'
  if (n.includes('invoice')) return 'invoice'
  if (/\.(ts|js|json|prompt|py)$/.test(n)) return 'code'
  if (n.endsWith('.pdf')) return 'paper'
  return { 'Meeting notes': 'notes', Email: 'email', Research: 'research' }[f.type] || 'doc'
}

export default function FileViewer() {
  const { openFiles, activeFile, setActiveFile, closeFile, closeAllFiles, toast, go } = useApp()
  const [zoom, setZoom] = useState(1)
  const file = openFiles.find((f) => f.name === activeFile) || openFiles[0]
  const z = (d) => setZoom((v) => Math.min(2, Math.max(0.5, +(v + d).toFixed(2))))
  useEffect(() => {
    const on = (e) => {
      if (e.key === 'Escape') closeAllFiles()
      if ((e.metaKey || e.ctrlKey) && (e.key === '=' || e.key === '+')) { e.preventDefault(); z(0.1) }
      if ((e.metaKey || e.ctrlKey) && e.key === '-') { e.preventDefault(); z(-0.1) }
    }
    window.addEventListener('keydown', on)
    return () => window.removeEventListener('keydown', on)
  }, [])
  if (!file) return null
  const kind = fileKind(file)
  const ask = () => { closeAllFiles(); go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: { text: `What's in ${file.name}?`, attachment: { ...file, kind: ['notes', 'email', 'research'].includes(kind) ? 'doc' : kind } } })), 50) }
  return (
    <div className="viewer" role="dialog" aria-label={file.name}>
      <div className="viewer-bar">
        <div className="viewer-tabs">
          {openFiles.map((f) => {
            const Ic = KIND_ICON[fileKind(f)] || FileText
            return (
              <div key={f.name} className={`viewer-tab ${f.name === file.name ? 'on' : ''}`}>
                <button onClick={() => setActiveFile(f.name)}><Ic size={13} /><span>{f.name}</span></button>
                <button className="viewer-x" onClick={() => closeFile(f.name)} aria-label={`Close ${f.name}`}><X size={12} /></button>
              </div>
            )
          })}
        </div>
        <div className="viewer-tools">
          <button onClick={() => z(-0.1)} aria-label="Zoom out"><ZoomOut size={15} /></button>
          <button className="viewer-pct num" onClick={() => setZoom(1)} aria-label="Reset zoom">{Math.round(zoom * 100)}%</button>
          <button onClick={() => z(0.1)} aria-label="Zoom in"><ZoomIn size={15} /></button>
          <button className="hide-m" onClick={() => setZoom(zoom === 1 ? 1.3 : 1)} aria-label="Fit width"><Maximize2 size={14} /></button>
          <button onClick={() => toast(`${file.name} saved to Downloads`)} aria-label="Download"><Download size={15} /></button>
          <button className="viewer-ask" onClick={ask} aria-label="Ask about this file"><Sparkles size={14} /><span className="hide-m">Ask</span></button>
          <button onClick={closeAllFiles} aria-label="Close viewer"><X size={16} /></button>
        </div>
      </div>
      <div className="viewer-body">
        <article className="doc" style={{ zoom }}>
          <h1 className="doc-title">{file.name.replace(/\.(md|pdf|csv|png|jpg|ts|js|json)$/i, '')}</h1>
          <div className="doc-props">
            {[['Type', file.type || kind[0].toUpperCase() + kind.slice(1)], ['Source', file.src || 'Hermit'], ['Updated', file.when || 'Today'], ['Size', file.size || '—']].map(([k, v]) => (
              <div key={k}><span>{k}</span><span>{v}</span></div>
            ))}
          </div>
          <Body file={file} kind={kind} />
        </article>
      </div>
    </div>
  )
}

const Todo = ({ done, children }) => <div className={`doc-todo ${done ? 'done' : ''}`}><span className="doc-check">{done ? '✓' : ''}</span><span>{children}</span></div>
const Callout = ({ children }) => <div className="doc-callout"><Sparkles size={15} /><div>{children}</div></div>

function Body({ file, kind }) {
  if (kind === 'notes') return (
    <>
      <Callout>Summarized on your device from a {file.size || '4 min'} recording.</Callout>
      <h2>Attendees</h2><p>Ryan, Mei (eng), Tom (design), Hermit</p>
      <h2>Decisions</h2>
      <ul><li>Ship wallet onboarding with Privy as default, local keys as an option.</li><li>Approval sheet stays on every money move, no silent spends.</li><li>Move the Telegram bot to the paid Perplexity tier ($20 a month).</li></ul>
      <h2>Action items</h2>
      <Todo done>Mei: hazard scan for approvals</Todo><Todo>Tom: final wallet switcher designs by Oct 29</Todo><Todo>Ryan: send the Pendle deck</Todo><Todo>Hermit: weekly PnL report every Monday</Todo>
    </>
  )
  if (kind === 'email') return (
    <>
      {[['Sam at Pendle', 'Oct 26, 09:12', 'Hi Ryan, loved the demo. Could Hermit route idle USDC into PT pools when rates beat Aave by 2%? Happy to share a co-marketing slot.'],
        ['Ryan', 'Oct 26, 10:40', 'Yes, that maps to our yield ladder. We will need a max lockup of 90 days and an exit plan. Can you send pool caps?'],
        ['Sam at Pendle', 'Oct 26, 11:05', 'Caps attached. Dec-26 pools have $40M headroom. Call Thursday?']].map(([who, when, text]) => (
        <div className="doc-mail" key={when}><div className="row between"><b>{who}</b><span className="faint small">{when}</span></div><p>{text}</p></div>
      ))}
      <Callout>Suggested reply: confirm Thursday 3pm and ask for the audit report.</Callout>
    </>
  )
  if (kind === 'csv') {
    const rows = [['Date', 'Pair', 'Side', 'Size', 'Entry', 'Exit', 'PnL'], ['Sep 30', 'HYPE-PERP', 'Long', '$3,000', '21.40', '22.92', '+$212'], ['Sep 28', 'PENGU', 'Buy', '$500', '0.031', '0.027', '−$64'], ['Sep 27', 'ETH-PERP', 'Short', '$2,000', '3,612', '3,453', '+$88'], ['Sep 25', 'SOL', 'Buy', '$1,200', '171.2', '177.0', '+$41'], ['Sep 22', 'BTC-PERP', 'Long', '$4,000', '112,400', '111,900', '−$18'], ['Sep 19', 'HYPE', 'Buy', '$1,000', '19.80', '21.10', '+$66'], ['Sep 15', 'WIF', 'Buy', '$300', '0.92', '0.84', '−$26']]
    return (
      <div className="doc-table-wrap"><table className="doc-table"><thead><tr>{rows[0].map((c) => <th key={c}>{c}</th>)}</tr></thead>
        <tbody>{rows.slice(1).map((r) => <tr key={r[0] + r[1]}>{r.map((c, i) => <td key={i} className={i === 6 ? (c.startsWith('+') ? 'up' : 'down') : ''}>{c}</td>)}</tr>)}</tbody></table></div>
    )
  }
  if (kind === 'invoice') return (
    <div className="doc-invoice">
      <div className="row between"><div><b>Figma, Inc.</b><p className="muted small">760 Market St, San Francisco</p></div><div style={{ textAlign: 'right' }}><b>Invoice #2291</b><p className="muted small">Due Oct 27</p></div></div>
      <table className="doc-table"><thead><tr><th>Item</th><th>Qty</th><th>Amount</th></tr></thead><tbody><tr><td>Professional plan, monthly</td><td>1</td><td>$45.00</td></tr><tr><td>Tax</td><td></td><td>$0.00</td></tr></tbody></table>
      <div className="row between" style={{ marginTop: 12 }}><b>Total</b><b>$45.00</b></div>
      <Callout>Matches your saved Figma bill. Hermit will pay it in USDC via Bridge on Oct 27.</Callout>
    </div>
  )
  if (kind === 'code') {
    const code = file.name.endsWith('.json') ? '{\n  "schedule": "0 8 * * *",\n  "budget": 20,\n  "pay": "x402",\n  "notify": "telegram"\n}' : 'import { hermit, telegram, cron } from "@hermit/sdk"\n\nconst news = hermit.tool("perplexity")\n\ncron("0 8 * * *", async () => {\n  const digest = await news.search("HYPE news, last 24h")\n  if (!digest.items.length) return\n  await telegram.send(me, digest.summary)\n})'
    return <pre className="doc-code">{code.split('\n').map((l, i) => <div key={i}><span className="ln">{i + 1}</span>{l || ' '}</div>)}</pre>
  }
  if (kind === 'chart') return <><CandleChart data={candles(60, 0.026, 0.05, 11, 0.05)} height={320} /><p className="muted small">PENGU 4H, saved from Photos.</p></>
  if (kind === 'research') return (
    <>
      <Callout>Bull case holds while buybacks exceed unlocks. Re-check on Nov 29.</Callout>
      <h2>Thesis</h2><p>Hyperliquid captures most on-chain perp volume. Fees fund daily HYPE buybacks, so price tracks volume more than sentiment.</p>
      <CandleChart data={candles(48, 16, 0.04, 9, 0.06)} height={200} />
      <h2>Risks</h2><ul><li>Team unlocks start Nov 29.</li><li>Competition from Lighter and Aster on fees.</li><li>Validator set is still small.</li></ul>
      <h2>Plan</h2><Todo done>Long 3x from $22.41, stop $21</Todo><Todo>Take half off at $27.50</Todo>
    </>
  )
  return (
    <>
      <p>{file.name} covers {file.size || 'a few pages'}. Hermit pulled out the parts that matter.</p>
      <h2>Overview</h2><p>Hermit is a local AI assistant with native wallets. It trades, earns and pays for you, and asks before any money moves.</p>
      <h2>Goals</h2><ul><li>First trade within 3 minutes of install.</li><li>No seed phrase needed (Privy), local keys for power users.</li><li>Every action explained in one line.</li></ul>
      <h2>Open questions</h2><Todo>Daily limit default: $1,000 or $2,000?</Todo><Todo>Which perp venues at launch?</Todo>
    </>
  )
}
