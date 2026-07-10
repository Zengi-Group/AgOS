// AgOS · TSP-2 · SCR-01 «Мои партии» (p1list) — список с фильтрами и группировкой.
// Реcкин под .mk-* прототипа (общий BatchCard). Данные приходят пропсами из CabinetApp.
// Основной список теперь на табе «Рынок» (MarketScreen); этот экран — вторичный вход
// (после публикации / back из карточки). Логика/пропсы не изменены.

import { useState } from 'react'
import type { Batch } from '../types'
import { filterBatches, DONE_STATES_SET, type ListFilter } from '../data/status'
import { IonShellFrame } from '../components/IonShellFrame'
import { BatchCard } from '../components/BatchListCard'
import { PhIcon } from '../components/icons/PhIcon'
import { ScreenSkeleton } from '../components/ScreenSkeleton'

interface Props {
  batches: Batch[]
  onBatch: (id: string) => void
  onNew: () => void
  onBack: () => void
  /** P-3 (ARS-219): пока грузятся партии — скелет, а НЕ ложный empty-state «Партий нет». */
  loading?: boolean
}

const FILTERS: { k: ListFilter; t: string }[] = [
  { k: 'all', t: 'Все' },
  { k: 'active', t: 'В работе' },
  { k: 'done', t: 'Завершённые' },
]

export function ListScreen({ batches, onBatch, onNew, onBack, loading }: Props) {
  const [filter, setFilter] = useState<ListFilter>('all')
  const list = filterBatches(batches, filter)
  const dec = list.filter((b) => b.state === 'decision')
  const act = list.filter((b) => b.state !== 'decision' && !DONE_STATES_SET.has(b.state))
  const fin = list.filter((b) => DONE_STATES_SET.has(b.state))
  const isEmpty = list.length === 0

  const group = (title: string, items: Batch[], urgent: boolean) => items.length > 0 && (
    <div className={'mk-grp' + (urgent ? ' urgent' : '')} key={title}>
      <div className="tier-h mk-grp-h">
        <span className="tier-h-l"><span className={'tier-label' + (urgent ? ' urgent' : '')}>{title}</span></span>
      </div>
      <div className="mk-stack8">{items.map((b) => <BatchCard key={b.id} b={b} onOpen={() => onBatch(b.id)} />)}</div>
    </div>
  )

  const footer = batches.length > 0
    ? <button className="mk-cta primary" style={{ margin: 0 }} onClick={onNew}><PhIcon name="plus" size={16} />Новая партия</button>
    : undefined

  return (
    <IonShellFrame noTabs label="Мои партии" footer={footer} footBare>
      <div className="lst-head">
        <button className="lst-back" onClick={onBack} aria-label="Назад"><PhIcon name="chevronLeft" size={18} /></button>
        <div className="lst-title">Мои партии</div>
        <span aria-hidden style={{ width: 34 }} />
      </div>
      <div className="mk mk-pt">
        {loading && batches.length === 0 ? (
          // P-3 (ARS-219): первичная загрузка — скелет вместо ложного «Партий нет».
          <ScreenSkeleton variant="list" />
        ) : (
          <>
            <div className="mk-tabs">
              {FILTERS.map((f) => (
                <button key={f.k} className={'mk-tab' + (filter === f.k ? ' on' : '')} onClick={() => setFilter(f.k)}>
                  <span className="mk-tab-t">{f.t}</span>
                </button>
              ))}
            </div>
            {isEmpty ? (
              <div className="mk-empty">
                <div className="mk-empty-art"><PhIcon name="package" size={46} /></div>
                <div className="mk-empty-h">{filter === 'done' ? 'Завершённых партий пока нет' : 'Партий пока нет'}</div>
                {filter !== 'done' && <div className="mk-empty-t">Создайте первую — она появится в этом списке.</div>}
                {filter !== 'done' && <button className="mk-cta primary" onClick={onNew}>Создать первую партию</button>}
              </div>
            ) : (
              <div className="mk-listgroups">
                {group('Требуют решения', dec, true)}
                {group('В работе', act, false)}
                {group('Завершённые', fin, false)}
              </div>
            )}
          </>
        )}
      </div>
    </IonShellFrame>
  )
}
