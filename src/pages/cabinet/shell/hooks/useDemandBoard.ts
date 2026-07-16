// AgOS · TSP · ARS-229 · Хук доски спроса МПК для фермера (агрегат-only, обезличено).
// Читает rpc_get_demand_board (M6: pools status=filling + pool_lines + pool_regions).
// Показывает только категорию / регион / индикативную цену / объём — НИКОГДА личность МПК
// (ст.171, aggregate-only; D40 / D-M6-5/12). Стиль — как useBatches/useBatchMedia:
// без react-query, мягкая деградация (нет backend / аноним → пусто, не падает).

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'

export interface DemandRow {
  categoryName: string
  regionId: string | null
  regionName: string | null
  lineCount: number
  priceMin: number | null
  priceMax: number | null
  priceAvg: number | null
  targetVolumeKg: number | null
  deliveryFrom: string | null
  deliveryTo: string | null
}

// Сырая форма из jsonb (snake_case из jsonb_build_object в RPC).
interface RawRow {
  category_name: string
  region_id: string | null
  region_name: string | null
  line_count: number
  price_min: number | null
  price_max: number | null
  price_avg: number | null
  target_volume_kg: number | null
  delivery_from: string | null
  delivery_to: string | null
}

function toRow(r: RawRow): DemandRow {
  return {
    categoryName: r.category_name,
    regionId: r.region_id,
    regionName: r.region_name,
    lineCount: r.line_count,
    priceMin: r.price_min,
    priceMax: r.price_max,
    priceAvg: r.price_avg,
    targetVolumeKg: r.target_volume_kg,
    deliveryFrom: r.delivery_from,
    deliveryTo: r.delivery_to,
  }
}

interface UseDemandBoardResult {
  items: DemandRow[]
  disclaimer: string
  loading: boolean
  canUse: boolean
  refetch: () => Promise<void>
}

export function useDemandBoard(orgId: string | null | undefined): UseDemandBoardResult {
  const [items, setItems] = useState<DemandRow[]>([])
  const [disclaimer, setDisclaimer] = useState('')
  const [loading, setLoading] = useState(false)

  const canUse = !!orgId

  const fetch = useCallback(async () => {
    if (!canUse) { setItems([]); setDisclaimer(''); return }
    setLoading(true)
    try {
      const { data, error } = await supabase.rpc('rpc_get_demand_board', {
        p_organization_id: orgId,
      })
      if (error) throw error
      const rows = (data?.demand ?? []) as RawRow[]
      setItems(rows.map(toRow))
      setDisclaimer(typeof data?.disclaimer_text === 'string' ? data.disclaimer_text : '')
    } catch (e) {
      console.warn('useDemandBoard: чтение недоступно:', e)
      setItems([])
      setDisclaimer('')
    } finally {
      setLoading(false)
    }
  }, [orgId, canUse])

  useEffect(() => { fetch() }, [fetch])

  return { items, disclaimer, loading, canUse, refetch: fetch }
}
