import { useEffect, useRef, useState } from 'react'
import { ArrowUp, X, Sparkles } from 'lucide-react'
import Logo from './Logo'
import { baseChecks } from './Approval'
import { HBars } from './Charts'
import { useApp } from '../App'

// Page-aware assistant available on every screen. Each suggestion can answer, act on the page
// (e.g. draw on the chart) or open an approval. Free text hands off to the full chat.
const PAGES = {
  trade: {
    label: 'Trade',
    qs: [
      { q: 'Mark support and resistance', a: 'Support at $22.40, resistance at $26.10. Both are now drawn on the HYPE chart.',
        act: (c) => c.setChartMarks([{ v: 22.4, label: 'Support 22.40', color: '#2563EB' }, { v: 26.1, label: 'Resistance 26.10', color: '#7C3AED' }]) },
      { q: 'Is my HYPE stop too tight?', chart: [{ label: 'Stop distance', value: 12.7, color: 'var(--red)' }, { label: 'Daily range', value: 9.1 }, { label: 'To swing low', value: 14.4 }], suffix: '%', a: 'Your $21.00 stop is 12.7% below the mark price, about 1.4× the daily range. It sits just above the last swing low at $20.60. A stop at $20.50 is less likely to get wicked out.' },
      { q: 'Move HYPE stop to breakeven', a: 'Ready. This moves your stop to your $22.41 entry, so the trade can no longer lose money.',
        approval: { kind: 'Update orders', title: 'HYPE stop → $22.41', success: 'Stop updated', lines: [['Stop-loss', '$21.00 → $22.41'], ['Take-profit', '$27.50']], checks: baseChecks() } },
    ],
  },
  earn: {
    label: 'Earn',
    qs: [
      { q: 'Which of these is safest?', chart: [{ label: 'Aave', sub: 'safety', value: 9.5 }, { label: 'Morpho', sub: 'safety', value: 9.1 }, { label: 'Ethena', sub: 'safety', value: 7.2 }, { label: 'Pendle', sub: 'safety', value: 7.0 }], suffix: '/10', a: 'Aave USDC and Morpho Steakhouse. Both have years of history, multiple audits, and instant withdrawals. Pendle pays more, but locks you in until Dec 26.' },
      { q: 'Put my idle $8,200 to work', a: 'I’d split it 60/40 between Morpho and Aave, for about 7.0% APY ($48 a month).',
        approval: { kind: '2 deposits', title: 'Deposit 8,200 USDC', success: 'Earning 7.0%', lines: [['Morpho', '4,920 USDC'], ['Aave', '3,280 USDC']], checks: baseChecks() } },
    ],
  },
  portfolio: {
    label: 'Wallets',
    qs: [
      { q: 'Where am I most exposed?', chart: [{ label: 'Hyperliquid', value: 26 }, { label: 'Pendle', value: 13 }, { label: 'Aave', value: 11 }, { label: 'Ethena', value: 7 }], suffix: '%', a: 'Hyperliquid holds 26% of your money, across perps and HLP. Your largest single risk is the HYPE long, which loses about $580 at its stop.' },
      { q: 'Top up Trading from Main', a: 'Moving 2,000 USDC from Main to Trading would bring margin used from 38% to 29%.',
        approval: { kind: 'Internal transfer', title: 'Move 2,000 USDC', success: 'Transfer complete', lines: [['From', 'Main'], ['To', 'Trading'], ['Amount', '2,000 USDC']], checks: baseChecks([{ label: 'Destination is your own wallet', status: 'pass' }]) } },
    ],
  },
  payments: {
    label: 'Payments',
    qs: [
      { q: 'Can I cut my subscriptions?', chart: [{ label: 'OpenAI API', value: 38 }, { label: 'Perplexity', value: 20 }, { label: 'Figma', value: 45 }, { label: 'Vercel', value: 20 }], prefix: '$', suffix: '', a: 'Perplexity overlaps with OpenAI search for your bot. Dropping it saves $20 a month. Figma and Vercel are used daily.' },
      { q: 'Pay alice.eth early', a: 'Ready. 1,200 USDC to alice.eth now instead of Nov 1.',
        approval: { kind: 'Payment', title: 'Pay alice.eth 1,200 USDC', success: 'Paid alice.eth', lines: [['For', 'Design milestone 2'], ['Amount', '1,200 USDC'], ['From', 'Main']], checks: baseChecks([{ label: 'Recipient matches saved contact', status: 'pass' }]) } },
      { q: 'What’s due this week?', chart: [{ label: 'Rent', value: 2400 }, { label: 'alice.eth', value: 1200 }, { label: 'Figma', value: 45 }, { label: 'Vercel', value: 20 }], prefix: '$', suffix: '', a: '$3,665 in total: Figma $45 tomorrow, Vercel $20 on Oct 30, alice.eth $1,200 on Nov 1, and rent $2,400 on Nov 3. Main has enough to cover all of it.' },
    ],
  },
  explore: {
    label: 'Explore',
    qs: [
      { q: 'Top DApps with money-making opportunities today?', chart: [{ label: 'Pendle PT-USDe', sub: 'fixed', value: 18.4 }, { label: 'Hyperliquid HLP', sub: 'vault', value: 14.7 }, { label: 'Kamino JLP loop', sub: 'leverage', value: 22.1, color: 'var(--amber)' }, { label: 'Morpho Steakhouse', sub: 'lending', value: 7.9 }], suffix: '%',
        a: 'Pendle has the best risk-adjusted yield today: 18.4% fixed until Dec 26. Hyperliquid HLP pays 14.7% but swings with trader PnL. Kamino JLP pays most at 22.1%, with liquidation risk. Monad testnet and Kaito are the best unpaid airdrop plays this week.' },
      { q: 'What launched this week worth a look?', a: 'Three worth your time: Lighter (zero-fee perps, points live), Kuru (Monad order-book DEX, early LP rewards) and Plasma (stablecoin chain, 9% USDT vault). Lighter is the only one with a token already priced in.' },
      { q: 'Connect the apps I need for airdrops', a: 'Galxe, Layer3 and Kaito cover 80% of open quests. I can connect all three with your Airdrop farm wallets.',
        approval: { kind: 'Connect apps', title: 'Connect Galxe, Layer3, Kaito', success: '3 apps connected', lines: [['Wallets', 'Airdrop farm (3)'], ['Permissions', 'Read and sign quests'], ['Spend', 'Gas only, $2 a day cap']], checks: baseChecks() } },
    ],
  },
  connectors: {
    label: 'Connectors',
    qs: [
      { q: 'Which connectors should I add?', a: 'Gmail is connected, so add Google Calendar for meeting prep and Notion for project notes. For trading, Telegram alerts are the fastest way to approve on the go.' },
      { q: 'What can each app access?', chart: [{ label: 'Gmail', sub: 'read, draft', value: 2 }, { label: 'X', sub: 'read, post on ask', value: 2 }, { label: 'Telegram', sub: 'alerts', value: 1 }, { label: 'GitHub', sub: 'repos', value: 1 }], suffix: ' scopes', a: 'Nothing can move money. Gmail can read and draft, X can read and post only when you ask, Telegram sends alerts, GitHub reads your repos.' },
    ],
  },
  calendar: {
    label: 'Calendar',
    qs: [
      { q: 'Plan my day around the market', a: 'CPI prints at 08:30, so I moved "Review arb bot PnL" to 11:00 and blocked 08:15 to 09:00 for trading. Standup stays at 14:30.', act: (c) => c.toast('Calendar updated') },
      { q: 'What is overdue?', a: 'Two things: "Send Pendle deck" (due yesterday, Stablecoin yield ladder) and "Rotate Telegram bot key" (due Oct 24). Want me to schedule them for this afternoon?' },
      { q: 'Find time for a 1-hour deep work block', a: 'Tomorrow 10:00 to 11:00 is free and before your first meeting. Booked as "Deep work: wallet onboarding".', act: (c) => c.addTodo({ t: 'Deep work: wallet onboarding', date: '2026-10-27', time: '10:00', dur: 60, status: 'todo' }) },
    ],
  },
  files: {
    label: 'Files',
    qs: [
      { q: 'Summarize this week’s notes', a: 'Three decisions: Privy is the default wallet, approvals stay on every money move, and the Telegram bot moves to paid Perplexity. Two open items: wallet switcher designs (Tom, Oct 29) and the Pendle deck (you).' },
      { q: 'Find my Figma invoice', a: 'Invoice #2291 from Figma, $45, due Oct 27. It matches your saved bill and is scheduled to pay from USDC.', act: (c) => c.openFile({ name: 'Invoice #2291 — Figma', type: 'Email', src: 'Gmail', when: 'Oct 24', size: 'PDF', kind: 'invoice' }) },
      { q: 'What did Pendle ask for?', a: 'Sam wants Hermit to route idle USDC into Pendle PT pools when they beat Aave by 2%. They sent pool caps and asked for a call Thursday.', act: (c) => c.openFile({ name: 'Re: Partnership with Pendle', type: 'Email', src: 'Gmail', when: 'Today', size: '3 messages' }) },
    ],
  },
  projects: {
    label: 'Projects',
    qs: [
      { q: 'Which project is making the most?', chart: [{ label: 'HYPE perp scripts', value: 1280 }, { label: 'Yield ladder', value: 412 }, { label: 'Airdrop farm', value: -38, color: 'var(--red)' }, { label: 'HYPE news bot', value: -140, color: 'var(--red)' }], prefix: '$', suffix: '', a: 'HYPE perp scripts: +$1,280 on $10,200. The news bot costs $140 a month and earns nothing directly, but it feeds two strategies.' },
      { q: 'Start a project for a Monad airdrop', a: 'Ready: "Monad airdrop" with 3 fresh wallets, $600 budget and daily testnet tasks.', act: (c) => c.addProject({ name: 'Monad airdrop', icon: 'Gift', desc: 'Farm Monad testnet with 3 wallets', status: 'Draft', pnl: '—', money: 600, cost: 0, gain: 0, gainLabel: 'Est. value', gainNote: 'Starts tomorrow', chats: [], fileList: [] }) },
    ],
  },
  automations: {
    label: 'Automations',
    qs: [
      { q: 'Suggest an automation for me', a: 'You check HYPE funding most mornings. I can alert you on Telegram when funding goes above 0.03%/h and open the hedge if you approve.' },
      { q: 'Which automations spent money this week?', chart: [{ label: 'DCA ETH', value: 200 }, { label: 'Gas refills', value: 14 }, { label: 'API top-ups', value: 20 }], prefix: '$', suffix: '', a: '$234 in total, all within your limits. DCA bought 0.057 ETH.' },
    ],
  },
  settings: {
    label: 'Settings',
    qs: [
      { q: 'Are my limits safe?', a: 'Yes. Hermit asks before anything over $100 and stops at $2,000 a day. For trading I’d keep it; for payments, raising the ask limit to $250 saves you about 6 approvals a week.' },
      { q: 'What do you remember about me?', a: 'Seven things in hermit.md: your risk limits, that you prefer stablecoins on Base, chart indicators you like, and your weekly report time. Edit them in Memory.', act: (c) => c.go('settings/memory') },
    ],
  },
  default: {
    label: 'This page',
    qs: [{ q: 'What can I do here?', a: 'Ask about anything on this screen. I can explain it, change it, or do it for you. Anything that moves money still needs your approval.' }],
  },
}

export default function AskPanel({ onClose, seed }) {
  const ctx = useApp()
  const page = PAGES[ctx.route] || PAGES.default
  const [msgs, setMsgs] = useState(seed ? [{ role: 'user', text: seed.q }, { role: 'ai', text: seed.a }] : [])
  const [input, setInput] = useState('')
  const end = useRef(null)
  useEffect(() => { end.current?.scrollIntoView({ behavior: 'smooth' }) }, [msgs])

  const run = (s) => {
    setMsgs((m) => [...m, { role: 'user', text: s.q }])
    setTimeout(() => {
      setMsgs((m) => [...m, { role: 'ai', text: s.a, approval: s.approval, chart: s.chart, suffix: s.suffix, prefix: s.prefix }])
      s.act?.(ctx)
    }, 500)
  }
  const send = () => {
    const text = input.trim()
    if (!text) return
    setInput('')
    const hit = page.qs.find((s) => s.q.toLowerCase().split(' ').filter((w) => w.length > 3).some((w) => text.toLowerCase().includes(w)))
    if (hit) return run({ ...hit, q: text })
    setMsgs((m) => [...m, { role: 'user', text }, { role: 'ai', text: 'I can take this further in a full chat.', handoff: text }])
  }

  return (
    <aside className="ask">
      <div className="ask-head">
        <div className="grow"><div className="row" style={{ gap: 8, fontWeight: 500 }}><Logo size={11} /> Ask Hermit</div><div className="faint small ellipsis">{page.label}</div></div>
        <button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
      </div>
      <div className="ask-body">
        {msgs.length === 0 && (
          <div className="stack" style={{ gap: 6 }}>
            {page.qs.map((s) => <button key={s.q} className="ask-q" onClick={() => run(s)}><Sparkles size={13} /> {s.q}</button>)}
          </div>
        )}
        {msgs.map((m, i) => m.role === 'user'
          ? <div key={i} className="msg-user" style={{ margin: '12px 0' }}><div className="bubble">{m.text}</div></div>
          : (
            <div key={i} className="fade-in" style={{ margin: '12px 0', lineHeight: 1.65 }}>
              {m.text}
              {m.chart && <div className="tx" style={{ marginTop: 10, padding: 14 }}><HBars data={m.chart} suffix={m.suffix} prefix={m.prefix} /></div>}
              {m.approval && <div style={{ marginTop: 10 }}><button className="btn primary sm" onClick={() => ctx.approve(m.approval)}>Review</button></div>}
              {m.handoff && <div style={{ marginTop: 10 }}><button className="btn sm" onClick={() => { onClose(); ctx.go('chat'); setTimeout(() => window.dispatchEvent(new CustomEvent('hermit:ask', { detail: m.handoff })), 50) }}>Open in chat</button></div>}
            </div>
          ))}
        <div ref={end} />
      </div>
      <div className="ask-foot">
        <div className="composer" style={{ padding: '8px 8px 8px 14px', borderRadius: 16 }}>
          <div className="row">
            <input className="grow" style={{ border: 0, outline: 0, background: 'transparent', fontSize: 14 }} placeholder="Ask about this page" value={input}
              onChange={(e) => setInput(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && send()} />
            <button className="send" disabled={!input.trim()} onClick={send} aria-label="Send"><ArrowUp size={16} /></button>
          </div>
        </div>
      </div>
    </aside>
  )
}
