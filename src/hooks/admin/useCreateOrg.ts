import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export interface CreateOrgInput {
  legalName: string
  orgType: 'farmer' | 'mpk' | 'supplier' | 'consultant' | 'other'
  binIin: string
  phone: string
  email: string
  address: string
}

export function useCreateOrg() {
  const qc = useQueryClient()
  return useMutation<string, Error, CreateOrgInput>({
    mutationFn: async (input) => {
      const { data, error } = await supabase.rpc('rpc_admin_create_organization', {
        p_legal_name: input.legalName,
        p_org_type: input.orgType,
        p_bin_iin: input.binIin || null,
        p_phone: input.phone || null,
        p_email: input.email || null,
        p_address: input.address || null,
      })
      if (error) throw error
      return data as string
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['admin-orgs'] })
      toast.success('Организация создана')
    },
    onError: (err) => toast.error(err.message || 'Ошибка создания'),
  })
}
