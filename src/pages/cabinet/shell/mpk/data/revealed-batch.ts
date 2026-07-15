// AgOS · TSP · ARS-229 · Чтение раскрытой партии для МПК (read-only, post-reveal).
// После закрытия пула (batches.status confirmed/dispatched/delivered) RLS открывает
// матч-МПК чтение batch_media + batch_animals через fn_batch_revealed_to_me (d02 RLS +
// d10 storage). МПК ТОЛЬКО ЧИТАЕТ — write остаётся у владельца+админа (owner-guard не
// трогаем). Личность фермера уже раскрыта на этом этапе (D-M6-5/12), поэтому детализация
// партии не нарушает анонимность. Стиль — как useBatchMedia/useBatchAnimals: без
// react-query, мягкая деградация (нет backend / ещё не раскрыто → пусто, не падает).

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'

export type RevealedMediaType = 'photo' | 'video'

export interface RevealedMedia {
  id: string
  type: RevealedMediaType
  url: string | null    // подписанный URL (истекает; перезапрос при повторном раскрытии)
}

export interface RevealedAnimal {
  id: string
  inzhNumber: string | null
  weightKg: number | null
  sex: 'm' | 'f' | null
  ageMonths: number | null
  notes: string | null
}

interface MediaRow { id: string; media_type: RevealedMediaType; storage_path: string }
interface AnimalRow {
  id: string
  inzh_number: string | null
  weight_kg: number | null
  sex: 'm' | 'f' | null
  age_months: number | null
  notes: string | null
}

const BUCKET = 'batch-media'
const SIGNED_TTL = 3600   // 1ч — карточка живёт недолго, повторное раскрытие освежит

function isServerBatch(batchId: string): boolean {
  return !!batchId && !batchId.startsWith('local-')
}

interface UseRevealedBatchResult {
  media: RevealedMedia[]
  animals: RevealedAnimal[]
  loading: boolean
  loaded: boolean
}

// Ленивое чтение: грузим только когда enabled=true (МПК раскрыл секцию у строки).
export function useRevealedBatch(batchId: string | undefined, enabled: boolean): UseRevealedBatchResult {
  const [media, setMedia] = useState<RevealedMedia[]>([])
  const [animals, setAnimals] = useState<RevealedAnimal[]>([])
  const [loading, setLoading] = useState(false)
  const [loaded, setLoaded] = useState(false)

  const canUse = enabled && !!batchId && isServerBatch(batchId)

  const fetch = useCallback(async () => {
    if (!canUse || !batchId) return
    setLoading(true)
    try {
      const [mRes, aRes] = await Promise.all([
        supabase
          .from('batch_media')
          .select('id, media_type, storage_path')
          .eq('batch_id', batchId)
          .order('sort_order', { ascending: true })
          .order('created_at', { ascending: true }),
        supabase
          .from('batch_animals')
          .select('id, inzh_number, weight_kg, sex, age_months, notes')
          .eq('batch_id', batchId)
          .order('sort_order', { ascending: true })
          .order('created_at', { ascending: true }),
      ])
      if (mRes.error) throw mRes.error
      if (aRes.error) throw aRes.error

      const mRows = (mRes.data ?? []) as MediaRow[]
      const paths = mRows.map((r) => r.storage_path)
      const signed = paths.length
        ? (await supabase.storage.from(BUCKET).createSignedUrls(paths, SIGNED_TTL)).data ?? []
        : []
      const urlByPath = new Map<string, string>()
      signed.forEach((s) => { if (s.path && s.signedUrl) urlByPath.set(s.path, s.signedUrl) })

      setMedia(mRows.map((r) => ({ id: r.id, type: r.media_type, url: urlByPath.get(r.storage_path) ?? null })))
      setAnimals(((aRes.data ?? []) as AnimalRow[]).map((r) => ({
        id: r.id,
        inzhNumber: r.inzh_number,
        weightKg: r.weight_kg,
        sex: r.sex,
        ageMonths: r.age_months,
        notes: r.notes,
      })))
    } catch (e) {
      // RLS ещё закрыто (не раскрыто) / нет backend — тихо пусто, не падаем.
      console.warn('useRevealedBatch: чтение недоступно:', e)
      setMedia([])
      setAnimals([])
    } finally {
      setLoading(false)
      setLoaded(true)
    }
  }, [batchId, canUse])

  useEffect(() => { if (canUse) fetch() }, [canUse, fetch])

  return { media, animals, loading, loaded }
}
