import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export function useDeleteUser() {
  const qc = useQueryClient()
  return useMutation<void, Error, string>({
    mutationFn: async (userId) => {
      const { error } = await supabase.rpc('rpc_admin_delete_user', { p_user_id: userId })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-users'] })
      toast.success('Пользователь удалён')
    },
    onError: (err) => toast.error(err.message || 'Ошибка удаления'),
  })
}
