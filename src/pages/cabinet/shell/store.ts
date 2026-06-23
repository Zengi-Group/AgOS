// AgOS · Этап 1 · Данные оболочки: словарь членства, способности, начальное состояние, tabOf.
// Тексты — слово в слово из прототипа shell/data.jsx и shell/app.jsx.

import type { MembershipStatus, Route, RouteName, ShellState } from './types'
import { MEMB_DATES } from './data/membership'
import { seedFarm } from './data/farm-seed'

export { MEMB_DATES }
export { FARM } from './data/farm-seed'

export const NBSP = ' '

// ---------- словарь членства · 9 состояний (shell/data.jsx) ----------
export interface MembershipPlate {
  tone: 'neutral' | 'amber' | 'gray'
  t: string
  cta: string | null
  act?: string
}
export interface MembershipEntry {
  cab: string
  cabSub?: string
  plate: MembershipPlate | null
}

// MEMB_DATES вычисляются от TODAY (data/membership.ts) — реэкспортированы выше.

export const MEMBERSHIP_DICT: Record<MembershipStatus, MembershipEntry> = {
  none: {
    cab: 'Не член ассоциации',
    plate: { tone: 'neutral', t: 'Вступите в TURAN — продажа партий, справочные цены, защита сделок', cta: 'Подать заявку', act: 'apply' },
  },
  pending: {
    cab: 'Заявка на рассмотрении',
    // БЕТА: админов нет — организация подтверждает членство сама (act 'selfjoin').
    plate: { tone: 'amber', t: 'Заявка отправлена. На бете членство можно подтвердить самостоятельно', cta: 'Подтвердить членство', act: 'selfjoin' },
  },
  rejected: {
    cab: 'Заявка отклонена',
    cabSub: 'Причина: нужна выписка о регистрации хозяйства',
    plate: { tone: 'gray', t: 'Заявка отклонена: нужна выписка о регистрации хозяйства', cta: 'Подать заново', act: 'apply' },
  },
  approved: {
    cab: 'Одобрено · взнос не оплачен',
    plate: { tone: 'amber', t: 'Вы член TURAN! Оплатите взнос до ' + MEMB_DATES.payApproved + ' — продажа уже доступна', cta: 'Оплатить взнос', act: 'pay' },
  },
  active: {
    cab: 'Членство активно до ' + MEMB_DATES.activeTill,
    plate: null,
  },
  expiring: {
    cab: 'Членство до ' + MEMB_DATES.expiringTill,
    plate: { tone: 'amber', t: 'Членство до ' + MEMB_DATES.expiringTill, cta: 'Продлить', act: 'pay' },
  },
  grace: {
    cab: 'Членство не продлено',
    plate: { tone: 'amber', t: 'Членство не продлено. Оплатите до ' + MEMB_DATES.payGrace + ', чтобы не потерять доступ', cta: 'Оплатить', act: 'pay' },
  },
  expired: {
    cab: 'Членство истекло',
    plate: { tone: 'gray', t: 'Членство истекло. Оплатите, чтобы вернуть доступ к продаже', cta: 'Оплатить', act: 'pay' },
  },
  terminated: {
    cab: 'Членство прекращено',
    plate: { tone: 'gray', t: 'Членство прекращено. Чтобы вернуться — подайте заявку заново', cta: 'Подать заявку', act: 'apply' },
  },
}

// ---------- маппинг членства БД → UI-кабинета (бета) ----------
// БД хранит level + статус последней заявки; UI — 9 статусов. Для беты (без оплаты/просрочки):
// level выше registered = реальный член → 'active'; иначе по последней заявке.
export function deriveMembership(level: string | null, applicationStatus: string | null): MembershipStatus {
  if (level && level !== 'registered') return 'active'
  if (applicationStatus === 'submitted' || applicationStatus === 'under_review') return 'pending'
  if (applicationStatus === 'rejected') return 'rejected'
  return 'none'
}

// ---------- способности (внутренние, в UI не показываются) ----------
export const CAN_SELL: MembershipStatus[] = ['approved', 'active', 'expiring', 'grace'] // создание и публикация партий
export const CAN_EXEC: MembershipStatus[] = [...CAN_SELL, 'expired'] // исполнение живых сделок (D8)
export const SEES_PRICES: MembershipStatus[] = CAN_SELL // блок «Цены TURAN»

export const sellOk = (m: MembershipStatus) => CAN_SELL.includes(m)
export const execOk = (m: MembershipStatus) => CAN_EXEC.includes(m)
export const gated = (m: MembershipStatus) => !CAN_EXEC.includes(m)

// ---------- таб для маршрута (shell/app.jsx tabOf) ----------
const TAB_MAP: Record<string, RouteName> = {
  home: 'home', services: 'home', cabinet: 'home',
  farm: 'farm',
  market: 'market', p1list: 'market', batch: 'market', review: 'market',
  shop: 'shop',
  messages: 'messages', thread: 'messages',
  turan: 'home',
}
export const tabOf = (r: Route): RouteName => TAB_MAP[r.name] ?? 'home'

// ---------- начальное состояние ----------
export const STORAGE_KEY = 'agos.cabinet.v1'

export const INITIAL_STATE: ShellState = {
  membership: 'active',
  isPro: false,
  route: { name: 'home' },
  batches: [],
  notifs: [],
  aiLog: [],
  newsOn: true,
  profileIncomplete: true,
  farmUnread: true,
  turanUnread: false,
  farm: seedFarm(),
}
