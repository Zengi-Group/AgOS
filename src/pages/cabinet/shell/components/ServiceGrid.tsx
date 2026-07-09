// AgOS · Грид сервисов Главной (прототип home.jsx ServiceGrid): 4 плитки —
// Торговать / Магазин / Цены / Сервисы. Phosphor-иконки 28. Навигация через ctx.

import { useShell } from '../context'
import { PhIcon, type PhIconName } from './icons/PhIcon'

export function ServiceGrid() {
  const ctx = useShell()
  const items: { t: string; ic: PhIconName; go: () => void; soon?: boolean }[] = [
    { t: 'Торговать', ic: 'arrowLeftRight', go: () => ctx.go({ name: 'market' }) },
    { t: 'Магазин', ic: 'bag', go: () => ctx.go({ name: 'shop' }) },
    { t: 'Цены', ic: 'tag', go: () => ctx.openPrices('bychki') },
    { t: 'Сервисы', ic: 'grid', go: () => ctx.go({ name: 'services' }) },
  ]
  return (
    <div className="svc-grid" data-screen-label="грид сервисов">
      {items.map((s) => (
        <button key={s.t} className={'svc' + (s.soon ? ' soon' : '')} disabled={!!s.soon} onClick={s.go}>
          <span className="svc-ic"><PhIcon name={s.ic} size={28} /></span>
          <span className="svc-t">{s.t}</span>
          {s.soon && <span className="svc-soon">скоро</span>}
        </button>
      ))}
    </div>
  )
}
