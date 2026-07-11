import { Navigate, Outlet } from 'react-router-dom';
import { useAuth } from '@/hooks/useAuth';
import type { UserRole } from '@/types/membership';
import { TuranLoader } from '@/components/TuranLoader';

interface Props {
  role: UserRole;
}

export function RequireRole({ role: requiredRole }: Props) {
  const { role, loading } = useAuth();

  if (loading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <TuranLoader variant="breathe" size={40} />
      </div>
    );
  }

  if (role !== requiredRole) {
    return <Navigate to="/cabinet" replace />;
  }

  return <Outlet />;
}
