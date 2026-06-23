/**
 * /cabinet-legacy/ration/summary — Сводный рацион фермы
 * Aggregates all active rations: total animals, feed cost, DM, per-group breakdown.
 * RPC: rpc_get_current_ration
 */
import { TrendingUp, Wheat, Users, BarChart3, AlertCircle, CheckCircle2 } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import type { HerdGroup } from '@/contexts/AuthContext'
import { useRpc } from '@/hooks/useRpc'

// ── Types ──────────────────────────────────────────────────────────────────────
interface RationVersion {
  results: {
    total_cost_per_day: number
    total_cost_per_month: number
    total_dm_kg: number
    deficiencies: string[]
    solver_status: string
    nutrient_values: Record<string, number>
  }
  items: Array<{ feed_item_code: string; quantity_kg_per_day: number; cost_per_day: number }>
}

interface RationData {
  ration_id: string
  herd_group_id: string | null
  animal_category_name_ru: string
  avg_weight_kg: number
  head_count: number
  objective: string
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

// ── StatCard ──────────────────────────────────────────────────────────────────
function StatCard({ icon, label, value, sub, accent }: {
  icon: React.ReactNode
  label: string
  value: string
  sub?: string
  accent?: string
}) {
  return (
    <div style={{
      background: 'var(--bg-c)',
      border: '1px solid var(--bd)',
      borderRadius: 12,
      padding: '14px 16px',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--fg3)', marginBottom: 8 }}>
        {icon}
        <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>{label}</span>
      </div>
      <div style={{ fontSize: 24, fontWeight: 700, color: accent ?? 'var(--fg)', lineHeight: 1 }}>{value}</div>
      {sub && <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 4 }}>{sub}</div>}
    </div>
  )
}

// ── FeedBar ───────────────────────────────────────────────────────────────────
const BAR_COLORS = ['var(--brand)', 'var(--blue)', 'var(--green)', 'var(--amber)', 'var(--red)', 'var(--fg3)']

function FeedBreakdown({ items }: { items: Array<{ code: string; kg: number }> }) {
  if (items.length === 0) return null
  const total = items.reduce((s, i) => s + i.kg, 0)
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      {/* Stacked bar */}
      <div style={{ display: 'flex', height: 8, borderRadius: 4, overflow: 'hidden', gap: 1 }}>
        {items.map((item, idx) => (
          <div
            key={item.code}
            style={{
              flex: item.kg / total,
              background: BAR_COLORS[idx % BAR_COLORS.length],
              minWidth: 2,
            }}
          />
        ))}
      </div>
      {/* Legend */}
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 12px' }}>
        {items.map((item, idx) => (
          <div key={item.code} style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
            <div style={{ width: 8, height: 8, borderRadius: 2, background: BAR_COLORS[idx % BAR_COLORS.length], flexShrink: 0 }} />
            <span style={{ fontSize: 12, color: 'var(--fg2)' }}>{item.code}</span>
            <span style={{ fontSize: 12, color: 'var(--fg3)' }}>{item.kg.toFixed(1)} кг</span>
          </div>
        ))}
      </div>
    </div>
  )
}

// ── GroupRow ──────────────────────────────────────────────────────────────────
function GroupRow({ group, ration }: { group: HerdGroup; ration: RationData | null }) {
  const v = ration?.current_version
  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: '1fr auto auto auto',
      alignItems: 'center',
      gap: 12,
      padding: '10px 0',
      borderBottom: '1px solid var(--bd)',
    }}>
      <div>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{group.animal_category_name}</div>
        <div style={{ fontSize: 11, color: 'var(--fg3)', marginTop: 1 }}>
          {group.head_count} гол · {ration ? OBJECTIVE_LABELS[ration.objective] ?? ration.objective : '—'}
        </div>
      </div>
      <div style={{ textAlign: 'right' }}>
        <div style={{ fontSize: 12, color: 'var(--fg3)' }}>СВ/гол</div>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>
          {v ? `${(v.results.total_dm_kg / group.head_count).toFixed(1)} кг` : '—'}
        </div>
      </div>
      <div style={{ textAlign: 'right' }}>
        <div style={{ fontSize: 12, color: 'var(--fg3)' }}>₸/день</div>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>
          {v ? Math.round(v.results.total_cost_per_day).toLocaleString() : '—'}
        </div>
      </div>
      <div>
        {!v ? (
          <span style={{ fontSize: 11, color: 'var(--fg3)', fontStyle: 'italic' }}>нет рациона</span>
        ) : v.results.deficiencies.length === 0 ? (
          <CheckCircle2 size={16} style={{ color: 'var(--green)' }} />
        ) : (
          <AlertCircle size={16} style={{ color: 'var(--amber)' }} />
        )}
      </div>
    </div>
  )
}

// ── Main ───────────────────────────────────────────────────────────────────────
export function Summary() {
  const { organization, farm } = useAuth()
  const orgId = organization?.id ?? null
  const groups: HerdGroup[] = farm?.herd_groups ?? []

  const { data: rations, isLoading, isError } = useRpc<RationData[]>('rpc_get_current_ration', {
    p_organization_id: orgId,
  })

  const rationByGroup = new Map<string, RationData>()
  if (rations) {
    for (const r of rations) {
      if (r.herd_group_id) rationByGroup.set(r.herd_group_id, r)
    }
  }

  // Aggregate stats across all rations with active versions
  const activeRations = rations?.filter(r => r.current_version) ?? []
  const totalAnimals = groups.reduce((s, g) => s + g.head_count, 0)
  const totalCostDay = activeRations.reduce((s, r) => s + (r.current_version?.results.total_cost_per_day ?? 0), 0)
  const totalDmDay = activeRations.reduce((s, r) => s + (r.current_version?.results.total_dm_kg ?? 0), 0)
  const totalDeficits = activeRations.reduce((s, r) => s + (r.current_version?.results.deficiencies.length ?? 0), 0)

  // Aggregate feed consumption across all rations
  const feedTotals = new Map<string, number>()
  for (const r of activeRations) {
    for (const item of r.current_version?.items ?? []) {
      feedTotals.set(item.feed_item_code, (feedTotals.get(item.feed_item_code) ?? 0) + item.quantity_kg_per_day)
    }
  }
  const feedItems = Array.from(feedTotals.entries())
    .map(([code, kg]) => ({ code, kg }))
    .sort((a, b) => b.kg - a.kg)

  // ── Render ───────────────────────────────────────────────────────────────────
  if (!orgId) return null

  if (isLoading) {
    return (
      <div style={{ padding: '0 16px 32px', maxWidth: 640, margin: '0 auto' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 16 }}>
          {[1, 2, 3, 4].map(i => (
            <div key={i} style={{ height: 84, background: 'var(--bg-c)', borderRadius: 12, border: '1px solid var(--bd)', opacity: 0.5 }} />
          ))}
        </div>
      </div>
    )
  }

  if (isError) {
    return (
      <div style={{ padding: '0 16px', maxWidth: 640, margin: '0 auto' }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          background: 'color-mix(in srgb, var(--red) 12%, transparent)',
          border: '1px solid color-mix(in srgb, var(--red) 30%, transparent)',
          borderRadius: 10, padding: '12px 16px',
          fontSize: 13, color: 'var(--red)',
        }}>
          <AlertCircle size={15} />
          Не удалось загрузить данные
        </div>
      </div>
    )
  }

  if (activeRations.length === 0) {
    return (
      <div style={{ padding: '0 16px 32px', maxWidth: 640, margin: '0 auto' }}>
        <div style={{
          textAlign: 'center', padding: '48px 24px',
          background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
          color: 'var(--fg3)', fontSize: 14,
        }}>
          Нет активных рационов.
          <br />
          <span style={{ fontSize: 13 }}>Перейдите в «Рационы фермы» и рассчитайте рационы для групп.</span>
        </div>
      </div>
    )
  }

  return (
    <div style={{ padding: '0 16px 32px', maxWidth: 640, margin: '0 auto' }}>

      {/* Stat cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 16 }}>
        <StatCard
          icon={<Users size={13} />}
          label="Животных"
          value={totalAnimals.toLocaleString()}
          sub={`${groups.length} групп · ${activeRations.length} рационов`}
        />
        <StatCard
          icon={<TrendingUp size={13} />}
          label="Расходы/день"
          value={`${Math.round(totalCostDay).toLocaleString()} ₸`}
          sub={`~${Math.round(totalCostDay * 30).toLocaleString()} ₸/мес`}
        />
        <StatCard
          icon={<Wheat size={13} />}
          label="Сухое вещество"
          value={`${totalDmDay.toFixed(0)} кг`}
          sub="суммарно по ферме/день"
        />
        <StatCard
          icon={<BarChart3 size={13} />}
          label="Дефициты"
          value={totalDeficits === 0 ? 'Нет' : `${totalDeficits}`}
          sub={totalDeficits === 0 ? 'все нормы выполнены' : 'питательных веществ'}
          accent={totalDeficits === 0 ? 'var(--green)' : 'var(--amber)'}
        />
      </div>

      {/* Feed breakdown */}
      {feedItems.length > 0 && (
        <div style={{
          background: 'var(--bg-c)', border: '1px solid var(--bd)',
          borderRadius: 12, padding: '14px 16px', marginBottom: 16,
        }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--fg2)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 12 }}>
            Структура рациона фермы
          </div>
          <FeedBreakdown items={feedItems} />
          <div style={{ marginTop: 12, fontSize: 12, color: 'var(--fg3)' }}>
            Итого: {feedItems.reduce((s, i) => s + i.kg, 0).toFixed(1)} кг/день
          </div>
        </div>
      )}

      {/* Per-group breakdown */}
      <div style={{
        background: 'var(--bg-c)', border: '1px solid var(--bd)',
        borderRadius: 12, padding: '14px 16px',
      }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--fg2)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>
          По группам
        </div>
        <div>
          {groups.map(group => (
            <GroupRow
              key={group.id}
              group={group}
              ration={rationByGroup.get(group.id) ?? null}
            />
          ))}
        </div>
        <div style={{ paddingTop: 10, display: 'flex', justifyContent: 'space-between', fontSize: 13, fontWeight: 700, color: 'var(--fg)' }}>
          <span>Итого</span>
          <span>{Math.round(totalCostDay).toLocaleString()} ₸/день</span>
        </div>
      </div>
    </div>
  )
}
