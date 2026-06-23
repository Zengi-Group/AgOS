// AgOS · Этап 2 · Ярус 3 «Впереди» — горизонт ближайших событий фермы (shell/ui.jsx AheadBlock).

import type { FarmPlanItem } from '../data/farm-seed'

export function AheadBlock({ items }: { items: FarmPlanItem[] }) {
  if (!items || !items.length) return null
  return (
    <div className="ahead">
      <div className="ahead-h mono">ВПЕРЕДИ</div>
      {items.map((a) => (
        <div className="ahead-row" key={a.name}>
          <span className="ahead-n">{a.name}</span>
          <span className="ahead-d mono">{a.dates}</span>
        </div>
      ))}
    </div>
  )
}
