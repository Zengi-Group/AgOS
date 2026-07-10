import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'
import { BootScreen } from '@/components/BootScreen'

export function RequireAuth() {
  const { session, loading } = useAuth()
  const location = useLocation()

  // P-2 (ARS-218): брендовый boot вместо голого спиннера при резолве сессии.
  if (loading) {
    return <BootScreen />
  }

  if (!session) {
    return <Navigate to="/login" state={{ from: location }} replace />
  }

  return <Outlet />
}
