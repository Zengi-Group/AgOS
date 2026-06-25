// AgOS · TSP-2 · SCR-04 «Карточка партии» — 4 зоны (герой / цена / действие / тихая).
// Все мутации через onPatch (мок). Шторки управляются локальным стейтом.

import { useState } from 'react'
import type { Batch } from '../types'
import { Cta } from '../components/Cta'
import { ShellFrame } from '../components/ShellFrame'
import { WithdrawSheet } from '../components/sheets/WithdrawSheet'
import { DispatchSheet } from '../components/sheets/DispatchSheet'
import { BatchPriceSheet } from '../components/sheets/BatchPriceSheet'
import { STATUS, protPrice } from '../data/status'
import { fmtMoney, batchSum } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'

interface Props {
  batch: Batch
  onBack: () => void
  onPatch: (patch: Partial<Batch>) => void
  onNew: () => void
  onReview: () => void
  onTuran: () => void
  toast: (text: string) => void
}

type LocalSheet = null | 'withdraw' | 'dispatch' | 'price'

const PATH_STEPS = ['Подготовка', 'Продажа', 'Покупатель', 'Доставка', 'Готово']

function pathIndex(state: string): number {
  if (state === 'draft' || state === 'scheduled') return 0
  if (state === 'published' || state === 'offering' || state === 'decision') return 1
  if (state === 'matched' || state === 'confirmed') return 2
  if (state === 'dispatched') return 3
  if (state === 'delivered') return 4
  return -1 // cancelled
}

function strField(b: Batch, key: string): string | undefined {
  const v = (b as Record<string, unknown>)[key]
  return typeof v === 'string' ? v : undefined
}

// ── Степпер жизненного цикла ───────────────────────────────────────────────
function BatchPath({ state }: { state: string }) {
  const cur = pathIndex(state)
  return (
    <div className="bpath">
      {PATH_STEPS.map((s, i) => (
        <span key={s} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
          <span className={'bpath-step' + (i === cur ? ' active' : '')}>{s}</span>
          {i < PATH_STEPS.length - 1 && <span className="bpath-sep">→</span>}
        </span>
      ))}
    </div>
  )
}

// ── DecisionActions (только для state=decision) ─────────────────────────────
function DecisionActions({ batch, onPatch, toast }: {
  batch: Batch; onPatch: (p: Partial<Batch>) => void; toast: (t: string) => void
}) {
  const [customOn, setCustomOn] = useState(false)
  const [custom, setCustom] = useState('')
  const prot = protPrice(batch)
  const cur = batch.price ?? 0
  const lowered = cur - 100
  const lowerBlocked = prot != null && lowered < prot

  const applyPrice = (newPrice: number) => {
    onPatch({ state: 'offering', price: newPrice, deadlineLabel: 'завтра, 14:30' })
    toast('Предложение отправлено покупателям по новой цене')
  }

  const customNum = parseInt(custom, 10)
  const customValid = !Number.isNaN(customNum) && customNum > 0 && (prot == null || customNum >= prot)

  return (
    <div className="dec-actions">
      <div className="dec-actions-note">
        Так бывает — цена выше, чем покупатели сейчас готовы платить.
      </div>

      <Cta onClick={() => !lowerBlocked && applyPrice(lowered)} disabled={lowerBlocked}>
        Снизить до {fmtMoney(lowered)}{NBSP}₸/кг и предложить снова
      </Cta>
      {lowerBlocked && (
        <div className="dec-actions-note">Цена уже у защитного уровня</div>
      )}

      {!customOn ? (
        <Cta variant="ghost" onClick={() => setCustomOn(true)}>Назначить свою цену</Cta>
      ) : (
        <>
          <input
            className="dec-price-input"
            type="number"
            min={1}
            value={custom}
            placeholder="Своя цена ₸/кг"
            onChange={(e) => setCustom(e.target.value)}
          />
          {prot != null && (
            <div className="dec-actions-note">Защитная цена: {fmtMoney(prot)}{NBSP}₸/кг</div>
          )}
          <Cta onClick={() => customValid && applyPrice(customNum)} disabled={!customValid}>
            Предложить новую цену
          </Cta>
        </>
      )}

      <Cta variant="ghost" onClick={() => toast('Партия остаётся в продаже. TURAN оповестит, когда появится подходящий покупатель')}>
        Оставить цену и ждать
      </Cta>
    </div>
  )
}

// ── Зона 3: действия по состоянию ───────────────────────────────────────────
function Actions({ batch, onPatch, onNew, onReview, onTuran, toast, openSheet }: {
  batch: Batch
  onPatch: (p: Partial<Batch>) => void
  onNew: () => void
  onReview: () => void
  onTuran: () => void
  toast: (t: string) => void
  openSheet: (s: LocalSheet) => void
}) {
  const s = batch.state
  switch (s) {
    case 'draft':
      return (
        <>
          <Cta onClick={() => toast('Заполнение черновика откроется в следующем обновлении')}>Продолжить заполнение</Cta>
          <Cta variant="danger" onClick={() => { onPatch({ state: 'cancelled' }); toast('Черновик удалён') }}>Удалить черновик</Cta>
        </>
      )
    case 'scheduled':
      return (
        <>
          <Cta variant="ghost" onClick={() => toast('Редактирование откроется в следующем обновлении')}>Изменить партию</Cta>
          <Cta variant="danger" onClick={() => openSheet('withdraw')}>Снять с продажи</Cta>
        </>
      )
    case 'published':
      return (
        <>
          <Cta variant="ghost" onClick={() => openSheet('price')}>Изменить цену</Cta>
          <Cta variant="danger" onClick={() => openSheet('withdraw')}>Снять с продажи</Cta>
        </>
      )
    case 'offering':
      return <Cta variant="danger" onClick={() => openSheet('withdraw')}>Снять с продажи</Cta>
    case 'decision':
      return (
        <>
          <DecisionActions batch={batch} onPatch={onPatch} toast={toast} />
          <Cta variant="danger" onClick={() => openSheet('withdraw')}>Снять с продажи</Cta>
        </>
      )
    case 'matched':
      return (
        <>
          <div className="bat-warn-note">Покупатель уже найден. Снятие может привести к штрафу.</div>
          <Cta variant="danger" onClick={() => openSheet('withdraw')}>Снять с продажи</Cta>
        </>
      )
    case 'confirmed':
      return (
        <>
          <Cta variant="primary-green" onClick={() => openSheet('dispatch')}>Партия отгружена</Cta>
          <Cta variant="danger" onClick={onTuran}>Нужно отменить? Обратитесь в TURAN</Cta>
        </>
      )
    case 'dispatched':
      return <Cta variant="danger" onClick={onTuran}>Возникла проблема? Обратитесь в TURAN</Cta>
    case 'delivered':
      return batch.review ? null : <Cta onClick={onReview}>Оставить отзыв</Cta>
    case 'cancelled':
      return <Cta variant="ghost" onClick={onNew}>Создать похожую партию</Cta>
    default:
      return null
  }
}

// ── Зона 4: данные + история + отзыв ────────────────────────────────────────
function QuietZone({ batch }: { batch: Batch }) {
  const [showDetails, setShowDetails] = useState(false)
  const [showAllHist, setShowAllHist] = useState(false)
  const history = batch.history ?? []
  const shownHist = showAllHist ? history : history.slice(0, 2)
  const details: [string, string | number | undefined][] = [
    ['Порода', batch.breed],
    ['Упитанность', batch.fatness],
    ['Район', batch.district],
    ['Возраст', batch.age != null ? `${batch.age} мес.` : undefined],
  ]

  return (
    <div className="bat-z4">
      <div>
        <button className="bat-details-toggle" onClick={() => setShowDetails((v) => !v)}>
          {showDetails ? 'Скрыть детали' : 'Показать детали'}
        </button>
        {showDetails && (
          <div style={{ marginTop: 8 }}>
            {details.filter(([, v]) => v != null && v !== '').map(([k, v]) => (
              <div className="bat-kv-row" key={k}>
                <span className="bat-kv-k">{k}</span>
                <span className="bat-kv-v">{v}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {history.length > 0 && (
        <div>
          {shownHist.map((h, i) => (
            <div className="bat-hist-item" key={i}>
              <span className="bat-hist-t">{h.t}</span>
              <span className="bat-hist-d">{h.d}</span>
            </div>
          ))}
          {history.length > 2 && (
            <button className="bat-show-all" onClick={() => setShowAllHist((v) => !v)}>
              {showAllHist ? 'Свернуть' : 'Показать всё'}
            </button>
          )}
        </div>
      )}

      {batch.state === 'delivered' && (
        <div className="bat-next">
          {batch.review ? 'Ваш отзыв сохранён' : 'Оцените покупателя — это помогает другим фермерам'}
        </div>
      )}
    </div>
  )
}

export function BatchScreen({ batch, onBack, onPatch, onNew, onReview, onTuran, toast }: Props) {
  const [sheet, setSheet] = useState<LocalSheet>(null)
  const def = STATUS[batch.state]

  const nextText = batch.state === 'offering'
    ? (strField(batch, 'deadlineLabel') ? `Ответ до ${strField(batch, 'deadlineLabel')}` : 'Ждём ответа')
    : (def?.next ?? '')

  const hasPrice = batch.price != null || batch.dealPrice != null
  const bigPrice = batch.dealPrice ?? batch.price ?? 0

  return (
    <ShellFrame noTabs label={`Партия · ${batch.state}`}>
      <div className="bat-wrap">
        <div className="bat-back-row">
          <button className="bat-back" onClick={onBack} aria-label="Назад">←</button>
        </div>

        {/* Зона 1 — Герой */}
        <BatchPath state={batch.state} />
        <div className="bat-z1">
          <div className="bat-phrase">{def?.phrase ?? batch.state}</div>
          <div className="bat-next">{nextText}</div>
        </div>

        {/* Зона 2 — Число */}
        {hasPrice && (
          <div className="bat-z2">
            <div className="bat-price-label">{batch.dealPrice ? 'Цена сделки' : 'Ваша цена'}</div>
            <div className="bat-price-big">{fmtMoney(bigPrice)} <span style={{ fontSize: 14 }}>₸/кг</span></div>
            <div className="bat-price-sum">
              ≈ {batch.heads} × {batch.avgWeight} кг = {fmtMoney(batchSum(batch))}{NBSP}₸
            </div>
          </div>
        )}

        {/* Покупатель — раскрывается фермеру при confirmed (D-M6-5) */}
        {strField(batch, 'buyer') && (
          <div className="bat-kv-row" style={{ padding: '0 16px 8px' }}>
            <span className="bat-kv-k">Покупатель</span>
            <span className="bat-kv-v">
              {strField(batch, 'buyer')}
              {strField(batch, 'buyerPhone') ? ` · ${strField(batch, 'buyerPhone')}` : ''}
            </span>
          </div>
        )}

        {/* Зона 3 — Действие */}
        <div className="bat-z3">
          <Actions
            batch={batch}
            onPatch={onPatch}
            onNew={onNew}
            onReview={onReview}
            onTuran={onTuran}
            toast={toast}
            openSheet={setSheet}
          />
        </div>

        {/* Зона 4 — Тихая */}
        <QuietZone batch={batch} />
      </div>

      {/* Шторки — вне bat-wrap чтобы перекрывали весь ShellFrame */}
      <WithdrawSheet
        batch={batch}
        open={sheet === 'withdraw'}
        onClose={() => setSheet(null)}
        onConfirm={() => { onPatch({ state: 'cancelled' }); toast('Партия снята с продажи'); setSheet(null) }}
      />
      <DispatchSheet
        batch={batch}
        open={sheet === 'dispatch'}
        onClose={() => setSheet(null)}
        onConfirm={() => { onPatch({ state: 'dispatched', dispatchedLabel: 'сегодня' }); toast('Покупатель уведомлён об отгрузке'); setSheet(null) }}
      />
      <BatchPriceSheet
        batch={batch}
        open={sheet === 'price'}
        onClose={() => setSheet(null)}
        onConfirm={(newPrice) => { onPatch({ price: newPrice }); toast('Цена обновлена'); setSheet(null) }}
      />
    </ShellFrame>
  )
}
