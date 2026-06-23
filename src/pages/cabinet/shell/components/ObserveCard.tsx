// AgOS · Этап 2 · Ярус 2 «Идёт само»: точка-статус + лейбл-источник, БЕЗ кнопок (shell/ui.jsx ObserveCard).

import type { ObserveItemModel } from '../data/membership'

const OBS_DOT: Record<string, string> = {
  offering: 'var(--st-yellow)', matched: 'var(--st-green)', published: 'var(--st-sky)',
  dispatched: 'var(--st-violet)', scheduled: 'var(--st-blue)', delivered: 'var(--st-deepgreen)', gray: 'var(--st-gray)',
}

export function ObserveCard({ o }: { o: ObserveItemModel }) {
  return (
    <button className="obs-card" onClick={o.onOpen} data-screen-label="ярус 2 · идёт само">
      <i className="obs-dot" style={{ background: OBS_DOT[o.dot] || 'var(--st-gray)' }} />
      <span className="obs-tx">
        <span className="obs-t">{o.t}</span>
        <span className="obs-s">{o.sub}</span>
      </span>
      <span className="obs-src">{o.src}</span>
    </button>
  )
}
