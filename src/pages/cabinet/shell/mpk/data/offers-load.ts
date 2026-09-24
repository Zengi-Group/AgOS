// AgOS · Слайс C · Входящие broadcast-офферы МПК через rpc_get_incoming_offers.
// Партия фермера, по которой не нашлось прямого матча, разослана подходящим МПК
// (FCFS, окно 24ч). Личность фермера НЕ раскрыта (D-M6-12) — только характеристики.
// Фолбэк: null (нет backend / аноним) → caller показывает пустой список.

import { supabase } from '@/lib/supabase'
import type { IncomingOffer, OfferStatus } from '../types'

// Сырая форма из rpc_get_incoming_offers (camelCase из jsonb_build_object).
interface RawOffer {
  id: string
  batchId: string
  cat: string
  breed: string
  heads: number
  avgWeight: number
  region: string
  windowLabel: string
  offeredPrice: number
  expiresAtIso: string
  status: string
}

function toIncomingOffer(r: RawOffer): IncomingOffer {
  return {
    id: r.id,
    batchId: r.batchId,
    cat: r.cat,
    breed: r.breed ?? '',
    heads: r.heads,
    avgWeight: r.avgWeight,
    region: r.region ?? '',
    windowLabel: r.windowLabel ?? '',
    offeredPrice: r.offeredPrice,
    expiresAt: new Date(r.expiresAtIso),
    status: r.status as OfferStatus,
  }
}

// Входящие офферы текущего МПК (pending, не истёкшие). null = нет backend/аноним.
export async function loadIncomingOffers(): Promise<IncomingOffer[] | null> {
  try {
    const { data, error } = await supabase.rpc('rpc_get_incoming_offers', {})
    if (error || !Array.isArray(data)) return null
    return (data as RawOffer[]).map(toIncomingOffer)
  } catch {
    return null
  }
}

// ARS-785: исход чтения офферов различим — «офферов нет» ≠ «не прочитали». Зеркало
// MyPoolsRead/readMyPools (ARS-687 FR-009): у loadIncomingOffers выше `null` означает
// сразу два разных исхода, и в десктопной консоли оператору в любом из них показали бы
// «Нет входящих офферов» — то есть «рынок пуст» там, где на самом деле отказала сеть.
// loadIncomingOffers оставлен как есть: его единственный читатель — мобильный шелл
// (MpkApp), который слайсу править запрещено.
export type IncomingOffersRead =
  | { kind: 'ok'; offers: IncomingOffer[] }
  | { kind: 'no_session' }   // читать нечего (аноним/демо-шелл)
  | { kind: 'failed' }       // сессия есть, RPC/сеть отказали → «список не загрузился»

// «Сессии нет» утверждаем ТОЛЬКО когда getSession ответил без ошибки — тот же довод, что
// у pools-load.failedOrNoSession: внутри EXPIRY_MARGIN_MS @supabase/auth-js уходит в сеть
// за refresh и в оффлайне отдаёт `{ session: null, error }`. Без проверки `error` реальному
// оператору с почти истёкшим токеном отказ сети выглядел бы как «нет сессии».
async function failedOrNoSession(): Promise<IncomingOffersRead> {
  try {
    const { data, error } = await supabase.auth.getSession()
    return error || data?.session ? { kind: 'failed' } : { kind: 'no_session' }
  } catch {
    return { kind: 'failed' }
  }
}

// Входящие офферы с различимым исходом чтения. Порядок карточек здесь НЕ задаётся: он —
// требование экрана, и его дом один — `sortByDeadline` в `offers/offers-model.ts` (P4).
// Читатель отдаёт то, что ответила база (RPC сортирует своим `order by o.expires_at asc`),
// а экран приводит порядок к своему контракту сам.
export async function readIncomingOffers(): Promise<IncomingOffersRead> {
  try {
    const { data, error } = await supabase.rpc('rpc_get_incoming_offers', {})
    if (error || !Array.isArray(data)) return await failedOrNoSession()
    return { kind: 'ok', offers: (data as RawOffer[]).map(toIncomingOffer) }
  } catch {
    return await failedOrNoSession()
  }
}
