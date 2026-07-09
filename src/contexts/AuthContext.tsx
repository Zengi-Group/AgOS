import React, { createContext, useCallback, useEffect, useRef, useState } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { useHost } from '@/platform/host/HostContext'
import type { PushToken } from '@/platform/host/AgOSHost'

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
  // S5/ARS-154: последний зарегистрированный push-токен — нужен для отзыва при signOut,
  // пока сессия ещё валидна (RLS push_token скоупит по user_id).
  const activePushRef = useRef<{ token: string; organizationId: string | null } | null>(null)

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

  // S5/ARS-153: отправка device-токена в общий бэкенд (EngSpec §6). Один RPC для всех
  // хостов; WebHost отдаёт null → no-op на web. Провайдер/платформа приходят от хоста.
  const sendPushToken = useCallback(
    async (pt: PushToken, organizationId: string | null) => {
      try {
        const { error } = await supabase.rpc('rpc_register_push_token', {
          p_organization_id: organizationId,
          p_token: pt.token,
          p_provider: pt.provider,
          p_platform: pt.platform,
          p_device_id: null,
        })
        if (error) {
          console.error('rpc_register_push_token failed:', error)
          return
        }
        activePushRef.current = { token: pt.token, organizationId }
      } catch (err) {
        console.error('rpc_register_push_token error:', err)
      }
    },
    [],
  )

  useEffect(() => {
    // S5/ARS-153: после auth регистрируем push. organization_id = первичная орг фермера.
    // §6 шаг 4: onPushToken перерегистрирует при ротации токена нативным слоем.
    if (!session || !userContext) return
    const organizationId = userContext.organizations[0]?.id ?? null
    let cancelled = false
    host.onPushToken((pt) => {
      void sendPushToken(pt, organizationId)
    })
    void host.registerPushToken().then((pt) => {
      if (!cancelled && pt) void sendPushToken(pt, organizationId)
    })
    return () => {
      cancelled = true
    }
  }, [session, userContext, host, sendPushToken])

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
    // S5/ARS-154: деактивируем push-токен ДО выхода (сессия ещё валидна для RLS push_token).
    const active = activePushRef.current
    if (active) {
      try {
        await supabase.rpc('rpc_revoke_push_token', {
          p_organization_id: active.organizationId,
          p_token: active.token,
        })
      } catch (err) {
        console.error('rpc_revoke_push_token error:', err)
      }
      activePushRef.current = null
    }
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
