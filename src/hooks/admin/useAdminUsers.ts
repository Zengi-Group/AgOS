import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface AdminUser {
  user_id: string
  full_name: string | null
  phone: string | null
  email: string | null
  avatar_url: string | null
  preferred_language: string | null
  is_active: boolean
  created_at: string
  organization_id: string | null
  organization_name: string | null
  org_types: string[] | null
  membership_level: string | null
  membership_paid: boolean
}

export function useAdminUsers(search: string) {
  return useQuery<AdminUser[]>({
    queryKey: ['admin-users', search],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('rpc_admin_list_farmer_mpk_users', {
        p_search: search || null,
      })
      if (error) {
        console.error('[useAdminUsers] rpc error:', error)
        throw error
      }
      return (data ?? []) as AdminUser[]
    },
  })
}
