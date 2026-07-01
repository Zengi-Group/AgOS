import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface AdminOrg {
  id: string
  legal_name: string
  bin_iin: string | null
  legal_form: string | null
  phone: string | null
  email: string | null
  address_text: string | null
  is_active: boolean
  created_at: string
  region_id: string | null
  region_name: string | null
  org_types: string[]
  member_count: number
}

export function useAdminOrgs(search: string) {
  return useQuery<AdminOrg[]>({
    queryKey: ['admin-orgs', search],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('rpc_admin_list_organizations', {
        p_search: search || null,
      })
      if (error) {
        console.error('[useAdminOrgs] rpc error:', error)
        throw error
      }
      return (data ?? []) as AdminOrg[]
    },
  })
}
