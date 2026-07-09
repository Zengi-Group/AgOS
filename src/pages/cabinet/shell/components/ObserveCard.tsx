// AgOS · Ярус «Идёт само» — каноническая строка (прототип shell.jsx Row / home.jsx HomeRow):
// иконка (тон по статусу) + заголовок + мета + шеврон. Рендерит реальную ObserveItemModel.

import { PhIcon, type PhIconName } from './icons/PhIcon'
import type { ObserveItemModel } from '../data/membership'

const DOT_ICON: Record<string, PhIconName> = {
  offering: 'clock', matched: 'check', published: 'tag', dispatched: 'truck', scheduled: 'clock', delivered: 'check', gray: 'clock',
}
const DOT_TONE: Record<string, string> = {
  offering: 'amber', matched: 'green', published: 'accent', dispatched: 'emerald', scheduled: 'blue', delivered: 'green', gray: 'fg3',
}

export function ObserveCard({ o }: { o: ObserveItemModel }) {
  const icon = DOT_ICON[o.dot] || 'tag'
  const tone = DOT_TONE[o.dot] || 'accent'
  return (
    <button className="sh-row" onClick={o.onOpen} data-screen-label="ярус · идёт само">
      <span className="sh-row-ic" style={{ color: `var(--${tone})` }}><PhIcon name={icon} size={20} /></span>
      <span className="sh-row-tx">
        <span className="sh-row-t">{o.t}</span>
        <span className="sh-row-m">{o.sub}</span>
      </span>
      <span className="sh-row-ch"><PhIcon name="chevronRight" size={16} /></span>
    </button>
  )
}
