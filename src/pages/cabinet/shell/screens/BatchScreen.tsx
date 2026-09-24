// AgOS · TSP-2 · SCR-04 «Карточка партии» — реcкин под прототип (market.jsx BatchDetail):
// заголовок + верт. трекер .mk-trk + .mk-money + .mk-buyer + .mk-dec-blk (decision) +
// .mk-acc аккордеоны (данные/история) + kebab-меню вторичных действий.
// Вся логика сохранена: onPatch-сигналы (_withdraw/_dispatchReady), prot-валидация,
// deal-doc, 3 шторки (Withdraw/Dispatch/BatchPrice), haptics.
// ARS-754 (FR-008): партия продаётся только целиком — SplitPanel/«ПРОДАЖА ЧАСТЯМИ»
// и статус `partial` убраны с экранов фермера.

import { useState } from 'react'
import type { CSSProperties } from 'react'
import type { Batch } from '../types'
import { IonShellFrame } from '../components/IonShellFrame'
import { SubHead } from '../components/SubHead'
import { Sheet } from '../components/Sheet'
import { PhIcon, type PhIconName } from '../components/icons/PhIcon'
import { BatchMedia } from '../components/BatchMedia'
import { BatchAnimals } from '../components/BatchAnimals'
import { WithdrawSheet } from '../components/sheets/WithdrawSheet'
import { DispatchSheet } from '../components/sheets/DispatchSheet'
import { BatchPriceSheet } from '../components/sheets/BatchPriceSheet'
import { STATUS, protPrice, catLabel, gradeLabel } from '../data/status'
import { catName } from '../data/batches'
import { fmtMoney, batchSum } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import { printDealDoc, fmtDealDate, type DealDocData } from '../data/deal-doc'
// S2.1 (ARS-157, spec §7): тактильный отклик на отгрузке через Host Bridge (web no-op).
import { useHost } from '@/platform/host/HostContext'

interface FarmerAccount {
  name?: string | null
  bin?: string | null
  phone?: string | null
  district?: string | null
}

interface Props {
  batch: Batch
  account?: FarmerAccount | null
  // ARS-227: org фермера — для загрузки/чтения медиа партии (rpc_*_batch_media + бакет).
  orgId?: string | null
  onBack: () => void
  backLabel?: string
  // S4=A · C4+D7: successToast — тост показывается в CabinetApp.patchBatch ПОСЛЕ
  // сетевого round-trip (не оптимистично); офлайн действие гейтится там же.
  onPatch: (patch: Partial<Batch>, successToast?: string) => void
  onNew: () => void
  onReview: () => void
  onTuran: () => void
  toast: (text: string) => void
}

function strField(b: Batch, key: string): string | undefined {
  const v = (b as Record<string, unknown>)[key]
  return typeof v === 'string' ? v : undefined
}

// ── deal-doc (Слайс 9 S4) — сборка со стороны фермера (продавец) ─────────────
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

const DEAL_STATES = new Set(['matched', 'confirmed', 'dispatched', 'delivered'])
function hasDeal(batch: Batch): boolean {
  return DEAL_STATES.has(batch.state)
    && (batch.dealPrice != null
        || (Array.isArray(batch.allocations) && batch.allocations.length > 0))
}

function chunkStatusLabel(s: string): string {
  switch (s) {
    case 'matched':    return 'ждёт заполнения пула'
    case 'confirmed':  return 'готов к отгрузке'
    case 'dispatched': return 'отгружено'
    case 'delivered':  return 'принято'
    default:           return ''
  }
}

// ── Вертикальный трекер жизненного цикла (порт market-ui.jsx BatchPath, focus+peek) ──
const PATH_STAGES = [
  { t: 'Подготовка', d: 'Объём, качество, цена и сроки готовности к отгрузке.' },
  { t: 'Поиск покупателя', d: 'Лот в ленте у проверенных покупателей региона.' },
  { t: 'Сделка', d: 'Согласование условий, договор и реквизиты.' },
  { t: 'Отгрузка', d: 'Передача груза перевозчику и движение по маршруту.' },
  { t: 'Завершено', d: 'Приёмка, расчёт и закрывающие документы.' },
]
function stageIndex(state: string): number {
  if (state === 'draft' || state === 'scheduled') return 0
  if (state === 'published' || state === 'offering' || state === 'decision') return 1
  if (state === 'matched' || state === 'confirmed') return 2
  if (state === 'dispatched') return 3
  if (state === 'delivered') return 4
  return -1
}

function BatchPath({ batch }: { batch: Batch }) {
  const [expanded, setExpanded] = useState(false)
  if (batch.state === 'cancelled') return null
  const cur = stageIndex(batch.state)
  const nowPhrase = STATUS[batch.state]?.phrase ?? ''
  const deadline = strField(batch, 'deadlineLabel')
  const updated = strField(batch, 'updatedLabel')
  const N = PATH_STAGES.length
  const peekFrom = Math.max(0, cur - 1)
  const peekTo = Math.min(N - 1, cur + 1)
  const beforeN = peekFrom
  const afterN = N - 1 - peekTo
  const lastVisibleIdx = expanded ? N - 1 : peekTo

  const renderRow = (stg: { t: string; d: string }, i: number) => {
    const st = i < cur ? 'done' : i === cur ? 'now' : 'todo'
    const isHidden = !expanded && (i < peekFrom || i > peekTo)
    const isPeek = !expanded && !isHidden && i !== cur
    const isCap = i === lastVisibleIdx
    const desc = st === 'now' ? nowPhrase : stg.d
    let meta: React.ReactNode = null
    if (st === 'now') {
      meta = batch.state === 'offering' && deadline
        ? <>Сейчас <span className="mk-trk-dot">·</span> до {deadline}</>
        : <>Сейчас</>
    } else if (st === 'done' && i === cur - 1 && updated) {
      meta = updated
    }
    const cls = ['mk-trk-i', st]
    if (isHidden) cls.push('hidden')
    if (isPeek) cls.push('peek')
    if (isCap) cls.push('cap')
    return (
      <div key={stg.t} className={cls.join(' ')}>
        <span className="mk-trk-bul">
          {st === 'done' ? <PhIcon name="check" size={13} color="var(--bg-c)" /> : <span className="mk-mono">{i + 1}</span>}
        </span>
        <div className="mk-trk-bd">
          <div className="mk-trk-t">{stg.t}</div>
          <div className="mk-trk-d">{desc}</div>
          {meta && <div className="mk-trk-meta">{meta}</div>}
        </div>
      </div>
    )
  }

  return (
    <div className={'mk-trk ' + (expanded ? 'ex' : 'co')}>
      <button type="button" className={'mk-trk-more top' + (expanded || beforeN === 0 ? ' hidden' : '')}
        onClick={() => setExpanded(true)} tabIndex={expanded || beforeN === 0 ? -1 : 0}>
        +{beforeN} пройдено
      </button>
      {PATH_STAGES.map((stg, i) => renderRow(stg, i))}
      <button type="button" className={'mk-trk-more bot' + (expanded || afterN === 0 ? ' hidden' : '')}
        onClick={() => setExpanded(true)} tabIndex={expanded || afterN === 0 ? -1 : 0}>
        ещё {afterN}
        <span className="mk-trk-more-arr" aria-hidden><PhIcon name="chevronRight" size={12} /></span>
      </button>
      {N > 3 && (
        <button type="button" className={'mk-trk-collapse' + (expanded ? '' : ' hidden')}
          onClick={() => setExpanded(false)} tabIndex={expanded ? 0 : -1}>
          свернуть
        </button>
      )}
    </div>
  )
}

// ── Зоны ────────────────────────────────────────────────────────────────────
const HERO_TONE: Record<string, string> = {
  draft: 'neutral', scheduled: 'neutral', published: 'neutral', dispatched: 'neutral', cancelled: 'neutral',
  offering: 'amber', decision: 'amber', matched: 'green', confirmed: 'green', delivered: 'green',
}

function TierH({ label, count }: { label: string; count?: number }) {
  return (
    <div className="tier-h">
      <span className="tier-h-l">
        <span className="tier-label">{label}</span>
        {count != null && <span className="tier-count mk-mono">{count}</span>}
      </span>
    </div>
  )
}

function ZoneMoney({ batch }: { batch: Batch }) {
  const deal = batch.dealPrice != null
  const p = deal ? batch.dealPrice! : (batch.price ?? 0)
  if (!p) return null
  return (
    <div className={'mk-money tone-' + (HERO_TONE[batch.state] ?? 'neutral')}>
      <div className="mk-money-k">
        {deal ? 'Цена сделки' : 'Ваша цена'}
        {deal && <span className="mk-lockchip"><PhIcon name="lock" size={10} />зафиксирована</span>}
      </div>
      <div className="mk-money-v mk-mono">{fmtMoney(p)}{NBSP}₸/кг</div>
      <div className="mk-money-s">≈ {fmtMoney(batchSum(batch))}{NBSP}₸ за партию</div>
    </div>
  )
}

function BuyerCard({ batch }: { batch: Batch }) {
  const name = strField(batch, 'buyer')
  const phone = strField(batch, 'buyerPhone')
  if (!name) return null
  return (
    <div className="mk-buyer">
      <div className="mk-buyer-k">Покупатель</div>
      <div className="mk-buyer-n">{name}</div>
      {phone && <div className="mk-buyer-m mk-mono">{phone}</div>}
    </div>
  )
}

// ── DecisionActions (state=decision) — .mk-rec + .dec-act. Логика/prot сохранены ──
// ARS-755: проп toast убран — все три действия теперь ведут к записи цены и сообщают о
// результате через successToast самого onPatch (тост больше не выдаётся «на месте», без RPC).
function DecisionActions({ batch, onPatch }: {
  batch: Batch; onPatch: (p: Partial<Batch>, successToast?: string) => void
}) {
  const [customOn, setCustomOn] = useState(false)
  const [custom, setCustom] = useState('')
  const prot = protPrice(batch)
  const cur = batch.price ?? 0
  // ARS-755 FR-005: шаг приходит с партией из tsp_config (P4/P8). Ключа нет — подсказки нет.
  const step = typeof batch.priceStepDown === 'number' ? batch.priceStepDown : null
  const lowered = step != null ? cur - step : null
  // ARS-755 FR-003: защитная цена — ОРИЕНТИР, а не запрет. Подсказку ниже неё не предлагаем
  // сами, но ручной ввод ниже разрешён и записывается как введён (soft warning, D-M6-3).
  const lowerBlocked = lowered == null || lowered <= 0 || (prot != null && lowered < prot)
  // ARS-755 FR-006/M-006: тост называет то, что произошло на самом деле. «Оставить цену»
  // идёт через ту же запись цены (текущей) — но обещать «по новой цене» там было бы ложью.
  // `deadlineLabel` больше НЕ выдумывается (найдено ревью якоря 7): сервер ставит партию в
  // `published` и при смене цены гасит старые предложения, так что срока ответа в этот
  // момент не существует ни одного. Прежний хардкод «завтра, 14:30» печатал фермеру
  // несуществующий дедлайн — тот же класс лжи, который чинит слайс. Настоящий срок
  // приезжает с ближайшим рефетчем (deadlineLabel из fn_tsp_batch_json).
  const applyPrice = (newPrice: number, successToast?: string) => {
    onPatch(
      { state: 'offering', price: newPrice, deadlineLabel: undefined },
      // ARS-755 M-001 (сверка замысел↔реальность, прогон 2): тост НАЗЫВАЕТ записанную цену.
      // Строка матрицы требует «тост называет 1600» — константа «по новой цене» этого не
      // делает, а весь слайс про то, что подтверждённое фермеру число и записанное совпадают.
      successToast ?? `Предложение отправлено покупателям по ${fmtMoney(newPrice)}${NBSP}₸/кг`,
    )
  }
  const customNum = parseInt(custom, 10)
  // ARS-755 FR-002: верхней границы нет, жёсткой нижней нет — активна для любого целого > 0.
  const customValid = !Number.isNaN(customNum) && customNum > 0
  const customBelowProt = prot != null && !Number.isNaN(customNum) && customNum < prot
  const recPrice = lowered

  if (customOn) {
    return (
      <div className="dec-row"><div className="dec-row-body">
        <label className="mk-field">
          <span className="mk-lab">Своя цена, ₸/кг</span>
          <input className="mk-input mk-mono price" inputMode="numeric" value={custom} autoFocus
            // ARS-755 FR-002 (сверка замысел↔реальность): верхней границы ввода нет —
            // прежний `.slice(0, 5)` был потолком 99 999 ₸/кг, которого замысел не вводил.
            // Остаётся только фильтр цифр; сумму отвергает сервер, а не длина поля.
            onChange={(e) => setCustom(e.target.value.replace(/\D/g, ''))} />
        </label>
        {/* ARS-755 FR-004: правило названо словами ДО нажатия. */}
        <div className="mk-hint">Цену назначаете вы — можно поднять, снизить или оставить прежней.</div>
        {/* ARS-755 FR-008: факт без совета — экран не комментирует решение фермера о цене.
            После ARS-760 в точку решения попадает только партия, которой отказали. */}
        <div className="mk-hint">По {fmtMoney(cur)}{NBSP}₸/кг покупателей не нашлось.</div>
        {/* ARS-755 FR-003: защитная цена остаётся ориентиром, ввод ниже разрешён. */}
        {prot != null && (
          <div className="mk-hint">Защитная цена ассоциации — {fmtMoney(prot)}{NBSP}₸/кг.</div>
        )}
        {customBelowProt && (
          <div className="bat-warn-note" style={{ marginTop: 6 }}>Ниже защитного уровня — назначить можно, цена запишется как введена.</div>
        )}
        <div className="dec-row-actions stack">
          <button className="dec-act primary" disabled={!customValid} onClick={() => customValid && applyPrice(customNum)}>
            Предложить по {custom ? fmtMoney(customNum) : '—'}{NBSP}₸/кг
          </button>
          <button className="dec-act link" onClick={() => { setCustomOn(false); setCustom('') }}>Отмена</button>
        </div>
      </div></div>
    )
  }
  return (
    <div className="dec-row"><div className="dec-row-body">
      {/* ARS-755 FR-005: блок подсказки ассоциации сохранён (HS-2), но число — из настройки.
          Шага нет (ключ пуст) или подсказка ушла бы ниже защитной — блок не показываем. */}
      {!lowerBlocked && (
        <div className="mk-rec">
          <div className="mk-rec-k">Рекомендуем</div>
          <div className="mk-rec-v mk-mono">{fmtMoney(recPrice!)}{NBSP}₸/кг</div>
          <div className="mk-rec-s">
            было <span className="mk-mono">{fmtMoney(cur)}{NBSP}₸/кг</span>
            {' '}· ≈ <span className="mk-mono">{fmtMoney(recPrice! * (batch.heads ?? 0) * (batch.avgWeight ?? 0))}{NBSP}₸</span> за партию
          </div>
        </div>
      )}
      {/* ARS-755 M-011 (сверка замысел↔реальность): строка матрицы называет состоянием
          «экран точки решения», а не «форма ввода», — факт должен быть виден ДО нажатия.
          Совета при этом нет никакого (FR-008, ст. 171). */}
      <div className="mk-hint">По {fmtMoney(cur)}{NBSP}₸/кг покупателей не нашлось.</div>
      {/* ARS-755 FR-003: защитная цена — ориентир, и число видно НА САМОМ экране решения,
          а не только внутри формы своей цены (найдено ревью якоря 7: иначе фермер выбирает
          вслепую, пока не откроет ввод). Запрета за собой не несёт. */}
      {prot != null && (
        <div className="mk-hint">Защитная цена ассоциации — {fmtMoney(prot)}{NBSP}₸/кг.</div>
      )}
      {/* ARS-755 FR-004: правило названо словами до нажатия — и на первом экране тоже. */}
      <div className="mk-hint">Цену назначаете вы — можно поднять, снизить или оставить прежней.</div>
      <div className="dec-row-actions stack">
        {!lowerBlocked && (
          <button className="dec-act primary" onClick={() => applyPrice(recPrice!)}>Снизить и предложить снова</button>
        )}
        <button className="dec-act alt" onClick={() => setCustomOn(true)}>Назначить свою цену</button>
        {/* ARS-755 FR-006: действие исполняет своё обещание — партия ВОЗВРАЩАЕТСЯ на рынок
            с неизменной ценой (та же RPC с текущей ценой; событие returned_to_published).
            Раньше здесь был только тост, и текст «остаётся в продаже» был неправдой. */}
        {/* Цены у партии может не быть вовсе (`price` из fn_tsp_batch_json — coalesce
            фермерской и справочной, обе могут быть пусты): тогда `cur` = 0, и действие
            ушло бы в RPC нулём и вернулось сырым INVALID_INPUT на ход «ничего не меняю».
            Нечего оставлять — нечего и предлагать (найдено ревью якоря 7). */}
        {cur > 0 && (
          <button
            className="dec-act link"
            onClick={() => applyPrice(cur, 'Партия снова в продаже по прежней цене. TURAN оповестит, когда появится подходящий покупатель')}
          >
            Оставить цену и ждать
          </button>
        )}
      </div>
    </div></div>
  )
}

// ── Аккордеон (порт market.jsx AccItem) ─────────────────────────────────────
const chevronStyle = (open: boolean): CSSProperties => ({
  transform: open ? 'rotate(-90deg)' : 'rotate(90deg)', transition: 'transform 200ms var(--ease)',
})
function AccItem({ icon, title, defaultOpen, children }: {
  icon: PhIconName; title: string; defaultOpen?: boolean; children: React.ReactNode
}) {
  const [open, setOpen] = useState(!!defaultOpen)
  return (
    <div className={'mk-acc-item' + (open ? ' open' : '')}>
      <button className="mk-acc-head" onClick={() => setOpen((o) => !o)}>
        <span className="mk-acc-ic"><PhIcon name={icon} size={16} /></span>
        <span className="mk-acc-t">{title}</span>
        <span className="mk-acc-chev"><PhIcon name="chevronRight" size={15} style={chevronStyle(open)} /></span>
      </button>
      <div className="mk-acc-body"><div className="mk-acc-inner">{children}</div></div>
    </div>
  )
}

function HistoryTimeline({ items }: { items: { t: string; d: string }[] }) {
  const [open, setOpen] = useState(false)
  const collapsed = !open && items.length > 5
  const shown = collapsed ? items.slice(-4) : items
  const last = items[items.length - 1]
  return (
    <div className="mk-olist">
      {collapsed && <button className="mk-olist-more" onClick={() => setOpen(true)}>Показать всю историю · {items.length}</button>}
      {shown.map((h, i) => {
        const now = h === last
        return (
          <div className={'mk-oi' + (now ? ' now' : ' done')} key={i}>
            <span className="mk-oi-bul">{!now && <PhIcon name="check" size={11} color="var(--cta-fg)" />}</span>
            <div className="mk-oi-bd"><div className="mk-oi-t">{h.t}</div><div className="mk-oi-m mk-mono">{h.d}</div></div>
          </div>
        )
      })}
      {open && items.length > 5 && <button className="mk-olist-more" onClick={() => setOpen(false)}>Свернуть</button>}
    </div>
  )
}

// ── Kebab-меню вторичных действий (порт market.jsx ActionSheet) ─────────────
interface MenuAction { t: string; fn: () => void; icon?: PhIconName; danger?: boolean; help?: boolean }
function ActionMenu({ open, onClose, items }: { open: boolean; onClose: () => void; items: MenuAction[] }) {
  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">Действия с партией</div>
      <div className="mk-menu">
        {items.map((a) => (
          <button key={a.t} className={'mk-menu-item' + (a.danger ? ' danger' : a.help ? ' help' : '')}
            onClick={() => { onClose(); a.fn() }}>
            {a.icon && <span className="mk-menu-ic"><PhIcon name={a.icon} size={17} /></span>}
            <span className="mk-menu-t">{a.t}</span>
          </button>
        ))}
      </div>
    </Sheet>
  )
}

type LocalSheet = null | 'withdraw' | 'dispatch' | 'price'

export function BatchScreen({ batch, account, orgId, onBack, backLabel = 'Мои партии', onPatch, onNew, onReview, onTuran, toast }: Props) {
  const [sheet, setSheet] = useState<LocalSheet>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const host = useHost()   // S2.1: тактильный отклик на отгрузке (web no-op)
  const st = batch.state
  const grade = gradeLabel(batch)

  const downloadDoc = () => {
    const ok = printDealDoc(buildFarmerDealDoc(batch, account))
    if (!ok) toast('Разрешите всплывающие окна, чтобы скачать документ')
  }

  // Композиция действий по состоянию (порт market.jsx BatchDetail: caption/primary/menu).
  let caption: string | null = null
  let primary: { t: string; fn: () => void; green?: boolean } | null = null
  const menu: MenuAction[] = []
  if (st === 'draft') {
    caption = 'Продолжите заполнение, чтобы выставить партию на продажу.'
    primary = { t: 'Продолжить заполнение', fn: () => toast('Заполнение черновика откроется в следующем обновлении') }
    menu.push({ t: 'Удалить черновик', icon: 'trash', danger: true, fn: () => onPatch({ state: 'cancelled' }, 'Черновик удалён') })
  } else if (st === 'scheduled') {
    caption = 'Изменить данные можно до выхода в продажу.'
    menu.push({ t: 'Изменить партию', icon: 'pencil', fn: () => toast('Редактирование откроется в следующем обновлении') })
    menu.push({ t: 'Снять с продажи', icon: 'ban', danger: true, fn: () => setSheet('withdraw') })
  } else if (st === 'published') {
    menu.push({ t: 'Изменить цену', icon: 'tag', fn: () => setSheet('price') })
    menu.push({ t: 'Изменить партию', icon: 'pencil', fn: () => toast('Редактирование откроется в следующем обновлении') })
    menu.push({ t: 'Снять с продажи', icon: 'ban', danger: true, fn: () => setSheet('withdraw') })
  } else if (st === 'offering') {
    menu.push({ t: 'Снять с продажи', icon: 'ban', danger: true, fn: () => setSheet('withdraw') })
  } else if (st === 'matched') {
    // ARS-731 (FR-009): состояние без хода обязано называть, чего оно ждёт — иначе экран
    // молчит там, где фермер ищет кнопку отгрузки. Кнопки здесь по-прежнему нет: пока
    // сделка не подтверждена, отгружать нечего (MS4-BT-16 требует confirmed).
    // Предупреждение о штрафе СОХРАНЕНО — объяснение добавлено к нему, а не вместо него.
    // Текст говорит о ФАКТЕ («не закрыл»), а не о процессе («набирается»): `matched`
    // достижим и при заявке в awaiting_mpk_decision, где она уже не набирается и партия
    // может вернуться на рынок. Формулировка владельца 2026-09-18 (Spec Change Log).
    caption = 'Покупатель ещё не закрыл заявку — отгрузка откроется, когда закроет. '
      + 'Снятие может привести к штрафу.'
    menu.push({ t: 'Снять с продажи', icon: 'ban', danger: true, fn: () => setSheet('withdraw') })
  } else if (st === 'confirmed') {
    caption = 'Когда отгрузите партию — отметьте здесь.'
    primary = { t: 'Партия отгружена', green: true, fn: () => setSheet('dispatch') }
    menu.push({ t: 'Нужно отменить сделку? Обратитесь в TURAN', icon: 'chat', help: true, fn: onTuran })
  } else if (st === 'dispatched') {
    caption = `Отгружена${strField(batch, 'dispatchedLabel') ? ' ' + strField(batch, 'dispatchedLabel') : ''}. Покупатель подтвердит приёмку — обычно в день доставки.`
    menu.push({ t: 'Возникла проблема? Обратитесь в TURAN', icon: 'chat', help: true, fn: onTuran })
  } else if (st === 'delivered') {
    if (!batch.review) primary = { t: 'Оставить отзыв', fn: onReview }
  } else if (st === 'cancelled') {
    primary = { t: 'Создать похожую партию', fn: onNew }
  }

  const showStage = st !== 'cancelled' && st !== 'draft'
  const hasPrice = batch.price != null || batch.dealPrice != null
  const moneyLabel = batch.dealPrice != null ? 'ЦЕНА СДЕЛКИ' : 'ВАША ЦЕНА'
  const showBuyer = ['confirmed', 'dispatched', 'delivered'].includes(st) && !!strField(batch, 'buyer')

  const details: [string, string | number | undefined][] = [
    ['Сорт', grade ?? undefined],
    ['Порода', batch.breed],
    ['Возраст', batch.age != null ? `${batch.age} мес` : undefined],
    ['Упитанность', batch.fatness],
    ['Средний вес', batch.avgWeight != null ? `${batch.avgWeight} кг` : undefined],
    ['Всего голов', batch.heads],
    ['Район', batch.district],
    ['Окно готовности', strField(batch, 'windowLabel')],
  ]
  const detailRows = details.filter(([, v]) => v != null && v !== '')
  const history = batch.history ?? []

  return (
    <IonShellFrame noTabs label={`Партия · ${st}`}>
      <div className="mk">
        <SubHead
          onBack={onBack}
          backLabel={backLabel}
          right={menu.length > 0 ? (
            <button className="mk-kebab" aria-label="Действия с партией" onClick={() => setMenuOpen(true)}><PhIcon name="more" size={20} /></button>
          ) : undefined}
        />

        <header className="mk-bz-head">
          <h1 className="mk-bz-title">{catName(batch)}</h1>
          <div className="mk-bz-meta">
            <span className="mk-bz-meta__item"><b>{batch.heads}</b><span className="mk-bz-meta__unit">голов</span></span>
            <span className="mk-bz-meta__sep" aria-hidden="true" />
            <span className="mk-bz-meta__item"><span className="mk-bz-meta__pre">ср.</span><b>{batch.avgWeight} кг</b></span>
            {batch.district && <><span className="mk-bz-meta__sep" aria-hidden="true" /><span className="mk-bz-meta__place">{batch.district}</span></>}
          </div>
        </header>

        <div className="home-stack mk-bz-stack">
          {st === 'cancelled' && (
            <div className="mk-hero-cancel">
              <div className="mk-phrase"><span className="mk-phrase-dot" style={{ background: 'var(--fg3)' }} /><span>{STATUS[st]?.phrase ?? 'Партия снята'}</span></div>
            </div>
          )}

          {showStage && (
            <div className="blk mk-dec-blk"><BatchPath batch={batch} /></div>
          )}

          {st !== 'draft' && st !== 'decision' && hasPrice && (
            <div className="blk">
              <TierH label={moneyLabel} />
              <ZoneMoney batch={batch} />
            </div>
          )}

          {showBuyer && (
            <div className="blk">
              <TierH label="ПОКУПАТЕЛЬ" />
              <BuyerCard batch={batch} />
            </div>
          )}

          {(caption || primary) && (
            <div className="mk-actions">
              {caption && <div className="mk-caption">{caption}</div>}
              {primary && (
                <button className={'mk-cta ' + (primary.green ? 'green' : st === 'draft' || st === 'cancelled' ? 'primary' : 'green')} onClick={primary.fn}>
                  {primary.t}
                </button>
              )}
            </div>
          )}

          {st === 'decision' && (
            <div className="blk mk-dec-blk"><DecisionActions batch={batch} onPatch={onPatch} /></div>
          )}

          {hasDeal(batch) && (
            <div className="blk">
              <button className="mk-cta ghost" onClick={downloadDoc}>Скачать документ сделки</button>
            </div>
          )}

          {batch.state === 'delivered' && batch.review != null && (
            <div className="blk">
              <TierH label="ОТЗЫВ" />
              <div className="mk-infonote"><div className="mk-infonote-b">Ваш отзыв сохранён. Спасибо — это помогает другим фермерам.</div></div>
            </div>
          )}

          {/* ARS-227 · Фото и видео — редактируемо владельцем в draft|published,
              иначе только просмотр. Само-скрывается, если показывать нечего. */}
          <BatchMedia
            batchId={batch.id}
            orgId={orgId}
            editable={st === 'draft' || st === 'published'}
            toast={toast}
          />

          {/* ARS-228 · Детализация по животным (ИНЖ) — опционально, редактируемо
              владельцем в draft|published; heads остаётся источником правды (P3/P4/D20). */}
          <BatchAnimals
            batchId={batch.id}
            orgId={orgId}
            editable={st === 'draft' || st === 'published'}
            heads={batch.heads}
            toast={toast}
          />

          {st !== 'draft' && detailRows.length > 0 && (
            <div className="blk">
              <TierH label="ДАННЫЕ ПАРТИИ" />
              <div className="mk-acc">
                <AccItem icon="list" title="Данные партии" defaultOpen>
                  {detailRows.map(([k, v]) => (
                    <div className="mk-acc-row" key={k}><span className="mk-acc-k">{k}</span><span className="mk-acc-v">{v}</span></div>
                  ))}
                </AccItem>
              </div>
            </div>
          )}

          {history.length > 0 && (
            <div className="blk">
              <TierH label="ИСТОРИЯ" />
              <div className="mk-acc">
                <AccItem icon="history" title="История партии" defaultOpen={st === 'draft'}>
                  <HistoryTimeline items={history} />
                </AccItem>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* kebab-меню + шторки — вне .mk чтобы перекрывали весь экран */}
      <ActionMenu open={menuOpen} onClose={() => setMenuOpen(false)} items={menu} />
      <WithdrawSheet
        batch={batch}
        open={sheet === 'withdraw'}
        onClose={() => setSheet((s) => (s === 'withdraw' ? null : s))}
        onConfirm={(includeMatched) => {
          onPatch(
            { _withdraw: includeMatched ? 'matched' : 'remainder' },
            includeMatched ? 'Партия снята — отмена проданного отмечена' : 'Партия снята с продажи',
          )
          setSheet(null)
        }}
      />
      <DispatchSheet
        batch={batch}
        open={sheet === 'dispatch'}
        onClose={() => setSheet((s) => (s === 'dispatch' ? null : s))}
        onConfirm={() => {
          onPatch({ _dispatchReady: true, dispatchedLabel: 'сегодня' }, 'Покупатель уведомлён об отгрузке')
          host.haptics('medium')   // S2.1: отгрузка — ключевое действие
          setSheet(null)
        }}
      />
      <BatchPriceSheet
        batch={batch}
        open={sheet === 'price'}
        onClose={() => setSheet((s) => (s === 'price' ? null : s))}
        onConfirm={(newPrice) => {
          // ARS-755 M-001/M-012: тост называет записанное число и во второй точке ввода.
          onPatch({ price: newPrice }, `Цена обновлена: ${fmtMoney(newPrice)}${NBSP}₸/кг`)
          setSheet(null)
        }}
      />
    </IonShellFrame>
  )
}
