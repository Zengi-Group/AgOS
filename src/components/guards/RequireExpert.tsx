/**
 * Guard: allows experts OR admins to access /admin/* routes.
 * Fast path: is_admin/is_expert from AuthContext (loaded at login).
 * Fallback: задеплоенный rpc_get_my_context может НЕ возвращать is_admin/is_expert
 * (канон d01 их не отдаёт) → флаги в контексте всегда false и доступ ломается.
 * Поэтому при пустых флагах делаем живой fn_is_admin()/fn_is_expert() RPC,
 * прежде чем редиректить. Так роль, выданная в admin_roles, срабатывает без правок БД.
 */
import { Navigate, Outlet } from 'react-router-dom'
import { useEffect, useState } from 'react'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'
import { Loader2 } from 'lucide-react'

export function RequireExpert() {
  const { session, loading, isContextLoading, isAdmin, isExpert } = useAuth()

  // Быстрый путь из контекста.
  const contextAllows = isAdmin || isExpert

  // Живой fallback: null = ещё не проверяли, true/false = результат RPC.
  const [liveAllowed, setLiveAllowed] = useState<boolean | null>(null)

  useEffect(() => {
    // Проверяем только когда: есть сессия, контекст догрузился, но флаги пустые.
    if (!session || loading || isContextLoading || contextAllows) return
    let alive = true
    ;(async () => {
      const [adminRes, expertRes] = await Promise.all([
        supabase.rpc('fn_is_admin'),
        supabase.rpc('fn_is_expert'),
      ])
      if (!alive) return
      setLiveAllowed(!!adminRes.data || !!expertRes.data)
    })()
    return () => { alive = false }
  }, [session, loading, isContextLoading, contextAllows])

  if (loading || isContextLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (!session) return <Navigate to="/login" replace />

  // Контекст уже разрешает — пускаем.
  if (contextAllows) return <Outlet />

  // Ждём результат живой проверки, чтобы не редиректить преждевременно.
  if (liveAllowed === null) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (!liveAllowed) return <Navigate to="/cabinet" replace />

  return <Outlet />
}
