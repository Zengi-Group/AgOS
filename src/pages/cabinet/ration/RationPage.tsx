/**
 * Ration section container — sets 4-tab topbar navigation
 * Routes:
 *   /cabinet-legacy/ration             → redirect → /cabinet-legacy/ration/groups
 *   /cabinet-legacy/ration/calculator  → quick NASEM calculator (not saved)
 *   /cabinet-legacy/ration/groups      → farm rations per herd group
 *   /cabinet-legacy/ration/summary     → aggregated farm summary
 *   /cabinet-legacy/ration/budget      → feed stock vs demand + budget
 */
import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Calculator } from 'lucide-react'

const TABS = [
  { label: 'Калькулятор', path: '/cabinet-legacy/ration/calculator' },
  { label: 'Рационы фермы', path: '/cabinet-legacy/ration/groups' },
  { label: 'Сводный', path: '/cabinet-legacy/ration/summary' },
  { label: 'Бюджет кормов', path: '/cabinet-legacy/ration/budget' },
]

export function RationPage() {
  const { pathname } = useLocation()

  useSetTopbar({ title: 'Рационы', titleIcon: <Calculator size={15} />, tabs: TABS })

  // Redirect bare /cabinet-legacy/ration → /cabinet-legacy/ration/groups
  if (pathname === '/cabinet-legacy/ration' || pathname === '/cabinet-legacy/ration/') {
    return <Navigate to="/cabinet-legacy/ration/groups" replace />
  }

  return (
    <div key={pathname} className="tab-content">
      <Outlet />
    </div>
  )
}
