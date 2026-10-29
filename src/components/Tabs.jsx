import { useEffect, useRef } from 'react'
import { useApp } from '../App'

// One row of page tabs. Sticks to the top while scrolling and scrolls sideways on phones instead of wrapping.
export default function Tabs({ tabs, value, onChange }) {
  const ref = useRef(null)
  useEffect(() => {
    const el = ref.current?.querySelector('.on')
    if (el) el.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' })
  }, [value])
  return (
    <div className="tabs" ref={ref} role="tablist">
      {tabs.map(([k, label, badge]) => (
        <button key={k} role="tab" aria-selected={value === k} className={value === k ? 'on' : ''} onClick={() => onChange(k)}>
          {label}{badge ? <span className="tab-badge">{badge}</span> : null}
        </button>
      ))}
    </div>
  )
}

// The page's top tab lives in the URL (#/trade/markets) so it survives reloads and can be linked.
export function usePageTab(tabs) {
  const { sub, setTab } = useApp()
  const keys = tabs.map((t) => t[0])
  return [keys.includes(sub) ? sub : keys[0], setTab]
}
