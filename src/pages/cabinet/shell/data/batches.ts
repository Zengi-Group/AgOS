// AgOS · Этап 2 · Партии: сид-данные, пресеты сборок, имя категории, статус-чипы.
// Перенесено из прототипов p1/data.jsx (seedBatches) и shell/data.jsx (shellBatchesPreset).

import { addDays, fmtD, monthEnd, TODAY } from './fmt'
import { CATS } from './prices'
import type { Batch } from '../types'

export const catName = (b: Batch): string => (b.cat ? (CATS[b.cat]?.name ?? 'Партия') : 'Черновик партии')

// статус-чип (минимум для ярусов Главной; STATUS из p1/data.jsx)
export const STATUS_CHIP: Record<string, string> = {
  draft: 'Черновик', scheduled: 'Запланировано', published: 'В продаже', offering: 'У покупателей',
  decision: 'Нужно решение', matched: 'Покупатель найден', confirmed: 'Подтверждено',
  dispatched: 'В пути', delivered: 'Доставлено', cancelled: 'Снято',
}

export const ACTIVE_STATES = ['scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched']

const D = (n: number) => fmtD(addDays(TODAY, n))

// стартовые партии (раздел 16)
export function seedBatches(): Batch[] {
  return [
    { id: 'b1', cat: 'bychki', heads: 40, avgWeight: 450, age: 24, breed: 'Казахская белоголовая',
      fatness: 'Хорошая', district: 'Сайрамский район', price: 1600, dealPrice: null, state: 'offering',
      deadlineLabel: 'завтра, 14:30',
      history: [
        { t: 'Создана', d: D(-1) }, { t: 'Выставлена на продажу', d: D(-1) }, { t: 'Отправлена покупателям', d: fmtD(TODAY) },
      ] },
    { id: 'b2', cat: 'bychki', heads: 30, avgWeight: 460, age: 25, breed: 'Казахская белоголовая',
      fatness: 'Хорошая', district: 'Сайрамский район', price: 1700, dealPrice: null, state: 'decision',
      history: [
        { t: 'Создана', d: D(-7) }, { t: 'Выставлена на продажу', d: D(-7) },
        { t: 'Отправлена покупателям', d: D(-6) }, { t: 'Окно ответа истекло — покупатели не согласились', d: D(-1) },
      ] },
    { id: 'b3', cat: 'telki', heads: 12, avgWeight: 380, age: 20, breed: 'Ангус',
      fatness: 'Хорошая', district: 'Сайрамский район', price: 1700, dealPrice: 1750, state: 'matched',
      history: [
        { t: 'Создана', d: D(-4) }, { t: 'Выставлена на продажу', d: D(-4) }, { t: 'Покупатель найден', d: D(-1) },
      ] },
    { id: 'b4', cat: 'molodnyak', heads: 25, avgWeight: 260, age: 9, breed: 'Симментал',
      fatness: 'Средняя', district: 'Сайрамский район', price: 1350, dealPrice: null, state: 'scheduled',
      publishAtLabel: '3 августа',
      history: [
        { t: 'Создана', d: D(-2) }, { t: 'Запланирована публикация на 3 августа', d: D(-2) },
      ] },
    { id: 'b5', cat: 'bychki', heads: 30, avgWeight: 430, age: 22, breed: 'Казахская белоголовая',
      fatness: 'Хорошая', district: 'Сайрамский район', price: 1550, dealPrice: 1580, state: 'delivered',
      review: null,
      history: [
        { t: 'Создана', d: D(-21) }, { t: 'Выставлена на продажу', d: D(-21) }, { t: 'Покупатель найден', d: D(-18) },
        { t: 'Сделка подтверждена', d: D(-15) }, { t: 'Отгружена', d: D(-3) }, { t: 'Принята покупателем', d: D(-2) },
      ] },
  ]
}

void monthEnd // зарезервировано прототипом для окон публикации

// сборки D1–D9 (shell/data.jsx shellBatchesPreset)
export function shellBatchesPreset(kind: string): Batch[] {
  const all = seedBatches()
  if (kind === 'none') return []
  if (kind === 'calm') return all.filter((b) => ['offering', 'scheduled', 'matched'].includes(b.state))
  if (kind === 'avral') return all.filter((b) => ['decision', 'offering', 'matched'].includes(b.state))
  if (kind === 'shtil') return all.filter((b) => b.state === 'offering')
  if (kind === 'live') {
    return all.filter((b) => ['matched', 'offering', 'delivered'].includes(b.state)).map((b) => {
      if (b.state === 'matched') return { ...b, state: 'confirmed', history: [...(b.history || []), { t: 'Сделка подтверждена', d: fmtD(TODAY) }] }
      if (b.state === 'offering') return { ...b, state: 'dispatched', dealPrice: b.price, history: [...(b.history || []), { t: 'Покупатель найден', d: D(-3) }, { t: 'Сделка подтверждена', d: D(-2) }, { t: 'Отгружена', d: D(-1) }] }
      return b
    })
  }
  return all
}
