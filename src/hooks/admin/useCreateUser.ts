import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export interface CreateUserInput {
  phone: string
  pin: string
  organizationId: string
  role: 'owner' | 'manager' | 'employee' | 'viewer'
  fullName: string
  email: string
  language: string
}

export function useCreateUser() {
  const qc = useQueryClient()
  return useMutation<void, Error, CreateUserInput>({
    mutationFn: async (input) => {
      const { error } = await supabase.rpc('rpc_admin_create_user', {
        p_phone: input.phone,
        p_pin: input.pin,
        p_organization_id: input.organizationId,
        p_role: input.role,
        p_full_name: input.fullName || null,
        p_email: input.email || null,
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
