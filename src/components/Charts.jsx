import { ShieldCheck } from 'lucide-react'
import { rng } from '../data'

// Lightweight SVG charts, no chart library needed for the demo.

export function Donut({ data, size = 140, thickness = 18, center }) {
  const total = data.reduce((a, b) => a + b.value, 0)
  const r = (size - thickness) / 2
  const c = 2 * Math.PI * r
  let offset = 0
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ flexShrink: 0 }}>
      <g transform={`rotate(-90 ${size / 2} ${size / 2})`}>
        {data.map((d) => {
          const len = (d.value / total) * c
          const el = (
            <circle key={d.label} cx={size / 2} cy={size / 2} r={r} fill="none" stroke={d.color}
              strokeWidth={thickness} strokeDasharray={`${Math.max(len - 2, 0)} ${c - len + 2}`} strokeDashoffset={-offset} />
          )
          offset += len
          return el
        })}
      </g>
      {center && (
        <text x="50%" y="50%" textAnchor="middle" dominantBaseline="central" style={{ font: '600 15px Inter', fill: 'var(--text)' }}>
          {center}
        </text>
      )}
    </svg>
  )
}

export function AreaChart({ data, height = 160, color = '#121212', id = 'a' }) {
  const w = 600
  const min = Math.min(...data), max = Math.max(...data)
  const x = (i) => (i / (data.length - 1)) * w
  const y = (v) => height - 8 - ((v - min) / (max - min || 1)) * (height - 20)
  const line = data.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(v).toFixed(1)}`).join('')
  return (
    <svg viewBox={`0 0 ${w} ${height}`} width="100%" height={height} preserveAspectRatio="none" style={{ display: 'block' }}>
      <defs>
        <linearGradient id={`g-${id}`} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor={color} stopOpacity=".08" />
          <stop offset="1" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={`${line}L${w} ${height}L0 ${height}Z`} fill={`url(#g-${id})`} />
      <path d={line} fill="none" stroke={color} strokeWidth="2" vectorEffect="non-scaling-stroke" />
    </svg>
  )
}

export function Sparkline({ data, width = 80, height = 26 }) {
  const up = data[data.length - 1] >= data[0]
  const min = Math.min(...data), max = Math.max(...data)
  const pts = data.map((v, i) => `${(i / (data.length - 1)) * width},${height - 2 - ((v - min) / (max - min || 1)) * (height - 4)}`).join(' ')
  return (
    <svg width={width} height={height}>
      <polyline points={pts} fill="none" stroke={up ? 'var(--green)' : 'var(--red)'} strokeWidth="1.5" />
    </svg>
  )
}

export function CandleChart({ data, height = 220, marks = [], padTo = [] }) {
  const w = 640
  const pad = 46
  // Widen the range so TP/SL lines outside recent prices still show.
  const min = Math.min(...data.map((d) => d.l), ...padTo), max = Math.max(...data.map((d) => d.h), ...padTo)
  const y = (v) => 10 + (1 - (v - min) / (max - min)) * (height - 30)
  const step = (w - pad) / data.length
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((t) => min + (max - min) * t)
  const fmtTick = (v) => (v < 0.01 ? v.toExponential(1) : v < 10 ? v.toFixed(3) : v.toFixed(0))
  return (
    <svg viewBox={`0 0 ${w} ${height}`} width="100%" style={{ display: 'block' }}>
      {ticks.map((t) => (
        <g key={t}>
          <line x1="0" x2={w - pad} y1={y(t)} y2={y(t)} stroke="var(--border)" strokeDasharray="2 4" />
          <text x={w - pad + 6} y={y(t) + 4} style={{ font: '10px Inter', fill: 'var(--faint)' }}>{fmtTick(t)}</text>
        </g>
      ))}
      {data.map((d, i) => {
        const up = d.c >= d.o
        const col = up ? 'var(--green)' : 'var(--red)'
        const cx = i * step + step / 2
        return (
          <g key={i}>
            <line x1={cx} x2={cx} y1={y(d.h)} y2={y(d.l)} stroke={col} strokeWidth="1" />
            <rect x={cx - step * 0.32} width={step * 0.64} y={y(Math.max(d.o, d.c))} height={Math.max(1, Math.abs(y(d.o) - y(d.c)))} fill={col} rx="1" />
          </g>
        )
      })}
      {marks.map((m) => (
        <g key={m.label}>
          <line x1="0" x2={w - pad} y1={y(m.v)} y2={y(m.v)} stroke={m.color} strokeDasharray="4 3" />
          {/* Keep the label inside the chart even when the line sits at the edge. */}
          <rect x="4" y={Math.max(2, y(m.v) - 16)} rx="4" width={m.label.length * 6 + 12} height="14" fill={m.color} />
          <text x="10" y={Math.max(12, y(m.v) - 6)} style={{ font: '600 9.5px Inter', fill: '#fff' }}>{m.label}</text>
        </g>
      ))}
    </svg>
  )
}

export function HBars({ data, max, suffix = '%', prefix = '', color = 'var(--text)' }) {
  const m = max || Math.max(...data.map((d) => d.value))
  return (
    <div className="stack" style={{ gap: 10 }}>
      {data.map((d) => (
        <div key={d.label}>
          <div className="row between small" style={{ marginBottom: 6 }}>
            <span className="ellipsis">{d.label} <span className="faint">{d.sub}</span></span>
            <span className="num" style={{ fontWeight: 500 }}>{prefix}{d.value.toLocaleString()}{suffix}</span>
          </div>
          <div className="bar-track"><div className="bar-fill" style={{ width: `${(d.value / m) * 100}%`, background: d.color || color }} /></div>
        </div>
      ))}
    </div>
  )
}

// Holder bubble map: clusters of linked wallets share a colour, lines show funding links.
export function BubbleMap({ seed = 7, clusters, height = 260 }) {
  const r = rng(seed)
  const w = 640
  const nodes = []
  const links = []
  clusters.forEach((cl, ci) => {
    const cx = cl.x * w, cy = cl.y * height
    const first = nodes.length
    for (let i = 0; i < cl.n; i++) {
      const a = i * 2.4 + r()
      const dist = i === 0 ? 0 : 14 + Math.sqrt(i) * (cl.spread || 16)
      const size = i === 0 ? cl.size : Math.max(4, cl.size * (0.25 + r() * 0.4))
      nodes.push({ x: cx + Math.cos(a) * dist, y: cy + Math.sin(a) * dist, s: size, c: cl.color, ci })
      if (i > 0 && cl.linked) links.push([first, nodes.length - 1])
    }
  })
  for (let i = 0; i < 40; i++) nodes.push({ x: 20 + r() * (w - 40), y: 16 + r() * (height - 32), s: 3 + r() * 6, c: '#D9D4CB' })
  return (
    <svg viewBox={`0 0 ${w} ${height}`} width="100%" style={{ display: 'block', background: 'var(--subtle)', borderRadius: 10 }}>
      {links.map(([a, b], i) => (
        <line key={i} x1={nodes[a].x} y1={nodes[a].y} x2={nodes[b].x} y2={nodes[b].y} stroke={nodes[a].c} strokeOpacity=".45" />
      ))}
      {nodes.map((n, i) => (
        <circle key={i} cx={n.x} cy={n.y} r={n.s} fill={n.c} fillOpacity={n.c === '#D9D4CB' ? 0.7 : 0.85} stroke="#fff" strokeWidth="1" />
      ))}
    </svg>
  )
}

// Flow diagram as a minimal timeline: dot per step, shield for the safety check.
// Horizontal on desktop, vertical on phones (see .flow in styles.css).
export function FlowDiagram({ steps }) {
  return (
    <ol className="flow">
      {steps.map((st, i) => (
        <li key={i} className={st.kind === 'guard' ? 'guard' : ''}>
          <span className="flow-dot">{st.kind === 'guard' ? <ShieldCheck size={12} strokeWidth={2.4} /> : null}</span>
          <div className="flow-text">
            <div className="flow-t">{st.t}</div>
            <div className="flow-d">{st.d}</div>
          </div>
        </li>
      ))}
    </ol>
  )
}

// Tiny candlestick chart for list rows (prices are always shown as candles).
export function MiniCandles({ data, width = 84, height = 28 }) {
  const min = Math.min(...data.map((d) => d.l)), max = Math.max(...data.map((d) => d.h))
  const y = (v) => 1 + (1 - (v - min) / (max - min || 1)) * (height - 2)
  const step = width / data.length
  return (
    <svg width={width} height={height} aria-hidden="true">
      {data.map((d, i) => {
        const col = d.c >= d.o ? 'var(--green)' : 'var(--red)'
        const cx = i * step + step / 2
        return <g key={i}><line x1={cx} x2={cx} y1={y(d.h)} y2={y(d.l)} stroke={col} strokeWidth="0.8" /><rect x={cx - step * 0.3} width={step * 0.6} y={y(Math.max(d.o, d.c))} height={Math.max(0.8, Math.abs(y(d.o) - y(d.c)))} fill={col} /></g>
      })}
    </svg>
  )
}
