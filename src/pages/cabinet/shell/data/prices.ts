// AgOS · Этап 2 · Цены TURAN: категории, история публикаций, дельты, связка со стадом,
// стикер хедера и шторка цен. Перенесено из прототипов p1/data.jsx и shell/data.jsx (слово в слово).

import { addDays, fmtDGen, TODAY } from './fmt'

export interface CatDef { name: string; rec: number; prot: number }

export const CATS: Record<string, CatDef> = {
  bychki:    { name: 'Бычки откормочные',   rec: 1550, prot: 1400 },
  telki:     { name: 'Тёлки племенные',     rec: 1700, prot: 1550 },
  korovy:    { name: 'Коровы (выбраковка)', rec: 1100, prot: 950  },
  molodnyak: { name: 'Молодняк до 12 мес',  rec: 1350, prot: 1200 },
}

export const SHORT_CAT: Record<string, string> = { bychki: 'Бычки', telki: 'Тёлки', korovy: 'Коровы', molodnyak: 'Молодняк' }

// 6 столбиков янв–июнь — тренд без цифр (последний тёмно-зелёный, предпоследний светлый)
export const PRICE_HISTORY: Record<string, number[]> = {
  bychki:    [1450, 1480, 1500, 1500, 1520, 1550],
  telki:     [1700, 1690, 1680, 1700, 1700, 1700],
  korovy:    [1180, 1150, 1130, 1120, 1100, 1100],
  molodnyak: [1300, 1320, 1330, 1340, 1340, 1350],
}

export type Trend = 'up' | 'down' | 'flat'
interface PriceDeltaDef { d: number; trend: Trend; note: string }
export const PRICE_DELTA: Record<string, PriceDeltaDef> = {
  bychki:    { d: 50,  trend: 'up',   note: '+50 за месяц · растёт 3 публикации подряд' },
  telki:     { d: 0,   trend: 'flat', note: 'без изменений за месяц' },
  korovy:    { d: -30, trend: 'down', note: '−30 за месяц' },
  molodnyak: { d: 10,  trend: 'up',   note: '+10 за месяц' },
}

export interface HerdLink { group: string; heads: number; avgW: number }
// связка со стадом (Группы seedFarm). null = в стаде нет этой товарной группы.
export const HERD_FOR_CAT: Record<string, HerdLink | null> = {
  bychki:    { group: 'Откорм', heads: 38, avgW: 440 },
  korovy:    { group: 'Выбраковка', heads: 9, avgW: 480 },
  telki:     { group: 'Тёлки ремонтные', heads: 18, avgW: 310 },
  molodnyak: null,
}

export const PRICE_NEXT = fmtDGen(addDays(TODAY, 14))
export const PRICE_CAT_ORDER = ['bychki', 'telki', 'korovy', 'molodnyak']
export const FARMER_LEAD_CAT = 'bychki' // ведущая группа стада (Откорм)

export interface StickerData {
  catKey: string
  name: string
  short: string
  price: number
  prot: number
  trend: Trend
  arrow: string
  delta: number
  note: string
  bars: number[]
  herd: HerdLink | null
}

export function stickerData(catKey: string, trendOverride?: string): StickerData {
  const key = CATS[catKey] ? catKey : FARMER_LEAD_CAT
  const cat = CATS[key]!
  const dl = PRICE_DELTA[key]!
  const trend: Trend = trendOverride && trendOverride !== 'auto' ? (trendOverride as Trend) : dl.trend
  const arrow = trend === 'up' ? '▲' : trend === 'down' ? '▼' : '—'
  return {
    catKey: key, name: cat.name, short: SHORT_CAT[key] ?? '', price: cat.rec, prot: cat.prot,
    trend, arrow, delta: dl.d,
    note: trend === dl.trend ? dl.note : (trend === 'up' ? 'рост за месяц' : trend === 'down' ? 'снижение за месяц' : 'без изменений'),
    bars: PRICE_HISTORY[key] ?? [], herd: HERD_FOR_CAT[key] ?? null,
  }
}

export function herdValueMln(h: HerdLink, price: number): number {
  return Math.round(h.heads * h.avgW * price / 1e5) / 10
}
