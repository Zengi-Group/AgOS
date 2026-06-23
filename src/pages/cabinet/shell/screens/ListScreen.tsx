// AgOS · TSP-2 · SCR-01 «Мои партии» — список с фильтрами и группировкой.
// Все данные приходят пропсами из CabinetApp (мок, без Supabase).

import { useState } from 'react'
import type { Batch } from '../types'
import { fmtMoney } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import {
  STATUS, catLabel, filterBatches,
  type ListFilter,
} from '../data/status'
import { ShellFrame } from '../components/ShellFrame'

interface Props {
  batches: Batch[]
  onBatch: (id: string) => void
  onNew: () => void
  onBack: () => void
}

const FILTERS: { k: ListFilter; t: string }[] = [
  { k: 'all', t: 'Все' },
  { k: 'active', t: 'В работе' },
  { k: 'done', t: 'Завершённые' },
]

function dotColor(state: string): string {
  if (state === 'decision') return 'var(--amber)'
  if (state === 'delivered') return 'var(--ok)'
  if (state === 'cancelled') return 'var(--ink-3)'
  return 'var(--primary)'
}

function BatchCard({ b, onClick }: { b: Batch; onClick: () => void }) {
  const def = STATUS[b.state]
  const price = b.dealPrice ?? b.price ?? 0
  const isDecision = b.state === 'decision'
  return (
    <button className={'lst-card' + (isDecision ? ' decision' : '')} onClick={onClick}>
      <span className="lst-card-r1">{catLabel(b)} · {b.heads} гол. · ~{b.avgWeight} кг</span>
      <span className="lst-card-r2">
        <span className="lst-dot" style={{ background: dotColor(b.state) }} />
        {def?.chip ?? b.state} · {def ? def.fact(b) : ''}
      </span>
      <span className="lst-card-r3">
        {b.dealPrice ? 'ЦЕНА СДЕЛКИ' : 'ВАША ЦЕНА'}: <span>{fmtMoney(price)}{NBSP}₸/кг</span>
      </span>
      {isDecision && <span className="lst-card-r4">Выбрать, что делать →</span>}
    </button>
  )
}

export function ListScreen({ batches, onBatch, onNew, onBack }: Props) {
  const [filter, setFilter] = useState<ListFilter>('all')
  const list = filterBatches(batches, filter)

  const showGroups = filter === 'all' || filter === 'active'
  const decisionList = showGroups ? list.filter((b) => b.state === 'decision') : []
  const restList = showGroups ? list.filter((b) => b.state !== 'decision') : list

  const isEmpty = list.length === 0
  const canCreateFromEmpty = filter === 'all' || filter === 'active'

  return (
    <ShellFrame noTabs label="Мои партии">
      <div className="lst-head">
        <button className="lst-back" onClick={onBack} aria-label="Назад">←</button>
        <div className="lst-title">Мои партии</div>
        <button className="lst-new" onClick={onNew}>+ Новая</button>
      </div>

      <div className="lst-filters">
        {FILTERS.map((f) => (
          <button
            key={f.k}
            className={'lst-tab' + (filter === f.k ? ' active' : '')}
            onClick={() => setFilter(f.k)}
          >
            {f.t}
          </button>
        ))}
      </div>

      {isEmpty ? (
        <div className="lst-empty">
          <div>Нет партий</div>
          {canCreateFromEmpty && (
            <button className="ws-btn" onClick={onNew}>+ Создать первую партию</button>
          )}
        </div>
      ) : (
        <div className="stack8" style={{ padding: '12px 0' }}>
          {showGroups && decisionList.length > 0 && (
            <>
              <div className="lst-section-head amber">Требуют решения</div>
              {decisionList.map((b) => (
                <BatchCard key={b.id} b={b} onClick={() => onBatch(b.id)} />
              ))}
            </>
          )}
          {showGroups && decisionList.length > 0 && restList.length > 0 && (
            <div className="lst-section-head">В работе</div>
          )}
          {restList.map((b) => (
            <BatchCard key={b.id} b={b} onClick={() => onBatch(b.id)} />
          ))}
        </div>
      )}

      {batches.length > 0 && (
        <button className="lst-fab" onClick={onNew}>+ Новая партия</button>
      )}
    </ShellFrame>
  )
}
