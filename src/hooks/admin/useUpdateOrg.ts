import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export interface UpdateOrgInput {
  orgId: string
  legalName: string
  binIin: string
  phone: string
  email: string
  address: string
  isActive: boolean
}

export function useUpdateOrg() {
  const qc = useQueryClient()
  return useMutation<void, Error, UpdateOrgInput>({
    mutationFn: async (input) => {
      const { error } = await supabase.rpc('rpc_admin_update_organization', {
        p_org_id: input.orgId,
        p_legal_name: input.legalName,
        p_bin_iin: input.binIin,
        p_phone: input.phone,
        p_email: input.email,
        p_address: input.address,
        p_is_active: input.isActive,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-orgs'] })
      toast.success('Организация обновлена')
    },
    onError: (err) => toast.error(err.message || 'Ошибка обновления'),
  })
}
