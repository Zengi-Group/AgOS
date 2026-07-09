// AgOS · Карточка «Требует решения» (прототип home.jsx DecisionCard): часы-иконка +
// заголовок/мета + чипы действий. Рендерит реальную модель DecisionCardModel
// (buildDecisions): продажа/членство/отгрузка — actions[0] primary, остальные alt.

import { PhIcon } from './icons/PhIcon'
import type { DecisionCardModel } from '../data/membership'

export function DecisionCard({ d }: { d: DecisionCardModel }) {
  // Клик по телу = вторичное действие (обычно «Открыть/Варианты»), иначе первое.
  const headFn = (d.actions.find((a) => a.kind === 'ghost') || d.actions[0])?.fn
  return (
    <div className="dec-row" data-screen-label="карточка решения">
      <span className="sh-row-ic dec-row-ic"><PhIcon name="clock" size={20} /></span>
      <div className="dec-row-body">
        <button className="dec-row-head" onClick={headFn}>
          <span className="sh-row-tx">
            <span className="sh-row-t">{d.t}</span>
            {d.m && <span className="dec-row-m">{d.m}</span>}
          </span>
        </button>
        {d.actions.length > 0 && (
          <div className="dec-row-actions">
            {d.actions.map((a) => (
              <button key={a.t} className={'dec-act ' + (a.kind === 'primary' ? 'primary' : 'alt')} onClick={a.fn}>
                {a.t}
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
