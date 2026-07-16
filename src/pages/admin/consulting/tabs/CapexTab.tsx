import { useState, useEffect, useRef } from 'react'
import { Card, CardContent } from '@/components/ui/card'
import { useParams } from 'react-router-dom'
import { Skeleton } from '@/components/ui/skeleton'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Checkbox } from '@/components/ui/checkbox'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { AlertCircle, ChevronDown, ChevronRight, Package } from 'lucide-react'
import { TuranLoader } from '@/components/TuranLoader'
import { useRpc } from '@/hooks/useRpc'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'
import { calculateProject } from '@/lib/consulting-api'
import { toast } from 'sonner'
import { useProjectData, fmt, cacheResults } from './usProjectData'

/** ADR-CAPEX-01: shape of per-item override row saved to consulting_projects.infra_items_override. */
interface OverrideRow {
  code: string
  include?: boolean
  qty_override?: number
  material_override?: string
  unit_cost_override?: number
}

/** Shape of each item emitted by capex.py Priority 2 path. Legacy Priority 3 items have a subset. */
interface CapexItem {
  code: string
  name?: string
  cost: number
  cost_model?: string
  applies_to?: string
  material_target?: string | null
  material_resolved?: string | null
  depreciation_years?: number
  qty?: number | null
  area_m2?: number | null
  calving_multiplier?: number
  included?: boolean
}

interface Material {
  code: string
  name_ru: string
  cost_per_m2: number
}

const BLOCK_CONFIG = [
  { key: 'farm',      title: 'Основная ферма', color: '#2563eb' },
  { key: 'pasture',   title: 'Пастбища',        color: '#16a34a' },
  { key: 'equipment', title: 'Техника',          color: '#d97706' },
  { key: 'tools',     title: 'Инструменты',      color: '#7c3aed' },
]


export function CapexTab() {
  const { organization } = useAuth()
  const { projectId } = useParams()
  const { results, version, loading, refetch } = useProjectData()
  const { data: materialsData } = useRpc<Material[]>('rpc_list_construction_materials', {})
  const orgId = organization?.id

  const [overrides, setOverrides] = useState<OverrideRow[]>([])
  const [saving, setSaving] = useState(false)
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const initialOverridesRef = useRef<string>('[]')

  // Seed local overrides from the last saved version (calculate.py injects
  // project-row infra_items_override into input_params before persistence,
  // so version.input_params is the authoritative snapshot).
  useEffect(() => {
    const existing: OverrideRow[] = version?.input_params?.infra_items_override || []
    setOverrides(existing)
    initialOverridesRef.current = JSON.stringify(existing)
  }, [version])

  if (loading) return (
    <div className="page space-y-2">
      <Skeleton className="h-5 w-44 mb-2" />
      {Array.from({ length: 10 }, (_, i) => (
        <div key={i} className="flex gap-3 items-center">
          <Skeleton className="h-3.5 grow" />
          <Skeleton className="h-3.5 w-16 shrink-0" />
          <Skeleton className="h-3.5 w-16 shrink-0" />
        </div>
      ))}
    </div>
  )
  if (!version) return (
    <div className="page">
      <Card className="w-full">
        <CardContent className="flex flex-col items-center py-12">
          <Package className="mb-4 h-10 w-10 text-muted-foreground" />
          <p className="text-muted-foreground">Нет данных. Запустите расчёт.</p>
        </CardContent>
      </Card>
    </div>
  )

  const materials: Material[] = materialsData || []
  const priority = results.capex?.priority_used
  const isLegacy = priority !== 2  // Priority 3 fallback OR missing → disable editing
  const editingDisabled = isLegacy || saving
  const isDirty = JSON.stringify(overrides) !== initialOverridesRef.current

  const overrideByCode = new Map(overrides.map(o => [o.code, o]))

  function upsertOverride(code: string, patch: Partial<OverrideRow>) {
    setOverrides(prev => {
      const existing = prev.find(o => o.code === code) || { code }
      const merged: OverrideRow = { ...existing, ...patch }
      // If all editable fields are now undefined → remove the entry (back to defaults).
      const hasContent =
        merged.include === false ||
        merged.qty_override !== undefined ||
        merged.material_override !== undefined ||
        merged.unit_cost_override !== undefined
      const filtered = prev.filter(o => o.code !== code)
      return hasContent ? [...filtered, merged] : filtered
    })
  }

  function handleReset() {
    try {
      setOverrides(JSON.parse(initialOverridesRef.current) as OverrideRow[])
    } catch {
      setOverrides([])
    }
  }

  async function handleSave() {
    if (!orgId || !projectId) return
    const inputParams = version?.input_params
    if (!inputParams) {
      toast.error('Нет параметров для пересчёта. Откройте вкладку Параметры и запустите расчёт.')
      return
    }

    setSaving(true)
    try {
      // Step 1: write overrides to consulting_projects. Materials are not
      // touched here (wizard owns them) — pass null so coalesce preserves.
      const { error: saveError } = await supabase.rpc('rpc_save_project_infra_override', {
        p_organization_id: orgId,
        p_project_id: projectId,
        p_enclosed: null,
        p_support: null,
        p_overrides: overrides,
      })
      if (saveError) {
        toast.error(saveError.message || 'Ошибка сохранения')
        return
      }

      toast.success('Сохранено. Пересчитываю…')

      // Step 2: trigger recalculation. calculate.py reads the fresh override
      // from the project row and injects into input_params before engine run.
      const result = await calculateProject({
        project_id: projectId,
        organization_id: orgId,
        input_params: inputParams,
      })
      cacheResults(projectId, result.results, inputParams)
      await refetch()
      initialOverridesRef.current = JSON.stringify(overrides)
      toast.success(`Пересчёт готов (версия ${result.version_number})`)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Ошибка пересчёта'
      toast.error(msg)
    } finally {
      setSaving(false)
    }
  }

  const materialsUsed = results.capex?.materials_used

  // Live preview grand total — recomputes whenever overrides change (bug fix)
  const previewGrandTotal = BLOCK_CONFIG.reduce((acc, { key }) => {
    const data = results.capex?.[key] as { items?: CapexItem[]; subtotal?: number; work_surcharge?: number; contingency?: number } | undefined
    const items: CapexItem[] = data?.items || []
    const sub = items.reduce((s, item) => {
      const ov = overrideByCode.get(item.code) || { code: item.code }
      return s + computePreviewCost(item, ov, materials)
    }, 0)
    const sRate = data?.subtotal && data.subtotal > 0 && data.work_surcharge != null ? data.work_surcharge / data.subtotal : 0
    const cRate = data?.subtotal && data.subtotal > 0 && data.contingency != null ? data.contingency / data.subtotal : 0
    return acc + sub * (1 + sRate + cRate)
  }, 0)
  const enclosedName = materialsUsed ? getMaterialName(materials, materialsUsed.enclosed) : null
  const supportName = materialsUsed ? getMaterialName(materials, materialsUsed.support) : null

  return (
    <div className="page pb-6">

      {/* Legacy banner */}
      {isLegacy && (
        <div className="mb-4 flex items-start gap-3 rounded-lg border border-[var(--amber)]/30 bg-[var(--amber-m)] px-4 py-3">
          <AlertCircle className="h-4 w-4 shrink-0 text-[var(--amber)] mt-0.5" />
          <div className="text-sm">
            <p className="font-medium text-[var(--amber)]">Старая модель CAPEX</p>
            <p className="text-[var(--amber)] opacity-80 mt-0.5">
              Проект рассчитан до обновления методики. Редактирование появится после пересчёта во вкладке «Параметры».
            </p>
          </div>
        </div>
      )}

      {/* ── Summary strip — sticky under tabs ──────────────────────── */}
      <div
        className="sticky top-0 z-10 -mx-7 px-7 py-4 grid grid-cols-2 md:grid-cols-5 gap-2"
        style={{ background: 'var(--bg)', borderBottom: '1px solid var(--bd)' }}
      >
        {BLOCK_CONFIG.map(({ key, title, color }) => {
          const data = results.capex?.[key] as { items?: CapexItem[]; subtotal?: number; work_surcharge?: number; contingency?: number } | undefined
          const items: CapexItem[] = data?.items || []
          const sub = items.reduce((s, item) => {
            const ov = overrideByCode.get(item.code) || { code: item.code }
            return s + computePreviewCost(item, ov, materials)
          }, 0)
          const sRate = data?.subtotal && data.subtotal > 0 && data.work_surcharge != null ? data.work_surcharge / data.subtotal : 0
          const cRate = data?.subtotal && data.subtotal > 0 && data.contingency != null ? data.contingency / data.subtotal : 0
          const blockTotal = sub * (1 + sRate + cRate)
          const pct = previewGrandTotal > 0 ? (blockTotal / previewGrandTotal * 100) : 0
          return (
            <button
              key={key}
              onClick={() => document.getElementById(`capex-block-${key}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })}
              className="rounded-lg border border-border/60 bg-card px-3 py-2.5 text-left hover:bg-muted/30 transition-colors"
            >
              <div className="flex items-center gap-1.5 mb-1.5">
                <span className="h-2 w-2 rounded-full shrink-0" style={{ backgroundColor: color }} />
                <span className="text-[11px] text-muted-foreground truncate">{title}</span>
              </div>
              <p className="font-mono text-sm font-semibold tabular-nums">{items.length ? fmt(blockTotal) : '—'}</p>
              {pct > 0 && <p className="text-[10px] text-muted-foreground mt-0.5">{pct.toFixed(0)}% от итого</p>}
            </button>
          )
        })}
        {/* Grand total tile */}
        <div className="rounded-lg border-2 border-foreground/15 bg-foreground/[0.03] px-3 py-2.5 col-span-2 md:col-span-1">
          <p className="text-[11px] text-muted-foreground mb-1.5 font-medium uppercase tracking-wide">Итого</p>
          <p className="font-mono text-sm font-bold tabular-nums">{fmt(previewGrandTotal)}</p>
          <p className="text-[10px] text-muted-foreground mt-0.5">тенге</p>
        </div>
      </div>

      {/* ── Per-block collapsible sections ──────────────────────────── */}
      {BLOCK_CONFIG.map(({ key, title, color }) => {
        const data = results.capex?.[key] as
          | { items: CapexItem[]; subtotal?: number; work_surcharge?: number; contingency?: number; total: number }
          | undefined
        if (!data?.items?.length) return null

        const isCollapsed = collapsed.has(key)
        const previewSub = data.items.reduce((s, item) => {
          const ov = overrideByCode.get(item.code) || { code: item.code }
          return s + computePreviewCost(item, ov, materials)
        }, 0)
        const sRate = data.subtotal && data.subtotal > 0 && data.work_surcharge != null ? data.work_surcharge / data.subtotal : 0
        const cRate = data.subtotal && data.subtotal > 0 && data.contingency != null ? data.contingency / data.subtotal : 0
        const previewWork = previewSub * sRate
        const previewCont = previewSub * cRate
        const previewTotal = previewSub + previewWork + previewCont
        const modifiedCount = data.items.filter(i => overrideByCode.has(i.code)).length

        return (
          <div key={key} id={`capex-block-${key}`} className="mb-3">
            {/* Section header */}
            <button
              className="w-full flex items-center gap-2.5 py-2.5 hover:opacity-75 transition-opacity text-left"
              onClick={() => setCollapsed(prev => {
                const next = new Set(prev)
                if (next.has(key)) next.delete(key); else next.add(key)
                return next
              })}
            >
              <span className="w-0.5 self-stretch rounded-full shrink-0" style={{ backgroundColor: color, minHeight: 18 }} />
              {isCollapsed
                ? <ChevronRight className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                : <ChevronDown className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
              }
              <span className="font-semibold text-sm">{title}</span>
              <span className="text-xs text-muted-foreground">· {data.items.length} позиций</span>
              {modifiedCount > 0 && (
                <span
                  className="rounded-full px-1.5 py-0.5 text-[10px] font-medium"
                  style={{ backgroundColor: `${color}20`, color }}
                >
                  {modifiedCount} изм.
                </span>
              )}
              <span className="ml-auto font-mono text-sm font-semibold tabular-nums">{fmt(previewTotal)}</span>
            </button>

            {!isCollapsed && (
              <div className="rounded-lg border border-border/50 overflow-hidden">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="border-b border-border/40 bg-muted/40">
                      <th className="w-9 py-2 pl-3" />
                      <th className="text-left py-2 font-medium text-[11px] text-muted-foreground uppercase tracking-wide">Позиция</th>
                      <th className="text-left py-2 font-medium text-[11px] text-muted-foreground uppercase tracking-wide hidden md:table-cell w-28">Модель</th>
                      <th className="text-right py-2 pr-2 font-medium text-[11px] text-muted-foreground uppercase tracking-wide w-32">Кол-во / Пл.</th>
                      <th className="text-left py-2 font-medium text-[11px] text-muted-foreground uppercase tracking-wide w-44">Материал</th>
                      <th className="text-right py-2 pr-3 font-medium text-[11px] text-muted-foreground uppercase tracking-wide w-32">Стоимость</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.items.map((item: CapexItem) => {
                      const ov = overrideByCode.get(item.code) || { code: item.code }
                      const included = ov.include !== false
                      const isModified = overrideByCode.has(item.code)
                      const modelLabel = formatModelLabel(item)
                      const qtyDisplay = formatQty(item, ov)
                      const materialSelectable = !isLegacy && item.material_target !== null && item.material_target !== undefined
                      const materialValue = ov.material_override || 'DEFAULT'
                      const previewCost = computePreviewCost(item, ov, materials)

                      return (
                        <tr
                          key={item.code}
                          className={`border-b border-border/20 transition-colors hover:bg-muted/20
                            ${!included ? 'opacity-35' : ''}
                            ${isModified && included ? 'bg-[var(--blue-m)]' : ''}`}
                        >
                          <td className="py-1.5 pl-3">
                            <Checkbox
                              checked={included}
                              disabled={editingDisabled}
                              onCheckedChange={(checked) => {
                                upsertOverride(item.code, { include: checked === false ? false : undefined })
                              }}
                            />
                          </td>
                          <td className="py-1.5 pr-2">
                            <div className="flex items-baseline gap-2">
                              <code className="text-[10px] text-muted-foreground/50 font-mono shrink-0">{item.code}</code>
                              <span>{item.name || item.code}</span>
                            </div>
                            <span className="md:hidden inline-block rounded bg-muted/70 px-1.5 py-0.5 text-[10px] text-muted-foreground mt-0.5">
                              {modelLabel}
                            </span>
                          </td>
                          <td className="py-1.5 hidden md:table-cell pr-2">
                            <span className="inline-flex items-center rounded bg-muted/70 px-1.5 py-0.5 text-[10px] text-muted-foreground font-medium">
                              {modelLabel}
                            </span>
                          </td>
                          <td className="py-1.5 text-right pr-2">
                            {qtyDisplay.editable ? (
                              <Input
                                type="number"
                                min={0}
                                step={qtyDisplay.step || 1}
                                className="w-20 h-6 ml-auto text-right font-mono text-xs"
                                value={ov.qty_override ?? qtyDisplay.defaultValue ?? 0}
                                disabled={editingDisabled || !included}
                                onChange={e => {
                                  const raw = e.target.value
                                  if (raw === '') { upsertOverride(item.code, { qty_override: undefined }); return }
                                  const n = Number(raw)
                                  if (Number.isNaN(n)) return
                                  upsertOverride(item.code, { qty_override: n === qtyDisplay.defaultValue ? undefined : n })
                                }}
                              />
                            ) : (
                              <span className="text-xs text-muted-foreground font-mono">{qtyDisplay.label}</span>
                            )}
                          </td>
                          <td className="py-1.5">
                            {materialSelectable ? (
                              <Select
                                value={materialValue}
                                disabled={editingDisabled || !included}
                                onValueChange={(v: string) => {
                                  upsertOverride(item.code, { material_override: v === 'DEFAULT' ? undefined : v })
                                }}
                              >
                                <SelectTrigger className="h-6 text-xs">
                                  <SelectValue />
                                </SelectTrigger>
                                <SelectContent>
                                  <SelectItem value="DEFAULT">
                                    По умолчанию ({materialTargetLabel(item.material_target)})
                                  </SelectItem>
                                  {materials.map(m => (
                                    <SelectItem key={m.code} value={m.code}>
                                      {m.name_ru} · {m.cost_per_m2.toLocaleString('ru-RU')} ₸/м²
                                    </SelectItem>
                                  ))}
                                </SelectContent>
                              </Select>
                            ) : (
                              <span className="text-xs text-muted-foreground">—</span>
                            )}
                          </td>
                          <td className="py-1.5 text-right pr-3">
                            <span className={`font-mono text-sm tabular-nums ${
                              !included
                                ? 'text-muted-foreground line-through'
                                : isModified
                                  ? 'text-[var(--blue)] font-medium'
                                  : ''
                            }`}>
                              {fmt(previewCost)}
                            </span>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                  <tfoot>
                    {sRate > 0 && (
                      <>
                        <tr className="text-xs text-muted-foreground bg-muted/20">
                          <td colSpan={5} className="py-1 text-right pr-2">Subtotal</td>
                          <td className="py-1 text-right pr-3 font-mono tabular-nums">{fmt(previewSub)}</td>
                        </tr>
                        <tr className="text-xs text-muted-foreground bg-muted/20">
                          <td colSpan={5} className="py-1 text-right pr-2">Работы 6%</td>
                          <td className="py-1 text-right pr-3 font-mono tabular-nums">{fmt(previewWork)}</td>
                        </tr>
                      </>
                    )}
                    {cRate > 0 && (
                      <tr className="text-xs text-muted-foreground bg-muted/20">
                        <td colSpan={5} className="py-1 text-right pr-2">Непредвиденные 2.5%</td>
                        <td className="py-1 text-right pr-3 font-mono tabular-nums">{fmt(previewCont)}</td>
                      </tr>
                    )}
                    <tr className="border-t border-border/40 bg-muted/30">
                      <td colSpan={5} className="py-2 text-right pr-2 text-sm font-semibold">Итого блока</td>
                      <td className="py-2 text-right pr-3 font-mono text-sm font-semibold tabular-nums">{fmt(previewTotal)}</td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            )}
          </div>
        )
      })}

      {/* ── Grand total bar ─────────────────────────────────────────── */}
      <div className="flex items-end justify-between pt-4 border-t-2 border-foreground/10 mt-2">
        <div>
          <p className="text-xs text-muted-foreground uppercase tracking-wide font-medium mb-1">CAPEX — Итого</p>
          {materialsUsed && (
            <p className="text-xs text-muted-foreground">
              Закрытое: <strong>{enclosedName}</strong> · Вспомогательное: <strong>{supportName}</strong>
              <span className="ml-1 opacity-50">(изменить в Параметрах)</span>
            </p>
          )}
        </div>
        <p className="font-mono text-2xl font-bold tabular-nums">
          {fmt(previewGrandTotal)} <span className="text-base font-normal text-muted-foreground">тг</span>
        </p>
      </div>

      {/* ── Sticky save bar ─────────────────────────────────────────── */}
      {isDirty && !isLegacy && (
        <div className="sticky bottom-0 -mx-7 z-20 mt-4 border-t border-border/50 bg-background/95 backdrop-blur-sm shadow-xl">
          <div className="flex items-center justify-between gap-4 px-7 py-3">
            <div className="text-sm">
              <span className="font-semibold">{overrides.length} {overrides.length === 1 ? 'изменение' : 'изменений'}</span>
              <span className="text-muted-foreground ml-2">· сохраните для пересчёта проекта</span>
            </div>
            <div className="flex gap-2">
              <Button variant="outline" size="sm" onClick={handleReset} disabled={saving}>
                Сбросить
              </Button>
              <Button size="sm" onClick={handleSave} disabled={saving} className="gap-1.5">
                {saving && <TuranLoader variant="spin" size={14} />}
                {saving ? 'Сохраняю…' : 'Сохранить и пересчитать'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function formatModelLabel(item: CapexItem): string {
  switch (item.cost_model) {
    case 'area_per_head':
      return 'м²/гол'
    case 'fixed_area':
      return 'фикс. площадь'
    case 'per_head_unit':
      return 'на голову'
    case 'fixed_qty':
      return 'шт (фикс.)'
    case 'fixed_per_project':
      return 'объект'
    case 'per_area_ha':
      return 'на пастбище'
    default:
      return item.cost_model || '—'
  }
}

/**
 * Which cells are editable in the "Кол-во / Площадь" column. Only fixed_qty
 * and per_head_unit expose a directly editable qty. area_per_head shows the
 * computed area read-only (user adjusts via capacity in the wizard).
 */
function formatQty(
  item: CapexItem,
  ov: OverrideRow,
): { editable: boolean; label: string; defaultValue?: number; step?: string } {
  if (item.cost_model === 'fixed_qty' || item.cost_model === 'per_head_unit') {
    const defaultValue = Number(item.qty ?? 0)
    const current = ov.qty_override ?? defaultValue
    return { editable: true, label: String(current), defaultValue, step: '1' }
  }
  if (item.area_m2 != null) {
    return { editable: false, label: `${Math.round(item.area_m2)} м²` }
  }
  if (item.qty != null) {
    return { editable: false, label: String(item.qty) }
  }
  return { editable: false, label: '—' }
}

function materialTargetLabel(target: string | null | undefined): string {
  if (target === 'enclosed') return 'закрытое'
  if (target === 'support') return 'вспомогательное'
  return 'проекта'
}

function getMaterialName(materials: Material[], code: string | null | undefined): string {
  if (!code) return '—'
  const m = materials.find(x => x.code === code)
  return m?.name_ru || code
}

/**
 * Compute the preview cost of a single item based on local overrides,
 * without waiting for a server recalculation (fixes price-not-updating bug).
 */
function computePreviewCost(item: CapexItem, ov: OverrideRow, materials: Material[]): number {
  if (ov.include === false) return 0
  // Explicit unit-cost override
  if (ov.unit_cost_override !== undefined) {
    const qty = ov.qty_override ?? item.qty ?? item.area_m2 ?? 1
    return ov.unit_cost_override * qty
  }
  // Material switch: re-derive cost from new cost_per_m2 × area
  if (ov.material_override && item.area_m2 != null) {
    const mat = materials.find(m => m.code === ov.material_override)
    if (mat) return mat.cost_per_m2 * item.area_m2
  }
  // Qty override: scale proportionally from original unit cost
  if (ov.qty_override !== undefined && item.qty != null && item.qty > 0) {
    const unitCost = item.cost / item.qty
    return unitCost * ov.qty_override
  }
  return item.cost
}
