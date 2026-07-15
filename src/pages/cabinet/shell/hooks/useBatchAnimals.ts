// AgOS · TSP · ARS-228 · Хук пофакторной детализации по животным партии (ИНЖ).
// Манифест продажи — строго per-batch (НЕ herd-реестр животного, граница D20).
// Агрегат batches.heads остаётся источником правды: строки опциональны и МОГУТ быть
// меньше heads (P3/P4/P11). Стиль — как useBatchMedia/useBatches: без react-query,
// мягкая деградация (нет backend / локальная демо-партия 'local-*' → пусто, не падает).

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'

export type AnimalSex = 'm' | 'f'

export interface BatchAnimal {
  id: string
  inzhNumber: string | null
  weightKg: number | null
  sex: AnimalSex | null
  ageMonths: number | null
  notes: string | null
  sortOrder: number
}

// Ввод формы (add/update): все поля опциональны (P11).
export interface BatchAnimalInput {
  inzhNumber?: string | null
  weightKg?: number | null
  sex?: AnimalSex | null
  ageMonths?: number | null
  notes?: string | null
}

interface DbRow {
  id: string
  inzh_number: string | null
  weight_kg: number | null
  sex: AnimalSex | null
  age_months: number | null
  notes: string | null
  sort_order: number
}

function isServerBatch(batchId: string): boolean {
  return !!batchId && !batchId.startsWith('local-')
}

function toItem(r: DbRow): BatchAnimal {
  return {
    id: r.id,
    inzhNumber: r.inzh_number,
    weightKg: r.weight_kg,
    sex: r.sex,
    ageMonths: r.age_months,
    notes: r.notes,
    sortOrder: r.sort_order,
  }
}

interface UseBatchAnimalsResult {
  items: BatchAnimal[]
  loading: boolean
  saving: boolean
  canUse: boolean
  refetch: () => Promise<void>
  add: (input: BatchAnimalInput) => Promise<boolean>
  update: (id: string, input: BatchAnimalInput) => Promise<boolean>
  remove: (id: string) => Promise<void>
}

export function useBatchAnimals(
  batchId: string,
  orgId: string | null | undefined,
  toast?: (text: string) => void,
): UseBatchAnimalsResult {
  const [items, setItems] = useState<BatchAnimal[]>([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)

  const canUse = !!orgId && isServerBatch(batchId)

  const fetch = useCallback(async () => {
    if (!canUse) { setItems([]); return }
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('batch_animals')
        .select('id, inzh_number, weight_kg, sex, age_months, notes, sort_order')
        .eq('batch_id', batchId)
        .order('sort_order', { ascending: true })
        .order('created_at', { ascending: true })
      if (error) throw error
      setItems(((data ?? []) as DbRow[]).map(toItem))
    } catch (e) {
      console.warn('useBatchAnimals: чтение недоступно:', e)
      setItems([])
    } finally {
      setLoading(false)
    }
  }, [batchId, canUse])

  useEffect(() => { fetch() }, [fetch])

  const add = useCallback(async (input: BatchAnimalInput): Promise<boolean> => {
    if (!canUse || !orgId) { toast?.('Сохраните партию, чтобы добавить животных'); return false }
    setSaving(true)
    try {
      const { error } = await supabase.rpc('rpc_add_batch_animal', {
        p_organization_id: orgId,
        p_batch_id:        batchId,
        p_inzh_number:     input.inzhNumber ?? null,
        p_weight_kg:       input.weightKg ?? null,
        p_sex:             input.sex ?? null,
        p_age_months:      input.ageMonths ?? null,
        p_notes:           input.notes ?? null,
        p_sort_order:      items.length,
      })
      if (error) throw error
      await fetch()
      return true
    } catch (e) {
      console.warn('useBatchAnimals: добавление не удалось:', e)
      toast?.('Не удалось добавить животное')
      return false
    } finally {
      setSaving(false)
    }
  }, [batchId, orgId, canUse, items.length, fetch, toast])

  const update = useCallback(async (id: string, input: BatchAnimalInput): Promise<boolean> => {
    if (!canUse || !orgId) return false
    setSaving(true)
    try {
      const { error } = await supabase.rpc('rpc_update_batch_animal', {
        p_organization_id: orgId,
        p_animal_id:       id,
        p_inzh_number:     input.inzhNumber ?? null,
        p_weight_kg:       input.weightKg ?? null,
        p_sex:             input.sex ?? null,
        p_age_months:      input.ageMonths ?? null,
        p_notes:           input.notes ?? null,
      })
      if (error) throw error
      await fetch()
      return true
    } catch (e) {
      console.warn('useBatchAnimals: обновление не удалось:', e)
      toast?.('Не удалось сохранить изменения')
      return false
    } finally {
      setSaving(false)
    }
  }, [orgId, canUse, fetch, toast])

  const remove = useCallback(async (id: string) => {
    if (!canUse || !orgId) return
    setItems((prev) => prev.filter((x) => x.id !== id))   // оптимистично
    try {
      const { error } = await supabase.rpc('rpc_remove_batch_animal', {
        p_organization_id: orgId,
        p_animal_id:       id,
      })
      if (error) throw error
    } catch (e) {
      console.warn('useBatchAnimals: удаление не удалось:', e)
      toast?.('Не удалось удалить животное')
      await fetch()   // откат к серверному состоянию
    }
  }, [orgId, canUse, fetch, toast])

  return { items, loading, saving, canUse, refetch: fetch, add, update, remove }
}
