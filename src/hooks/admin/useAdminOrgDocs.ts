import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

const BUCKET = 'membership-documents'

export interface AdminDoc {
  /** Имя для показа (может включать подпапку, напр. "docs/file.pdf") */
  name: string
  /** Полный путь в бакете: "orgId/docs/file.pdf" */
  path: string
  size: number | null
  updatedAt: string | null
}

// Storage .list нерекурсивен: листаем корень орг-папки и один уровень подпапок.
async function listOrgDocs(orgId: string): Promise<AdminDoc[]> {
  const root = await supabase.storage.from(BUCKET).list(orgId, { limit: 100 })
  const out: AdminDoc[] = []
  for (const entry of root.data ?? []) {
    if (entry.name === '.emptyFolderPlaceholder') continue
    if (entry.id === null) {
      // папка → листаем её содержимое
      const sub = await supabase.storage.from(BUCKET).list(`${orgId}/${entry.name}`, { limit: 100 })
      for (const f of sub.data ?? []) {
        if (f.id === null || f.name === '.emptyFolderPlaceholder') continue
        out.push({
          name: `${entry.name}/${f.name}`,
          path: `${orgId}/${entry.name}/${f.name}`,
          size: (f.metadata as { size?: number } | null)?.size ?? null,
          updatedAt: f.updated_at ?? null,
        })
      }
    } else {
      out.push({
        name: entry.name,
        path: `${orgId}/${entry.name}`,
        size: (entry.metadata as { size?: number } | null)?.size ?? null,
        updatedAt: entry.updated_at ?? null,
      })
    }
  }
  return out
}

export function useAdminOrgDocs(orgId: string | undefined) {
  const qc = useQueryClient()
  const key = ['admin-org-docs', orgId]

  const query = useQuery<AdminDoc[]>({
    queryKey: key,
    queryFn: () => (orgId ? listOrgDocs(orgId) : Promise.resolve([])),
    enabled: !!orgId,
  })

  const upload = useMutation<void, Error, File>({
    mutationFn: async (file) => {
      if (!orgId) throw new Error('Нет организации')
      const safe = file.name.replace(/[^\w.\-]+/g, '_')
      const path = `${orgId}/docs/${Date.now()}_${safe}`
      const { error } = await supabase.storage.from(BUCKET).upload(path, file, { upsert: true })
      if (error) throw error
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: key }); toast.success('Документ загружен') },
    onError: (e) => toast.error(e.message || 'Ошибка загрузки'),
  })

  const remove = useMutation<void, Error, string>({
    mutationFn: async (path) => {
      const { error } = await supabase.storage.from(BUCKET).remove([path])
      if (error) throw error
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: key }); toast.success('Документ удалён') },
    onError: (e) => toast.error(e.message || 'Ошибка удаления'),
  })

  const download = useCallback(async (path: string) => {
    const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path, 300)
    if (error || !data?.signedUrl) { toast.error('Не удалось открыть файл'); return }
    window.open(data.signedUrl, '_blank')
  }, [])

  return { ...query, upload, remove, download }
}
