// AgOS · Слайс 3 · Загрузка маркет-борда МПК через rpc_get_market_batches.
// Реальные активные партии всех ферм (published/offering/decision), обезличенно (D40).
// Фолбэк на seedMarketBatches() — для демо без backend / анонима.

import { supabase } from '@/lib/supabase'
import { seedMarketBatches, type MarketBatch } from './pools'

// Сырая форма из rpc_get_market_batches (camelCase из jsonb_build_object).
interface RawMarketBatch {
  id: string
  cat: string
  skuName: string
  breed: string
  heads: number
  avgWeight: number
  age: number
  fatness: string
  region: string
  minPrice: number
  state: string
  windowLabel: string
}

function toMarketBatch(r: RawMarketBatch): MarketBatch {
  return {
    id: r.id,
    catName: r.skuName || r.cat,
    region: r.region,
    heads: r.heads,
    avgWeight: r.avgWeight,
    minPrice: r.minPrice,
    breed: r.breed,
    // В схеме batches нет признака вакцинации/пригодности — на бете показываем все доступные.
    vaccinated: true,
    suitable: true,
  }
}

// Возвращает реальные партии. null = backend недоступен/аноним → caller берёт seed.
export async function loadMarketBatches(): Promise<MarketBatch[] | null> {
  try {
    const { data, error } = await supabase.rpc('rpc_get_market_batches', {})
    if (error) return null
    if (!Array.isArray(data)) return null
    return (data as RawMarketBatch[]).map(toMarketBatch)
  } catch {
    return null
  }
}

export { seedMarketBatches }
export type { MarketBatch }
