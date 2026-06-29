import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export interface CreateUserInput {
  email: string
  phone: string
  password: string
  fullName: string
  language: string
}

export function useCreateUser() {
  const qc = useQueryClient()
  return useMutation<void, Error, CreateUserInput>({
    mutationFn: async (input) => {
      const { error } = await supabase.rpc('rpc_admin_create_user', {
        p_email: input.email || null,
        p_phone: input.phone || null,
        p_password: input.password,
        p_full_name: input.fullName || null,
        p_language: input.language || 'ru',
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-users'] })
      toast.success('Пользователь создан')
    },
    onError: (err) => toast.error(err.message || 'Ошибка создания'),
  })
}
