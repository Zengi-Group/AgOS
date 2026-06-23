// AgOS · Этап 2 · Членство: динамические даты, сборки ярусов Главной D1–D9.
// Перенесено из прототипа shell/data.jsx (buildDecisions / buildObserve, слово в слово).

import { addDays, fmtDGen, fmtMoney, NBSP, TODAY } from './fmt'
import { catName, STATUS_CHIP } from './batches'
import type { Batch, MembershipStatus } from '../types'

// даты вычисляются от TODAY (как в прототипе)
export const MEMB_DATES = {
  payApproved: fmtDGen(addDays(TODAY, 18)),
  payGrace: fmtDGen(addDays(TODAY, 13)),
  activeTill: '15 марта 2027',
  expiringTill: fmtDGen(addDays(TODAY, 11)),
}

export interface DecisionAction { t: string; kind: 'primary' | 'ghost'; fn: () => void }
export interface DecisionCardModel { id: string; pri: number; src: string; due?: string; t: string; m?: string; actions: DecisionAction[] }
export interface ObserveItemModel { id: string; rank: number; dot: string; t: string; sub: string; src: string; onOpen: () => void }

export interface DecH {
  lower: (b: Batch) => void
  open: (b: Batch) => void
  dispatch: (b: Batch) => void
  review: (b: Batch) => void
  pay: () => void
  apply: () => void
  cabinet: () => void
  farm: () => void
}

interface BuildArgs { batches: Batch[]; membership: MembershipStatus; h: DecH }

// Ярус 1 «ТРЕБУЕТ РЕШЕНИЯ» — процесс остановлен, ждёт выбора/ответа. Сортировка pri↑.
export function buildDecisions({ batches, membership, h }: BuildArgs): DecisionCardModel[] {
  const cards: DecisionCardModel[] = []
  batches.filter((b) => b.state === 'decision').forEach((b) => cards.push({
    id: 'dec-' + b.id, pri: 2, src: 'ПРОДАЖА', due: 'ждёт вашего решения',
    t: catName(b) + ' · ' + b.heads + ' голов',
    m: 'Покупатели не согласились по ' + fmtMoney(b.price as number) + NBSP + '₸/кг',
    actions: [
      { t: 'Снизить до ' + fmtMoney((b.price as number) - 100) + NBSP + '₸/кг', kind: 'primary', fn: () => h.lower(b) },
      { t: 'Другие варианты', kind: 'ghost', fn: () => h.open(b) },
    ],
  }))
  if (membership === 'approved') cards.push({
    id: 'm-pay', pri: 0, src: 'ЧЛЕНСТВО TURAN', due: 'до ' + MEMB_DATES.payApproved,
    t: 'Оплатите взнос — продажа уже доступна',
    actions: [{ t: 'Оплатить взнос', kind: 'primary', fn: h.pay }, { t: 'Кабинет', kind: 'ghost', fn: h.cabinet }],
  })
  if (membership === 'expiring') cards.push({
    id: 'm-ext', pri: 0, src: 'ЧЛЕНСТВО TURAN', due: 'до ' + MEMB_DATES.expiringTill,
    t: 'Продлите членство',
    actions: [{ t: 'Продлить', kind: 'primary', fn: h.pay }, { t: 'Кабинет', kind: 'ghost', fn: h.cabinet }],
  })
  if (membership === 'grace') cards.push({
    id: 'm-grace', pri: 0, src: 'ЧЛЕНСТВО TURAN', due: 'до ' + MEMB_DATES.payGrace,
    t: 'Продлите членство — иначе доступ закроется',
    actions: [{ t: 'Оплатить', kind: 'primary', fn: h.pay }, { t: 'Кабинет', kind: 'ghost', fn: h.cabinet }],
  })
  if (membership === 'expired') cards.push({
    id: 'm-exp', pri: 1, src: 'ЧЛЕНСТВО TURAN',
    t: 'Членство истекло — оплатите, чтобы вернуть продажу',
    m: 'Текущие сделки можно довести до конца',
    actions: [{ t: 'Оплатить', kind: 'primary', fn: h.pay }],
  })
  if (membership === 'rejected') cards.push({
    id: 'm-rej', pri: 1, src: 'ЧЛЕНСТВО TURAN',
    t: 'Заявка отклонена', m: 'Причина: нужна выписка о регистрации хозяйства',
    actions: [{ t: 'Подать заново', kind: 'primary', fn: h.apply }],
  })
  if (membership === 'terminated') cards.push({
    id: 'm-term', pri: 1, src: 'ЧЛЕНСТВО TURAN',
    t: 'Членство прекращено', m: 'Чтобы вернуться — подайте заявку заново',
    actions: [{ t: 'Подать заявку', kind: 'primary', fn: h.apply }],
  })
  batches.filter((b) => b.state === 'confirmed').forEach((b) => cards.push({
    id: 'shp-' + b.id, pri: 1, src: 'ПРОДАЖА · СДЕЛКА',
    t: 'Отметьте отгрузку — ' + catName(b) + ', ' + b.heads + ' голов',
    actions: [{ t: 'Отгружена', kind: 'primary', fn: () => h.dispatch(b) }, { t: 'Открыть', kind: 'ghost', fn: () => h.open(b) }],
  }))
  return cards.sort((a, b) => a.pri - b.pri)
}

// Ярус 2 «ИДЁТ САМО» — процесс движется без меня. Сортировка по близости события.
const OBSERVE_SUB: Record<string, (b: Batch) => string> = {
  offering: (b) => 'ответ до ' + ((b.deadlineLabel as string) || 'завтра'),
  matched: () => 'покупатель найден · цена зафиксирована',
  published: () => 'в продаже — ждём покупателя',
  dispatched: () => 'в пути — ждём приёмку',
  scheduled: (b) => 'выйдет в продажу ' + ((b.publishAtLabel as string) || 'по плану'),
  delivered: () => 'доставлено · оцените сделку',
}
export const OBSERVE_RANK: Record<string, number> = { offering: 0, matched: 1, published: 2, dispatched: 3, scheduled: 4, delivered: 5 }

export function buildObserve({ batches, membership, h }: BuildArgs): ObserveItemModel[] {
  const items: ObserveItemModel[] = []
  batches
    .filter((b) => ['offering', 'matched', 'published', 'dispatched', 'scheduled'].includes(b.state) || (b.state === 'delivered' && !b.review))
    .forEach((b) => items.push({
      id: 'obs-' + b.id, rank: OBSERVE_RANK[b.state] ?? 9, dot: b.state,
      t: catName(b) + ' · ' + b.heads + ' голов',
      sub: (OBSERVE_SUB[b.state] || (() => STATUS_CHIP[b.state] ?? ''))(b),
      src: 'Продажа', onOpen: () => h.open(b),
    }))
  if (membership === 'pending') items.push({
    id: 'obs-pending', rank: 8, dot: 'gray',
    t: 'Заявка на рассмотрении', sub: 'ответ в течение 3 рабочих дней', src: 'Членство',
    onOpen: () => h.cabinet(),
  })
  return items.sort((a, b) => a.rank - b.rank)
}
