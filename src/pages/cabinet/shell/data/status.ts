// AgOS · TSP-2 · STATUS словарь состояний партии + сортировка/фильтры для ListScreen.
// Источник истины — p1/data.jsx (STATUS) из контекст-файла §9.

import type { Batch } from '../types'
import { fmtMoney } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import { CATS } from './prices'

export interface StatusDef {
  chip: string                // текст чипа (= STATUS_CHIP из batches.ts)
  phrase: string              // крупная фраза состояния (Зона 1 BatchScreen)
  next: string                // «Что дальше» (Зона 1 BatchScreen)
  fact: (b: Batch) => string  // ключевой факт для BatchCard (строка 2)
}

const lbl = (b: Batch, key: string): string | undefined => {
  const v = (b as Record<string, unknown>)[key]
  return typeof v === 'string' ? v : undefined
}

export const STATUS: Record<string, StatusDef> = {
  draft: {
    chip: 'Черновик',
    phrase: 'Черновик не опубликован',
    next: 'Заполните все шаги и опубликуйте',
    fact: () => 'Не выставлена',
  },
  scheduled: {
    chip: 'Запланировано',
    phrase: 'Выйдет в продажу автоматически',
    next: 'Партия выйдет на рынок в назначенную дату',
    fact: (b) => { const p = lbl(b, 'publishAtLabel'); return p ? `Публикация ${p}` : 'Запланировано' },
  },
  published: {
    chip: 'В продаже',
    phrase: 'Партия опубликована',
    next: 'Ожидаем подходящего покупателя',
    fact: () => 'Ищем покупателя',
  },
  offering: {
    chip: 'У покупателей',
    phrase: 'Партия отправлена покупателям',
    next: 'Ждём ответа',
    fact: (b) => { const d = lbl(b, 'deadlineLabel'); return d ? `Дедлайн: ${d}` : 'Ждём ответа' },
  },
  decision: {
    chip: 'Нужно решение',
    phrase: 'Покупатели не согласились с ценой',
    next: 'Решите: снизить цену или ждать',
    fact: () => 'Требует решения',
  },
  matched: {
    chip: 'Покупатель найден',
    phrase: 'Покупатель подобран',
    next: 'Ожидайте подтверждения сделки',
    fact: (b) => b.dealPrice ? `Сделка: ${fmtMoney(b.dealPrice)}${NBSP}₸/кг` : 'Покупатель найден',
  },
  confirmed: {
    chip: 'Подтверждено',
    phrase: 'Сделка подтверждена',
    next: 'Нажмите «Партия отгружена» после отгрузки',
    fact: (b) => b.dealPrice ? `Сделка: ${fmtMoney(b.dealPrice)}${NBSP}₸/кг` : 'Подтверждено',
  },
  dispatched: {
    chip: 'В пути',
    phrase: 'Партия отгружена',
    next: 'Покупатель подтверждает приёмку',
    fact: () => 'В пути',
  },
  delivered: {
    chip: 'Доставлено',
    phrase: 'Партия принята покупателем',
    next: 'Оставьте отзыв о покупателе',
    fact: (b) => b.dealPrice ? `Итог: ${fmtMoney(b.dealPrice)}${NBSP}₸/кг` : 'Доставлено',
  },
  cancelled: {
    chip: 'Снято',
    phrase: 'Партия снята с продажи',
    next: 'Можно создать похожую партию',
    fact: () => 'Снято с продажи',
  },
}

// Сортировка для ListScreen — decision всегда первое
export const STATE_RANK: Record<string, number> = {
  decision: 0,
  offering: 1, published: 1, matched: 1, confirmed: 1, dispatched: 1, scheduled: 1, draft: 1,
  delivered: 2, cancelled: 2,
}

// Категории для фильтра ListScreen
export type ListFilter = 'all' | 'active' | 'done'

export const ACTIVE_STATES_SET = new Set([
  'scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched', 'draft',
])
export const DONE_STATES_SET = new Set(['delivered', 'cancelled'])

export function filterBatches(batches: Batch[], f: ListFilter): Batch[] {
  const filtered =
    f === 'active' ? batches.filter((b) => ACTIVE_STATES_SET.has(b.state))
    : f === 'done'   ? batches.filter((b) => DONE_STATES_SET.has(b.state))
    : batches
  return [...filtered].sort((a, b2) => (STATE_RANK[a.state] ?? 9) - (STATE_RANK[b2.state] ?? 9))
}

// Имя категории для карточки
export function catLabel(b: Batch): string {
  return b.cat ? (CATS[b.cat]?.name ?? 'Партия') : 'Черновик партии'
}

// Сорт партии (КРС · Высшая/Первая/Вторая) — тот же, по которому закупает МПК.
// Коды VS/S/NS приходят из fn_tsp_batch_grade. null/неизвестный → не показываем.
const GRADE_RU: Record<string, string> = { VS: 'Высшая', S: 'Первая', NS: 'Вторая' }
export function gradeLabel(b: Batch): string | null {
  const ru = b.grade ? GRADE_RU[b.grade] : undefined
  return ru ? `КРС · ${ru}` : null
}

// Защитная цена категории (для DecisionActions / BatchPriceSheet)
export function protPrice(b: Batch): number | null {
  return b.cat ? (CATS[b.cat]?.prot ?? null) : null
}
