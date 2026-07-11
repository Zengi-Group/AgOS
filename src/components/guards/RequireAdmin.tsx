import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'
import { useEffect, useState } from 'react'
import { TuranLoader } from '@/components/TuranLoader'
import { toast } from 'sonner'

/**
 * Admin route guard — checks fn_is_admin() via RPC.
 * Dok 6 Slice 2: Every /admin/* route MUST verify admin status.
 */
export function RequireAdmin() {
  const { session, loading: authLoading } = useAuth()
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null)
  const [checking, setChecking] = useState(true)

  useEffect(() => {
    if (!session) {
      setChecking(false)
      return
    }

    const checkAdmin = async () => {
      try {
        const { data, error } = await supabase.rpc('fn_is_admin')
        if (error) {
          console.error('fn_is_admin check failed:', error)
          setIsAdmin(false)
        } else {
          setIsAdmin(!!data)
        }
      } catch {
        setIsAdmin(false)
      } finally {
        setChecking(false)
      }
    }

    checkAdmin()
  }, [session])

  if (authLoading || checking) {
    return (
      <div className="flex items-center justify-center min-h-screen bg-[#f8f9fa]">
        <TuranLoader variant="breathe" size={40} />
      </div>
    )
  }

  if (!session) {
    return <Navigate to="/register" replace />
  }

  if (!isAdmin) {
    toast.error('Доступ запрещён')
    return <Navigate to="/cabinet" replace />
  }

  return <Outlet />
}
