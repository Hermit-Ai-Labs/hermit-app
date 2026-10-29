import { useState } from 'react'
import { ArrowLeftRight, ArrowDownToLine, ArrowUpFromLine, Waypoints, Plus, X, Copy, Fuel, ChevronRight, ChevronDown, Check, KeyRound, Mail, Wallet as WalletIcon, History, ShieldCheck, ScanLine } from 'lucide-react'
import { Sheet, AddWalletSheet, TokenSheet, ActivitySheet } from '../components/Sheets'
import { Donut, AreaChart } from '../components/Charts'
import Mark from '../components/Mark'
import { baseChecks } from '../components/Approval'
import { aumByAsset, aumByProject, allocation, totalAUM, wallets, holdings, dappExposure, spending, fmt, walk, gas, chains, rng, projectColors } from '../data'
import { useApp } from '../App'
import Tabs, { usePageTab } from '../components/Tabs'
import ConnectSheet from '../components/ConnectSheet'

const RANGES = { '1W': 7, '1M': 30, '3M': 90, '1Y': 365 }
const ALL_TABS = [['tokens', 'Tokens'], ['dapps', 'DApps'], ['gas', 'Gas'], ['activity', 'Activity'], ['accounts', 'Accounts']]

// What each wallet funds: projects, trades, scheduled payments and DeFi positions.
const LINKS = {
  main: {
    projects: [['Stablecoin yield ladder', 16300], ['Dev: HYPE news bot', 20], ['Presale tracker', 1250]],
    trades: [['SOL', 'SOL spot', 178]],
    payments: [['Figma', 'Pro plan', 45, 'Tomorrow'], ['Vercel', 'Pro team', 20, 'Oct 30'], ['alice.eth', 'Design milestone 2', 1200, 'Nov 1'], ['Landlord', 'November rent', 2400, 'Nov 3']],
    defi: [['Aave', 'USDC supply', 5100, 5.6], ['Morpho', 'USDC vault', 4000, 7.9]],
  },
  trading: {
    projects: [['HYPE perp scripts', 10200], ['Meme auto-trader', 300]],
    trades: [['HYPE', 'HYPE-PERP long 3x', 530], ['ETH', 'ETH-PERP short 1x', 32]],
    payments: [['Hyperliquid', 'Margin top-up if needed', 500, 'Conditional']],
    defi: [['Hyperliquid', 'HLP vault', 1500, 14.7]],
  },
  vault: { projects: [], trades: [], payments: [], defi: [['Pendle', 'PT-USDe Dec-26', 6200, 18.4], ['Lido', 'stETH', 950, 3.1]] },
  sol: { projects: [['Meme auto-trader', 300]], trades: [['PENGU', 'PENGU spot', 0], ['SOL', 'SOL spot', 178]], payments: [], defi: [['Jupiter Lend', 'USDC lending', 2000, 6.8]] },
  farm: { projects: [['Airdrop farming S3', 2950]], trades: [], payments: [['Gas.zip', 'Gas refills', 2, 'Daily']], defi: [] },
}

const GROUPS = [
  { type: 'local', t: 'Local wallets', d: 'Keys stay on this device' },
  { type: 'privy', t: 'Privy wallets', d: 'Keyless, sign in with email or passkey' },
]

export default function Portfolio() {
  const [list, setList] = useState(wallets)
  const [sel, setSel] = useState('all')
  const [adding, setAdding] = useState(null)
  const w = list.find((x) => x.id === sel)
  return (
    <div className="page">
      <div className="page-head tabbed" style={{ marginBottom: 16 }}>
        <WalletPicker list={list} sel={sel} onPick={setSel} onAdd={setAdding} />
      </div>
      {w ? <WalletView key={w.id} w={w} /> : <AllWallets />}
      {adding && <AddWalletSheet type={adding} onAdd={(nw) => { setList((l) => [...l, nw]); setSel(nw.id) }} onClose={() => setAdding(null)} />}
    </div>
  )
}

// Binance-style wallet switcher: one menu, local and keyless wallets in separate groups.
function WalletPicker({ list, sel, onPick, onAdd }) {
  const [open, setOpen] = useState(false)
  const cur = list.find((x) => x.id === sel)
  const pick = (id) => { onPick(id); setOpen(false) }
  return (
    <div style={{ position: 'relative' }}>
      <button className="wallet-pick" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span className="wallet-ico">{cur ? (cur.type === 'privy' ? <Mail size={14} /> : <KeyRound size={14} />) : <WalletIcon size={14} />}</span>
        <span>{cur ? cur.name : 'All wallets'}</span>
        <ChevronDown size={16} />
      </button>
      {open && (
        <>
          <div className="menu-backdrop" onClick={() => setOpen(false)} />
          <div className="wallet-menu">
            <button className={`wallet-item ${sel === 'all' ? 'on' : ''}`} onClick={() => pick('all')}>
              <span className="wallet-ico"><WalletIcon size={14} /></span>
              <span className="grow"><b>All wallets</b><small>{list.length} wallets</small></span>
              <span className="num">{fmt.usd(list.reduce((a, x) => a + x.usd, 0))}</span>
              {sel === 'all' && <Check size={14} />}
            </button>
            {GROUPS.map((g) => (
              <div key={g.type} className="wallet-group">
                <div className="wallet-group-head"><span>{g.t}</span><small>{g.d}</small></div>
                {list.filter((x) => x.type === g.type).map((x) => (
                  <button key={x.id} className={`wallet-item ${sel === x.id ? 'on' : ''}`} onClick={() => pick(x.id)}>
                    <span className="wallet-ico">{g.type === 'privy' ? <Mail size={14} /> : <KeyRound size={14} />}</span>
                    <span className="grow"><b>{x.name}</b><small className="mono">{x.addr}</small></span>
                    <span className="num">{fmt.usd(x.usd)}</span>
                    {sel === x.id && <Check size={14} />}
                  </button>
                ))}
                <button className="wallet-item add" onClick={() => { setOpen(false); onAdd(g.type) }}>
                  <span className="wallet-ico"><Plus size={14} /></span>
                  <span className="grow">{g.type === 'local' ? 'Create or import local wallet' : 'Create Privy wallet'}</span>
                </button>
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  )
}

// Shared header: balance + exchange-style actions, scoped to one wallet or all of them.
function Header({ label, usd, sub, from, aside }) {
  const [transfer, setTransfer] = useState(null)
  const [sheet, setSheet] = useState(null)
  return (
    <>
      <div className="wallet-head">
      <div className="wallet-head-main">
      <div style={{ marginBottom: 18 }}>
        <div>
          <div className="row between bal-top">
            <div className="stat-label" style={{ margin: 0 }}>{label}</div>
            <button className="icon-btn history-btn" onClick={() => setSheet('history')} aria-label="Transaction history" title="Transaction history"><History size={17} /></button>
          </div>
          <div className="big">{fmt.usd(usd)}</div>
          {sub && <div className="small muted num">{sub}</div>}
        </div>
      </div>
      <div className="quick">
        {[
          [from ? 'Add funds' : 'Deposit', ArrowDownToLine, () => setSheet('deposit')],
          ['Send', ArrowUpFromLine, () => setTransfer({ external: true, from })],
          ['Transfer', ArrowLeftRight, () => setTransfer({ from })],
          ['Bridge', Waypoints, () => setSheet('bridge')],
        ].map(([l, Icon, on]) => <button key={l} onClick={on}><span><Icon size={19} strokeWidth={1.9} /></span>{l}</button>)}
      </div>
      </div>
      {aside && <div className="wallet-head-aside hide-m">{aside}</div>}
      </div>
      {transfer && <TransferSheet init={transfer} onClose={() => setTransfer(null)} />}
      {sheet === 'deposit' && <DepositSheet onClose={() => setSheet(null)} />}
      {sheet === 'bridge' && <BridgeSheet onClose={() => setSheet(null)} />}
      {sheet === 'history' && <HistorySheet onClose={() => setSheet(null)} />}
    </>
  )
}

function WalletView({ w }) {
  const { go, openProject, toast } = useApp()
  const l = LINKS[w.id] || { projects: [], trades: [], payments: [], defi: [] }
  const Empty = ({ children }) => <p className="muted small" style={{ padding: '6px 0' }}>{children}</p>
  const [tab, setTab] = useState('projects')
  const T = [['projects', 'Projects', l.projects.length || null], ['trading', 'Trading', l.trades.length || null], ['payments', 'Payments', l.payments.length || null], ['defi', 'DeFi', l.defi.length || null]]
  return (
    <>
      <Header label={w.kind} usd={w.usd} sub={<button className="mono small muted row" style={{ gap: 4 }} onClick={() => toast('Address copied')}>{w.addr} <Copy size={11} /></button>} from={w.id} />
      <Tabs tabs={T} value={tab} onChange={setTab} />

      {tab === 'projects' && <div>
        {l.projects.length ? l.projects.map(([name, usd]) => (
          <button className="list-row" key={name} onClick={() => openProject(name)}>
            <span className="swatch" style={{ background: projectColors[name] || '#8A8A8A', borderRadius: 99, width: 10, height: 10 }} />
            <div className="grow"><div className="list-title">{name}</div></div>
            <div className="list-end">{fmt.usd(usd)}</div><ChevronRight size={15} color="var(--faint)" />
          </button>
        )) : <Empty>No projects use this wallet.</Empty>}
      </div>}

      {tab === 'trading' && <div>
        {l.trades.length ? l.trades.map(([sym, label, pnl]) => (
          <button className="list-row" key={label} onClick={() => go('trade')}>
            <Mark name={sym} size={30} />
            <div className="grow"><div className="list-title">{label}</div></div>
            <div className={`list-end ${pnl >= 0 ? 'up' : 'down'}`}>{pnl >= 0 ? '+' : '−'}${Math.abs(pnl)}</div><ChevronRight size={15} color="var(--faint)" />
          </button>
        )) : <Empty>No open trades.</Empty>}
      </div>}

      {tab === 'payments' && <div>
        {l.payments.length ? l.payments.map(([to, what, amt, when]) => (
          <button className="list-row" key={to + what} onClick={() => go('payments')}>
            <Mark name={to} size={30} />
            <div className="grow"><div className="list-title">{to}</div><div className="list-sub">{what}</div></div>
            <div className="list-end"><div>{fmt.usd(amt)}</div><div className="faint small">{when}</div></div><ChevronRight size={15} color="var(--faint)" />
          </button>
        )) : <Empty>No payments from this wallet.</Empty>}
      </div>}

      {tab === 'defi' && <div>
        {l.defi.length ? l.defi.map(([proto, name, usd, apy]) => (
          <button className="list-row" key={proto + name} onClick={() => go('earn')}>
            <Mark name={proto} size={30} />
            <div className="grow"><div className="list-title">{proto} {name}</div></div>
            <div className="list-end"><div>{fmt.usd(usd)}</div><div className="up small">{apy}%</div></div><ChevronRight size={15} color="var(--faint)" />
          </button>
        )) : <Empty>No DeFi positions.</Empty>}
      </div>}
    </>
  )
}

function AllWallets() {
  const { go } = useApp()
  const [range, setRange] = useState('1M')
  const [token, setToken] = useState(null)
  const [act, setAct] = useState(null)
  const [tx, setTx] = useState(null)
  const series = walk(RANGES[range], totalAUM * 0.86, 0.03, 5 + RANGES[range], 0.05).map((v, i, a) => v * (totalAUM / a[a.length - 1]))
  const tokenAction = (a, t) => (a === 'send' ? setAct({ external: true }) : a === 'bridge' ? setAct('bridge') : go(a === 'swap' ? 'trade' : 'earn'))
  const [tab, setTab] = usePageTab(ALL_TABS)
  return (
    <>
      <Header label="Total balance" usd={totalAUM} sub={<span className="up">+$3,842 in {range}</span>} aside={<AumCard />} />
      <div className="wallet-chart">
      <div className="hide-d" style={{ marginBottom: 24 }}><AumCard /></div>
      <AreaChart data={series} id="nw" height={90} />
      <div className="row" style={{ justifyContent: 'flex-end', marginTop: 8 }}>
        <div className="seg">{Object.keys(RANGES).map((r) => <button key={r} className={r === range ? 'on' : ''} onClick={() => setRange(r)}>{r}</button>)}</div>
      </div>
      </div>
      <Tabs tabs={ALL_TABS} value={tab} onChange={setTab} />


      {tab === 'gas' && <Gas onBridge={() => setAct('bridge')} />}
      {tab === 'accounts' && <Accounts />}

      {tab === 'tokens' && <div>
          {holdings.filter((h) => h.usd).map((h) => (
            <button className="list-row" key={h.sym} style={{ padding: '9px 0' }} onClick={() => setToken(h)}>
              <Mark name={h.sym} size={28} />
              <div className="grow"><div className="list-title">{h.sym}</div><div className="list-sub">{h.amt.toLocaleString()}</div></div>
              <div className="list-end"><div>{fmt.usd(h.usd)}</div><div className={`small ${h.ch >= 0 ? 'up' : 'down'}`}>{fmt.pct(h.ch)}</div></div>
            </button>
          ))}
      </div>}

      {tab === 'dapps' && <div>
        {dappExposure.filter((d) => d.name !== 'Wallet').map((d) => (
          <button className="list-row" key={d.name} onClick={() => go(/Perps|Spot/.test(d.type) ? 'trade' : 'earn')}>
            <Mark name={d.name} size={28} />
            <div className="grow"><div className="list-title">{d.name}</div><div className="list-sub">{d.type}</div></div>
            <div className="list-end"><div>{fmt.usd(d.usd)}</div><div className={`small ${d.pnl >= 0 ? 'up' : 'down'}`}>{d.pnl >= 0 ? '+' : '−'}{fmt.usd(Math.abs(d.pnl))}</div></div>
            <ChevronRight size={15} color="var(--faint)" />
          </button>
        ))}
      </div>}

      {tab === 'activity' && <div>
        {spending.map((s) => (
          <button className="list-row" key={s.what + s.when} onClick={() => setTx(s)}>
            <div className="grow"><div className="list-title" style={{ fontWeight: 400 }}>{s.what}</div><div className="list-sub">{s.when}</div></div>
            <div className={`list-end ${s.amt > 0 ? 'up' : ''}`}>{s.amt > 0 ? '+' : '−'}${Math.abs(s.amt).toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
          </button>
        ))}
      </div>}
      {tx && <ActivitySheet item={tx} onClose={() => setTx(null)} />}
      {token && <TokenSheet token={token} onClose={() => setToken(null)} onAction={tokenAction} />}
      {act && act !== 'bridge' && <TransferSheet init={act} onClose={() => setAct(null)} />}
      {act === 'bridge' && <BridgeSheet onClose={() => setAct(null)} />}
    </>
  )
}

const ACCOUNTS = [
  { id: 'X', handle: '@ryanchi', on: '2,140 followers', off: 'Quests and posts' },
  { id: 'Discord', handle: 'ryanchi', on: '14 servers', off: 'Airdrop roles' },
  { id: 'Telegram', handle: '@ryanchi', on: 'Alerts on', off: 'Alerts and alpha groups' },
]

function Accounts() {
  const { toast } = useApp()
  const [linked, setLinked] = useState({ X: true })
  const [connecting, setConnecting] = useState(null)
  return (
    <div>
      {ACCOUNTS.map((a) => (
        <div className="list-row" key={a.id}>
          <Mark name={a.id} size={34} />
          <div className="grow"><div className="list-title">{linked[a.id] ? a.handle : a.id}</div><div className="list-sub">{linked[a.id] ? a.on : a.off}</div></div>
          {linked[a.id]
            ? <button className="btn sm" onClick={() => { setLinked({ ...linked, [a.id]: false }); toast(`${a.id} disconnected`) }}>Disconnect</button>
            : <button className="btn sm primary" onClick={() => setConnecting(a.id)}>Connect</button>}
        </div>
      ))}
      {connecting && <ConnectSheet app={connecting} onDone={() => setLinked((l) => ({ ...l, [connecting]: true }))} onClose={() => setConnecting(null)} />}
    </div>
  )
}

export function TransferSheet({ init, onClose }) {
  if (init.external) return <SendSheet from={init.from} onClose={onClose} />
  return <InternalTransfer init={init} onClose={onClose} />
}

function InternalTransfer({ init, onClose }) {
  const { approve } = useApp()
  const [from, setFrom] = useState(init.from || 'main')
  const [to, setTo] = useState(init.external ? 'external' : wallets.find((w) => w.id !== (init.from || 'main')).id)
  const [asset, setAsset] = useState('USDC')
  const [amt, setAmt] = useState(500)
  const src = wallets.find((w) => w.id === from)
  const dst = wallets.find((w) => w.id === to)
  const review = () => {
    onClose()
    approve({
      kind: dst ? 'Internal transfer' : 'Send', title: `Move ${amt.toLocaleString()} ${asset}`, success: 'Transfer complete',
      lines: [['From', src.name], ['To', dst ? dst.name : '0x2b9…e04 (alice.eth)'], ['Amount', `${amt.toLocaleString()} ${asset}`], ['Route', dst?.id === 'sol' ? 'Bridge, 30s' : 'Direct'], ['Fee', '$0.02']],
      checks: baseChecks(dst ? [{ label: 'Destination is your own wallet', status: 'pass' }] : [{ label: 'Address matches saved contact', status: 'pass' }]),
    })
  }
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head"><div style={{ fontSize: 17, fontWeight: 600 }}>{init.external ? 'Send' : 'Transfer'}</div><button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button></div>
        <div className="modal-body stack" style={{ gap: 14 }}>
          <label className="field">From
            <select value={from} onChange={(e) => setFrom(e.target.value)}>{wallets.map((w) => <option key={w.id} value={w.id}>{w.name} ({fmt.usd(w.usd)})</option>)}</select>
          </label>
          <label className="field">To
            <select value={to} onChange={(e) => setTo(e.target.value)}>
              {wallets.filter((w) => w.id !== from).map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
              <option value="external">External address</option>
            </select>
          </label>
          <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <label className="field">Amount<input type="number" value={amt} min="0" onChange={(e) => setAmt(+e.target.value)} /></label>
            <label className="field">Asset<select value={asset} onChange={(e) => setAsset(e.target.value)}>{['USDC', 'ETH', 'SOL', 'HYPE'].map((a) => <option key={a}>{a}</option>)}</select></label>
          </div>
          <div className="chips">{[100, 500, 1000].map((v) => <button key={v} className="chip" onClick={() => setAmt(v)}>{v}</button>)}<button className="chip" onClick={() => setAmt(src.usd)}>Max</button></div>
        </div>
        <div className="modal-foot"><button className="btn primary block" disabled={!amt} onClick={review}>Review</button></div>
      </div>
    </div>
  )
}

const GAS_PX = { ETH: 3498, SOL: 186.6, HYPE: 24.06, POL: 0.25 }

function Gas({ onBridge }) {
  const [auto, setAuto] = useState(true)
  const [list, setList] = useState(gas)
  const [topping, setTopping] = useState(null)
  const [withdrawing, setWithdrawing] = useState(null)
  // After a withdrawal, shrink that chain's balance and estimate.
  const drain = (chain, usd) => setList((l) => l.map((g) => {
    if (g.chain !== chain) return g
    const perUsd = g.txs / Math.max(g.usd, 0.1)
    const nu = Math.max(0, g.usd - usd)
    const txs = Math.round(nu * perUsd)
    return { ...g, usd: +nu.toFixed(2), amt: +Math.max(0, g.amt - usd / GAS_PX[g.token]).toPrecision(2), txs, level: Math.max(0.03, g.level * (nu / Math.max(g.usd, 0.1))), low: txs < 50 }
  }))
  const total = list.reduce((a, g) => a + g.usd, 0)
  // After a top-up, refill that chain's bar and estimate.
  const refill = (chain, usd) => setList((l) => l.map((g) => {
    if (g.chain !== chain) return g
    const perUsd = g.txs / Math.max(g.usd, 0.1)
    const nu = g.usd + usd
    return { ...g, usd: +nu.toFixed(2), amt: +(g.amt + usd / GAS_PX[g.token]).toPrecision(2), txs: Math.round(nu * perUsd), level: Math.min(0.95, g.level + 0.6), low: false }
  }))
  return (
    <div className="section">
      <div className="section-title">
        <span className="row" style={{ gap: 6 }}><Fuel size={14} /> Gas <span className="faint num">${total.toFixed(0)}</span></span>
        <span className="row small" style={{ gap: 8 }}>Auto top-up<button className={`toggle ${auto ? 'on' : ''}`} onClick={() => setAuto(!auto)} aria-label="Auto top-up gas" /></span>
      </div>
      {list.map((g) => (
        <div className="list-row" key={g.chain} onClick={() => setTopping(g)} style={{ cursor: 'pointer' }}>
          <Mark name={g.chain} size={30} />
          <div className="grow">
            <div className="row between"><span className="list-title">{g.chain}</span><span className="num small">{g.amt} {g.token}</span></div>
            <div className="bar-track" style={{ marginTop: 7 }}><div className="bar-fill" style={{ width: `${g.level * 100}%`, background: g.low ? 'var(--red)' : undefined }} /></div>
            <div className="row between list-sub" style={{ marginTop: 4 }}>
              <span className={`ellipsis ${g.low ? 'down' : ''}`}>{g.low ? 'Low, ' : ''}{g.txs.toLocaleString()} txs left</span>
              <span className="num" style={{ flexShrink: 0 }}>${g.usd >= 10 ? Math.round(g.usd) : g.usd.toFixed(2)}</span>
            </div>
          </div>
          <div className="gas-acts" onClick={(e) => e.stopPropagation()}>
            <button className={`gas-act ${g.low ? 'brand' : ''}`} onClick={() => setTopping(g)} aria-label={`Top up ${g.chain} gas`} title="Top up"><ArrowDownToLine size={15} /></button>
            <button className="gas-act" onClick={() => setWithdrawing(g)} aria-label={`Withdraw ${g.chain} gas`} title="Withdraw" disabled={g.usd < 1}><ArrowUpFromLine size={15} /></button>
          </div>
        </div>
      ))}
      <p className="faint small" style={{ marginTop: 10 }}>{auto ? 'Refills any chain below 20 transactions.' : 'Auto top-up is off.'} <button className="small" style={{ color: 'var(--accent)' }} onClick={onBridge}>Bridge funds</button></p>
      {topping && <GasTopUp g={topping} onDone={refill} onClose={() => setTopping(null)} />}
      {withdrawing && <GasWithdraw g={withdrawing} onDone={drain} onClose={() => setWithdrawing(null)} />}
    </div>
  )
}

// Two ways to refill gas: swap a token already on that chain, or send gas from another of your wallets.
function GasTopUp({ g, onDone, onClose }) {
  const { approve } = useApp()
  const [usd, setUsd] = useState(10)
  const [method, setMethod] = useState('swap')
  const perUsd = g.txs / Math.max(g.usd, 0.1)
  const sameChain = g.chain === 'Solana' ? 'sol' : null
  const swapFrom = [['USDC', g.chain === 'Solana' ? 2000 : 1240], ['USDT', 310]]
  const [token, setToken] = useState('USDC')
  const sources = wallets.filter((w) => w.id !== 'farm').map((w) => ({ ...w, direct: w.id === sameChain || (g.chain !== 'Solana' && w.id !== 'sol' && ['main', 'trading'].includes(w.id) && g.chain !== 'Polygon') }))
  const [from, setFrom] = useState(sources[0].id)
  const src = sources.find((w) => w.id === from)
  const amt = (usd / GAS_PX[g.token]).toPrecision(2)
  const review = () => {
    onClose()
    approve(method === 'swap' ? {
      kind: 'Gas top-up', title: `Swap ${usd} ${token} to ${g.token}`, success: `${g.chain} gas topped up`,
      lines: [['Pay', `${usd} ${token} on ${g.chain}`], ['Get', `≈ ${amt} ${g.token}`], ['Route', g.chain === 'Solana' ? 'Jupiter' : 'Uniswap'], ['Fee', '$0.02'], ['Adds', `about ${Math.round(usd * perUsd).toLocaleString()} transactions`]],
      checks: baseChecks([{ label: 'Swap stays in your wallet', status: 'pass' }]),
      onSuccess: () => onDone(g.chain, usd),
    } : {
      kind: 'Gas top-up', title: `Send gas from ${src.name}`, success: `${g.chain} gas topped up`,
      lines: [['From', `${src.name} (${src.kind})`], ['To', `${g.chain} gas`], ['Amount', `≈ ${amt} ${g.token} ($${usd})`], ['Route', src.direct ? 'Direct transfer' : 'Bridge via Gas.zip'], ['Arrives', src.direct ? 'Instant' : 'About 30s']],
      checks: baseChecks([{ label: 'Destination is your own wallet', status: 'pass' }]),
      onSuccess: () => onDone(g.chain, usd),
    })
  }
  return (
    <Sheet title={`Top up ${g.chain} gas`} onClose={onClose} foot={<button className="btn primary block" style={{ height: 42 }} onClick={review}>Review</button>}>
      <div className="row" style={{ gap: 12 }}>
        <Mark name={g.chain} size={36} />
        <div className="grow"><div style={{ fontWeight: 500 }}>{g.amt} {g.token}</div><div className={`small ${g.low ? 'down' : 'muted'}`}>About {g.txs.toLocaleString()} transactions left</div></div>
      </div>

      <div className="topup-amts">
        {[5, 10, 25].map((v) => (
          <button key={v} className={usd === v ? 'on' : ''} onClick={() => setUsd(v)}><b>${v}</b><span>{Math.round(v * perUsd).toLocaleString()} txs</span></button>
        ))}
      </div>

      <div className="topup-methods">
        <button className={method === 'swap' ? 'on' : ''} onClick={() => setMethod('swap')}><ArrowLeftRight size={16} /><span><b>Swap from balance</b><small>Use a token on {g.chain}</small></span></button>
        <button className={method === 'deposit' ? 'on' : ''} onClick={() => setMethod('deposit')}><ArrowDownToLine size={16} /><span><b>From another wallet</b><small>Send {g.token} across</small></span></button>
      </div>

      {method === 'swap' ? (
        <div>
          {swapFrom.map(([t, bal]) => (
            <button key={t} className={`topup-src ${token === t ? 'on' : ''}`} onClick={() => setToken(t)}>
              <Mark name={t} size={28} /><span className="grow"><b>{t}</b><small>${bal.toLocaleString()} on {g.chain}</small></span>
              <span className="small muted num topup-meta">{usd} {t} → {amt} {g.token}</span>
            </button>
          ))}
        </div>
      ) : (
        <div>
          {sources.map((w) => (
            <button key={w.id} className={`topup-src ${from === w.id ? 'on' : ''}`} onClick={() => setFrom(w.id)}>
              <span className="wallet-ico">{w.type === 'privy' ? <Mail size={13} /> : <KeyRound size={13} />}</span>
              <span className="grow"><b>{w.name}</b><small>{fmt.usd(w.usd)}, {w.direct ? 'direct' : 'bridged in 30s'}</small></span>
            </button>
          ))}
        </div>
      )}
    </Sheet>
  )
}

// Illustrative QR: the three corner finder squares, random modules elsewhere.
function finder(x, y) {
  for (const [ox, oy] of [[0, 0], [14, 0], [0, 14]]) {
    const dx = x - ox, dy = y - oy
    if (dx >= 0 && dx < 7 && dy >= 0 && dy < 7) return dx === 0 || dy === 0 || dx === 6 || dy === 6 || (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4)
    if (dx >= -1 && dx <= 7 && dy >= -1 && dy <= 7) return false
  }
  return null
}

export function DepositSheet({ onClose, title = 'Deposit' }) {
  const { toast } = useApp()
  const [chain, setChain] = useState('Base')
  const addr = chain === 'Solana' ? '7xKpVt3…Qm2aR9' : '0x7a3F2c…E19c2E'
  const r = rng(chain.length * 7)
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head"><div style={{ fontSize: 17, fontWeight: 600 }}>{title}</div><button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button></div>
        <div className="modal-body stack" style={{ gap: 16 }}>
          <div className="chips">{chains.map((c) => <button key={c} className={`chip sm ${c === chain ? 'on' : ''}`} onClick={() => setChain(c)}><Mark name={c} size={14} />{c}</button>)}</div>
          <div className="qr">{Array.from({ length: 21 * 21 }, (_, i) => { const on = finder(i % 21, Math.floor(i / 21)); return <i key={i} style={{ opacity: (on === null ? r() > 0.5 : on) ? 1 : 0 }} /> })}</div>
          <div className="tx row between" style={{ padding: '10px 14px' }}><span className="mono">{addr}</span><button className="icon-btn" onClick={() => toast('Address copied')} aria-label="Copy address"><Copy size={15} /></button></div>
          <p className="muted small">Only send assets on {chain} to this address.</p>
        </div>
      </div>
    </div>
  )
}

const ROUTES = [
  { name: 'Across', time: '~20 seconds', fee: 0.42 },
  { name: 'deBridge', time: '~1 minute', fee: 0.65 },
]

function BridgeSheet({ onClose }) {
  const { approve } = useApp()
  const [from, setFrom] = useState('Base')
  const [to, setTo] = useState('Arbitrum')
  const [token, setToken] = useState('USDC')
  const [amt, setAmt] = useState(500)
  const [route, setRoute] = useState('Across')
  const pick = ROUTES.find((x) => x.name === route)
  const go = () => {
    onClose()
    approve({
      kind: 'Bridge', title: `Bridge ${amt} ${token}`, success: `${amt} ${token} arrived on ${to}`,
      lines: [['From', from], ['To', to], ['Amount', `${amt} ${token}`], ['Route', route], ['Time', pick.time], ['Fee', `$${pick.fee}`]],
      checks: baseChecks([{ label: 'Bridge contract audited', status: 'pass' }, { label: 'Destination is your own wallet', status: 'pass' }]),
    })
  }
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head"><div style={{ fontSize: 17, fontWeight: 600 }}>Bridge</div><button className="icon-btn" onClick={onClose} aria-label="Close"><X size={16} /></button></div>
        <div className="modal-body stack" style={{ gap: 14 }}>
          <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <label className="field">From<select value={from} onChange={(e) => setFrom(e.target.value)}>{chains.filter((c) => c !== to).map((c) => <option key={c}>{c}</option>)}</select></label>
            <label className="field">To<select value={to} onChange={(e) => setTo(e.target.value)}>{chains.filter((c) => c !== from).map((c) => <option key={c}>{c}</option>)}</select></label>
          </div>
          <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <label className="field">Amount<input type="number" value={amt} min="0" onChange={(e) => setAmt(+e.target.value)} /></label>
            <label className="field">Token<select value={token} onChange={(e) => setToken(e.target.value)}>{['USDC', 'ETH'].map((t) => <option key={t}>{t}</option>)}</select></label>
          </div>
          <div className="field">Route
            {ROUTES.map((x) => (
              <button key={x.name} className="list-row" style={{ border: `1px solid ${x.name === route ? 'var(--text)' : 'var(--border)'}`, borderRadius: 12, padding: '10px 12px', marginTop: 6 }} onClick={() => setRoute(x.name)}>
                <Mark name={x.name} size={26} />
                <div className="grow"><div className="list-title" style={{ color: 'var(--text)' }}>{x.name}{x.name === 'Across' && <span className="up small" style={{ fontWeight: 400 }}> Best</span>}</div><div className="list-sub">{x.time}</div></div>
                <div className="list-end small" style={{ color: 'var(--text)' }}>${x.fee}</div>
              </button>
            ))}
          </div>
        </div>
        <div className="modal-foot"><button className="btn primary block" disabled={!amt} onClick={go}>Review</button></div>
      </div>
    </div>
  )
}

// Assets the agent manages, as a pie: by token or by project (money inside a project is not a direct holding).
function AumCard() {
  const { openProject } = useApp()
  const [by, setBy] = useState('asset')
  const data = by === 'asset' ? aumByAsset : aumByProject
  const total = data.reduce((a, d) => a + d.value, 0)
  return (
    <div className="card aum-card">
      <div className="row between" style={{ marginBottom: 12 }}>
        <span className="stat-label" style={{ margin: 0 }}>Managed by agent</span>
        <div className="seg">{[['asset', 'Assets'], ['project', 'Projects']].map(([k, l]) => <button key={k} className={by === k ? 'on' : ''} onClick={() => setBy(k)}>{l}</button>)}</div>
      </div>
      <div className="row" style={{ gap: 18, alignItems: 'center' }}>
        <Donut data={data} size={108} thickness={14} />
        <div className="legend grow" style={{ minWidth: 0 }}>
          {data.map((d) => {
            const row = <><span className="swatch" style={{ background: d.color }} /><span className="grow ellipsis">{d.label}</span><span className="num">{fmt.usd(d.value)}</span><span className="faint num" style={{ width: 34, textAlign: 'right' }}>{Math.round((d.value / total) * 100)}%</span></>
            return by === 'project' && d.label !== 'Not in a project'
              ? <button className="legend-row" key={d.label} onClick={() => openProject(d.label)}>{row}</button>
              : <div className="legend-row" key={d.label}>{row}</div>
          })}
        </div>
      </div>
    </div>
  )
}

// Take gas back out: swap it to USDC in place, or send it to another of your wallets.
function GasWithdraw({ g, onDone, onClose }) {
  const { approve } = useApp()
  const [pct, setPct] = useState(50)
  const [to, setTo] = useState('usdc')
  const usd = +(g.usd * pct / 100).toFixed(2)
  const amt = (usd / GAS_PX[g.token]).toPrecision(2)
  const others = wallets.filter((w) => w.id !== 'farm' && w.id !== 'main')
  const review = () => {
    onClose()
    const dst = wallets.find((w) => w.id === to)
    approve({
      kind: 'Gas withdrawal', title: to === 'usdc' ? `Swap ${amt} ${g.token} to USDC` : `Send ${amt} ${g.token} to ${dst.name}`, success: `${g.chain} gas withdrawn`,
      lines: [['From', `${g.chain} gas`], ['Amount', `${amt} ${g.token} ($${usd})`], ['To', to === 'usdc' ? `≈ ${usd.toFixed(2)} USDC in Main` : `${dst.name} (${dst.kind})`], ['Leaves', `about ${Math.round((g.usd - usd) * g.txs / Math.max(g.usd, 0.1)).toLocaleString()} transactions`]],
      checks: baseChecks([{ label: 'Destination is your own wallet', status: 'pass' }, { label: 'Enough gas left for pending orders', status: pct === 100 ? 'warn' : 'pass', detail: pct === 100 ? 'Auto top-up will refill it if needed' : undefined }]),
      onSuccess: () => onDone(g.chain, usd),
    })
  }
  return (
    <Sheet title={`Withdraw ${g.chain} gas`} onClose={onClose} foot={<button className="btn primary block" style={{ height: 42 }} onClick={review}>Review</button>}>
      <div className="row" style={{ gap: 12 }}>
        <Mark name={g.chain} size={36} />
        <div className="grow"><div style={{ fontWeight: 500 }}>{g.amt} {g.token}</div><div className="small muted">${g.usd} available</div></div>
      </div>
      <div className="topup-amts">
        {[25, 50, 100].map((v) => (
          <button key={v} className={pct === v ? 'on' : ''} onClick={() => setPct(v)}><b>{v === 100 ? 'Max' : `${v}%`}</b><span>${(g.usd * v / 100).toFixed(2)}</span></button>
        ))}
      </div>
      <button className={`topup-src ${to === 'usdc' ? 'on' : ''}`} onClick={() => setTo('usdc')}>
        <Mark name="USDC" size={28} /><span className="grow"><b>Swap to USDC</b><small>Lands in Main</small></span>
      </button>
      {others.map((w) => (
        <button key={w.id} className={`topup-src ${to === w.id ? 'on' : ''}`} onClick={() => setTo(w.id)}>
          <span className="wallet-ico">{w.type === 'privy' ? <Mail size={13} /> : <KeyRound size={13} />}</span>
          <span className="grow"><b>Send to {w.name}</b><small>{w.kind}</small></span>
        </button>
      ))}
    </Sheet>
  )
}

// Exchange-style send: network, address (paste or scan), and a whitelist of saved addresses.
const NETWORKS = ['Base', 'Ethereum', 'Arbitrum', 'Solana']
const WHITELIST = [
  { label: 'alice.eth', addr: '0x2b9F41c8D0e7A3b1…e04', net: 'Base', note: 'Designer' },
  { label: 'Coinbase deposit', addr: '0x7d10Ae92b4C5f8…3fa1', net: 'Ethereum', note: 'Exchange' },
  { label: 'Ledger cold storage', addr: '0xF09e5B2c11Aa7D…13B4', net: 'Ethereum', note: 'Own wallet' },
  { label: 'bob on Solana', addr: '9PfQ2tLm7Wc…Vx4k', net: 'Solana', note: 'Friend' },
]
const short = (a) => (a.length > 16 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a)

function SendSheet({ from: fromId, onClose }) {
  const { approve, toast } = useApp()
  const [step, setStep] = useState('form')
  const [from, setFrom] = useState(fromId || 'main')
  const [asset, setAsset] = useState('USDC')
  const [net, setNet] = useState('Base')
  const [addr, setAddr] = useState('')
  const [amt, setAmt] = useState(200)
  const [only, setOnly] = useState(true)
  const [list, setList] = useState(WHITELIST)
  const [nw, setNw] = useState({ label: '', net: 'Base', addr: '' })
  const src = wallets.find((w) => w.id === from)
  const saved = list.find((w) => w.addr === addr)
  const valid = net === 'Solana' ? addr.length >= 10 && !addr.startsWith('0x') : /^0x/.test(addr) && addr.length >= 10
  const blocked = only && (!saved || saved.hold)
  const wrongNet = saved && saved.net !== net
  const pick = (w) => { if (w.hold) return toast('This address unlocks 24 hours after it was added'); setAddr(w.addr); setNet(w.net) }
  const review = () => {
    onClose()
    approve({
      kind: 'Send', title: `Send ${amt.toLocaleString()} ${asset}`, success: `Sent to ${saved ? saved.label : short(addr)}`,
      lines: [['From', src.name], ['To', saved ? `${saved.label} (${short(addr)})` : short(addr)], ['Network', net], ['Amount', `${amt.toLocaleString()} ${asset}`], ['Fee', net === 'Ethereum' ? '$1.20' : '$0.01'], ['Arrives', net === 'Ethereum' ? 'About 1 min' : 'Seconds']],
      checks: baseChecks([
        { label: saved ? 'Address is on your whitelist' : 'New address, not on your whitelist', status: saved ? 'pass' : 'warn' },
        { label: 'Network matches the address', status: wrongNet ? 'fail' : 'pass' },
      ]),
    })
  }
  if (step === 'add') return (
    <Sheet title="Add to whitelist" onClose={onClose} foot={<div className="row" style={{ gap: 8, width: '100%' }}><button className="btn grow" style={{ height: 42 }} onClick={() => setStep('form')}>Back</button><button className="btn primary grow" style={{ height: 42 }} disabled={!nw.label || nw.addr.length < 10} onClick={() => { setList((l) => [...l, { ...nw, note: 'Added today', hold: true }]); toast(`${nw.label} added. Usable in 24 hours.`); setNw({ label: '', net: 'Base', addr: '' }); setStep('form') }}>Save address</button></div>}>
      <div className="stack" style={{ gap: 14 }}>
        <label className="field">Label<input className="tx send-input" placeholder="e.g. Binance deposit" value={nw.label} onChange={(e) => setNw({ ...nw, label: e.target.value })} /></label>
        <label className="field">Network<select value={nw.net} onChange={(e) => setNw({ ...nw, net: e.target.value })}>{NETWORKS.map((n) => <option key={n}>{n}</option>)}</select></label>
        <label className="field">Address<input className="tx send-input mono" placeholder={nw.net === 'Solana' ? 'Solana address' : '0x… or ENS'} value={nw.addr} onChange={(e) => setNw({ ...nw, addr: e.target.value.trim() })} /></label>
        <div className="notice" style={{ background: 'var(--subtle)' }}><ShieldCheck size={15} style={{ flexShrink: 0, marginTop: 2 }} /><span className="small">For safety, new addresses unlock 24 hours after you add them. You confirm with your passkey.</span></div>
      </div>
    </Sheet>
  )
  return (
    <Sheet title="Send" onClose={onClose} foot={<button className="btn primary block" style={{ height: 42 }} disabled={!valid || !amt || blocked || wrongNet} onClick={review}>Review</button>}>
      <div className="stack" style={{ gap: 14 }}>
        <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
          <label className="field">From<select value={from} onChange={(e) => setFrom(e.target.value)}>{wallets.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>
          <label className="field">Network<select value={net} onChange={(e) => setNet(e.target.value)}>{NETWORKS.map((n) => <option key={n}>{n}</option>)}</select></label>
        </div>
        <label className="field">Address
          <div className="send-addr">
            <input className="mono" placeholder={net === 'Solana' ? 'Solana address' : '0x… or ENS name'} value={addr} onChange={(e) => setAddr(e.target.value.trim())} />
            <button className="small" onClick={() => setAddr(net === 'Solana' ? '9PfQ2tLm7Wc…Vx4k' : '0x2b9F41c8D0e7A3b1…e04')}>Paste</button>
            <button className="icon-btn" onClick={() => { setAddr('0x7d10Ae92b4C5f8…3fa1'); setNet('Ethereum'); toast('QR code scanned') }} aria-label="Scan QR code"><ScanLine size={16} /></button>
          </div>
        </label>
        {addr && (
          <div className={`small row ${blocked || wrongNet ? 'down' : saved ? 'up' : ''}`} style={{ gap: 6, marginTop: -6 }}>
            {saved && !wrongNet && !saved.hold ? <><ShieldCheck size={14} /> Whitelisted: {saved.label}</>
              : wrongNet ? <>This address is saved for {saved.net}, not {net}</>
              : saved?.hold ? <>Unlocks 24 hours after it was added</>
              : only ? <>Not on your whitelist. Add it first, or turn off Whitelist only.</>
              : valid ? <span className="muted">New address. Double-check before sending.</span> : <>Not a valid {net} address</>}
          </div>
        )}

        <div>
          <div className="row between" style={{ marginBottom: 6 }}>
            <span className="stat-label" style={{ margin: 0 }}>Whitelist</span>
            <span className="row small" style={{ gap: 8 }}>Whitelist only<button className={`toggle sm ${only ? 'on' : ''}`} onClick={() => setOnly(!only)} aria-label="Only send to whitelisted addresses" /></span>
          </div>
          {list.map((w) => (
            <button key={w.addr} className={`topup-src ${addr === w.addr ? 'on' : ''}`} onClick={() => pick(w)} style={w.hold ? { opacity: 0.6 } : undefined}>
              <Mark name={w.net === 'Base' ? 'base' : w.net} size={26} />
              <span className="grow"><b>{w.label}</b><small className="mono">{short(w.addr)}, {w.net}</small></span>
              {w.hold ? <span className="tag amber small">24h hold</span> : <ShieldCheck size={15} color="var(--green)" />}
            </button>
          ))}
          <button className="topup-src add-row" onClick={() => setStep('add')}><span className="wallet-ico"><Plus size={13} /></span><span className="grow"><b>Add address</b><small>Save a label, network and address</small></span></button>
        </div>

        <div className="grid g2" style={{ gridTemplateColumns: '1fr 1fr' }}>
          <label className="field">Amount<input type="number" value={amt} min="0" onChange={(e) => setAmt(+e.target.value)} /></label>
          <label className="field">Asset<select value={asset} onChange={(e) => setAsset(e.target.value)}>{['USDC', 'ETH', 'SOL', 'HYPE'].map((a) => <option key={a}>{a}</option>)}</select></label>
        </div>
        <div className="chips">{[100, 500, 1000].map((v) => <button key={v} className={`chip sm ${amt === v ? 'on' : ''}`} onClick={() => setAmt(v)}>{v}</button>)}<button className="chip sm" onClick={() => setAmt(src.usd)}>Max</button></div>
      </div>
    </Sheet>
  )
}

// Full transaction history with filters; each row opens its receipt.
const HISTORY_FILTERS = { All: () => true, Sent: (s) => s.amt < 0 && s.cat === 'Payment', Received: (s) => s.amt > 0, Trades: (s) => s.cat === 'Trade', APIs: (s) => s.cat === 'API', Earn: (s) => s.cat === 'Earn' }
const MORE_HISTORY = [
  { what: 'Sent to alice.eth', cat: 'Payment', amt: -1200, via: 'USDC on Base', when: 'Oct 1' },
  { what: 'Received from Coinbase', cat: 'Transfer', amt: 5000, via: 'USDC on Base', when: 'Sep 30' },
  { what: 'Aave USDC interest', cat: 'Earn', amt: 24.1, via: 'Auto-claim', when: 'Sep 30' },
  { what: 'Long HYPE 3x opened', cat: 'Trade', amt: -500, via: 'Hyperliquid', when: 'Sep 29' },
]
function HistorySheet({ onClose }) {
  const [f, setF] = useState('All')
  const [tx, setTx] = useState(null)
  const list = [...spending, ...MORE_HISTORY].filter(HISTORY_FILTERS[f])
  if (tx) return <ActivitySheet item={tx} onClose={() => setTx(null)} />
  return (
    <Sheet title="History" onClose={onClose} wide>
      <div className="chips one-line" style={{ marginBottom: 6 }}>{Object.keys(HISTORY_FILTERS).map((k) => <button key={k} className={`chip sm ${k === f ? 'on' : ''}`} onClick={() => setF(k)}>{k}</button>)}</div>
      {list.map((s) => (
        <button className="list-row" key={s.what + s.when} onClick={() => setTx(s)}>
          <span className={`hist-ico ${s.amt > 0 ? 'in' : ''}`}>{s.amt > 0 ? <ArrowDownToLine size={14} /> : <ArrowUpFromLine size={14} />}</span>
          <div className="grow"><div className="list-title" style={{ fontWeight: 400 }}>{s.what}</div><div className="list-sub">{s.when}, {s.via}</div></div>
          <div className={`list-end num ${s.amt > 0 ? 'up' : ''}`}>{s.amt > 0 ? '+' : '−'}${Math.abs(s.amt).toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
        </button>
      ))}
      {!list.length && <p className="muted small" style={{ padding: 16, textAlign: 'center' }}>Nothing here yet</p>}
    </Sheet>
  )
}
