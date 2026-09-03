// AgOS · S6 (ARS-152, ADR-NATIVE-ROUTER-01 AMEND-1) · Маппинг MpkRoute ↔ URL для
// v5-острова IonReactRouter оболочки МПК (зеркало фермерского ../nav.ts). URL — источник
// истины стека; Route-состояние синкается с него. DEBT-NATIVE-ROUTER-01: поддерживать
// карту при добавлении роутов. Спека: AGOS-NativeApp-EngSpec-v0_1.md §3.

import { MPK_PROFILE_TABS, type MpkProfileTab, type MpkRoute } from './types'

// Глубина роута — направление анимации: home — корень стека, tsp/offers — push поверх.
// profile — десктопная консоль (Slice10), в Ionic-стек закупок не входит: её монтирует
// v6-роут App.tsx, глубина нужна лишь для полноты карты.
const DEPTH: Record<MpkRoute['name'], number> = { home: 0, tsp: 1, offers: 1, profile: 1 }

// Разбор пути `/mpk/...` на сегменты — один дом нормализации для обоих направлений.
const mpkSegments = (pathname: string): string[] =>
  pathname.replace(/\/+$/, '').replace(/^\/mpk\/?/, '').split('/')

// Slice10 §1.1 / M-002: неизвестный или отсутствующий сегмент таба → null, чтобы вызывающий
// мог отличить «нужен redirect replace» от «таб распознан». mpkUrlToRoute сводит null к
// overview — консоль делает из null именно redirect (D-MPK-DESKTOP-01).
export function mpkProfileTabFromUrl(pathname: string): MpkProfileTab | null {
  const seg = mpkSegments(pathname)
  if (seg[0] !== 'profile') return null
  // Канонический вид — ровно `/mpk/profile/:tab`. Лишние сегменты
  // (`/mpk/profile/org/что-угодно`) — такой же неканонический адрес, как неизвестный таб:
  // отдаём null, чтобы консоль сделала redirect, а не оставила мусорный URL пригодным
  // к копированию и возврату по истории.
  if (seg.length > 2) return null
  const tab = seg[1]
  return (MPK_PROFILE_TABS as readonly string[]).includes(tab ?? '') ? tab as MpkProfileTab : null
}

export function mpkRouteToUrl(r: MpkRoute): string {
  switch (r.name) {
    case 'tsp': return '/mpk/tsp'
    case 'offers': return '/mpk/offers'
    case 'profile': return `/mpk/profile/${r.tab}`
    default: return '/mpk'
  }
}

// Обратный маппинг для browser-back / edge-swipe / deep-link: URL → MpkRoute.
export function mpkUrlToRoute(pathname: string): MpkRoute {
  const seg = mpkSegments(pathname)
  switch (seg[0]) {
    case 'tsp': return { name: 'tsp' }
    case 'offers': return { name: 'offers' }
    case 'profile': return { name: 'profile', tab: mpkProfileTabFromUrl(pathname) ?? 'overview' }
    default: return { name: 'home' }
  }
}

// Ключ идентичности роута — go() и URL-синк не должны зацикливаться. У профиля таб входит
// в ключ: смена подраздела — смена роута, иначе синк URL→состояние проглотит переход.
export const mpkRouteKey = (r: MpkRoute): string => (r.name === 'profile' ? `profile:${r.tab}` : r.name)

export type MpkNavDirection = 'forward' | 'back'

// Направление перехода из карты глубины: к home — pop назад, от home — push вперёд.
export function mpkDirFor(from: MpkRoute, to: MpkRoute): MpkNavDirection {
  return (DEPTH[to.name] ?? 0) < (DEPTH[from.name] ?? 0) ? 'back' : 'forward'
}
