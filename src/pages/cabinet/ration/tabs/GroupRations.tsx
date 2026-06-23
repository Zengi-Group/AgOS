/**
 * /cabinet-legacy/ration/groups — Рационы фермы
 * Shows every herd group with its current active ration (or CTA to calculate).
 * RPC: rpc_get_current_ration (returns all active rations for the farm)
 * Auth: useAuth() → herd_groups
 */
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Calculator, ChevronRight, Loader2, AlertCircle, Beef, Wheat, TrendingUp } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import type { HerdGroup } from '@/contexts/AuthContext'
import { useRpc } from '@/hooks/useRpc'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

// ── Types ──────────────────────────────────────────────────────────────────────
interface RationItem {
  feed_item_id: string
  feed_item_code: string
  quantity_kg_per_day: number
  cost_per_day: number
}

interface RationVersion {
  version_id: string
  version_number: number
  items: RationItem[]
  results: {
    total_cost_per_day: number
    total_cost_per_month: number
    total_dm_kg: number
    nutrient_values: Record<string, number>
    nutrients_met: Record<string, boolean>
    deficiencies: string[]
    solver_status: string
  }
}

interface RationData {
  ration_id: string
  herd_group_id: string | null
  animal_category_code: string
  animal_category_name_ru: string
  avg_weight_kg: number
  head_count: number
  objective: string
  status: string
  current_version: RationVersion | null
}

const OBJECTIVE_LABELS: Record<string, string> = {
  maintenance: 'Поддержание',
  growth: 'Рост',
  finishing: 'Откорм',
  breeding: 'Случка',
  gestation: 'Стельность',
  lactation: 'Лактация',
}

// ── GroupCard ─────────────────────────────────────────────────────────────────
function GroupCard({
  group,
  ration,
  onCalculate,
  calculating,
}: {
  group: HerdGroup
  ration: RationData | null
  onCalculate: (group: HerdGroup) => void
  calculating: boolean
}) {
  const navigate = useNavigate()
  const hasRation = ration && ration.current_version

  return (
    <div
      style={{
        background: 'var(--bg-c)',
        border: '1px solid var(--bd)',
        borderRadius: 12,
        overflow: 'hidden',
      }}
    >
      {/* Header row */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '14px 16px', borderBottom: hasRation ? '1px solid var(--bd)' : 'none' }}>
        <div
          style={{
            width: 36, height: 36, borderRadius: 8,
            background: 'var(--bg-m)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}
        >
          <Beef size={18} style={{ color: 'var(--brand)' }} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)', lineHeight: 1.3 }}>
            {group.animal_category_name}
          </div>
          <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 2 }}>
            {group.head_count} гол · {group.avg_weight_kg ?? '—'} кг
            {ration && <> · <span style={{ color: 'var(--fg2)' }}>{OBJECTIVE_LABELS[ration.objective] ?? ration.objective}</span></>}
          </div>
        </div>
        {hasRation ? (
          <button
            onClick={() => navigate(`/cabinet-legacy/ration/groups/${ration!.ration_id}`)}
            style={{
              display: 'flex', alignItems: 'center', gap: 4,
              fontSize: 12, fontWeight: 600, color: 'var(--brand)',
              background: 'none', border: 'none', cursor: 'pointer', padding: '4px 8px',
            }}
          >
            Открыть <ChevronRight size={14} />
          </button>
        ) : (
          <button
            onClick={() => onCalculate(group)}
            disabled={calculating}
            style={{
              display: 'flex', alignItems: 'center', gap: 6,
              fontSize: 12, fontWeight: 600,
              color: 'var(--cta-fg)', background: 'var(--cta)',
              border: 'none', borderRadius: 8, padding: '6px 12px',
              cursor: calculating ? 'not-allowed' : 'pointer',
              opacity: calculating ? 0.6 : 1,
              whiteSpace: 'nowrap',
            }}
          >
            {calculating ? <Loader2 size={13} className="animate-spin" /> : <Calculator size={13} />}
            Рассчитать
          </button>
        )}
      </div>

      {/* Ration summary row */}
      {hasRation && ration!.current_version && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', padding: '12px 16px', gap: 8 }}>
          <Metric
            icon={<Wheat size={13} />}
            label="СВ/день"
            value={`${ration!.current_version.results.total_dm_kg.toFixed(1)} кг`}
          />
          <Metric
            icon={<TrendingUp size={13} />}
            label="₸/день"
            value={`${Math.round(ration!.current_version.results.total_cost_per_day).toLocaleString()}`}
          />
          <Metric
            icon={<AlertCircle size={13} />}
            label="Дефициты"
            value={ration!.current_version.results.deficiencies.length === 0
              ? 'Нет'
              : `${ration!.current_version.results.deficiencies.length} пит.`}
            accent={ration!.current_version.results.deficiencies.length > 0 ? 'var(--red)' : 'var(--green)'}
          />
        </div>
      )}

      {/* No ration placeholder */}
      {!hasRation && !ration && (
        <div style={{ padding: '10px 16px 14px' }}>
          <div style={{ fontSize: 12, color: 'var(--fg3)' }}>
            Рацион не рассчитан — нажмите «Рассчитать» чтобы получить рекомендацию NASEM
          </div>
        </div>
      )}
    </div>
  )
}

function Metric({ icon, label, value, accent }: { icon: React.ReactNode; label: string; value: string; accent?: string }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, color: 'var(--fg3)' }}>
        {icon}
        <span style={{ fontSize: 10, textTransform: 'uppercase', letterSpacing: '0.04em' }}>{label}</span>
      </div>
      <div style={{ fontSize: 14, fontWeight: 700, color: accent ?? 'var(--fg)' }}>{value}</div>
    </div>
  )
}

// ── Main ───────────────────────────────────────────────────────────────────────
export function GroupRations() {
  const { organization, farm } = useAuth()
  const [calculatingGroupId, setCalculatingGroupId] = useState<string | null>(null)

  const orgId = organization?.id ?? null
  const groups: HerdGroup[] = farm?.herd_groups ?? []

  // Load all active rations for this farm
  const { data: rations, isLoading, isError } = useRpc<RationData[]>('rpc_get_current_ration', {
    p_organization_id: orgId,
  })

  // Map rations by herd_group_id for O(1) lookup
  const rationByGroup = new Map<string, RationData>()
  if (rations) {
    for (const r of rations) {
      if (r.herd_group_id) rationByGroup.set(r.herd_group_id, r)
    }
  }

  async function handleCalculate(group: HerdGroup) {
    if (!orgId || !farm) return
    setCalculatingGroupId(group.id)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const res = await supabase.functions.invoke('calculate-ration', {
        body: {
          organization_id: orgId,
          farm_id: farm.id,
          herd_group_id: group.id,
          animal_category_id: group.animal_category_id,
          head_count: group.head_count,
          avg_weight_kg: group.avg_weight_kg ?? 400,
          objective: 'maintenance',
          quick_mode: false,
        },
        headers: session?.access_token ? { Authorization: `Bearer ${session.access_token}` } : {},
      })
      if (res.error) throw res.error
      toast.success(`Рацион рассчитан для группы ${group.animal_category_name}`)
      // Refetch happens via React Query invalidation — force reload
      window.location.reload()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Ошибка расчёта'
      toast.error(msg)
    } finally {
      setCalculatingGroupId(null)
    }
  }

  // ── Render ───────────────────────────────────────────────────────────────────
  if (!orgId) {
    return (
      <div style={{ padding: 24, textAlign: 'center', color: 'var(--fg3)', fontSize: 14 }}>
        Организация не найдена
      </div>
    )
  }

  return (
    <div style={{ padding: '0 16px 32px', maxWidth: 640, margin: '0 auto' }}>

      {/* Summary bar */}
      <div
        style={{
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '14px 0', marginBottom: 4,
        }}
      >
        <div style={{ fontSize: 13, color: 'var(--fg3)' }}>
          {groups.length} {groups.length === 1 ? 'группа' : groups.length < 5 ? 'группы' : 'групп'} ·{' '}
          {groups.reduce((s, g) => s + g.head_count, 0)} гол.
        </div>
        <div style={{ fontSize: 13, color: 'var(--fg3)' }}>
          Рационов: {rationByGroup.size} / {groups.length}
        </div>
      </div>

      {/* Error */}
      {isError && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          background: 'color-mix(in srgb, var(--red) 12%, transparent)',
          border: '1px solid color-mix(in srgb, var(--red) 30%, transparent)',
          borderRadius: 10, padding: '10px 14px', marginBottom: 16,
          fontSize: 13, color: 'var(--red)',
        }}>
          <AlertCircle size={15} />
          Не удалось загрузить рационы
        </div>
      )}

      {/* Loading skeleton */}
      {isLoading && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {[1, 2, 3].map(i => (
            <div key={i} style={{ height: 80, background: 'var(--bg-c)', borderRadius: 12, border: '1px solid var(--bd)', opacity: 0.5 }} />
          ))}
        </div>
      )}

      {/* Groups list */}
      {!isLoading && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {groups.length === 0 ? (
            <div style={{
              textAlign: 'center', padding: '48px 24px',
              background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
              color: 'var(--fg3)', fontSize: 14,
            }}>
              Добавьте группы скота в разделе «Стадо»
            </div>
          ) : (
            groups.map(group => (
              <GroupCard
                key={group.id}
                group={group}
                ration={rationByGroup.get(group.id) ?? null}
                onCalculate={handleCalculate}
                calculating={calculatingGroupId === group.id}
              />
            ))
          )}
        </div>
      )}
    </div>
  )
}
