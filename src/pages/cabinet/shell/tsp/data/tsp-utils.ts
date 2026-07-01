// AgOS · TSP-1 · Утилиты визарда — слово в слово из p1/data.jsx + p1/wizard.jsx.

import { NBSP } from './tsp-dicts'
import type { Batch, CatKey, WizState } from '../types/batch'

// Форматирование денег — NBSP как разделитель тысяч
export function fmtMoney(n: number): string {
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, NBSP)
}

// Даты — точно как в прототипе
const MON_SHORT = ['янв','фев','мар','апр','мая','июн','июл','авг','сен','окт','ноя','дек']
const MON_GEN   = ['января','февраля','марта','апреля','мая','июня','июля',
                   'августа','сентября','октября','ноября','декабря']
export const TODAY = new Date()
export const fmtD    = (d: Date) => d.getDate() + ' ' + MON_SHORT[d.getMonth()]
export const fmtDGen = (d: Date) => d.getDate() + ' ' + MON_GEN[d.getMonth()]
export const addDays  = (d: Date, n: number) => { const x = new Date(d); x.setDate(x.getDate() + n); return x }
export const monthEnd   = (d: Date) => new Date(d.getFullYear(), d.getMonth() + 1, 0)
export const monthStart = (d: Date, plus: number) => new Date(d.getFullYear(), d.getMonth() + plus, 1)

// Автоопределение категории — точно из прототипа, НЕ МЕНЯТЬ логику
export function deriveCategory(w: WizState): CatKey | null {
  if (w.breed === 'Смешанная/другая') return null
  if (w.age <= 12) return 'molodnyak'
  if (w.age >= 60) return 'korovy'
  if (w.age <= 36) return 'bychki'
  return 'telki'
}

// ── Единая формула сорта МПК (упитанность + порода + вес + возраст) ─────────────
// Тот же расчёт, что бэкенд применяет к grade_standard_id партии
// (fn_tsp_grade_id_from_fatness): упитанность — основа сорта. Фермер видит, к какой
// закупаемой категории МПК относится его скот, ещё на этапе ввода данных.
//   Хорошая      → Высшая (Премиум, если элитная порода и вес ≥ 450 кг) · сорт VS
//   Средняя      → Первая  · сорт S
//   Ниже средней → Вторая  · сорт NS
export type MpkSort = 'premium' | 'vysshaya' | 'pervaya' | 'vtoraya'

export const MPK_SORT_LABEL: Record<MpkSort, string> = {
  premium:  'Премиум',
  vysshaya: 'Высшая',
  pervaya:  'Первая',
  vtoraya:  'Вторая',
}

// Элитные мясные породы — синхронно с fn_tsp_resolve_sku (breed_group='elite_meat').
const ELITE_BREED_RE = /ангус|герефорд|абердин|вагю|wagyu|angus|hereford|шароле|лимузин|limousin|charolais|симмент/i

export function deriveMpkGrade(
  w: Pick<WizState, 'breed' | 'avgWeight' | 'age' | 'fatness'>,
): MpkSort | null {
  let sort: MpkSort | null =
    w.fatness === 'Хорошая'      ? 'vysshaya'
    : w.fatness === 'Средняя'      ? 'pervaya'
    : w.fatness === 'Ниже средней' ? 'vtoraya'
    : null
  if (sort === 'vysshaya' && ELITE_BREED_RE.test(w.breed) && w.avgWeight >= 450) {
    sort = 'premium'
  }
  return sort
}

// Пресеты окна готовности
export interface WindowPreset {
  k: string; t: string; from?: Date; to?: Date
}
export function windowPresets(): WindowPreset[] {
  const t = TODAY
  return [
    { k: 'now', t: 'Готовы сейчас',        from: t,                  to: addDays(t, 14) },
    { k: 'm0',  t: 'В этом месяце',        from: t,                  to: monthEnd(t) },
    { k: 'm1',  t: 'В следующем месяце',   from: monthStart(t, 1),   to: monthEnd(monthStart(t, 1)) },
    { k: 'm2',  t: 'Через 2 месяца',       from: monthStart(t, 2),   to: monthEnd(monthStart(t, 2)) },
    { k: 'own', t: 'Указать свои даты' },
  ]
}

// Вычислить объект окна из wizard state
export function wizWindow(w: WizState): { from: Date; to: Date } | null {
  const ps = windowPresets().find((p) => p.k === w.windowPreset)
  if (!ps) return null
  if (ps.k === 'own') {
    if (!w.customFrom || !w.customTo) return null
    return { from: new Date(w.customFrom), to: new Date(w.customTo) }
  }
  return ps.from && ps.to ? { from: ps.from, to: ps.to } : null
}

// Нужна ли отложенная публикация (партия выйдет за 7 дней до окна)?
export function publishInfo(win: { from: Date; to: Date } | null) {
  if (!win) return null
  const lead = Math.round((win.from.getTime() - TODAY.getTime()) / 86400000)
  if (lead > 7) return { delayed: true, at: addDays(win.from, -7) }
  return { delayed: false }
}

// Ориентировочная сумма партии
export const batchSum = (b: Pick<Batch, 'heads' | 'avgWeight' | 'price' | 'dealPrice'>) => {
  const p = b.dealPrice ?? b.price ?? 0
  return (b.heads ?? 0) * (b.avgWeight ?? 0) * p
}
