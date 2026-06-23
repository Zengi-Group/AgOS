// AgOS · хук загрузки и мутации партий фермера через Supabase RPC.
// rpc_get_org_batches (AI-19) — список партий текущей org.
// rpc_cancel_batch (RPC-11) — отмена партии.
// Остальные переходы state — оптимистично локально (TSP-4).

import { useState, useEffect, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import type { Batch } from '../types'

// Локальное хранилище партий — фолбэк для разработки без backend (TSP demo).
// Если RPC недоступен (нет деплоя схемы / офлайн), кабинет работает на localStorage:
// созданные через визард партии сохраняются и кликаются в рамках браузера.
const LS_KEY = 'agos.cabinet.batches.v1'

function loadLocal(): Batch[] {
  try {
    const raw = localStorage.getItem(LS_KEY)
    return raw ? (JSON.parse(raw) as Batch[]) : []
  } catch {
    return []
  }
}

function saveLocal(list: Batch[]): void {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(list))
  } catch {
    /* localStorage недоступен — игнорируем */
  }
}

interface UseBatchesResult {
  batches: Batch[]
  loading: boolean
  error: string | null
  refetch: () => Promise<void>
  addBatch: (b: Batch) => void          // после визарда — добавить + рефетч
  patchBatch: (id: string, patch: Partial<Batch>) => Promise<void>
}

export function useBatches(): UseBatchesResult {
  const [batches, setBatches] = useState<Batch[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const fetch = useCallback(async (opts?: { silent?: boolean }) => {
    const silent = opts?.silent ?? false
    if (!silent) setLoading(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_get_org_batches', {})
      if (rpcError) throw rpcError
      // rpc_get_org_batches возвращает JSONB массив
      const list = Array.isArray(data) ? (data as Batch[]) : []
      if (list.length > 0) {
        // Есть backend и данные — синхронизируем локальную копию
        setBatches(list)
        saveLocal(list)
      } else {
        // Backend пуст (нет партий у org) — показываем локальные, созданные в демо
        setBatches(loadLocal())
      }
    } catch {
      // Нет backend (схема не задеплоена / офлайн) — работаем на localStorage,
      // не падать с белым экраном
      setBatches(loadLocal())
    } finally {
      if (!silent) setLoading(false)
    }
  }, [])

  // Рекомендация цены (D-PRICEREC-01): партии published/offering, провисевшие 24ч
  // без покупателя, переводятся в 'decision' — фермеру показывается экран снижения
  // цены. Ленивый вызов перед загрузкой. Ошибки/нет backend — тихо глушим.
  const reviewDue = useCallback(async () => {
    try { await supabase.rpc('rpc_self_review_due_batches', {}) } catch { /* нет backend */ }
  }, [])

  useEffect(() => {
    reviewDue().then(() => fetch())
  }, [reviewDue, fetch])

  // Лёгкий поллинг (D-SYNC-01): тихий рефетч раз в 20с — фермер видит авто-матч
  // и смену статуса партии без перезагрузки. silent=true — без спиннера/мигания.
  // Безопасно для демо: fetch падает в localStorage-фолбэк при отсутствии backend.
  useEffect(() => {
    const id = setInterval(() => { reviewDue().then(() => fetch({ silent: true })) }, 20000)
    return () => clearInterval(id)
  }, [reviewDue, fetch])

  const refetch = useCallback(async () => {
    await fetch()
  }, [fetch])

  // После onDone визарда — добавить batch оптимистично + рефетч для синхронизации
  const addBatch = useCallback((b: Batch) => {
    setBatches((prev) => {
      // Избежать дублей если рефетч уже добавил
      if (prev.some((x) => x.id === b.id)) return prev
      const next = [b, ...prev]
      saveLocal(next)   // сохранить локально (демо без backend)
      return next
    })
    // Рефетч в фоне для синхронизации с сервером (если backend есть)
    fetch()
  }, [fetch])

  const patchBatch = useCallback(async (id: string, patch: Partial<Batch>) => {
    // Оптимистичное обновление + сохранить локально (демо без backend)
    setBatches((prev) => {
      const next = prev.map((b) => (b.id === id ? { ...b, ...patch } : b))
      saveLocal(next)
      return next
    })

    try {
      // Выбрать нужный RPC по содержимому патча
      if (patch.state === 'cancelled') {
        // rpc_cancel_batch (RPC-11) — существует с TSP-1
        const { error } = await supabase.rpc('rpc_cancel_batch', { p_batch_id: id })
        if (error) throw error
      } else if (patch.state === 'dispatched') {
        // rpc_dispatch_batch — confirmed → dispatched
        const { error } = await supabase.rpc('rpc_dispatch_batch', { p_batch_id: id })
        if (error) throw error
      } else if (patch.state === 'offering' && patch.price !== undefined) {
        // rpc_lower_price — decision → offering с новой ценой
        const { error } = await supabase.rpc('rpc_lower_price', {
          p_batch_id:  id,
          p_new_price: patch.price,
        })
        if (error) throw error
        // Переоценка → повторный авто-матч (D-AUTOMATCH-01): по новой цене партия
        // может теперь подойти под пул. Сматчилось — обновляем локально.
        try {
          const { data: m } = await supabase.rpc('rpc_self_auto_match_batch', { p_batch_id: id })
          const match = m as { matched?: boolean; dealPrice?: number } | null
          if (match?.matched) {
            setBatches((prev) => {
              const next = prev.map((b) =>
                b.id === id ? { ...b, state: 'matched' as Batch['state'], dealPrice: match.dealPrice ?? b.dealPrice } : b)
              saveLocal(next)
              return next
            })
          }
        } catch { /* нет backend — пропускаем */ }
      } else if (patch.price !== undefined && patch.state === undefined) {
        // rpc_update_price — только смена цены без смены state
        const { error } = await supabase.rpc('rpc_update_price', {
          p_batch_id:  id,
          p_new_price: patch.price,
        })
        if (error) throw error
      } else if (patch.review !== undefined) {
        // rpc_submit_review — отзыв фермера о покупателе
        const r = patch.review as { r1: number; r2: number; comment?: string }
        const { error } = await supabase.rpc('rpc_submit_review', {
          p_batch_id: id,
          p_r1:       r.r1,
          p_r2:       r.r2,
          p_comment:  r.comment ?? '',
        })
        if (error) throw error
      }
      // Остальные локальные патчи (deadlineLabel, dispatchedLabel и т.д.) —
      // только UI, RPC не нужны
    } catch (e: unknown) {
      // Нет backend (схема не задеплоена / офлайн) — оставляем локальное
      // изменение (уже сохранено в localStorage), не откатываем и не падаем.
      // Когда backend появится, RPC отработает и рефетч синхронизирует данные.
      console.warn('patchBatch: RPC недоступен, изменение сохранено локально:', e)
    }
  }, [])

  return { batches, loading, error, refetch, addBatch, patchBatch }
}
