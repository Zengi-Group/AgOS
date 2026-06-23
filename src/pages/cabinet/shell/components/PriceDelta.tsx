// AgOS · Этап 2 · Дельта цены (▲▼—) с семантической окраской (shell/pricesheet.jsx PriceDelta).

import type { StickerData } from '../data/prices'

export function PriceDelta({ s, big }: { s: StickerData; big?: boolean }) {
  const cls = s.trend === 'up' ? 'up' : s.trend === 'down' ? 'down' : 'flat'
  const sign = s.delta > 0 ? '+' + s.delta : s.delta < 0 ? '−' + Math.abs(s.delta) : '0'
  return (
    <span className={'pdelta ' + cls + (big ? ' big' : '')}>
      <i className="pd-arr">{s.arrow}</i>
      <span className="mono">{sign}</span>
      {big && <span className="pd-note">{s.note}</span>}
    </span>
  )
}
