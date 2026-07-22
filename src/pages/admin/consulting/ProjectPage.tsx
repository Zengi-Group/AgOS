/**
 * ProjectPage — container for consulting project with topbar tabs.
 * Pattern: same as RationPage (useSetTopbar + Outlet).
 *
 * Routes:
 *   /admin/consulting/:projectId          → redirect → /admin/consulting/:projectId/summary
 *   /admin/consulting/:projectId/edit     → ProjectWizard (parameter input)
 *   /admin/consulting/:projectId/summary  → Summary tab
 *   /admin/consulting/:projectId/herd     → Herd turnover tab
 *   /admin/consulting/:projectId/pnl      → P&L tab
 *   /admin/consulting/:projectId/cashflow → Cash Flow tab
 *   /admin/consulting/:projectId/capex    → CAPEX tab
 */
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Navigate, NavLink, Outlet, useLocation, useNavigate, useParams } from 'react-router-dom'
import { Activity, ChevronDown, ChevronUp, ClipboardList, LayoutGrid, MoreHorizontal, Package, RefreshCw, SlidersHorizontal, Star, TrendingUp, Users, Wheat, X } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useTopbarConfig } from '@/components/layout/TopbarContext'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'
import { calculateProject } from '@/lib/consulting-api'

interface ProjectMeta {
  name: string
  status: string
  needs_recalc: boolean
  organization_id: string
  latestInputParams: Record<string, unknown> | null
}

export function ProjectPage() {
  const { projectId } = useParams()
  const { pathname } = useLocation()
  const navigate = useNavigate()
  const { organization, isAdmin, isExpert } = useAuth()
  const [project, setProject] = useState<ProjectMeta | null>(null)
  const [projects, setProjects] = useState<{ id: string }[]>([])
  const [recalcLoading, setRecalcLoading] = useState(false)

  const orgId = organization?.id
  // TURAN admin/expert accounts have no farmer organization_id of their own (P2) —
  // DEF-CONSULTING-AUTH-02 lets them pass p_organization_id: null to reach any project.
  const canManageAllOrgs = isAdmin || isExpert
  const base = `/admin/consulting/${projectId}`

  const loadProject = useCallback((oId: string | null, pId: string) => {
    supabase
      .rpc('rpc_get_consulting_project', {
        p_organization_id: oId,
        p_project_id: pId,
      })
      .then(({ data, error }) => {
        if (!error && data) {
          const versions: Array<{ input_params: Record<string, unknown> }> = data.versions ?? []
          setProject({
            name: data.name,
            status: data.status,
            needs_recalc: data.needs_recalc ?? false,
            organization_id: data.organization_id,
            latestInputParams: versions[0]?.input_params ?? null,
          })
        }
      })
  }, [])

  useEffect(() => {
    if ((!orgId && !canManageAllOrgs) || !projectId) return
    loadProject(orgId ?? null, projectId)
  }, [orgId, canManageAllOrgs, projectId, loadProject])

  const handleRecalculate = useCallback(async () => {
    // Project's own org, not the viewer's — an admin has none, and even a
    // consultant with an org shouldn't recalc under the wrong one (DEF-CONSULTING-AUTH-02).
    const recalcOrgId = project?.organization_id ?? orgId
    if (!recalcOrgId || !projectId || !project?.latestInputParams) return
    setRecalcLoading(true)
    try {
      await calculateProject({
        project_id: projectId,
        organization_id: recalcOrgId,
        input_params: project.latestInputParams,
      })
      loadProject(recalcOrgId, projectId)
    } catch {
      // keep badge visible on error — user can retry
    } finally {
      setRecalcLoading(false)
    }
  }, [orgId, projectId, project?.organization_id, project?.latestInputParams, loadProject])

  useEffect(() => {
    if (!orgId && !canManageAllOrgs) return
    supabase
      .rpc('rpc_list_consulting_projects', { p_organization_id: orgId ?? null })
      .then(({ data }) => { if (data) setProjects(data) })
  }, [orgId, canManageAllOrgs])

  const STATUS_LABELS: Record<string, string> = {
    draft: 'Черновик', calculating: 'Расчёт...', calculated: 'Рассчитан', archived: 'Архив',
  }

  const headerContent = useMemo(() => {
    // captured for closure — useMemo re-runs when project changes
    const TABS = [
      { label: 'Параметры',    path: `${base}/edit`,     icon: SlidersHorizontal },
      { label: 'Сводка',       path: `${base}/summary`,  icon: LayoutGrid },
      { label: 'Тех. карта',   path: `${base}/techcard`, icon: ClipboardList },
      { label: 'Оборот стада', path: `${base}/herd`,     icon: RefreshCw },
      { label: 'P&L',          path: `${base}/pnl`,      icon: TrendingUp },
      { label: 'Cash Flow',    path: `${base}/cashflow`, icon: Activity },
      { label: 'CAPEX',        path: `${base}/capex`,    icon: Package },
      { label: 'Штат',         path: `${base}/staff`,    icon: Users },
      { label: 'Рационы',      path: `${base}/ration`,   icon: Wheat },
    ]
    return (
      <div className="flex flex-col w-full">

        {/* Строка 1: навигация */}
        <div className="flex items-center h-10 px-3.5 gap-2" style={{ borderBottom: '1px solid var(--bd)' }}>
          <button
            onClick={() => navigate('/admin/consulting')}
            className="w-6 h-6 rounded-[5px] flex items-center justify-center hover:bg-muted transition-colors"
            style={{ border: '1px solid var(--bd)', background: 'transparent', color: 'var(--fg3)' }}
          >
            <X className="w-2.5 h-2.5" />
          </button>

          <div className="flex gap-0.5">
            <button disabled className="w-6 h-6 rounded-[5px] flex items-center justify-center opacity-30"
              style={{ border: '1px solid var(--bd)', background: 'transparent', color: 'var(--fg3)' }}>
              <ChevronUp className="w-3 h-3" />
            </button>
            <button disabled className="w-6 h-6 rounded-[5px] flex items-center justify-center opacity-30"
              style={{ border: '1px solid var(--bd)', background: 'transparent', color: 'var(--fg3)' }}>
              <ChevronDown className="w-3 h-3" />
            </button>
          </div>

          <span className="text-[12px] ml-1" style={{ color: 'var(--fg2)' }}>
            {projects.length > 0
              ? `${projects.findIndex(p => p.id === projectId) + 1} из ${projects.length} проектов`
              : 'Инвестиционные проекты'}
          </span>

          <div className="ml-auto">
            <button className="w-7 h-7 rounded-md flex items-center justify-center hover:bg-muted transition-colors"
              style={{ background: 'transparent', border: 'none', color: 'var(--fg3)' }}>
              <MoreHorizontal className="w-3.5 h-3.5" />
            </button>
          </div>
        </div>

        {/* Строка 2: заголовок */}
        <div className="flex items-center h-[54px] px-4 gap-2.5" style={{ borderBottom: '1px solid var(--bd)' }}>
          <div className="w-[34px] h-[34px] rounded-[8px] flex items-center justify-center flex-shrink-0"
            style={{ border: '1px solid var(--bd)', background: 'var(--bg-m)' }}>
            <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
              <rect x="2" y="2" width="6" height="6" rx="1.5" fill="currentColor" opacity=".2"/>
              <rect x="10" y="2" width="6" height="6" rx="1.5" fill="currentColor" opacity=".5"/>
              <rect x="2" y="10" width="6" height="6" rx="1.5" fill="currentColor" opacity=".5"/>
              <rect x="10" y="10" width="6" height="6" rx="1.5" fill="currentColor" opacity=".85"/>
            </svg>
          </div>

          <h1 style={{ fontSize: 16, fontWeight: 600, margin: 0, whiteSpace: 'nowrap', color: 'var(--fg)' }}>
            {project?.name ?? '...'}
          </h1>

          <button className="hover:opacity-70 transition-opacity"
            style={{ background: 'transparent', border: 'none', color: 'var(--fg3)' }}>
            <Star className="w-3.5 h-3.5" />
          </button>

          {project?.status && (
            <Badge variant={project.status === 'calculated' ? 'default' : 'secondary'} className="ml-1">
              {STATUS_LABELS[project.status] ?? project.status}
            </Badge>
          )}

          {/* Dok 7 §10.5: staleness badge + recalc trigger */}
          {project?.needs_recalc && (
            <>
              <Badge variant="outline" className="ml-1 border-[var(--amber)] text-[var(--amber)] text-xs">
                Требуется пересчёт
              </Badge>
              <Button
                size="sm"
                variant="outline"
                className="h-7 text-xs gap-1 ml-1"
                disabled={recalcLoading || !project.latestInputParams}
                onClick={handleRecalculate}
              >
                <RefreshCw className={`w-3 h-3 ${recalcLoading ? 'animate-spin' : ''}`} />
                {recalcLoading ? 'Расчёт...' : 'Пересчитать'}
              </Button>
            </>
          )}
        </div>

        {/* Строка 3: табы */}
        <div className="flex items-stretch h-10 px-4 overflow-x-auto"
          style={{ borderBottom: '1px solid var(--bd)', scrollbarWidth: 'none' }}>
          {TABS.map(tab => (
            <NavLink
              key={tab.path}
              to={tab.path}
              end
              className={({ isActive }) =>
                `flex items-center gap-1.5 px-2.5 text-[13px] border-b-2 whitespace-nowrap cursor-pointer transition-colors ${
                  isActive
                    ? 'font-medium border-foreground'
                    : 'border-transparent hover:text-foreground'
                }`
              }
              style={({ isActive }) => ({ color: isActive ? 'var(--fg)' : 'var(--fg2)' })}
            >
              <tab.icon className="w-3.5 h-3.5 flex-shrink-0" />
              {tab.label}
            </NavLink>
          ))}
        </div>

      </div>
    )
  }, [project, navigate, base, projects, projectId, handleRecalculate, recalcLoading])

  const { setConfig, clearConfig } = useTopbarConfig()
  useEffect(() => {
    setConfig({ headerContent })
    return () => clearConfig()
  }, [headerContent, setConfig, clearConfig])

  // Redirect bare /admin/consulting/:id → /admin/consulting/:id/summary
  if (pathname === base || pathname === `${base}/`) {
    return <Navigate to={`${base}/summary`} replace />
  }

  return (
    <div key={pathname} className="tab-content">
      <Outlet />
    </div>
  )
}
