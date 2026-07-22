/**
 * Shared hook to load project + latest version data.
 * Used by all result tab pages.
 *
 * Data sources (priority order):
 * 1. sessionStorage cache (set by Wizard after calculation) — instant
 * 2. Supabase RPC (rpc_get_consulting_version) — persistent
 */
import { useState, useEffect, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'

const CACHE_KEY = 'consulting_results'

/** Save calculation results to sessionStorage for instant tab access */
export function cacheResults(projectId: string, results: any, inputParams: any) {
  sessionStorage.setItem(CACHE_KEY, JSON.stringify({ projectId, results, inputParams, ts: Date.now() }))
}

/** Read cached results */
function getCachedResults(projectId: string) {
  try {
    const raw = sessionStorage.getItem(CACHE_KEY)
    if (!raw) return null
    const cached = JSON.parse(raw)
    // Only use if same project and less than 10 min old
    if (cached.projectId === projectId && Date.now() - cached.ts < 600_000) {
      return cached
    }
  } catch { /* ignore */ }
  return null
}

export function useProjectData() {
  const { projectId } = useParams()
  const { organization, isAdmin, isExpert } = useAuth()
  const [project, setProject] = useState<any>(null)
  const [version, setVersion] = useState<any>(null)
  const [loading, setLoading] = useState(true)

  const orgId = organization?.id
  // Admin/expert (TURAN staff) have no farmer organization_id of their own
  // (DEF-CONSULTING-AUTH-02) — still need to load any client's project.
  const canManageAllOrgs = isAdmin || isExpert

  const load = useCallback(async () => {
    if ((!orgId && !canManageAllOrgs) || !projectId) { setLoading(false); return }
    setLoading(true)

    // 1. Check sessionStorage cache first
    const cached = getCachedResults(projectId)
    if (cached) {
      setVersion({ results: cached.results, input_params: cached.inputParams, version_number: 1 })
    }

    // 2. Load project from Supabase
    const { data: proj } = await supabase.rpc('rpc_get_consulting_project', {
      p_organization_id: orgId ?? null,
      p_project_id: projectId,
    })
    setProject(proj)

    // 3. Load latest version from Supabase (overwrites cache if available).
    // Use the project's own organization_id — rpc_get_consulting_version matches
    // it directly (no admin bypass), so the viewer's (possibly absent) org won't do.
    if (proj?.versions?.length > 0) {
      const { data: ver } = await supabase.rpc('rpc_get_consulting_version', {
        p_organization_id: proj.organization_id ?? orgId,
        p_version_id: proj.versions[0].id,
      })
      if (ver?.results) {
        setVersion(ver)
      }
    }
    setLoading(false)
  }, [orgId, projectId, canManageAllOrgs])

  useEffect(() => {
    load()
  }, [load])

  return { project, version, results: version?.results || {}, loading, refetch: load }
}

export function fmt(n: number | null | undefined, decimals = 0): string {
  if (n === null || n === undefined || isNaN(n)) return '—'
  return new Intl.NumberFormat('ru-RU', { maximumFractionDigits: decimals }).format(n)
}

export function fmtPct(n: number | null | undefined): string {
  if (n === null || n === undefined || isNaN(n)) return '—'
  return `${(n * 100).toFixed(1)}%`
}
