import React, { createContext, useCallback, useEffect, useState } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { useHost } from '@/platform/host/HostContext'

export interface Organization {
  id: string
  name: string
  org_type: string
  bin: string | null
  region_id: string | null
}

export interface Farm {
  id: string
  organization_id: string
  name: string
  region_id: string | null
  shelter_type: string | null
  calving_system: string | null
  herd_groups: HerdGroup[]
}

export interface HerdGroup {
  id: string
  farm_id: string
  animal_category_id: string
  animal_category_code: string
  animal_category_name: string
  breed_name: string | null
  breed_id: string | null
  head_count: number
  avg_weight_kg: number | null
  data_source: string
  updated_at: string
}

export interface Membership {
  id: string
  organization_id: string
  membership_type: string
  status: string
}

export interface UserContext {
  is_admin: boolean
  is_expert: boolean
  user_id: string
  full_name: string | null
  phone: string | null
  organizations: Organization[]
  farms: Farm[]
  memberships: Membership[]
  health_restrictions: HealthRestriction[]
}

export interface HealthRestriction {
  id: string
  organization_id: string
  restriction_type: string
  reason: string
  expires_at: string
}

interface AuthContextValue {
  session: Session | null
  user: User | null
  userContext: UserContext | null
  isLoading: boolean
  isContextLoading: boolean
  signOut: () => Promise<void>
  refreshContext: () => Promise<void>
}

export const AuthContext = createContext<AuthContextValue>({
  session: null,
  user: null,
  userContext: null,
  isLoading: true,
  isContextLoading: false,
  signOut: async () => {},
  refreshContext: async () => {},
})

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const host = useHost()
  const [session, setSession] = useState<Session | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  const [userContext, setUserContext] = useState<UserContext | null>(null)
  const [isContextLoading, setIsContextLoading] = useState(false)

  const loadContext = useCallback(async () => {
    setIsContextLoading(true)
    try {
      const { data, error } = await supabase.rpc('rpc_get_my_context')
      if (error) {
        console.error('Failed to load user context:', error)
        return
      }
      if (data) {
        setUserContext(data as unknown as UserContext)
      }
    } catch (err) {
      console.error('rpc_get_my_context error:', err)
    } finally {
      setIsContextLoading(false)
    }
  }, [])

  useEffect(() => {
    let cancelled = false
    // Host Bridge (ARS-147): webview/capacitor могут инжектить сессию до чтения из storage;
    // WebHost возвращает null — supabase-js читает localStorage сам, поведение web не меняется.
    const init = async () => {
      const injected = await host.bootstrapSession()
      if (injected) {
        await supabase.auth.setSession(injected)
      }
      const {
        data: { session: s },
      } = await supabase.auth.getSession()
      if (cancelled) return
      setSession(s)
      setIsLoading(false)
      if (s) {
        loadContext()
      }
    }
    init()

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event, s) => {
      setSession(s)
      setIsLoading(false)
      if (event === 'SIGNED_IN') {
        // Load context only on actual sign-in, not on TOKEN_REFRESHED
        loadContext()
      } else if (event === 'SIGNED_OUT') {
        setUserContext(null)
      }
      // TOKEN_REFRESHED: session already updated via setSession — no reload needed
    })

    return () => {
      cancelled = true
      subscription.unsubscribe()
    }
  }, [loadContext, host])

  const signOut = useCallback(async () => {
    // Host Bridge: хост чистит своё хранилище (Preferences / мост) и зовёт supabase.signOut
    await host.signOut()
    setSession(null)
    setUserContext(null)
  }, [host])

  return (
    <AuthContext.Provider
      value={{
        session,
        user: session?.user ?? null,
        userContext,
        isLoading,
        isContextLoading,
        signOut,
        refreshContext: loadContext,
      }}
    >
      {children}
    </AuthContext.Provider>
  )
}
