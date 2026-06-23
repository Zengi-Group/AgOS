// AgOS · Этап 2 · Карточка «Требует решения» (shell/ui.jsx DecisionCard) — содержание, не счётчик.

import type { DecisionCardModel } from '../data/membership'

export function DecisionCard({ d }: { d: DecisionCardModel }) {
  return (
    <div className="dec-card" data-screen-label="карточка решения">
      <div className="dec-src mono">{d.src}{d.due ? ' · ' + d.due : ''}</div>
      <div className="dec-t">{d.t}</div>
      {d.m && <div className="dec-m">{d.m}</div>}
      {d.actions && d.actions.length > 0 && (
        <div className="dec-btns">
          {d.actions.map((a) => (
            <button key={a.t} className={'dec-btn ' + (a.kind || 'ghost')} onClick={a.fn}>{a.t}</button>
          ))}
        </div>
      )}
    </div>
  )
}
