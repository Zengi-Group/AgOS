/**
 * SimpleRationEditor — табличный ввод рационов (кг/сут × корм × сезон)
 * Альтернатива NASEM-калькулятору для базового сценария.
 * Сохраняет через rpc_save_consulting_ration.
 */
import { useState, useCallback, useMemo, useEffect, useRef } from 'react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Save, RotateCcw, Calculator, CheckCircle } from 'lucide-react'
import { TuranLoader } from '@/components/TuranLoader'
import { supabase } from '@/lib/supabase'
import { useRpc } from '@/hooks/useRpc'
import { useAnimalCategoryMappings } from '@/hooks/useAnimalCategoryMappings'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Badge } from '@/components/ui/badge'
import { Checkbox } from '@/components/ui/checkbox'

interface FeedItem {
  id: string
  code: string
  name_ru: string
  category: string
  category_name_ru: string
}

interface FeedPrice {
  feed_item_id: string
  price_per_kg: number
}

/** Simplified ration groups matching expert scenario — static fallback (HS-5). */
const RATION_GROUPS = [
  { key: 'COW', label: 'Маточное поголовье', code: 'COW' },
  { key: 'SUCKLING_CALF', label: 'Молодняк (телята)', code: 'SUCKLING_CALF' },
  { key: 'HEIFER_YOUNG', label: 'Тёлки', code: 'HEIFER_YOUNG' },
  { key: 'STEER', label: 'Бычки', code: 'STEER' },
  { key: 'BULL_BREEDING', label: 'Быки-производители', code: 'BULL_BREEDING' },
]

/**
 * TAXONOMY-M3c: UI labels for feeding_group target codes.
 * These are presentation labels — NOT taxonomy data. Taxonomy provides the
 * canonical code (COW, STEER, …); the label is a UI concern kept here.
 * If a new group code lacks a label, the code itself is displayed as fallback.
 */
const FEEDING_GROUP_LABELS: Record<string, string> = {
  COW:           'Маточное поголовье',
  SUCKLING_CALF: 'Молодняк (телята)',
  HEIFER_YOUNG:  'Тёлки',
  STEER:         'Бычки',
  BULL_BREEDING: 'Быки-производители',
}

/** Default rations matching CFC Excel template (feeding_model.py hardcoded).
 * Exported so RationTab can compute feed volume preview before user saves. */
export const DEFAULT_RATIONS: Record<string, Record<string, { pasture: number; stall: number }>> = {
  COW: {
    green_mass: { pasture: 32, stall: 0 },
    hay: { pasture: 0, stall: 8 },
    straw: { pasture: 0, stall: 2 },
    concentrates: { pasture: 0, stall: 2 },
    salt: { pasture: 0.05, stall: 0.06 },
    bran_meal: { pasture: 0, stall: 1 },
  },
  SUCKLING_CALF: {
    green_mass: { pasture: 10, stall: 0 },
    hay: { pasture: 0, stall: 2.5 },
    concentrates: { pasture: 0, stall: 1 },
    salt: { pasture: 0.02, stall: 0.02 },
  },
  HEIFER_YOUNG: {
    green_mass: { pasture: 29, stall: 0 },
    hay: { pasture: 0, stall: 4 },
    haylage: { pasture: 0, stall: 5 },
    salt: { pasture: 0.03, stall: 0.03 },
  },
  STEER: {
    green_mass: { pasture: 29, stall: 0 },
    hay: { pasture: 0, stall: 4 },
    concentrates: { pasture: 0, stall: 2.5 },
    salt: { pasture: 0.03, stall: 0.03 },
  },
  BULL_BREEDING: {
    green_mass: { pasture: 12, stall: 0 },
    hay: { pasture: 0, stall: 8 },
    concentrates: { pasture: 0, stall: 2.78 },
    bran_meal: { pasture: 0, stall: 1 },
    salt: { pasture: 0.05, stall: 0.045 },
  },
}

/** Feed display names (ru). Exported for RationTab volume preview. */
export const FEED_NAMES: Record<string, string> = {
  green_mass: 'Зелёная масса',
  hay: 'Сено',
  straw: 'Солома',
  haylage: 'Сенаж',
  silage: 'Силос',
  concentrates: 'Концентраты',
  salt: 'Соль',
  bran_meal: 'Отруби/шрот',
  milk: 'Молоко',
  barley_meal: 'Дерть ячменная',
  feed_phosphate: 'Кормофос',
}

/** Base prices (same as feeding_model.py) */
const BASE_PRICES: Record<string, number> = {
  green_mass: 0,
  hay: 28,
  straw: 15,
  haylage: 28,
  silage: 15,
  concentrates: 80,
  salt: 145,
  bran_meal: 120,
  milk: 0,
  barley_meal: 36,
  feed_phosphate: 145,
}

/** NutritionBadge — shows nutrient balance status for a season. */
function NutritionBadge({ season, status }: {
  season: string;
  status: { met: boolean; deficiencies: string[] } | null;
}) {
  if (!status) return <span className="text-xs text-muted-foreground">{season}: —</span>
  if (status.met) return (
    <span className="text-xs font-medium text-[var(--green)]">🟢 {season}</span>
  )
  return (
    <span className="text-xs font-medium text-[var(--amber)]" title={status.deficiencies.join(', ')}>
      🟡 {season}: {status.deficiencies.slice(0, 2).join(', ')}
    </span>
  )
}

/** Type alias exported so RationTab can type liveRations state. */
export type RationsState = Record<string, Record<string, { pasture: number; stall: number }>>

export function SimpleRationEditor({
  projectId,
  orgId,
  onSaved,
  onRationsChange,
  initialRations,
}: {
  projectId: string
  orgId: string
  onSaved: () => void
  /** Called on every rations change (including initial mount) so parent can show live volumes. */
  onRationsChange?: (rations: RationsState) => void
  /** Saved rations from DB — seeded once on mount when available. */
  initialRations?: RationsState
}) {
  const [activeGroup, setActiveGroup] = useState<string>(RATION_GROUPS[0]?.key ?? 'COW')
  const [rations, setRations] = useState<RationsState>(
    () => JSON.parse(JSON.stringify(DEFAULT_RATIONS))
  )
  const [saving, setSaving] = useState(false)

  // One-time seed from DB rations (ADR-FEED-CLIENT-01 Fix #1).
  // hasLoadedFromDb prevents re-seeding when parent re-renders.
  const hasLoadedFromDb = useRef(false)
  useEffect(() => {
    if (!hasLoadedFromDb.current && initialRations && Object.keys(initialRations).length > 0) {
      hasLoadedFromDb.current = true
      // Merge over DEFAULT_RATIONS so groups with no saved ration keep defaults
      setRations({ ...JSON.parse(JSON.stringify(DEFAULT_RATIONS)), ...initialRations })
    }
  }, [initialRations])

  // Notify parent of rations state on every change (including initial mount).
  // Parent (RationTab) uses this for live feed-volume preview.
  useEffect(() => {
    onRationsChange?.(rations)
  }, [rations, onRationsChange])

  // ADR-FEED-05 §10: NASEM Подобрать state
  const [suggestDialog, setSuggestDialog] = useState<{
    groupCode: string
    season: 'pasture' | 'stall'
    groupLabel: string
  } | null>(null)
  const [suggestResult, setSuggestResult] = useState<{
    items: Array<{ feed_item_id: string; feed_code: string; quantity_kg_per_day: number; unit_price: number; total_cost_per_day: number }>
    nutrients_met: Record<string, boolean>
    deficiencies: string[]
  } | null>(null)
  const [suggestLoading, setSuggestLoading] = useState(false)
  const [suggestParams, setSuggestParams] = useState({
    weight: 450,
    objective: 'maintenance',
    feed_item_ids: [] as string[],
  })
  const [nutritionStatus, setNutritionStatus] = useState<Record<string, {
    pasture: { met: boolean; deficiencies: string[] } | null;
    stall:   { met: boolean; deficiencies: string[] } | null;
    loading: boolean;
  }>>({})
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const feedCodeToIdRef = useRef<Map<string, string>>(new Map())

  // TAXONOMY-M3c: dynamic feeding groups from DB (staleTime=60s, fallback to static RATION_GROUPS)
  const { data: feedingGroupData } = useAnimalCategoryMappings('feeding_group')
  const rationGroups = useMemo(() => {
    if (!feedingGroupData || feedingGroupData.length === 0) return RATION_GROUPS
    const seen = new Set<string>()
    const groups: Array<{ key: string; label: string; code: string }> = []
    for (const row of feedingGroupData) {
      if (!row.is_primary || seen.has(row.target_code)) continue
      seen.add(row.target_code)
      groups.push({
        key: row.target_code,
        label: FEEDING_GROUP_LABELS[row.target_code] ?? row.target_code,
        code: row.target_code,
      })
    }
    return groups.length > 0 ? groups : RATION_GROUPS
  }, [feedingGroupData])

  // Load feed items, prices and animal categories for ID resolution
  const { data: feedItems } = useRpc<FeedItem[]>('rpc_list_feed_items', { p_active_only: true })
  const { data: feedPrices } = useRpc<FeedPrice[]>('rpc_list_feed_prices', {})
  const { data: animalCategories } = useRpc<{ id: string; code: string }[]>(
    'rpc_list_animal_categories',
    { p_at_date: null, p_include_deprecated: false },
  )

  // Build animal category code → UUID map
  const animalCategoryToId = new Map<string, string>()
  ;(animalCategories || []).forEach(ac => animalCategoryToId.set(ac.code, ac.id))

  // Build feed code→id and code→price maps
  const feedCodeToId = new Map<string, string>()
  const feedCodeToPrice = new Map<string, number>()
  ;(feedItems || []).forEach(f => {
    // Map simplified names to feed item codes
    const simpleMap: Record<string, string> = {
      green_mass: 'PASTURE_SUMMER',
      hay: 'HAY_MIXED_GRASS',
      straw: 'STRAW_WHEAT',
      haylage: 'HAYLAGE_GRASS',
      silage: 'SILAGE_CORN',
      concentrates: 'GRAIN_BARLEY',
      salt: 'SALT_NaCl',
      bran_meal: 'MEAL_SUNFLOWER',
      // milk has no DB feed_item entry (dam's milk, not purchased) — excluded from ID map
      barley_meal: 'GRAIN_BARLEY',
      feed_phosphate: 'PREMIX_BEEF',
    }
    for (const [simple, code] of Object.entries(simpleMap)) {
      if (f.code === code) feedCodeToId.set(simple, f.id)
    }
  })
  ;(feedPrices || []).forEach(fp => {
    const entry = (feedItems || []).find(f => f.id === fp.feed_item_id)
    if (entry) {
      // reverse map
      for (const [simple, code] of Object.entries({
        hay: 'HAY_MIXED_GRASS', straw: 'STRAW_WHEAT', haylage: 'HAYLAGE_GRASS',
        silage: 'SILAGE_CORN', concentrates: 'GRAIN_BARLEY', salt: 'SALT_NaCl',
        bran_meal: 'MEAL_SUNFLOWER', barley_meal: 'GRAIN_BARLEY', feed_phosphate: 'PREMIX_BEEF',
      })) {
        if (entry.code === code) feedCodeToPrice.set(simple, fp.price_per_kg)
      }
    }
  })

  // Keep ref in sync with the latest feedCodeToId map (built each render from feedItems)
  feedCodeToIdRef.current = feedCodeToId

  // checkNutrition: calls Edge Function in check_only mode for pasture + stall
  const checkNutrition = useCallback(async (group: string, groupRation: Record<string, { pasture: number; stall: number }>) => {
    const idMap = feedCodeToIdRef.current
    if (idMap.size === 0) return

    const buildItems = (season: 'pasture' | 'stall') =>
      Object.entries(groupRation)
        .filter(([feed, vals]) => vals[season] > 0 && idMap.has(feed))
        .reduce<Array<{ feed_item_id: string; quantity_kg_per_day: number }>>((acc, [feed, vals]) => {
          const id = idMap.get(feed)
          if (id) acc.push({ feed_item_id: id, quantity_kg_per_day: vals[season] })
          return acc
        }, [])

    const pastureItems = buildItems('pasture')
    const stallItems   = buildItems('stall')

    if (pastureItems.length === 0 && stallItems.length === 0) return

    setNutritionStatus(prev => ({
      ...prev,
      [group]: { pasture: prev[group]?.pasture ?? null, stall: prev[group]?.stall ?? null, loading: true },
    }))

    const supabaseUrl = (supabase as any).supabaseUrl as string | undefined
    const edgeFnBase = supabaseUrl ? `${supabaseUrl}/functions/v1/calculate-ration` : '/functions/v1/calculate-ration'

    const callCheck = async (items: Array<{ feed_item_id: string; quantity_kg_per_day: number }>) => {
      if (items.length === 0) return null
      try {
        const res = await fetch(edgeFnBase, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            organization_id: orgId,
            consulting_project_id: projectId,
            animal_category_id: group, // will be resolved server-side; pass code as fallback
            avg_weight_kg: 400,        // neutral default for check_only
            head_count: 1,
            check_only: true,
            check_ration_items: items,
          }),
        })
        if (!res.ok) return null
        const data = await res.json()
        return data.check_only
          ? { met: Object.values(data.nutrients_met as Record<string, boolean>).every(Boolean), deficiencies: data.deficiencies as string[] }
          : null
      } catch {
        return null
      }
    }

    const [pastureResult, stallResult] = await Promise.all([
      callCheck(pastureItems),
      callCheck(stallItems),
    ])

    setNutritionStatus(prev => ({
      ...prev,
      [group]: { pasture: pastureResult, stall: stallResult, loading: false },
    }))
  }, [orgId, projectId])

  // Debounced trigger: re-check whenever active group ration changes
  useEffect(() => {
    const groupRation = rations[activeGroup]
    if (!groupRation) return
    if (debounceRef.current) clearTimeout(debounceRef.current)
    debounceRef.current = setTimeout(() => {
      checkNutrition(activeGroup, groupRation)
    }, 300)
    return () => { if (debounceRef.current) clearTimeout(debounceRef.current) }
  }, [rations, activeGroup, checkNutrition])

  const currentGroup = rations[activeGroup] || {}

  const setFeedValue = useCallback((feed: string, season: 'pasture' | 'stall', value: number) => {
    setRations(prev => {
      const next = { ...prev }
      if (!next[activeGroup]) next[activeGroup] = {}
      if (!next[activeGroup][feed]) next[activeGroup][feed] = { pasture: 0, stall: 0 }
      next[activeGroup] = { ...next[activeGroup] }
      const existing = next[activeGroup][feed] || { pasture: 0, stall: 0 }
      next[activeGroup][feed] = { pasture: existing.pasture, stall: existing.stall, [season]: value }
      return next
    })
  }, [activeGroup])

  const addFeed = useCallback((feed: string) => {
    setRations(prev => {
      const next = { ...prev }
      if (!next[activeGroup]) next[activeGroup] = {}
      next[activeGroup] = { ...next[activeGroup], [feed]: { pasture: 0, stall: 0 } }
      return next
    })
  }, [activeGroup])

  // Calculate daily cost for current group
  const dailyCostPasture = Object.entries(currentGroup).reduce((sum, [feed, vals]) => {
    const price = feedCodeToPrice.get(feed) ?? BASE_PRICES[feed] ?? 0
    return sum + price * vals.pasture
  }, 0)

  const dailyCostStall = Object.entries(currentGroup).reduce((sum, [feed, vals]) => {
    const price = feedCodeToPrice.get(feed) ?? BASE_PRICES[feed] ?? 0
    return sum + price * vals.stall
  }, 0)

  // ADR-FEED-05 §10: call Edge Function in suggest mode
  const handleSuggest = async () => {
    if (!suggestDialog) return
    setSuggestLoading(true)
    setSuggestResult(null)
    try {
      const { data, error } = await supabase.functions.invoke('calculate-ration', {
        body: {
          organization_id: orgId,
          consulting_project_id: projectId,
          animal_category_id: animalCategoryToId.get(suggestDialog.groupCode) || suggestDialog.groupCode,
          feed_item_ids: suggestParams.feed_item_ids,
          avg_weight_kg: suggestParams.weight,
          head_count: 1,
          objective: suggestParams.objective,
          season: suggestDialog.season,
          mode: 'suggest',
        },
      })
      if (error) throw error
      setSuggestResult(data)
    } catch (e: any) {
      toast.error('Ошибка подбора: ' + (e.message || String(e)))
    } finally {
      setSuggestLoading(false)
    }
  }

  // ADR-FEED-05 §10: apply NASEM suggestion into rations state
  const handleApplySuggest = () => {
    if (!suggestDialog || !suggestResult) return
    const { groupCode, season } = suggestDialog
    setRations(prev => {
      const updated = { ...prev }
      const existingGroup = { ...(updated[groupCode] || {}) }
      // Apply suggested items — zero out other entries for this season first
      const newGroup: Record<string, { pasture: number; stall: number }> = {}
      for (const [fc, seasonVals] of Object.entries(existingGroup)) {
        newGroup[fc] = { ...seasonVals, [season]: 0 }
      }
      for (const item of suggestResult.items) {
        const fc = item.feed_code
        if (!newGroup[fc]) newGroup[fc] = { pasture: 0, stall: 0 }
        newGroup[fc] = { ...newGroup[fc], [season]: item.quantity_kg_per_day }
      }
      updated[groupCode] = newGroup
      return updated
    })
    toast.success('Рацион вставлен в Simple. Проверьте и сохраните.')
    setSuggestDialog(null)
    setSuggestResult(null)
  }

  // Save all groups as consulting rations
  const handleSave = async () => {
    setSaving(true)
    try {
      // For each group, save a ration with combined items
      for (const group of rationGroups) {
        const groupRation = rations[group.key]
        if (!groupRation) continue

        // Build separate pasture and stall item arrays (DEF-RATION-01)
        // Skip feeds with no DB ID (e.g. milk — dam's feed, not purchased)
        const pastureItems = Object.entries(groupRation)
          .filter(([feed, vals]) => vals.pasture > 0 && feedCodeToId.has(feed))
          .map(([feed, vals]) => {
            const price = feedCodeToPrice.get(feed) ?? BASE_PRICES[feed] ?? 0
            return {
              feed_item_id: feedCodeToId.get(feed) || feed,
              feed_item_code: feed,
              quantity_kg_per_day: Number(vals.pasture.toFixed(3)),
              effective_price_per_kg: price,
              cost_per_day: Number((vals.pasture * price).toFixed(2)),
            }
          })

        const stallItems = Object.entries(groupRation)
          .filter(([feed, vals]) => vals.stall > 0 && feedCodeToId.has(feed))
          .map(([feed, vals]) => {
            const price = feedCodeToPrice.get(feed) ?? BASE_PRICES[feed] ?? 0
            return {
              feed_item_id: feedCodeToId.get(feed) || feed,
              feed_item_code: feed,
              quantity_kg_per_day: Number(vals.stall.toFixed(3)),
              effective_price_per_kg: price,
              cost_per_day: Number((vals.stall * price).toFixed(2)),
            }
          })

        // p_items: year-average for RPC backward compatibility
        const items = Object.entries(groupRation)
          .filter(([feed, vals]) => (vals.stall > 0 || vals.pasture > 0) && feedCodeToId.has(feed))
          .map(([feed, vals]) => {
            const price = feedCodeToPrice.get(feed) ?? BASE_PRICES[feed] ?? 0
            const avgKg = (vals.pasture * 183 + vals.stall * 182) / 365
            return {
              feed_item_id: feedCodeToId.get(feed) || feed,
              feed_item_code: feed,
              quantity_kg_per_day: Number(avgKg.toFixed(3)),
              effective_price_per_kg: price,
              cost_per_day: Number((avgKg * price).toFixed(2)),
            }
          })

        if (items.length === 0) continue

        const dailyCostPastureGroup = pastureItems.reduce((s, i) => s + i.cost_per_day, 0)
        const dailyCostStallGroup = stallItems.reduce((s, i) => s + i.cost_per_day, 0)
        // Weighted average: 6 pasture months + 6 stall months
        const avgDailyCost = Number(((dailyCostPastureGroup * 6 + dailyCostStallGroup * 6) / 12).toFixed(2))

        // Resolve animal category UUID
        const categoryId = animalCategoryToId.get(group.code)
        if (!categoryId) {
          console.warn(`[SimpleRation] No UUID for category ${group.code}, skipping`)
          continue
        }

        // Call RPC directly (simpler than Edge Function for manual input)
        const { error } = await supabase.rpc('rpc_save_consulting_ration', {
          p_organization_id: orgId,
          p_consulting_project_id: projectId,
          p_animal_category_id: categoryId,
          p_items: items,
          p_results: {
            // Seasonal split — primary data (DEF-RATION-01)
            pasture: {
              items: pastureItems,
              total_cost_per_day: Number(dailyCostPastureGroup.toFixed(2)),
            },
            stall: {
              items: stallItems,
              total_cost_per_day: Number(dailyCostStallGroup.toFixed(2)),
            },
            source: 'simple_editor',
            // Weighted average for display and backward compat
            total_cost_per_day: avgDailyCost,
            total_cost_per_month: Number((avgDailyCost * 30.44).toFixed(2)),
          },
        })

        if (error) {
          console.error(`[SimpleRation] ${group.key}:`, error)
          toast.error(`Ошибка сохранения: ${group.label}`)
          return
        }
      }

      toast.success('Рационы сохранены')
      onSaved()
    } catch (err: any) {
      toast.error(err.message || 'Ошибка сохранения')
    } finally {
      setSaving(false)
    }
  }

  const handleReset = () => {
    setRations(JSON.parse(JSON.stringify(DEFAULT_RATIONS)))
    toast.info('Рационы сброшены на нормативные')
  }

  return (
    <div className="space-y-4">
      {/* Group tabs */}
      <div className="flex gap-1 overflow-x-auto">
        {rationGroups.map(g => (
          <Button
            key={g.key}
            variant={activeGroup === g.key ? 'default' : 'outline'}
            size="sm"
            className="text-xs whitespace-nowrap"
            onClick={() => setActiveGroup(g.key)}
          >
            {g.label}
          </Button>
        ))}
      </div>

      {/* Ration table */}
      <Card>
        <CardHeader className="py-3 px-4">
          <CardTitle className="text-sm">
            {rationGroups.find(g => g.key === activeGroup)?.label} — рацион кг/гол/сут
          </CardTitle>
          {nutritionStatus[activeGroup] && !nutritionStatus[activeGroup].loading && (
            <div className="flex gap-2 mt-1">
              <NutritionBadge season="Пастбище" status={nutritionStatus[activeGroup].pasture} />
              <NutritionBadge season="Стойло"   status={nutritionStatus[activeGroup].stall} />
            </div>
          )}
        </CardHeader>
        <CardContent className="px-0 pb-3">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-xs text-muted-foreground">
                <th className="px-4 py-2 text-left font-medium">Корм</th>
                <th className="px-2 py-2 text-right font-medium w-28">
                  <span className="flex items-center justify-end gap-1">
                    Пастбище
                    <Button variant="ghost" size="icon" className="h-5 w-5 shrink-0" title="Подобрать рацион (NASEM)"
                      onClick={() => setSuggestDialog({ groupCode: activeGroup, season: 'pasture', groupLabel: `${rationGroups.find(g => g.key === activeGroup)?.label ?? activeGroup} — Пастбище` })}>
                      <Calculator className="w-3 h-3" />
                    </Button>
                  </span>
                </th>
                <th className="px-2 py-2 text-right font-medium w-28">
                  <span className="flex items-center justify-end gap-1">
                    Стойло
                    <Button variant="ghost" size="icon" className="h-5 w-5 shrink-0" title="Подобрать рацион (NASEM)"
                      onClick={() => setSuggestDialog({ groupCode: activeGroup, season: 'stall', groupLabel: `${rationGroups.find(g => g.key === activeGroup)?.label ?? activeGroup} — Стойло` })}>
                      <Calculator className="w-3 h-3" />
                    </Button>
                  </span>
                </th>
                <th className="px-2 py-2 text-right font-medium w-24">Цена тг/кг</th>
              </tr>
            </thead>
            <tbody>
              {Object.entries(currentGroup)
                .filter(([feed]) => feed in FEED_NAMES)
                .map(([feed, vals]) => {
                  const price = feedCodeToPrice.get(feed) ?? BASE_PRICES[feed] ?? 0
                  return (
                    <tr key={feed} className="border-b border-border/30 hover:bg-muted/20">
                      <td className="px-4 py-1.5 text-sm">{FEED_NAMES[feed] || feed}</td>
                      <td className="px-2 py-1.5">
                        <Input
                          type="number"
                          min="0"
                          step="0.1"
                          value={vals.pasture || ''}
                          onChange={e => setFeedValue(feed, 'pasture', Number(e.target.value) || 0)}
                          className="h-7 w-24 text-right font-mono text-xs ml-auto"
                          placeholder="—"
                        />
                      </td>
                      <td className="px-2 py-1.5">
                        <Input
                          type="number"
                          min="0"
                          step="0.1"
                          value={vals.stall || ''}
                          onChange={e => setFeedValue(feed, 'stall', Number(e.target.value) || 0)}
                          className="h-7 w-24 text-right font-mono text-xs ml-auto"
                          placeholder="—"
                        />
                      </td>
                      <td className="px-2 py-1.5 text-right font-mono text-xs text-muted-foreground">
                        {price > 0 ? price : '—'}
                      </td>
                    </tr>
                  )
                })}
            </tbody>
          </table>

          {/* Add feed */}
          {Object.keys(FEED_NAMES).filter(f => !(f in currentGroup)).length > 0 && (
            <div className="px-4 pt-2">
              <select
                className="text-xs border rounded px-2 py-1 text-muted-foreground"
                onChange={e => { if (e.target.value) addFeed(e.target.value); e.target.value = '' }}
                defaultValue=""
              >
                <option value="" disabled>+ Добавить корм...</option>
                {Object.entries(FEED_NAMES)
                  .filter(([k]) => !(k in currentGroup))
                  .map(([k, name]) => (
                    <option key={k} value={k}>{name}</option>
                  ))}
              </select>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Cost summary */}
      <div className="flex items-center justify-between rounded-lg border border-border/50 bg-muted/30 px-4 py-3">
        <div className="space-y-0.5">
          <p className="text-xs text-muted-foreground">Стоимость рациона (текущая группа)</p>
          <div className="flex gap-4 text-sm">
            <span>Пастбище: <strong className="font-mono">{dailyCostPasture.toFixed(0)} тг/гол/день</strong></span>
            <span>Стойло: <strong className="font-mono">{dailyCostStall.toFixed(0)} тг/гол/день</strong></span>
          </div>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={handleReset}>
            <RotateCcw className="w-3 h-3 mr-1" /> Сброс
          </Button>
          <Button size="sm" onClick={handleSave} disabled={saving}>
            <Save className="w-3 h-3 mr-1" /> {saving ? 'Сохранение...' : 'Сохранить все'}
          </Button>
        </div>
      </div>
      {/* ADR-FEED-05 §10: NASEM Подобрать Dialog */}
      {suggestDialog && (
        <Dialog open={true} onOpenChange={() => { setSuggestDialog(null); setSuggestResult(null) }}>
          <DialogContent className="sm:max-w-[560px] max-h-[90vh] overflow-y-auto">
            <DialogHeader>
              <DialogTitle>🧮 Подобрать рацион — {suggestDialog.groupLabel}</DialogTitle>
              <DialogDescription>NASEM LP-solver предложит оптимальный состав. Вы можете принять или скорректировать.</DialogDescription>
            </DialogHeader>

            <div className="space-y-4">
              {/* Params */}
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <Label>Живой вес (кг)</Label>
                  <input
                    type="number"
                    className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm mt-1"
                    value={suggestParams.weight}
                    onChange={e => setSuggestParams(p => ({ ...p, weight: Number(e.target.value) }))}
                  />
                </div>
                <div>
                  <Label>Цель</Label>
                  <Select value={suggestParams.objective}
                    onValueChange={v => setSuggestParams(p => ({ ...p, objective: v }))}>
                    <SelectTrigger className="mt-1"><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="maintenance">Поддержание</SelectItem>
                      <SelectItem value="growth">Рост</SelectItem>
                      <SelectItem value="gestation">Стельность</SelectItem>
                      <SelectItem value="lactation">Лактация</SelectItem>
                      <SelectItem value="finishing">Финишный откорм</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </div>

              {/* Feed selection — grouped by category */}
              {(() => {
                const CATEGORY_ICONS: Record<string, string> = {
                  ROUGHAGE:     '🌾',
                  SILAGE:       '🌽',
                  CONCENTRATE:  '🌰',
                  PROTEIN_SUPP: '🫘',
                  MINERAL:      '🧂',
                  PASTURE:      '🌿',
                }

                // Group feedItems by category
                const grouped = (feedItems || []).reduce<Record<string, { name: string; icon: string; items: FeedItem[] }>>(
                  (acc, f) => {
                    const key = f.category
                    if (!acc[key]) acc[key] = { name: f.category_name_ru || key, icon: CATEGORY_ICONS[key] ?? '•', items: [] }
                    acc[key]!.items.push(f)
                    return acc
                  },
                  {}
                )

                const totalSelected = suggestParams.feed_item_ids.length

                const toggleAll = (ids: string[], select: boolean) =>
                  setSuggestParams(p => ({
                    ...p,
                    feed_item_ids: select
                      ? [...new Set([...p.feed_item_ids, ...ids])]
                      : p.feed_item_ids.filter(id => !ids.includes(id)),
                  }))

                return (
                  <div className="space-y-1">
                    <div className="flex items-center justify-between mb-2">
                      <Label>Корма для подбора</Label>
                      {totalSelected > 0 && (
                        <button
                          type="button"
                          className="text-xs text-muted-foreground hover:text-foreground transition-colors"
                          onClick={() => setSuggestParams(p => ({ ...p, feed_item_ids: [] }))}
                        >
                          Сбросить все
                        </button>
                      )}
                    </div>

                    <div className="border rounded-lg overflow-hidden divide-y">
                      {Object.entries(grouped).map(([catCode, { name, icon, items }]) => {
                        const catIds = items.map(f => f.id)
                        const selectedInCat = catIds.filter(id => suggestParams.feed_item_ids.includes(id)).length
                        const allSelected = selectedInCat === items.length

                        return (
                          <div key={catCode}>
                            {/* Category header */}
                            <div className="flex items-center justify-between px-3 py-2 bg-muted/40">
                              <div className="flex items-center gap-2">
                                <span className="text-sm">{icon}</span>
                                <span className="text-xs font-semibold text-foreground">{name}</span>
                                {selectedInCat > 0 && (
                                  <span className="text-xs text-muted-foreground">({selectedInCat}/{items.length})</span>
                                )}
                              </div>
                              <button
                                type="button"
                                className="text-xs text-primary hover:underline"
                                onClick={() => toggleAll(catIds, !allSelected)}
                              >
                                {allSelected ? 'Убрать все' : 'Выбрать все'}
                              </button>
                            </div>

                            {/* Feed rows */}
                            <div className="divide-y divide-border/40">
                              {items.map(f => {
                                const checked = suggestParams.feed_item_ids.includes(f.id)
                                return (
                                  <label
                                    key={f.id}
                                    className="flex items-center gap-3 px-3 py-2 cursor-pointer hover:bg-muted/30 transition-colors"
                                  >
                                    <Checkbox
                                      checked={checked}
                                      onCheckedChange={(v) =>
                                        setSuggestParams(p => ({
                                          ...p,
                                          feed_item_ids: v
                                            ? [...p.feed_item_ids, f.id]
                                            : p.feed_item_ids.filter(id => id !== f.id),
                                        }))
                                      }
                                    />
                                    <span className="text-sm select-none">{f.name_ru || f.code}</span>
                                  </label>
                                )
                              })}
                            </div>
                          </div>
                        )
                      })}
                    </div>
                  </div>
                )
              })()}

              {/* Run button */}
              <Button className="w-full" disabled={suggestLoading || suggestParams.feed_item_ids.length === 0}
                onClick={handleSuggest}>
                {suggestLoading
                  ? <><TuranLoader variant="spin" size={16} className="mr-2" />Считаем...</>
                  : `🧮 Подобрать${suggestParams.feed_item_ids.length > 0 ? ` (${suggestParams.feed_item_ids.length})` : ''}`}
              </Button>

              {/* Preview result */}
              {suggestResult && (
                <div className="space-y-3">
                  <div className="flex items-center gap-2">
                    <CheckCircle className="w-4 h-4 text-[var(--green)]" />
                    <span className="text-sm font-medium">Предложение NASEM</span>
                    {suggestResult.deficiencies.length > 0
                      ? <Badge variant="destructive" className="text-xs">{suggestResult.deficiencies.length} дефицит</Badge>
                      : <Badge className="text-xs bg-[var(--green)] text-[var(--cta-fg)]">Баланс ✓</Badge>
                    }
                  </div>

                  {/* Diff table: было → станет */}
                  <div className="border rounded-md overflow-hidden text-xs">
                    <div className="grid grid-cols-3 bg-muted px-3 py-1.5 font-medium">
                      <span>Корм</span>
                      <span className="text-right">Было</span>
                      <span className="text-right">NASEM</span>
                    </div>
                    {suggestResult.items.map(item => {
                      const feedName = (feedItems || []).find(f => f.id === item.feed_item_id)?.name_ru || item.feed_code
                      const currentVal = rations[suggestDialog.groupCode]?.[item.feed_code]?.[suggestDialog.season] ?? 0
                      return (
                        <div key={item.feed_item_id} className="grid grid-cols-3 px-3 py-1 border-t">
                          <span className="truncate">{feedName}</span>
                          <span className="text-right text-muted-foreground">
                            {currentVal > 0 ? `${currentVal} кг` : '—'}
                          </span>
                          <span className="text-right font-medium">{item.quantity_kg_per_day} кг</span>
                        </div>
                      )
                    })}
                  </div>

                  {/* Apply button */}
                  <Button variant="default" className="w-full" onClick={handleApplySuggest}>
                    ✅ Вставить в Simple
                  </Button>
                </div>
              )}
            </div>
          </DialogContent>
        </Dialog>
      )}
    </div>
  )
}
