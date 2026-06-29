import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export interface UpdateUserInput {
  userId: string
  fullName: string
  phone: string
  email: string
  language: string
  isActive: boolean
  avatarUrl: string | null
}

export function useUpdateUser() {
  const qc = useQueryClient()
  return useMutation<void, Error, UpdateUserInput>({
    mutationFn: async (input) => {
      const { error } = await supabase.rpc('rpc_admin_update_user', {
        p_user_id: input.userId,
        p_full_name: input.fullName || null,
        p_phone: input.phone || null,
        p_email: input.email || null,
        p_language: input.language || null,
        p_is_active: input.isActive,
        p_avatar_url: input.avatarUrl || null,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-users'] })
      toast.success('Профиль обновлён')
    },
    onError: (err) => toast.error(err.message || 'Ошибка сохранения'),
  })
}
