// AgOS · TSP · ARS-227 · Хук фото/видео партии.
// Приватный бакет 'batch-media', путь {orgId}/{batchId}/{uuid}.{ext}.
// Загрузка: storage.upload → rpc_add_batch_media (метаданные). Чтение: select по RLS
// (владелец+админ, ARS-227; МПК отложено на ARS-229) + createSignedUrl. Удаление:
// rpc_remove_batch_media → storage.remove. Стиль — как useBatches: без react-query,
// мягкая деградация (нет backend/локальная демо-партия → пусто, без падения).

import { useCallback, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'

export type BatchMediaType = 'photo' | 'video'

export interface BatchMediaItem {
  id: string
  type: BatchMediaType
  path: string          // storage_path в бакете batch-media
  url: string | null    // подписанный URL (истекает; перезапрашивается при рефетче)
  sortOrder: number
}

interface DbRow {
  id: string
  media_type: BatchMediaType
  storage_path: string
  sort_order: number
}

const BUCKET = 'batch-media'
const SIGNED_TTL = 3600            // 1ч — карточка живёт недолго, повторный fetch освежит
const MAX_PHOTO = 15 * 1024 * 1024 // 15 МБ
const MAX_VIDEO = 100 * 1024 * 1024 // 100 МБ

// Реальная (серверная) партия — uuid из backend. Локальные демо-партии визарда имеют
// id 'local-...' (см. BatchWizard.buildLocalBatch): для них медиа не персистится.
function isServerBatch(batchId: string): boolean {
  return !!batchId && !batchId.startsWith('local-')
}

function extOf(file: File): string {
  const fromName = file.name.includes('.') ? file.name.split('.').pop()! : ''
  if (fromName) return fromName.toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 8)
  const fromMime = file.type.split('/')[1] ?? 'bin'
  return fromMime.toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 8) || 'bin'
}

interface UseBatchMediaResult {
  items: BatchMediaItem[]
  loading: boolean
  uploading: boolean
  canUse: boolean                 // backend доступен (реальная партия + есть orgId)
  refetch: () => Promise<void>
  upload: (file: File) => Promise<boolean>
  remove: (item: BatchMediaItem) => Promise<void>
}

export function useBatchMedia(
  batchId: string,
  orgId: string | null | undefined,
  toast?: (text: string) => void,
): UseBatchMediaResult {
  const [items, setItems] = useState<BatchMediaItem[]>([])
  const [loading, setLoading] = useState(false)
  const [uploading, setUploading] = useState(false)

  const canUse = !!orgId && isServerBatch(batchId)

  const fetch = useCallback(async () => {
    if (!canUse) { setItems([]); return }
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('batch_media')
        .select('id, media_type, storage_path, sort_order')
        .eq('batch_id', batchId)
        .order('sort_order', { ascending: true })
        .order('created_at', { ascending: true })
      if (error) throw error
      const rows = (data ?? []) as DbRow[]
      // Подписанные URL одним батч-запросом (createSignedUrls принимает массив путей).
      const paths = rows.map((r) => r.storage_path)
      const signed = paths.length
        ? (await supabase.storage.from(BUCKET).createSignedUrls(paths, SIGNED_TTL)).data ?? []
        : []
      const urlByPath = new Map<string, string>()
      signed.forEach((s) => { if (s.path && s.signedUrl) urlByPath.set(s.path, s.signedUrl) })
      setItems(rows.map((r) => ({
        id: r.id,
        type: r.media_type,
        path: r.storage_path,
        url: urlByPath.get(r.storage_path) ?? null,
        sortOrder: r.sort_order,
      })))
    } catch (e) {
      // Нет backend/схемы — тихо пусто, как useBatches (демо не падает).
      console.warn('useBatchMedia: чтение недоступно:', e)
      setItems([])
    } finally {
      setLoading(false)
    }
  }, [batchId, canUse])

  useEffect(() => { fetch() }, [fetch])

  const upload = useCallback(async (file: File): Promise<boolean> => {
    if (!canUse || !orgId) { toast?.('Сохраните партию, чтобы добавить фото'); return false }
    const isVideo = file.type.startsWith('video/')
    const isPhoto = file.type.startsWith('image/')
    if (!isVideo && !isPhoto) { toast?.('Только фото или видео'); return false }
    const type: BatchMediaType = isVideo ? 'video' : 'photo'
    if (isPhoto && file.size > MAX_PHOTO) { toast?.('Фото больше 15 МБ'); return false }
    if (isVideo && file.size > MAX_VIDEO) { toast?.('Видео больше 100 МБ'); return false }

    setUploading(true)
    try {
      const path = `${orgId}/${batchId}/${crypto.randomUUID()}.${extOf(file)}`
      const { error: upErr } = await supabase.storage.from(BUCKET).upload(path, file, {
        contentType: file.type || undefined,
        upsert: false,
      })
      if (upErr) throw upErr

      const { error: rpcErr } = await supabase.rpc('rpc_add_batch_media', {
        p_organization_id: orgId,
        p_batch_id:        batchId,
        p_media_type:      type,
        p_storage_path:    path,
        p_sort_order:      items.length,
      })
      if (rpcErr) {
        // Метаданные не записались — убрать осиротевший объект, не оставлять мусор.
        await supabase.storage.from(BUCKET).remove([path]).catch(() => {})
        throw rpcErr
      }
      await fetch()
      return true
    } catch (e) {
      console.warn('useBatchMedia: загрузка не удалась:', e)
      toast?.('Не удалось загрузить файл')
      return false
    } finally {
      setUploading(false)
    }
  }, [batchId, orgId, canUse, items.length, fetch, toast])

  const remove = useCallback(async (item: BatchMediaItem) => {
    if (!canUse || !orgId) return
    // Оптимистично убираем из ленты.
    setItems((prev) => prev.filter((x) => x.id !== item.id))
    try {
      const { error } = await supabase.rpc('rpc_remove_batch_media', {
        p_organization_id: orgId,
        p_media_id:        item.id,
      })
      if (error) throw error
      await supabase.storage.from(BUCKET).remove([item.path]).catch(() => {})
    } catch (e) {
      console.warn('useBatchMedia: удаление не удалось:', e)
      toast?.('Не удалось удалить файл')
      await fetch()   // откат к серверному состоянию
    }
  }, [orgId, canUse, fetch, toast])

  return { items, loading, uploading, canUse, refetch: fetch, upload, remove }
}
