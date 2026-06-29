import { useMutation } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

const BUCKET = 'avatars'

// Загружает аватар в бакет avatars (путь userId/uuid.ext) и возвращает public URL.
export function useUploadAvatar() {
  return useMutation<string, Error, { userId: string; file: File }>({
    mutationFn: async ({ userId, file }) => {
      const ext = file.name.split('.').pop() ?? 'jpg'
      const path = `${userId}/${crypto.randomUUID()}.${ext}`

      const { error: uploadError } = await supabase.storage
        .from(BUCKET)
        .upload(path, file, { cacheControl: '3600', upsert: false })
      if (uploadError) throw uploadError

      const { data } = supabase.storage.from(BUCKET).getPublicUrl(path)
      return data.publicUrl
    },
  })
}
