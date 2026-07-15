// AgOS · S2 (ARS-148, ADR-NATIVE-ROUTER-01 AMEND-1) · Маппинг Route ↔ URL для v5-острова
// IonReactRouter. URL — источник истины стека; Route-состояние синкается с него (эффекты,
// шторки, tabOf продолжают работать). Спека: AGOS-NativeApp-EngSpec-v0_1.md §3.
//
// N-2 (Increment 2, аудит нативности): URL сгруппированы ПО ТАБУ (sibling-префиксы
// /cabinet/{home,farm,market,messages}/...). Это требование Ionic для независимого
// навигационного стека на каждую вкладку (docs react/navigation «each tab operates as its
// own independent navigation stack»): активный таб определяется тем, чей href-префикс
// совпадает с текущим URL, а IonRouterOutlet держит лист-страницу каждого таба смонтированной
// → стек и скролл вкладки переживают переключение. Раньше плоские URL + root-replace на
// каждом свитче схлопывали всё в один общий стек (потеря стека/скролла таба).

import type { Route, RouteName } from './types'
import { tabOf } from './store'

// Видимые корни-вкладки таб-бара. Переход на них = смена активного таба
// (Ionic нативно восстанавливает стек таба). N-2: у каждого свой URL-префикс.
const TAB_ROOTS: RouteName[] = ['home', 'farm', 'market', 'messages']

// Глубина роута ВНУТРИ его таба — для направления анимации (forward/back), когда переход
// не корневой и остаётся в том же табе.
const DEPTH: Record<RouteName, number> = {
  home: 0, farm: 0, market: 0, shop: 1, messages: 0,
  cabinet: 1, p1list: 1, thread: 1, turan: 1, services: 1, farmwiz: 1, batchwiz: 1, pub: 1,
  batch: 2,
  review: 3,
}

// Route → URL. Каждый экран висит под URL-префиксом СВОЕГО таба (см. tabOf/TAB_MAP в store).
export function routeToUrl(r: Route): string {
  switch (r.name) {
    // --- таб «Главная» ---
    case 'home': return '/cabinet/home'
    case 'cabinet': return '/cabinet/home/account'
    case 'turan': return '/cabinet/home/turan'
    case 'shop': return '/cabinet/home/shop'
    case 'services': return '/cabinet/home/services'
    // --- таб «Ферма» ---
    case 'farm': return '/cabinet/farm'
    case 'farmwiz': return '/cabinet/farm/wizard'
    // --- таб «Рынок» ---
    case 'market': return '/cabinet/market'
    case 'batchwiz': return '/cabinet/market/new'
    case 'p1list': return '/cabinet/market/list'
    case 'batch': return `/cabinet/market/batch/${r.batchId ?? ''}`
    case 'review': return `/cabinet/market/review/${r.batchId ?? ''}`
    case 'pub': return `/cabinet/market/pub/${r.batchId ?? ''}`
    // --- таб «Сообщения» ---
    case 'messages': return '/cabinet/messages'
    // ARS-231: тред TURAN — лента на /cabinet/messages/thread/turan; форма обращения — route 'turan'.
    case 'thread': return `/cabinet/messages/thread/${r.tid ?? 'consultant'}`
    default: return '/cabinet/home'
  }
}

// URL → Route для browser-back / edge-swipe / deep-link. Распознаёт КЛЮЧЕВОЙ сегмент пути,
// поэтому одинаково ловит и новую схему (с таб-префиксом), и СТАРУЮ плоскую (без префикса) —
// backward-compat для deep-link/push-пейлоадов, выпущенных до N-2 (C10, IMPL_DEBT). `back` не
// восстанавливается (подсказка направления, не хранилище) — onBack используют `route.back ?? fallback`.
export function urlToRoute(pathname: string): Route {
  const p = pathname.replace(/\/+$/, '')
  if (p === '' || p === '/cabinet' || p === '/cabinet/home') return { name: 'home' }
  const seg = p.replace(/^\/cabinet\/?/, '').split('/')
  // id/tid — сегмент СРАЗУ после ключевого имени (работает и для '…/batch/123', и для 'batch/123').
  const after = (name: string): string | undefined => {
    const i = seg.indexOf(name)
    return i >= 0 ? seg[i + 1] : undefined
  }
  // Порядок: под-экраны с параметром и листья РАНЬШЕ корней таба (market/farm/messages —
  // одновременно и таб-префикс, и имя корня; листовые проверки должны сработать первыми).
  if (seg.includes('batch')) return { name: 'batch', batchId: after('batch') }
  if (seg.includes('review')) return { name: 'review', batchId: after('review') }
  if (seg.includes('pub')) return { name: 'pub', batchId: after('pub') }
  if (seg.includes('thread')) return { name: 'thread', tid: after('thread') ?? 'consultant' }
  if (seg.includes('wizard')) return { name: 'farmwiz' }
  if (seg.includes('new')) return { name: 'batchwiz' }
  if (seg.includes('list')) return { name: 'p1list' }
  if (seg.includes('account')) return { name: 'cabinet' }
  if (seg.includes('turan')) return { name: 'turan' }
  if (seg.includes('services')) return { name: 'services' }
  if (seg.includes('shop')) return { name: 'shop' }
  // Корни табов.
  if (seg.includes('market')) return { name: 'market' }
  if (seg.includes('farm')) return { name: 'farm' }
  if (seg.includes('messages')) return { name: 'messages' }
  return { name: 'home' }
}

// Ключ идентичности роута — go() и URL-синк не должны зацикливаться.
export const routeKey = (r: Route): string => `${r.name}|${r.tid ?? ''}|${r.batchId ?? ''}`

export type NavDirection = 'forward' | 'back' | 'root'

// Направление перехода. Корень таба → 'root' (сброс/свитч, native tab UX). Смена таба на
// под-экран → тоже 'root' (нативный таб-свитч без push-анимации стека). Внутри одного таба —
// forward/back по карте глубины (DEBT-NATIVE-ROUTER-01: поддерживать при добавлении роутов).
export function dirFor(from: Route, to: Route): NavDirection {
  if (TAB_ROOTS.includes(to.name)) return 'root'
  if (tabOf(from) !== tabOf(to)) return 'root'
  const df = DEPTH[from.name] ?? 0
  const dt = DEPTH[to.name] ?? 0
  return dt < df ? 'back' : 'forward'
}
