import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export function useDeleteOrg() {
  const qc = useQueryClient()
  return useMutation<void, Error, string>({
    mutationFn: async (orgId) => {
      const { error } = await supabase.rpc('rpc_admin_delete_organization', { p_org_id: orgId })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-orgs'] })
      qc.invalidateQueries({ queryKey: ['admin-users'] })
      toast.success('Организация удалена')
    },
    onError: (err) => toast.error(err.message || 'Ошибка удаления'),
  })
}
