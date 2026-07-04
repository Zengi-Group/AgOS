// AgOS · S6 (ARS-152, ADR-NATIVE-ROUTER-01 AMEND-1) · Маппинг MpkRoute ↔ URL для
// v5-острова IonReactRouter оболочки МПК (зеркало фермерского ../nav.ts). URL — источник
// истины стека; Route-состояние синкается с него. DEBT-NATIVE-ROUTER-01: поддерживать
// карту при добавлении роутов. Спека: AGOS-NativeApp-EngSpec-v0_1.md §3.

import type { MpkRoute } from './types'

// Глубина роута — направление анимации: home — корень стека, tsp/offers — push поверх.
const DEPTH: Record<MpkRoute['name'], number> = { home: 0, tsp: 1, offers: 1 }

export function mpkRouteToUrl(r: MpkRoute): string {
  switch (r.name) {
    case 'tsp': return '/mpk/tsp'
    case 'offers': return '/mpk/offers'
    default: return '/mpk'
  }
}

// Обратный маппинг для browser-back / edge-swipe / deep-link: URL → MpkRoute.
export function mpkUrlToRoute(pathname: string): MpkRoute {
  const seg = pathname.replace(/\/+$/, '').replace(/^\/mpk\/?/, '').split('/')
  switch (seg[0]) {
    case 'tsp': return { name: 'tsp' }
    case 'offers': return { name: 'offers' }
    default: return { name: 'home' }
  }
}

// Ключ идентичности роута — go() и URL-синк не должны зацикливаться.
export const mpkRouteKey = (r: MpkRoute): string => r.name

export type MpkNavDirection = 'forward' | 'back'

// Направление перехода из карты глубины: к home — pop назад, от home — push вперёд.
export function mpkDirFor(from: MpkRoute, to: MpkRoute): MpkNavDirection {
  return (DEPTH[to.name] ?? 0) < (DEPTH[from.name] ?? 0) ? 'back' : 'forward'
}
