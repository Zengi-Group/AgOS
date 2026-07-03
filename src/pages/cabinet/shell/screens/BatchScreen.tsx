// AgOS · TSP-2 · SCR-04 «Карточка партии» — 4 зоны (герой / цена / действие / тихая).
// Все мутации через onPatch (мок). Шторки управляются локальным стейтом.

import { useState } from 'react'
import type { Batch } from '../types'
import { Cta } from '../components/Cta'
import { ShellFrame } from '../components/ShellFrame'
import { WithdrawSheet } from '../components/sheets/WithdrawSheet'
import { DispatchSheet } from '../components/sheets/DispatchSheet'
import { BatchPriceSheet } from '../components/sheets/BatchPriceSheet'
import { STATUS, protPrice, catLabel, gradeLabel } from '../data/status'
import { fmtMoney, batchSum } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import { printDealDoc, fmtDealDate, type DealDocData } from '../data/deal-doc'

interface FarmerAccount {
  name?: string | null
  bin?: string | null
  phone?: string | null
  district?: string | null
}

interface Props {
  batch: Batch
  account?: FarmerAccount | null
  onBack: () => void
  onPatch: (patch: Partial<Batch>) => void
  onNew: () => void
  onReview: () => void
  onTuran: () => void
  toast: (text: string) => void
}

// Слайс 9 (S4): сборка документа сделки со стороны ФЕРМЕРА (продавец).
// Куски = allocations (каждый — покупатель/пул). Даты берём из *AtIso партии.
function buildFarmerDealDoc(batch: Batch, account?: FarmerAccount | null): DealDocData {
  const allocs = Array.isArray(batch.allocations) ? batch.allocations : []
  const iso = (k: string): string | undefined => {
    const v = (batch as Record<string, unknown>)[k]
    return typeof v === 'string' ? v : undefined
  }
  const chunks = allocs.length > 0
    ? allocs.map((a) => ({
        counterparty: a.buyer ?? null,
        counterpartyPhone: a.buyerPhone ?? null,
        heads: a.heads,
        price: a.price,
        weight: batch.avgWeight ?? null,
        statusLabel: chunkStatusLabel(a.status),
      }))
    : [{
        counterparty: (batch.buyer as string | undefined) ?? null,
        counterpartyPhone: (batch.buyerPhone as string | undefined) ?? null,
        heads: batch.heads ?? 0,
        price: batch.dealPrice ?? batch.price ?? 0,
        weight: batch.avgWeight ?? null,
        statusLabel: STATUS[batch.state]?.chip ?? '',
      }]
  return {
    side: 'farmer',
    dealNo: String(batch.id).slice(0, 8).toUpperCase(),
    self: {
      role: 'Продавец',
      name: account?.name || 'Ваше хозяйство',
      bin: account?.bin ?? null,
      phone: account?.phone ?? null,
      region: account?.district || batch.district || null,
    },
    subject: {
      catName: catLabel(batch),
      grade: gradeLabel(batch),
      breed: batch.breed ?? null,
      avgWeight: batch.avgWeight ?? null,
      fatness: batch.fatness ?? null,
      age: batch.age ?? null,
    },
    totalHeads: batch.heads ?? 0,
    dealPrice: batch.dealPrice ?? null,
    chunks,
    statusLabel: STATUS[batch.state]?.chip ?? batch.state,
    timeline: [
      { label: 'Создана', value: fmtDealDate(iso('createdAtIso')) },
      { label: 'Выставлена', value: fmtDealDate(iso('publishedAtIso')) },
      { label: 'Покупатель подобран', value: fmtDealDate(iso('matchedAtIso')) },
      { label: 'Сделка подтверждена', value: fmtDealDate(iso('confirmedAtIso')) },
      { label: 'Отгружена', value: fmtDealDate(iso('dispatchedAtIso')) },
      { label: 'Принята', value: fmtDealDate(iso('deliveredAtIso')) },
    ],
  }
}

// Документ доступен, когда сделка состоялась (есть цена сделки и подобран покупатель).
const DEAL_STATES = new Set(['matched', 'confirmed', 'dispatched', 'delivered', 'partial'])
function hasDeal(batch: Batch): boolean {
  return DEAL_STATES.has(batch.state)
    && (batch.dealPrice != null
        || (Array.isArray(batch.allocations) && batch.allocations.length > 0))
}

type LocalSheet = null | 'withdraw' | 'dispatch' | 'price'

const PATH_STEPS = ['Подготовка', 'Продажа', 'Покупатель', 'Доставка', 'Готово']

function pathIndex(state: string): number {
  if (state === 'draft' || state === 'scheduled') return 0
  // partial — часть продана, остаток ещё на рынке → держим шаг «Продажа»
  if (state === 'published' || state === 'offering' || state === 'decision' || state === 'partial') return 1
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

// ── Панель частичной продажи (state=partial или несколько кусков) ───────────
// Показывает прогресс «продано X / Y, осталось Z» + список кусков с покупателями.
// Контакт покупателя раскрыт только после закрытия его пула (иначе «скрыт до сделки»).
// Слайс 9 S3: человекочитаемый статус куска в панели частичной продажи.
function chunkStatusLabel(s: string): string {
  switch (s) {
    case 'matched':    return 'ждёт заполнения пула'
    case 'confirmed':  return 'готов к отгрузке'
    case 'dispatched': return 'отгружено'
    case 'delivered':  return 'принято'
    default:           return ''
  }
}

function SplitPanel({ batch }: { batch: Batch }) {
  const allocs = Array.isArray(batch.allocations) ? batch.allocations : []
  const total = typeof batch.heads === 'number' ? batch.heads : 0
  const matched = typeof batch.matchedHeads === 'number' ? batch.matchedHeads : 0
  const remaining = typeof batch.remainingHeads === 'number'
    ? batch.remainingHeads
    : Math.max(total - matched, 0)
  if (allocs.length === 0 && matched === 0) return null

  const pct = total > 0 ? Math.min(Math.round((matched / total) * 100), 100) : 0
  // Остаток снят: батч ушёл из matchable-набора (matched/confirmed), но продан не весь.
  // В обычном потоке matched достигается только при matched==total, поэтому расхождение = снятый остаток.
  const withdrawn = remaining > 0 && (batch.state === 'matched' || batch.state === 'confirmed')

  return (
    <div className="bat-split" style={{ padding: '0 16px 8px' }}>
      <div className="bat-split-head" style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 6 }}>
        <span className="bat-kv-k">Продано {matched} из {total} гол.</span>
        {remaining > 0 && (
          <span className="bat-kv-v">{withdrawn ? `остаток снят (${remaining})` : `на рынке ещё ${remaining}`}</span>
        )}
      </div>
      <div className="bat-split-bar" style={{ height: 6, borderRadius: 3, background: 'rgba(0,0,0,0.08)', overflow: 'hidden' }}>
        <div style={{ width: `${pct}%`, height: '100%', background: 'var(--green, #2e9c5a)' }} />
      </div>
      {allocs.length > 0 && (
        <div style={{ marginTop: 10 }}>
          {allocs.map((a, i) => (
            <div className="bat-kv-row" key={i}>
              <span className="bat-kv-k">
                {a.heads} гол. · {fmtMoney(a.price)}{NBSP}₸/кг
                {chunkStatusLabel(a.status) ? ` · ${chunkStatusLabel(a.status)}` : ''}
              </span>
              <span className="bat-kv-v">
                {a.buyer
                  ? `${a.buyer}${a.buyerPhone ? ` · ${a.buyerPhone}` : ''}`
                  : 'Покупатель · скрыт до закрытия сделки'}
              </span>
            </div>
          ))}
        </div>
      )}
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
    case 'partial': {
      // Часть партии уже продана (matched/подтверждённые куски). Снятие идёт через
      // rpc_self_withdraw_batch (Слайс 9 S1b): остаток — безплатно, matched-куски —
      // за штраф, подтверждённые — нельзя. Сценарии выбираются в WithdrawSheet.
      // Слайс 9 S3: куски со статусом confirmed (их пул заполнился) можно ОТГРУЗИТЬ,
      // не дожидаясь распродажи остатка — по-кусковая отгрузка (rpc_self_dispatch_ready).
      const allocs = Array.isArray(batch.allocations) ? batch.allocations : []
      const readyHeads = allocs.filter((a) => a.status === 'confirmed').reduce((s, a) => s + a.heads, 0)
      return (
        <>
          <div className="bat-warn-note">Часть партии уже продана. Остаток продолжает продаваться автоматически.</div>
          {readyHeads > 0 && (
            <Cta variant="primary-green" onClick={() => openSheet('dispatch')}>
              Отгрузить готовое ({readyHeads} гол.)
            </Cta>
          )}
          <Cta variant="danger" onClick={() => openSheet('withdraw')}>Снять с продажи</Cta>
        </>
      )
    }
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
  const grade = gradeLabel(batch)
  const details: [string, string | number | undefined][] = [
    ['Сорт', grade ?? undefined],
    ['Порода', batch.breed],
    ['Средний вес', batch.avgWeight != null ? `${batch.avgWeight} кг` : undefined],
    ['Всего голов', batch.heads],
    ['Упитанность', batch.fatness],
    ['Возраст', batch.age != null ? `${batch.age} мес.` : undefined],
    ['Район', batch.district],
    ['Окно готовности', strField(batch, 'windowLabel')],
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

export function BatchScreen({ batch, account, onBack, onPatch, onNew, onReview, onTuran, toast }: Props) {
  const [sheet, setSheet] = useState<LocalSheet>(null)
  const def = STATUS[batch.state]

  const downloadDoc = () => {
    const ok = printDealDoc(buildFarmerDealDoc(batch, account))
    if (!ok) toast('Разрешите всплывающие окна, чтобы скачать документ')
  }

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

        {/* Слайс 9 — прогресс частичной продажи + покупатели по кускам. Показываем при
            partial, при нескольких кусках, либо когда остаток снят (matched/confirmed, но
            продан не весь) — иначе дублирует блок «Покупатель». */}
        {(batch.state === 'partial'
          || (Array.isArray(batch.allocations) && batch.allocations.length > 1)
          || ((batch.state === 'matched' || batch.state === 'confirmed')
              && typeof batch.matchedHeads === 'number' && typeof batch.heads === 'number'
              && batch.matchedHeads < batch.heads)) && (
          <SplitPanel batch={batch} />
        )}

        {/* Слайс 9 (S4) — документ сделки (печать → PDF). Доступен, когда сделка состоялась. */}
        {hasDeal(batch) && (
          <div style={{ padding: '0 16px 8px' }}>
            <Cta variant="ghost" onClick={downloadDoc}>Скачать документ сделки</Cta>
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
        onConfirm={(includeMatched) => {
          // partial/matched → rpc_self_withdraw_batch (сигнал _withdraw); остальные
          // состояния тоже безопасно проходят через тот же RPC (matched_heads=0 → cancelled).
          const hasSold = (typeof batch.matchedHeads === 'number' ? batch.matchedHeads : 0) > 0
          onPatch({ _withdraw: includeMatched ? 'matched' : 'remainder' })
          toast(
            includeMatched ? 'Партия снята — отмена проданного отмечена'
            : hasSold        ? 'Остаток снят с продажи'
            :                  'Партия снята с продажи',
          )
          setSheet(null)
        }}
      />
      <DispatchSheet
        batch={batch}
        open={sheet === 'dispatch'}
        onClose={() => setSheet(null)}
        onConfirm={() => {
          // Слайс 9 S3: по-кусковая отгрузка через rpc_self_dispatch_ready (сигнал
          // _dispatchReady). Отгружает все готовые (confirmed) куски; для цельного
          // confirmed-батча без кусков — легаси-фолбэк (confirmed→dispatched).
          onPatch({ _dispatchReady: true, dispatchedLabel: 'сегодня' })
          toast('Покупатель уведомлён об отгрузке')
          setSheet(null)
        }}
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
