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
