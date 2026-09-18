// AgOS · Slice11 (ARS-718) · Модель раздела «Мои заявки» десктопной консоли МПК.
//
// Чистые функции без React и без сети: раскладка по вкладкам, счётчики, подписи статуса,
// причина закрытия, средняя цена строки. Вынесены сюда, а не в компонент, ровно затем,
// чтобы строки матрицы (M-001, M-017) проверялись без монтирования экрана.
//
// ДОМ РАСКЛАДКИ ОДИН (P4). Мобильный шелл схлопывает статусы в `PoolStatus`
// (`data/pools-load.ts` → `mapStatus`); десктоп раскладывает по вкладкам от СЫРОГО
// `pools.status` (`Pool.dbStatus`), как требует FR-004: `closed_unfilled`,
// `expired_empty` и `cancelled` дают один и тот же `PoolStatus = 'closed'`, и по
// схлопнутому значению вкладку «Не состоялись» от «Завершённые» отличить ещё можно,
// а причину закрытия (FR-010) — уже нет.

import { mpkCatName, type Pool } from '../types'

export type RequestsTab = 'all' | 'filling' | 'decision' | 'shipping' | 'done' | 'failed'
/** Вкладка, в которую попадает заявка. «Все» — не исход раскладки, а объединение. */
export type RequestsBucket = Exclude<RequestsTab, 'all'>

export const REQUESTS_TABS: { id: RequestsTab; label: string }[] = [
  { id: 'all', label: 'Все' },
  { id: 'filling', label: 'Набираются' },
  { id: 'decision', label: 'Требуют решения' },
  { id: 'shipping', label: 'Отгрузка и приёмка' },
  { id: 'done', label: 'Завершённые' },
  { id: 'failed', label: 'Не состоялись' },
]

const TAB_IDS = REQUESTS_TABS.map((t) => t.id)

/** Слаг вкладки из URL (`?tab=`). Неизвестный или отсутствующий → «Все» (M-005). */
export function tabFromParam(raw: string | null): RequestsTab {
  return raw && (TAB_IDS as string[]).includes(raw) ? (raw as RequestsTab) : 'all'
}

// FR-004 · раскладка от статуса в базе. Перечень сверен с `pools_status_check`
// (`d02_tsp.sql:1330`) — названы все 15 разрешённых значений, включая легаси-шестёрку
// (`filled`, `dispatched`, `delivered`, `executing`, `executed`, `closed`): их пишет
// `rpc_self_advance_pool_status`, функция открыта роли `authenticated`, и слайс этот путь
// не отменяет (FR-014; дом перевода на канонические статусы — ARS-314).
const BUCKET_BY_STATUS: Record<string, RequestsBucket> = {
  draft: 'filling',
  filling: 'filling',
  awaiting_mpk_decision: 'decision',
  closed_filled: 'shipping',
  closed_partial: 'shipping',
  executing: 'shipping',
  filled: 'shipping',
  dispatched: 'shipping',
  delivered: 'shipping',
  completed: 'done',
  executed: 'done',
  closed_unfilled: 'failed',
  expired_empty: 'failed',
  cancelled: 'failed',
  closed: 'failed',
}

/** FR-004: статус, не названный в перечне, попадает в «Не состоялись» и не теряется
 *  из «Все». То же и для заявки без `dbStatus`: угадывать вкладку по схлопнутому
 *  фронтовому статусу нельзя — это и есть запрещённое «фронтовое схлопывание». */
export function bucketOf(pool: Pool): RequestsBucket {
  return BUCKET_BY_STATUS[pool.dbStatus ?? ''] ?? 'failed'
}

/** Счётчик каждой вкладки. `all` = число заявок: сумма остальных пяти равна ему
 *  ровно потому, что каждая заявка попадает в один бакет (M-001). */
export function tabCounts(pools: Pool[]): Record<RequestsTab, number> {
  const counts: Record<RequestsTab, number> = {
    all: pools.length, filling: 0, decision: 0, shipping: 0, done: 0, failed: 0,
  }
  for (const p of pools) counts[bucketOf(p)] += 1
  return counts
}

export function filterByTab(pools: Pool[], tab: RequestsTab): Pool[] {
  return tab === 'all' ? pools : pools.filter((p) => bucketOf(p) === tab)
}

// Подпись статуса в строке (FR-005) и тон чипа. Отдельные подписи у `closed_filled`
// и `closed_partial`: «набрана полностью» и «принято частично» — разные факты для
// закупщика, и оба уже случились, а не «закрыты».
const STATUS_LABEL: Record<string, { label: string; tone: 'blue' | 'amber' | 'green' | 'red' | 'neutral' }> = {
  draft: { label: 'Черновик', tone: 'neutral' },
  filling: { label: 'Набирается', tone: 'blue' },
  awaiting_mpk_decision: { label: 'Нужно ваше решение', tone: 'amber' },
  closed_filled: { label: 'Набрана — отгрузка', tone: 'green' },
  closed_partial: { label: 'Принято частично', tone: 'green' },
  executing: { label: 'Отгрузка', tone: 'green' },
  filled: { label: 'Набрана', tone: 'green' },
  dispatched: { label: 'В пути', tone: 'green' },
  delivered: { label: 'Доставлена', tone: 'green' },
  completed: { label: 'Завершена', tone: 'neutral' },
  executed: { label: 'Завершена', tone: 'neutral' },
  closed_unfilled: { label: 'Недобрала', tone: 'red' },
  expired_empty: { label: 'Не состоялась', tone: 'red' },
  cancelled: { label: 'Отменена', tone: 'red' },
  closed: { label: 'Закрыта', tone: 'red' },
}

export function statusLabel(pool: Pool): { label: string; tone: 'blue' | 'amber' | 'green' | 'red' | 'neutral' } {
  // Неизвестный статус НЕ выдаём за один из известных: показываем сырое значение.
  // Оператору честнее увидеть незнакомое слово, чем неверную подпись.
  return STATUS_LABEL[pool.dbStatus ?? ''] ?? { label: pool.dbStatus ?? 'Статус неизвестен', tone: 'neutral' }
}

/** FR-010 · причина закрытия — из статуса базы, а не из чисел: после возврата партий
 *  `filledHeads` обнуляется, и недобравшая заявка по числам неотличима от пустой.
 *  null — заявка не закрыта. */
export function closureReason(pool: Pool): { title: string; note: string } | null {
  switch (pool.dbStatus) {
    case 'closed_unfilled':
      return {
        title: 'Заявка недобрала',
        note: 'Набранного не хватило для закупки — партии вернулись поставщикам на рынок.',
      }
    case 'expired_empty':
      return {
        title: 'Заявка не набрала ни одной партии',
        note: 'За время действия заявки к ней не привязалась ни одна партия.',
      }
    case 'cancelled':
      return { title: 'Заявка отменена', note: 'Заявку отменили — набор по ней не ведётся.' }
    case 'closed':
      return { title: 'Заявка закрыта', note: 'Заявка закрыта вручную — набор по ней не ведётся.' }
    default:
      return null
  }
}

/** FR-005 · цена строки списка. У многострочной заявки — средняя по строкам, тем же
 *  правилом, что монитор мобильного шелла (`avgLinePrice`,
 *  `modals/PoolMonitorModal.tsx`): одно число не должно считаться двумя способами (P4).
 *  Второй дом формулы здесь — вынужденный: извлечь её в общий модуль нельзя, мобильные
 *  модалки слайс не правит (FR-014). Долг записан в `IMPL_DEBT`. */
export function avgLinePrice(pool: Pool): number {
  if (pool.lines.length === 0) return 0
  return Math.round(pool.lines.reduce((s, l) => s + l.price, 0) / pool.lines.length)
}

/** Показывать ли подпись «средняя» рядом с ценой (FR-005). */
export function isAvgPrice(pool: Pool): boolean {
  return pool.lines.length > 1
}

/** Категории заявки списком — подпись под названием строки. */
export function linesSummary(pool: Pool): string {
  return pool.lines.map((l) => mpkCatName(l.catKey)).join(' · ')
}

/** Прогресс набора в процентах, ограничен сотней: перенабор (`closed_filled` при
 *  overshoot) не должен рисовать полосу шире дорожки. */
export function fillPct(pool: Pool): number {
  if (pool.totalHeads <= 0) return 0
  return Math.min(100, Math.round((pool.filledHeads / pool.totalHeads) * 100))
}

/** FR-006 · заявка в точке выбора: из строки виден вход в решение. */
export function needsDecision(pool: Pool): boolean {
  return pool.dbStatus === 'awaiting_mpk_decision'
}
