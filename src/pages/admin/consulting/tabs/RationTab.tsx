/**
 * Slice 8 Part C-UI: RationTab
 * /admin/consulting/:projectId/ration
 *
 * Per-category NASEM ration builder for consulting projects.
 * Uses calculate-ration Edge Function in consulting context (ADR-FEED-02, D-S8-3).
 * Saves results via rpc_save_consulting_ration (C-RPC-09).
 * Reads existing rations via rpc_get_consulting_rations (C-RPC-10).
 */
import { useState, useMemo, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'
import { useRpc } from '@/hooks/useRpc'
import { useAnimalCategoryMappings } from '@/hooks/useAnimalCategoryMappings'
import { useProjectData } from './usProjectData'
import {
  getHeadCount,
  CATEGORY_CODE_TO_HERD,
} from './herdCategoryMapping'
import { SimpleRationEditor, DEFAULT_RATIONS, FEED_NAMES, RationsState } from './SimpleRationEditor'
import { supabase } from '@/lib/supabase'
import { calculateProject } from '@/lib/consulting-api'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Badge } from '@/components/ui/badge'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { TrendingDown } from 'lucide-react'
import { toast } from 'sonner'

// ─── Types ────────────────────────────────────────────────────────────────────

interface FeedItem {
  id: string
  code: string
  name_ru: string
  category: string
  is_validated: boolean
}

interface ConsultingRation {
  ration_version_id: string
  animal_category_id: string
  animal_category_name: string
  animal_category_code: string
  version_number: number
  items: Array<{
    feed_item_id: string
    feed_item_code: string
    quantity_kg_per_day: number
    cost_per_day: number
  }>
  results: {
    total_cost_per_day: number
    total_cost_per_month: number
    nutrients_met: Record<string, boolean>
    deficiencies: string[]
    solver_status: string
  }
  created_at: string
}

const OBJECTIVES = [
  { value: 'growth', label: 'Рост' },
  { value: 'maintenance', label: 'Поддержание' },
  { value: 'finishing', label: 'Финишный откорм' },
  { value: 'gestation', label: 'Стельность' },
  { value: 'lactation', label: 'Лактация' },
]

// ─── Main Component ───────────────────────────────────────────────────────────

export function RationTab() {
  const { projectId } = useParams<{ projectId: string }>()
  const { organization } = useAuth()
  // ADR-FEED-05: Simple is the only writer. NASEM is advisory via 🧮 in SimpleRationEditor.
  // DEF-RATION-07: NASEM toggle removed — CalcDialog component still imported for 🧮 path.
  const [calcDialog, setCalcDialog] = useState<{
    categoryId: string
    categoryName: string
    categoryCode: string
    defaultWeight: number
    defaultHeadCount: number
    defaultObjective: string
  } | null>(null)
  // Live rations state — initialised to DEFAULT_RATIONS, updated by SimpleRationEditor
  // via onRationsChange on every cell edit. Used for the feed-volume preview tables.
  const [liveRations, setLiveRations] = useState<RationsState>(
    () => JSON.parse(JSON.stringify(DEFAULT_RATIONS))
  )

  const { project, version, results, loading: projectLoading, refetch: refetchProject } = useProjectData()
  const herd = results?.herd

  // Project's own org, not the viewer's — admin/expert have none of their own
  // (DEF-CONSULTING-AUTH-02); rpc_get_consulting_rations/calculateProject match
  // against the project's real org, not the caller's identity.
  const orgId = project?.organization_id ?? organization?.id

  const { data: feedingGroupData } = useAnimalCategoryMappings('feeding_group')
  const { data: rations, isLoading, refetch } = useRpc<ConsultingRation[]>(
    'rpc_get_consulting_rations',
    { p_organization_id: orgId, p_consulting_project_id: projectId },
    { enabled: !!orgId && !!projectId }
  )

  // DEF-AUTO-RECALC-01 (2026-04-17): auto-run /calculate after ration save so the
  // financial model (SummaryTab, PnlTab, CashFlow) reflects new feed costs without
  // the user having to press "Рассчитать весь проект". Called from SimpleRationEditor
  // onSaved after the ration RPCs complete.
  const [recalcLoading, setRecalcLoading] = useState(false)
  const handleRationSaved = useCallback(async () => {
    // 1. Refresh rations list (affects RationTab COGS and volume tables).
    await refetch()
    // 2. Re-run engine if we have input_params from the last version.
    const inputParams = version?.input_params
    if (!orgId || !projectId || !inputParams) return
    setRecalcLoading(true)
    try {
      await calculateProject({
        project_id: projectId,
        organization_id: orgId,
        input_params: inputParams,
      })
      await refetchProject()
      toast.success('Проект пересчитан')
    } catch (e: any) {
      toast.error('Пересчёт не удался: ' + (e?.message || 'неизвестная ошибка'))
    } finally {
      setRecalcLoading(false)
    }
  }, [orgId, projectId, version?.input_params, refetch, refetchProject])

  // Fix #1 (ADR-FEED-CLIENT-01): Convert saved rations from DB → RationsState so
  // SimpleRationEditor seeds its state from DB values instead of DEFAULT_RATIONS.
  // Reads pasture.items / stall.items written by DEF-RATION-01 save format.
  const initialRations = useMemo<RationsState>(() => {
    if (!rations || rations.length === 0) return {}
    const result: RationsState = {}
    for (const ration of rations) {
      const code = ration.animal_category_code
      const group: Record<string, { pasture: number; stall: number }> = {}
      const pastureItems = (ration.results as any)?.pasture?.items ?? []
      const stallItems   = (ration.results as any)?.stall?.items   ?? []
      for (const item of pastureItems) {
        const fc = item.feed_item_code as string
        if (!group[fc]) group[fc] = { pasture: 0, stall: 0 }
        group[fc]!.pasture = item.quantity_kg_per_day
      }
      for (const item of stallItems) {
        const fc = item.feed_item_code as string
        if (!group[fc]) group[fc] = { pasture: 0, stall: 0 }
        group[fc]!.stall = item.quantity_kg_per_day
      }
      if (Object.keys(group).length > 0) result[code] = group
    }
    return result
  }, [rations])

  // DEF-RATION-COVERAGE-01 (2026-04-17): coverage считается по unique target_code
  // (feeding_group taxonomy), а не по animal_category_code. COW_CULL/BULL_CULL/
  // HEIFER_PREG/BULL_CALF — это фазы тех же животных, что ест рацион COW/BULL/
  // HEIFER_YOUNG/STEER; feeding_model.py объединяет их в одну feeding group через
  // max(cpd). UI согласован с движением голов в engine.
  //
  // ВАЖНО: не фильтруем по наличию поголовья в herd — SimpleRationEditor показывает
  // все 5 вкладок (BULL_BREEDING, COW, HEIFER_YOUNG, STEER, SUCKLING_CALF), поэтому
  // счётчик coverage тоже должен показывать все 5. Группы без поголовья дают 0 к
  // total_cogs автоматически (ration × 0 = 0), но вкладка и возможность заполнить
  // ration остаются — на случай, если позже поголовье появится (напр. отёл в году 2).
  const relevantGroups = useMemo(() => {
    if (!feedingGroupData || feedingGroupData.length === 0) {
      // Fallback: 5 default target codes from static CATEGORY_CODE_TO_HERD
      return [
        { target_code: 'COW',           member_codes: ['COW', 'COW_CULL', 'MIXED'] },
        { target_code: 'SUCKLING_CALF', member_codes: ['SUCKLING_CALF', 'YOUNG_CALF'] },
        { target_code: 'HEIFER_YOUNG',  member_codes: ['HEIFER_YOUNG', 'HEIFER_PREG'] },
        { target_code: 'STEER',         member_codes: ['STEER', 'BULL_CALF', 'OX'] },
        { target_code: 'BULL_BREEDING', member_codes: ['BULL_BREEDING', 'BULL_CULL'] },
      ]
    }

    // Group feeding_group rows by target_code → list of member animal_category_codes
    const byTarget = new Map<string, string[]>()
    for (const row of feedingGroupData) {
      if (!row.is_primary) continue
      const arr = byTarget.get(row.target_code) ?? []
      arr.push(row.animal_category_code)
      byTarget.set(row.target_code, arr)
    }
    return [...byTarget.entries()].map(([target_code, member_codes]) => ({
      target_code,
      member_codes,
    }))
  }, [feedingGroupData])

  if (!orgId || !projectId) return null

  const rationByCode = new Map<string, ConsultingRation>(
    (rations || []).map(r => [r.animal_category_code, r])
  )

  // A feeding group is "covered" if ANY of its member codes has a saved ration.
  const coveredGroups = relevantGroups.filter(g =>
    g.member_codes.some(c => rationByCode.has(c))
  )
  const totalCategories = relevantGroups.length
  const rationCount = coveredGroups.length

  // DEF-UI-WEANING-01 (2026-04-17): COGS must mirror engine weaning split.
  // Engine applies SUCKLING_CALF ration to (suckling_heifers + suckling_steers) and
  // HEIFER_YOUNG/STEER rations only to weaned portion. Previous UI used raw
  // heifers.avg / steers.avg, overstating COGS by the price delta × suckling-heads.
  //
  // heads_for_target(target, t) =
  //   SUCKLING_CALF  → Σ(heifers.from_calves + steers.from_calves)[t-w+1 .. t]
  //   HEIFER_YOUNG   → max(0, heifers.avg[t] − suckling_heifers[t])
  //   STEER          → max(0, steers.avg[t]  − suckling_steers[t])
  //   COW / BULL_BREEDING / ... → getHeadCount fallback
  const weaningMonths = ((results?.input as { weaning_months?: number } | undefined)
    ?.weaning_months) ?? 6

  const getCogsHeadCountY1 = (targetCode: string): number => {
    if (!herd) return 0
    const WINDOW = 12  // Y1 avg
    const sumWindow = (arr: number[] | undefined, start: number, end: number) =>
      (arr ?? []).slice(start, end + 1).reduce((a, b) => a + (b ?? 0), 0)

    if (targetCode === 'SUCKLING_CALF') {
      const hfc = herd.heifers?.from_calves as number[] | undefined
      const sfc = herd.steers?.from_calves  as number[] | undefined
      let total = 0
      for (let t = 0; t < WINDOW; t++) {
        const start = Math.max(0, t - weaningMonths + 1)
        total += sumWindow(hfc, start, t) + sumWindow(sfc, start, t)
      }
      return total / WINDOW
    }
    if (targetCode === 'HEIFER_YOUNG') {
      const hfc = herd.heifers?.from_calves as number[] | undefined
      const havg = herd.heifers?.avg ?? []
      let total = 0
      for (let t = 0; t < WINDOW; t++) {
        const start = Math.max(0, t - weaningMonths + 1)
        const suckling = sumWindow(hfc, start, t)
        total += Math.max(0, (havg[t] ?? 0) - suckling)
      }
      return total / WINDOW
    }
    if (targetCode === 'STEER') {
      const sfc = herd.steers?.from_calves as number[] | undefined
      const savg = herd.steers?.avg ?? []
      let total = 0
      for (let t = 0; t < WINDOW; t++) {
        const start = Math.max(0, t - weaningMonths + 1)
        const suckling = sumWindow(sfc, start, t)
        total += Math.max(0, (savg[t] ?? 0) - suckling)
      }
      return total / WINDOW
    }
    // COW, BULL_BREEDING etc. — unchanged behaviour
    return getHeadCount(herd, targetCode)
  }

  // COGS per feeding group = ration × head count (weaning-aware).
  const totalCogsMontly = coveredGroups.reduce((sum, g) => {
    const ration =
      rationByCode.get(g.target_code) ??
      g.member_codes.map(c => rationByCode.get(c)).find(Boolean)
    if (!ration) return sum
    const headCount = Math.round(getCogsHeadCountY1(g.target_code))
    return sum + ration.results.total_cost_per_month * headCount
  }, 0)

  return (
    <div className="page space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold">Рационы кормления</h2>
          <p className="text-sm text-muted-foreground">
            Табличный ввод рационов кг/гол/сут. Используйте 🧮 для NASEM-подбора по сезону.
          </p>
        </div>
      </div>

      <SimpleRationEditor
        projectId={projectId}
        orgId={orgId}
        onSaved={handleRationSaved}
        onRationsChange={setLiveRations}
        initialRations={initialRations}
      />

      {/* COGS Summary — visible in both modes (DEF-RATION-06) */}
      {!isLoading && rationCount > 0 && (
        <Card className="border-primary/20 bg-primary/5">
          <CardContent className="py-3 px-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <TrendingDown className="w-4 h-4 text-primary" />
                <span className="text-sm font-medium">Расчётный COGS по кормам</span>
                <span className="text-xs text-muted-foreground">
                  ({rationCount} из {totalCategories} {rationCount === totalCategories ? '— все категории' : 'категорий'})
                </span>
              </div>
              <div className="text-right">
                <div className="text-base font-semibold">
                  {totalCogsMontly.toLocaleString('ru-RU')} ₸/мес
                </div>
                <div className="text-xs text-muted-foreground">
                  {recalcLoading
                    ? 'Пересчёт P&L...'
                    : 'Применяется в P&L автоматически после сохранения'}
                </div>
              </div>
            </div>
            {rationCount < totalCategories && (
              <p className="mt-1.5 text-xs text-amber-600 dark:text-amber-400">
                {totalCategories - rationCount} {totalCategories - rationCount === 1 ? 'категория без рациона' : 'категорий без рациона'} — P&L использует нормативные значения
              </p>
            )}
          </CardContent>
        </Card>
      )}

      {/* ========== Feed volumes by group & by feed type ========== */}
      {(() => {
        // ── 1. Engine data (post-recalculation with DEF-RATION-08) ────────────
        const engineByGroup = results?.feeding?.quantities?.by_group as
          Record<string, Record<string, number[]>> | undefined
        const engineAnnual = results?.feeding?.annual_feed_summary as
          Record<string, number[]> | undefined
        const hasEngineGroups = !!(engineByGroup && Object.keys(engineByGroup).length > 0)
        const hasEngineAnnual = !!(engineAnnual && Object.keys(engineAnnual).length > 0)

        // ── 2. Client-side computation from liveRations × herd ────────────────
        // liveRations is in RationTab state, initialised to DEFAULT_RATIONS and
        // updated on every cell edit via onRationsChange callback — no save needed.
        // Formula: (pasture×183 + stall×182) × avgHeads_yr / 1000 = tonnes/yr
        let clientGroups: { key: string; label: string; annual: number[] }[] = []
        let clientFeeds:  { name: string; annual: number[] }[] = []

        if (!hasEngineGroups && !hasEngineAnnual) {
          if (!herd) {
            return projectLoading
              ? <p className="text-xs text-muted-foreground animate-pulse px-0.5 py-2">Загрузка данных проекта...</p>
              : <p className="text-xs text-muted-foreground px-0.5 py-2">Запустите расчёт проекта для отображения объёмов кормов</p>
          }

          const GROUP_LABEL_MAP: Record<string, string> = {
            COW:           'Маточное поголовье',
            SUCKLING_CALF: 'Молодняк (телята)',
            HEIFER_YOUNG:  'Тёлки',
            STEER:         'Бычки',
            BULL_BREEDING: 'Быки-производители',
          }
          const grpAcc:  Record<string, { label: string; annual: number[] }> = {}
          const feedAcc: Record<string, number[]> = {}

          for (const [code, feeds] of Object.entries(liveRations)) {
            const mapping = CATEGORY_CODE_TO_HERD[code]
            if (!mapping) continue
            const herdGrp = (herd as Record<string, Record<string, number[]>>)[mapping.group]
            if (!herdGrp) continue
            const monthArr = herdGrp[mapping.metric]
            if (!Array.isArray(monthArr) || monthArr.length === 0) continue

            const annual = Array<number>(10).fill(0)
            for (let yr = 0; yr < 10; yr++) {
              const slice = monthArr.slice(yr * 12, (yr + 1) * 12)
              if (slice.length === 0) break
              const avgHeads = slice.reduce((a: number, b: number) => a + (b ?? 0), 0) / slice.length
              if (avgHeads <= 0) continue

              for (const [feedCode, vals] of Object.entries(feeds)) {
                const avgKg = (vals.pasture * 183 + vals.stall * 182) / 365
                if (avgKg <= 0) continue
                const tonnes = avgKg * avgHeads * 365 / 1000
                annual[yr] = (annual[yr] ?? 0) + tonnes
                if (!feedAcc[feedCode]) feedAcc[feedCode] = Array<number>(10).fill(0)
                feedAcc[feedCode]![yr] = (feedAcc[feedCode]![yr] ?? 0) + tonnes
              }
            }
            if (annual.some(v => v > 0.05))
              grpAcc[code] = { label: GROUP_LABEL_MAP[code] ?? code, annual }
          }

          clientGroups = Object.entries(grpAcc)
            .map(([k, v]) => ({ key: k, ...v }))
            .filter(g => g.annual.some(v => v > 0.05))

          clientFeeds = Object.entries(feedAcc)
            .map(([fc, annual]) => ({ name: FEED_NAMES[fc] ?? fc, annual }))
            .filter(f => f.annual.some(v => v > 0.05))
            .sort((a, b) => (b.annual[0] ?? 0) - (a.annual[0] ?? 0))
        }

        // ── 3. Resolve final data source ──────────────────────────────────────
        const GROUP_LABELS: Record<string, string> = {
          molodnyak:            'Молодняк (телята)',
          heifers_prev:         'Тёлки',
          cows_12m:             'Маточное стадо',
          bulls:                'Быки-производители',
          fattening_breeding:   'Доращивание',
          fattening_commercial: 'Откорм (товарный)',
        }
        const SKIP = new Set(['cows_9m', 'heifers_curr'])

        function toAnnual(arr: number[]): number[] {
          const years: number[] = []
          for (let yr = 0; yr < 10; yr++) {
            const s = yr * 12
            if (s >= arr.length) break
            years.push(arr.slice(s, s + 12).reduce((a, b) => a + (b ?? 0), 0))
          }
          return years
        }

        const groups: { key: string; label: string; annual: number[] }[] = hasEngineGroups
          ? Object.entries(engineByGroup!)
              .filter(([k]) => !SKIP.has(k))
              .map(([k, feeds]) => {
                const monthly = Array<number>(120).fill(0)
                Object.values(feeds).forEach(fa => fa?.forEach((v, t) => { monthly[t] = (monthly[t] ?? 0) + (v ?? 0) }))
                return { key: k, label: GROUP_LABELS[k] ?? k, annual: toAnnual(monthly) }
              })
              .filter(g => g.annual.some(v => v > 0.05))
          : clientGroups

        const feedRows: { name: string; annual: number[] }[] = hasEngineAnnual
          ? Object.entries(engineAnnual!)
              .map(([name, arr]) => ({ name, annual: arr }))
              .filter(f => f.annual.some(v => v > 0.05))
              .sort((a, b) => (b.annual[0] ?? 0) - (a.annual[0] ?? 0))
          : clientFeeds

        if (groups.length === 0 && feedRows.length === 0) return null

        const numYears = Math.max(
          groups.length  > 0 ? groups[0]!.annual.length  : 0,
          feedRows.length > 0 ? feedRows[0]!.annual.length : 0,
        )
        const yearHeaders = Array.from({ length: numYears }, (_, i) => `Год ${i + 1}`)
        const groupTotals = Array.from({ length: numYears }, (_, i) => groups.reduce((s, g) => s + (g.annual[i] ?? 0), 0))
        const feedTotals  = Array.from({ length: numYears }, (_, i) => feedRows.reduce((s, f) => s + (f.annual[i] ?? 0), 0))

        const sourceLabel = hasEngineGroups || hasEngineAnnual
          ? null
          : rationByCode.size > 0
            ? 'сохранённые рационы'
            : 'нормативные значения'

        return (
          <div className="space-y-3">
            <div className="flex items-center gap-2 px-0.5">
              <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                Потребность в кормах
              </p>
              {sourceLabel && (
                <span className="text-[10px] text-muted-foreground border border-border/50 rounded px-1.5 py-0.5">
                  {sourceLabel}
                </span>
              )}
            </div>

            {/* По группам животных */}
            {groups.length > 0 && (
              <Card>
                <CardHeader className="pb-0 pt-3 px-4">
                  <CardTitle className="text-xs text-muted-foreground font-medium">По группам животных, тн/год</CardTitle>
                </CardHeader>
                <CardContent className="px-0 pb-2 overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b text-muted-foreground">
                        <th className="px-4 py-2 text-left font-medium min-w-[180px]">Группа</th>
                        {yearHeaders.map(y => <th key={y} className="px-2 py-2 text-right font-medium whitespace-nowrap">{y}</th>)}
                      </tr>
                    </thead>
                    <tbody>
                      {groups.map(g => (
                        <tr key={g.key} className="border-b border-border/30 hover:bg-muted/20">
                          <td className="px-4 py-1.5">{g.label}</td>
                          {Array.from({ length: numYears }, (_, i) => (
                            <td key={i} className="px-2 py-1.5 text-right font-mono">
                              {(g.annual[i] ?? 0) > 0.05 ? g.annual[i]!.toFixed(1) : '—'}
                            </td>
                          ))}
                        </tr>
                      ))}
                      <tr className="border-t-2 bg-muted/40 font-semibold">
                        <td className="px-4 py-2">Итого</td>
                        {groupTotals.map((v, i) => <td key={i} className="px-2 py-2 text-right font-mono">{v.toFixed(1)}</td>)}
                      </tr>
                    </tbody>
                  </table>
                </CardContent>
              </Card>
            )}

            {/* По видам кормов */}
            {feedRows.length > 0 && (
              <Card>
                <CardHeader className="pb-0 pt-3 px-4">
                  <CardTitle className="text-xs text-muted-foreground font-medium">По видам кормов, тн/год</CardTitle>
                </CardHeader>
                <CardContent className="px-0 pb-2 overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="border-b text-muted-foreground">
                        <th className="px-4 py-2 text-left font-medium min-w-[180px]">Корм</th>
                        {yearHeaders.map(y => <th key={y} className="px-2 py-2 text-right font-medium whitespace-nowrap">{y}</th>)}
                      </tr>
                    </thead>
                    <tbody>
                      {feedRows.map(f => (
                        <tr key={f.name} className="border-b border-border/30 hover:bg-muted/20">
                          <td className="px-4 py-1.5">{f.name}</td>
                          {Array.from({ length: numYears }, (_, i) => (
                            <td key={i} className="px-2 py-1.5 text-right font-mono">
                              {(f.annual[i] ?? 0) > 0.05 ? f.annual[i]!.toFixed(1) : '—'}
                            </td>
                          ))}
                        </tr>
                      ))}
                      <tr className="border-t-2 bg-muted/40 font-semibold">
                        <td className="px-4 py-2">Итого</td>
                        {feedTotals.map((v, i) => <td key={i} className="px-2 py-2 text-right font-mono">{v.toFixed(1)}</td>)}
                      </tr>
                    </tbody>
                  </table>
                </CardContent>
              </Card>
            )}
          </div>
        )
      })()}

      {/* NASEM CalcDialog entry point closed per ADR-FEED-05 / DEF-RATION-07;
          dialog component still mounted for the 🧮 "Подобрать" button inside SimpleRationEditor. */}

      {calcDialog && (
        <CalcDialog
          projectId={projectId}
          orgId={orgId}
          categoryId={calcDialog.categoryId}
          categoryName={calcDialog.categoryName}
          defaultWeight={calcDialog.defaultWeight}
          defaultHeadCount={calcDialog.defaultHeadCount}
          defaultObjective={calcDialog.defaultObjective}
          hasHerdData={!!herd}
          onClose={() => setCalcDialog(null)}
          onSaved={() => { setCalcDialog(null); refetch() }}
        />
      )}
    </div>
  )
}

// ─── Calc Dialog ──────────────────────────────────────────────────────────────

function CalcDialog({ projectId, orgId, categoryId, categoryName, defaultWeight, defaultHeadCount, defaultObjective, hasHerdData, onClose, onSaved }: {
  projectId: string
  orgId: string
  categoryId: string
  categoryName: string
  defaultWeight: number
  defaultHeadCount: number
  defaultObjective: string
  hasHerdData: boolean
  onClose: () => void
  onSaved: () => void
}) {
  const [avgWeight, setAvgWeight] = useState(String(defaultWeight))
  const [headCount, setHeadCount] = useState(String(defaultHeadCount))
  const [objective, setObjective] = useState(defaultObjective)
  const [selectedFeeds, setSelectedFeeds] = useState<string[]>([])
  const [calculating, setCalculating] = useState(false)

  const { data: feedItems } = useRpc<FeedItem[]>('rpc_list_feed_items', { p_active_only: true })

  const toggleFeed = (id: string) =>
    setSelectedFeeds(prev => prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id])

  const handleCalculate = async () => {
    if (!avgWeight || parseFloat(avgWeight) <= 0) return toast.error('Укажите живой вес')
    if (selectedFeeds.length === 0) return toast.error('Выберите корма для расчёта')

    setCalculating(true)
    try {
      const { data, error } = await supabase.functions.invoke('calculate-ration', {
        body: {
          organization_id: orgId,
          consulting_project_id: projectId,
          animal_category_id: categoryId,
          avg_weight_kg: parseFloat(avgWeight),
          head_count: parseInt(headCount) || 1,
          objective,
          feed_item_ids: selectedFeeds,
        },
      })

      if (error || data?.error) {
        // FunctionsHttpError.context is a Response — read body to get actual message
        let errMsg = data?.error || data?.message
        if (!errMsg && (error as any)?.context?.json) {
          try { const body = await (error as any).context.json(); errMsg = body?.error || body?.message } catch (_) {}
        }
        errMsg = errMsg || error?.message || 'Ошибка расчёта'
        console.error('[calculate-ration]', errMsg, error, data)
        toast.error(errMsg)
        return
      }

      toast.success(`Рацион рассчитан · v${data.version_number}`)
      onSaved()
    } catch (err: any) {
      toast.error(err.message || 'Ошибка расчёта')
    } finally {
      setCalculating(false)
    }
  }

  // Group feeds by category
  const grouped = (feedItems || []).reduce<Record<string, FeedItem[]>>((acc, f) => {
    if (!acc[f.category]) acc[f.category] = []
    acc[f.category]!.push(f)
    return acc
  }, {})

  return (
    <Dialog open onOpenChange={v => !v && onClose()}>
      <DialogContent className="max-w-lg max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Расчёт рациона — {categoryName}</DialogTitle>
        </DialogHeader>

        <div className="space-y-4 py-2">
          {/* Animal params */}
          <div className="grid grid-cols-3 gap-3">
            <div className="space-y-1">
              <Label className="text-xs">Живой вес (кг)</Label>
              <Input
                type="number" min="1" step="10"
                value={avgWeight} onChange={e => setAvgWeight(e.target.value)}
                className="h-8 text-sm"
              />
              {hasHerdData && (
                <p className="text-[10px] text-muted-foreground">из модели привеса</p>
              )}
            </div>
            <div className="space-y-1">
              <Label className="text-xs">Голов</Label>
              <Input
                type="number" min="1"
                value={headCount} onChange={e => setHeadCount(e.target.value)}
                className="h-8 text-sm"
              />
              {hasHerdData && (
                <p className="text-[10px] text-muted-foreground">из оборота стада</p>
              )}
            </div>
            <div className="space-y-1">
              <Label className="text-xs">Цель</Label>
              <Select value={objective} onValueChange={setObjective}>
                <SelectTrigger className="h-8 text-xs"><SelectValue /></SelectTrigger>
                <SelectContent>
                  {OBJECTIVES.map(o => (
                    <SelectItem key={o.value} value={o.value} className="text-xs">{o.label}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          {/* Feed selection */}
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <Label className="text-xs">Выберите корма для расчёта</Label>
              <span className="text-xs text-muted-foreground">{selectedFeeds.length} выбрано</span>
            </div>

            <div className="border border-border rounded-md max-h-52 overflow-y-auto">
              {Object.entries(grouped).map(([cat, feeds]) => (
                <div key={cat}>
                  <div className="px-3 py-1.5 bg-muted/50 text-xs font-medium text-muted-foreground border-b border-border/50">
                    {cat}
                  </div>
                  {feeds.map(f => (
                    <label
                      key={f.id}
                      className="flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-muted/30 border-b border-border/30 last:border-0"
                    >
                      <input
                        type="checkbox"
                        checked={selectedFeeds.includes(f.id)}
                        onChange={() => toggleFeed(f.id)}
                        className="rounded"
                      />
                      <span className="text-sm flex-1">{f.name_ru}</span>
                      {!f.is_validated && (
                        <Badge variant="outline" className="text-xs h-4">Q37</Badge>
                      )}
                    </label>
                  ))}
                </div>
              ))}
              {Object.keys(grouped).length === 0 && (
                <div className="p-4 text-center text-sm text-muted-foreground">
                  Нет кормов в каталоге. Добавьте корма в разделе «Кормовая база».
                </div>
              )}
            </div>
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={calculating}>Отмена</Button>
          <Button onClick={handleCalculate} disabled={calculating || selectedFeeds.length === 0}>
            {calculating ? 'Расчёт...' : 'Рассчитать и сохранить'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
