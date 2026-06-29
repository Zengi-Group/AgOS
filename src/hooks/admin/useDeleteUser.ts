import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { readEdgeError } from './edgeError'

export function useDeleteUser() {
  const qc = useQueryClient()
  return useMutation<void, Error, string>({
    mutationFn: async (userId) => {
      const { data, error } = await supabase.functions.invoke('admin-delete-user', {
        body: { user_id: userId },
      })
      if (error) throw new Error(await readEdgeError(error, 'Ошибка удаления'))
      if (data?.error) throw new Error(data.error)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-users'] })
      toast.success('Пользователь удалён')
    },
    onError: (err) => toast.error(err.message || 'Ошибка удаления'),
  })
}
