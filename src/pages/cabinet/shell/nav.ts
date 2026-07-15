// AgOS · S2 (ARS-148, ADR-NATIVE-ROUTER-01 AMEND-1) · Маппинг Route ↔ URL для v5-острова
// IonReactRouter. URL — источник истины стека; Route-состояние синкается с него (эффекты,
// шторки, tabOf продолжают работать). Спека: AGOS-NativeApp-EngSpec-v0_1.md §3.

import type { Route, RouteName } from './types'

// Табы-корни: переход на них = смена корня стека ('root'), не push.
const TAB_ROOTS: RouteName[] = ['home', 'farm', 'market', 'shop', 'messages']

// Глубина роута — для направления анимации (forward/back), когда это не таб-корень.
const DEPTH: Record<RouteName, number> = {
  home: 0, farm: 0, market: 0, shop: 0, messages: 0,
  cabinet: 1, p1list: 1, thread: 1, turan: 1, services: 1, farmwiz: 1, batchwiz: 1, pub: 1,
  batch: 2,
  review: 3,
}

export function routeToUrl(r: Route): string {
  switch (r.name) {
    case 'home': return '/cabinet'
    case 'services': return '/cabinet/services'
    case 'market': return '/cabinet/market'
    case 'batchwiz': return '/cabinet/market/new'
    case 'pub': return `/cabinet/pub/${r.batchId ?? ''}`
    case 'p1list': return '/cabinet/list'
    case 'batch': return `/cabinet/batch/${r.batchId ?? ''}`
    case 'review': return `/cabinet/review/${r.batchId ?? ''}`
    case 'cabinet': return '/cabinet/account'
    case 'farm': return '/cabinet/farm'
    case 'farmwiz': return '/cabinet/farm/wizard'
    case 'shop': return '/cabinet/shop'
    case 'messages': return '/cabinet/messages'
    // ARS-231: тред TURAN — лента на /cabinet/thread/turan; форма обращения — route 'turan'.
    case 'thread': return `/cabinet/thread/${r.tid ?? 'consultant'}`
    case 'turan': return '/cabinet/turan'
    default: return '/cabinet'
  }
}

// Обратный маппинг для browser-back / edge-swipe / deep-link: URL → Route.
// `back` не восстанавливается (подсказка направления, не хранилище) — onBack-хендлеры
// используют `route.back ?? fallback`, fallback сохраняет прежнее поведение.
export function urlToRoute(pathname: string): Route {
  const p = pathname.replace(/\/+$/, '')
  if (p === '/cabinet' || p === '') return { name: 'home' }
  const seg = p.replace(/^\/cabinet\/?/, '').split('/')
  switch (seg[0]) {
    case 'market': return seg[1] === 'new' ? { name: 'batchwiz' } : { name: 'market' }
    case 'pub': return { name: 'pub', batchId: seg[1] }
    case 'list': return { name: 'p1list' }
    case 'batch': return { name: 'batch', batchId: seg[1] }
    case 'review': return { name: 'review', batchId: seg[1] }
    case 'account': return { name: 'cabinet' }
    case 'farm': return seg[1] === 'wizard' ? { name: 'farmwiz' } : { name: 'farm' }
    case 'shop': return { name: 'shop' }
    case 'services': return { name: 'services' }
    case 'messages': return { name: 'messages' }
    case 'turan': return { name: 'turan' }
    case 'thread': return { name: 'thread', tid: seg[1] ?? 'consultant' }
    default: return { name: 'home' }
  }
}

// Ключ идентичности роута — go() и URL-синк не должны зацикливаться.
export const routeKey = (r: Route): string => `${r.name}|${r.tid ?? ''}|${r.batchId ?? ''}`

export type NavDirection = 'forward' | 'back' | 'root'

// Направление перехода из карты глубины (DEBT-NATIVE-ROUTER-01: поддерживать при
// добавлении роутов). Таб-корень → 'root' (смена корня стека, native tab UX).
export function dirFor(from: Route, to: Route): NavDirection {
  if (TAB_ROOTS.includes(to.name)) return 'root'
  const df = DEPTH[from.name] ?? 0
  const dt = DEPTH[to.name] ?? 0
  return dt < df ? 'back' : 'forward'
}
