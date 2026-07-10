// AgOS · TSP · Карточка партии в списке (порт прототипа market.jsx BatchCard + StatusChip).
// Общий компонент для MarketScreen (таб «Рынок») и ListScreen (p1list) — .mk-card ledger-row.

import type { Batch } from '../types'
import { STATUS } from '../data/status'
import { catName } from '../data/batches'
import { fmtMoney } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import { PhIcon } from './icons/PhIcon'

// тон статуса (в карточке полиш делает чип монохромным — тон косметический)
const STATE_TONE: Record<string, string> = {
  draft: 'neutral', scheduled: 'blue', published: 'blue', offering: 'amber', decision: 'amber',
  partial: 'blue', matched: 'green', confirmed: 'green', dispatched: 'neutral', delivered: 'green', cancelled: 'neutral',
}
const PULSE = new Set(['offering'])

export function StatusChip({ b }: { b: Batch }) {
  const tone = STATE_TONE[b.state] ?? 'neutral'
  const chip = STATUS[b.state]?.chip ?? b.state
  return (
    <span className={'mk-chip tone-' + tone}>
      {PULSE.has(b.state) ? <i className="mk-pulse" /> : <i className="mk-dot" />}
      <span className={b.state === 'cancelled' ? 'mk-strike' : ''}>{chip}</span>
    </span>
  )
}

export function BatchCard({ b, onOpen }: { b: Batch; onOpen: () => void }) {
  const dec = b.state === 'decision'
  const fact = STATUS[b.state]?.fact(b) ?? ''
  const price = b.dealPrice
    ? <>цена сделки <b className="mk-mono">{fmtMoney(b.dealPrice)}{NBSP}₸/кг</b></>
    : b.price ? <>ваша цена <b className="mk-mono">{fmtMoney(b.price)}{NBSP}₸/кг</b></>
    : <span className="mk-kv-hint">цена не назначена</span>
  return (
    <button className={'mk-card' + (dec ? ' urgent' : '')} onClick={onOpen}>
      <div className="mk-card-top">
        <span className="mk-card-name">{catName(b)}</span>
        <span className="mk-card-meta"><span className="mk-mono">{b.heads}</span> голов · ср. <span className="mk-mono">{b.avgWeight}</span> кг</span>
      </div>
      <div className="mk-card-state"><StatusChip b={b} />{fact && <span className="mk-card-fact">{fact}</span>}</div>
      <div className="mk-card-price">
        {dec ? <span className="mk-card-cta">Решить<PhIcon name="chevronRight" size={13} /></span> : price}
      </div>
    </button>
  )
}
