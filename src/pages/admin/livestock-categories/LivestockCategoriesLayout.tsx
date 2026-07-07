/**
 * A-CAT — Категории скота и формула классификации (admin).
 * Dok 6 A-CAT (v1.0), scope: A-CAT-01 (Категории) + A-CAT-02 (Формула/правила).
 * Backend: d02_tsp.sql Section 8a — AR-1/AR-2 (read), AC-1..4 (write).
 */
import { Outlet } from 'react-router-dom'
import { Tags } from 'lucide-react'
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Skeleton } from '@/components/ui/skeleton'

const TABS = [
  { label: 'Категории', path: '/admin/livestock-categories/categories' },
  { label: 'Формула (правила)', path: '/admin/livestock-categories/rules' },
]

export function LivestockCategoriesLayout() {
  const { isAdmin, checking } = useAdminGuard()

  useSetTopbar({
    title: 'Категории скота',
    titleIcon: <Tags size={15} />,
    tabs: TABS,
  })

  if (checking) return <div className="page"><Skeleton className="h-48 w-full" /></div>
  if (!isAdmin) return null

  return <Outlet />
}

export { CategoriesTab } from './CategoriesTab'
export { RulesTab } from './RulesTab'
