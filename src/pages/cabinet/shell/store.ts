// AgOS · Этап 1 · Данные оболочки: словарь членства, способности, начальное состояние, tabOf.
// Тексты — слово в слово из прототипа shell/data.jsx и shell/app.jsx.

import type { MembershipStatus, Route, RouteName, ShellState } from './types'
import { MEMB_DATES } from './data/membership'
import { fmtDGenYear } from './data/fmt'
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
    // Документы на проверке у ассоциации — решение придёт уведомлением (admin-гейт).
    plate: { tone: 'amber', t: 'Заявка на проверке у ассоциации. Сообщим о решении уведомлением', cta: null },
  },
  rejected: {
    cab: 'Заявка отклонена',
    cabSub: 'Причина: нужна выписка о регистрации хозяйства',
    plate: { tone: 'gray', t: 'Заявка отклонена: нужна выписка о регистрации хозяйства', cta: 'Подать заново', act: 'apply' },
  },
  approved: {
    cab: 'Заявка одобрена · взнос не оплачен',
    plate: { tone: 'amber', t: 'Заявка одобрена! Оплатите взнос до ' + MEMB_DATES.payApproved + ', чтобы открыть продажу на Рынке', cta: 'Оплатить взнос', act: 'pay' },
  },
  active: {
    // ARS-263 (B6): без хардкод-даты. Реальная дата продления добавляется
    // membershipEntry() из подписки (current_period_end). Демо/легаси без даты — «Членство активно».
    cab: 'Членство активно',
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

// ---------- маппинг членства БД → UI-кабинета ----------
// Источник истины (ARS-263, D-BILL-TRUTH-01): подписка. Зеркалит SQL-предикат
// fn_org_membership_active — живая подписка (trialing|active|grace) ИЛИ legacy level.
// Приоритет: подписка → legacy level → терминальная подписка (промпт продления) → заявка.
// subscriptionState опционален: null/недоступен → падаем на старую level+заявка-логику
// (легаси-члены и демо не ломаются).
export function deriveMembership(
  level: string | null,
  applicationStatus: string | null,
  subscriptionState?: string | null,
): MembershipStatus {
  // 1) живая подписка = канонический член (доступ ON)
  if (subscriptionState === 'trialing' || subscriptionState === 'active') return 'active'
  if (subscriptionState === 'grace') return 'grace'  // доступ ещё ON, но нужен платёж
  // 2) legacy level-stack член (старый флоу) — тоже активный член по предикату
  if (level && level !== 'registered') return 'active'
  // 3) нет активного членства: промпт из терминального состояния подписки (доступ OFF)
  if (subscriptionState === 'past_due' || subscriptionState === 'expired') return 'expired'
  // 4) иначе — по последней заявке (canceled без legacy/заявки → 'none')
  if (applicationStatus === 'approved') return 'approved'
  if (applicationStatus === 'submitted' || applicationStatus === 'under_review') return 'pending'
  if (applicationStatus === 'rejected') return 'rejected'
  return 'none'
}

// ARS-263 (B6): запись словаря с РЕАЛЬНЫМИ датами подписки вместо хардкода.
// Аддитивно поверх MEMBERSHIP_DICT (он остаётся фолбэком для легаси/демо/без дат).
// active  → «Членство активно до <current_period_end>»
// grace   → плашка «Оплатите до <next_billing_at || current_period_end>»
export function membershipEntry(
  membership: MembershipStatus,
  sub?: { currentPeriodEnd?: string | null; nextBillingAt?: string | null } | null,
): MembershipEntry {
  const base = MEMBERSHIP_DICT[membership]
  if (!sub) return base
  if (membership === 'active') {
    const till = fmtDGenYear(sub.currentPeriodEnd)
    return till ? { ...base, cab: 'Членство активно до ' + till } : base
  }
  if (membership === 'grace' && base.plate) {
    const deadline = fmtDGenYear(sub.nextBillingAt ?? sub.currentPeriodEnd)
    return deadline
      ? { ...base, plate: { ...base.plate, t: 'Членство не продлено. Оплатите до ' + deadline + ', чтобы не потерять доступ' } }
      : base
  }
  return base
}

// ---------- способности (внутренние, в UI не показываются) ----------
export const CAN_SELL: MembershipStatus[] = ['approved', 'active', 'expiring', 'grace'] // создание и публикация партий
export const CAN_EXEC: MembershipStatus[] = [...CAN_SELL, 'expired'] // исполнение живых сделок (D8)
export const SEES_PRICES: MembershipStatus[] = CAN_SELL // блок «Цены TURAN»

export const sellOk = (m: MembershipStatus) => CAN_SELL.includes(m)
export const execOk = (m: MembershipStatus) => CAN_EXEC.includes(m)
export const gated = (m: MembershipStatus) => !CAN_EXEC.includes(m)

// ---------- таб для маршрута (shell/app.jsx tabOf) ----------
// N-2: таб экрана = URL-префикс его таба (см. nav.ts routeToUrl). Флоу-роуты острова
// (farmwiz→ферма, batchwiz/pub→рынок) и shop→главная, чтобы подсветка/стек совпадали с URL.
const TAB_MAP: Record<string, RouteName> = {
  home: 'home', services: 'home', cabinet: 'home', shop: 'home', turan: 'home',
  farm: 'farm', farmwiz: 'farm',
  market: 'market', p1list: 'market', batch: 'market', review: 'market', batchwiz: 'market', pub: 'market',
  messages: 'messages', thread: 'messages',
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
