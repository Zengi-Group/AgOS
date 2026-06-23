/**
 * F17 — Просмотр рациона (Ration Viewer)
 * Dok 6 Slice 3: /cabinet-legacy/ration
 * RPC: rpc_get_current_ration (RPC-24)
 * UX: NASEM norms cards → feed rows with proportion bars → nutrient balance → monthly group totals
 */
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Calculator, Loader2, AlertTriangle } from 'lucide-react'
import { Skeleton } from '@/components/ui/skeleton'
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
  effective_price_per_kg: number
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
    nutrient_requirements: Record<string, number>
    nutrients_met: Record<string, boolean>
    deficiencies: string[]
    solver_status: string
  }
  calculated_by: string
  created_at: string
}

interface RationData {
  ration_id: string
  herd_group_id: string | null
  animal_category_code: string
  animal_category_name_ru: string
  breed_name_ru: string | null
  avg_weight_kg: number
  head_count: number
  objective: string
  status: string
  current_version: RationVersion | null
  version_count: number
}

// ── Constants ──────────────────────────────────────────────────────────────────
const OBJECTIVE_LABELS: Record<string, string> = {
  maintenance: 'Поддержание',
  growth: 'Рост (0.8 кг/сут)',
  finishing: 'Откорм (1.2 кг/сут)',
  breeding: 'Случка',
  gestation: 'Стельность',
  lactation: 'Лактация',
}

// Feed bar colors by position (циклически)
const BAR_COLORS = ['var(--brand)', 'var(--blue)', 'var(--green)', 'var(--amber)', 'var(--fg3)']

// ── Sub-components ────────────────────────────────────────────────────────────

function NormCard({ label, value, unit }: { label: string; value: string; unit: string }) {
  return (
    <div
      style={{
        background: 'var(--bg-c)',
        border: '1px solid var(--bd)',
        borderRadius: 10,
        padding: '14px 16px',
      }}
    >
      <div style={{ fontSize: 11, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 4 }}>
        {label}
      </div>
      <div style={{ fontSize: 22, fontWeight: 700, color: 'var(--fg)', lineHeight: 1 }}>
        {value}
      </div>
      <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 4 }}>{unit}</div>
    </div>
  )
}

function StatusBadge({ ok, okLabel = 'ОК', failLabel = 'дефицит' }: { ok: boolean; okLabel?: string; failLabel?: string }) {
  return (
    <span
      style={{
        display: 'inline-block',
        fontSize: 11,
        fontWeight: 600,
        padding: '2px 8px',
        borderRadius: 6,
        background: ok ? 'var(--green-m)' : 'var(--red-m)',
        color: ok ? 'var(--green)' : 'var(--red)',
      }}
    >
      {ok ? okLabel : failLabel}
    </span>
  )
}

interface FeedRowProps {
  name: string
  desc?: string
  kgPerDay: number
  kgPerMonth: number
  pct: number
  color: string
}
function FeedRow({ name, desc, kgPerDay, kgPerMonth, pct, color }: FeedRowProps) {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: '140px 1fr 80px 90px',
        gap: 10,
        alignItems: 'center',
        padding: '10px 14px',
        background: 'var(--bg)',
        border: '1px solid var(--bd)',
        borderRadius: 8,
        marginBottom: 6,
      }}
    >
      <div>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{name}</div>
        {desc && <div style={{ fontSize: 11, color: 'var(--fg3)' }}>{desc}</div>}
      </div>
      <div
        style={{
          height: 8,
          background: 'var(--bg-m)',
          borderRadius: 4,
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            height: 8,
            borderRadius: 4,
            width: `${Math.min(pct, 100)}%`,
            background: color,
            transition: 'width 0.4s ease',
          }}
        />
      </div>
      <div style={{ textAlign: 'right' }}>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{kgPerDay.toFixed(1)} кг</span>
      </div>
      <div style={{ textAlign: 'right' }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{Math.round(kgPerMonth)}</div>
        <div style={{ fontSize: 11, color: 'var(--fg3)' }}>кг/мес</div>
      </div>
    </div>
  )
}

// ── Single ration card ────────────────────────────────────────────────────────
function RationCard({ ration, onRecalculate }: { ration: RationData; onRecalculate: () => void }) {
  const v = ration.current_version
  const res = v?.results

  const items = v?.items ?? []
  const totalKgPerDay = items.reduce((s, i) => s + i.quantity_kg_per_day, 0)

  // NASEM norms (from results if available, else show —)
  const dmReq = res?.nutrient_requirements?.dm_kg ?? null
  const meReq = res?.nutrient_requirements?.me_mj ?? null
  const cpReq = res?.nutrient_requirements?.cp_g ?? null

  const dmFact = res?.nutrient_values?.dm_kg ?? res?.total_dm_kg ?? null
  const meFact = res?.nutrient_values?.me_mj ?? null
  const cpFact = res?.nutrient_values?.cp_g ?? null
  const roughagePct = res?.nutrient_values?.roughage_pct ?? null

  const meOk = meReq && meFact ? meFact >= meReq * 0.97 : (res?.nutrients_met?.me ?? true)
  const cpOk = cpReq && cpFact ? cpFact >= cpReq * 0.97 : (res?.nutrients_met?.cp ?? true)
  const rgOk = roughagePct !== null ? roughagePct >= 38 : true

  const warnings: string[] = []
  if (!meOk) warnings.push('Дефицит обменной энергии. Увеличьте долю концентратов или добавьте силос.')
  if (!cpOk) warnings.push('Дефицит протеина. Увеличьте долю шрота.')
  if (!rgOk) warnings.push(`Доля грубых кормов ниже 40% СВ (${roughagePct?.toFixed(0)}%) — риск ацидоза.`)
  if (res?.deficiencies?.length) {
    res.deficiencies.forEach(d => {
      if (!warnings.some(w => w.includes(d))) warnings.push(`Дефицит: ${d}`)
    })
  }

  return (
    <div
      style={{
        background: 'var(--bg-c)',
        border: '1px solid var(--bd)',
        borderRadius: 12,
        overflow: 'hidden',
        boxShadow: 'var(--sh-sm)',
      }}
    >
      {/* Header */}
      <div style={{ padding: '16px 20px 0', borderBottom: '1px solid var(--bd)', paddingBottom: 14 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <h2 style={{ fontSize: 15, fontWeight: 600, color: 'var(--fg)', margin: 0 }}>
              {ration.animal_category_name_ru}
              {ration.breed_name_ru && (
                <span style={{ color: 'var(--fg3)', fontWeight: 400, fontSize: 13, marginLeft: 8 }}>
                  {ration.breed_name_ru}
                </span>
              )}
            </h2>
            <p style={{ fontSize: 12, color: 'var(--fg3)', margin: '4px 0 0' }}>
              {ration.head_count} гол · {ration.avg_weight_kg} кг ср. масса · {OBJECTIVE_LABELS[ration.objective] ?? ration.objective}
            </p>
          </div>
          <button
            onClick={onRecalculate}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 6,
              fontSize: 12,
              fontWeight: 600,
              padding: '6px 12px',
              borderRadius: 8,
              border: '1px solid var(--bd)',
              background: 'var(--bg)',
              color: 'var(--fg2)',
              cursor: 'pointer',
              transition: 'all 80ms',
            }}
            onMouseEnter={e => { e.currentTarget.style.background = 'var(--bg-m)'; e.currentTarget.style.color = 'var(--fg)' }}
            onMouseLeave={e => { e.currentTarget.style.background = 'var(--bg)'; e.currentTarget.style.color = 'var(--fg2)' }}
          >
            <Calculator size={13} />
            Пересчитать
          </button>
        </div>
      </div>

      <div style={{ padding: '18px 20px' }}>
        {/* ── NASEM Norms ────────────────────────────────────────────────────── */}
        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
          Нормы NASEM (расчётные)
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 20 }}>
          <NormCard label="Сухое вещество" value={dmReq !== null ? dmReq.toFixed(1) : '—'} unit="кг / гол / сут" />
          <NormCard label="Обм. энергия" value={meReq !== null ? meReq.toFixed(1) : '—'} unit="МДж / гол / сут" />
          <NormCard label="Сырой протеин" value={cpReq !== null ? Math.round(cpReq).toString() : '—'} unit="г / гол / сут" />
        </div>

        {/* ── Feed rows ──────────────────────────────────────────────────────── */}
        {items.length > 0 ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
              Рацион (кг / голову / сутки)
            </div>

            {items.map((item, idx) => (
              <FeedRow
                key={item.feed_item_id}
                name={item.feed_item_code}
                kgPerDay={item.quantity_kg_per_day}
                kgPerMonth={item.quantity_kg_per_day * 30}
                pct={totalKgPerDay > 0 ? (item.quantity_kg_per_day / totalKgPerDay) * 100 : 0}
                color={BAR_COLORS[idx % BAR_COLORS.length] ?? 'var(--brand)'}
              />
            ))}

            {/* Total row */}
            <div
              style={{
                display: 'grid',
                gridTemplateColumns: '140px 1fr 80px 90px',
                gap: 10,
                alignItems: 'center',
                padding: '10px 14px',
                background: 'var(--bg-m)',
                border: '1px solid var(--bd)',
                borderRadius: 8,
                marginBottom: 20,
              }}
            >
              <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>Итого</div>
              <div />
              <div style={{ textAlign: 'right', fontSize: 13, fontWeight: 700, color: 'var(--fg)' }}>
                {totalKgPerDay.toFixed(1)} кг
              </div>
              <div style={{ textAlign: 'right' }}>
                <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--fg)' }}>{Math.round(totalKgPerDay * 30)}</div>
                <div style={{ fontSize: 11, color: 'var(--fg3)' }}>кг/мес</div>
              </div>
            </div>
          </>
        ) : (
          <div style={{ padding: '20px 0', textAlign: 'center', color: 'var(--fg3)', fontSize: 13 }}>
            Нет рассчитанных версий рациона
          </div>
        )}

        {/* ── Nutrient balance ───────────────────────────────────────────────── */}
        {res && (
          <>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
              Питательность рациона
            </div>
            <div
              style={{
                background: 'var(--bg)',
                border: '1px solid var(--bd)',
                borderRadius: 10,
                padding: '4px 16px',
                marginBottom: 20,
              }}
            >
              {[
                {
                  label: 'СВ факт / норма',
                  value: dmFact !== null && dmReq !== null
                    ? `${dmFact.toFixed(1)} / ${dmReq.toFixed(1)} кг`
                    : (dmFact !== null ? `${dmFact.toFixed(1)} кг` : '—'),
                  badge: null,
                },
                {
                  label: 'ОЭ факт / норма',
                  value: meFact !== null && meReq !== null
                    ? `${meFact.toFixed(1)} / ${meReq.toFixed(1)} МДж`
                    : (meFact !== null ? `${meFact.toFixed(1)} МДж` : '—'),
                  badge: <StatusBadge ok={meOk} />,
                },
                {
                  label: 'СП факт / норма',
                  value: cpFact !== null && cpReq !== null
                    ? `${Math.round(cpFact)} / ${Math.round(cpReq)} г`
                    : (cpFact !== null ? `${Math.round(cpFact)} г` : '—'),
                  badge: <StatusBadge ok={cpOk} />,
                },
                {
                  label: 'Грубые корма, % от СВ',
                  value: roughagePct !== null ? `${roughagePct.toFixed(0)}%` : '—',
                  badge: roughagePct !== null ? <StatusBadge ok={rgOk} okLabel="≥40% NASEM" failLabel="< 40%" /> : null,
                },
              ].map(({ label, value, badge }) => (
                <div
                  key={label}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    padding: '9px 0',
                    borderBottom: '1px solid var(--bd)',
                  }}
                >
                  <span style={{ fontSize: 13, color: 'var(--fg2)' }}>{label}</span>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>
                    {value}
                    {badge}
                  </span>
                </div>
              ))}
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  padding: '9px 0',
                }}
              >
                <span style={{ fontSize: 13, color: 'var(--fg2)' }}>Стоимость рациона</span>
                <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>
                  {res.total_cost_per_day ? `${res.total_cost_per_day.toLocaleString('ru-RU')} ₸ / гол / сут` : '—'}
                </span>
              </div>
            </div>

            {/* ── Monthly group totals ─────────────────────────────────────────── */}
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
              Потребность группы на месяц
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 20 }}>
              {items.slice(0, 3).map((item) => (
                <div
                  key={item.feed_item_id}
                  style={{
                    background: 'var(--bg-c)',
                    border: '1px solid var(--bd)',
                    borderRadius: 10,
                    padding: '12px 14px',
                  }}
                >
                  <div style={{ fontSize: 11, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.03em', marginBottom: 4 }}>
                    {item.feed_item_code}
                  </div>
                  <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--fg)' }}>
                    {Math.round(item.quantity_kg_per_day * 30 * ration.head_count).toLocaleString('ru-RU')}
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 2 }}>
                    кг/мес на {ration.head_count} гол
                  </div>
                </div>
              ))}
              {items.length === 0 && (
                <div style={{ gridColumn: '1/-1', fontSize: 13, color: 'var(--fg3)', textAlign: 'center', padding: '8px 0' }}>—</div>
              )}
            </div>
          </>
        )}

        {/* ── Warnings ──────────────────────────────────────────────────────── */}
        {warnings.length > 0 && (
          <div
            style={{
              background: 'var(--amber-m)',
              border: '1px solid color-mix(in srgb, var(--amber) 30%, transparent)',
              borderRadius: 8,
              padding: '10px 14px',
              fontSize: 13,
              color: 'var(--amber)',
              lineHeight: 1.6,
            }}
          >
            {warnings.map((w, i) => (
              <div key={i} style={{ display: 'flex', gap: 8, alignItems: 'flex-start' }}>
                <AlertTriangle size={14} style={{ marginTop: 2, flexShrink: 0 }} />
                <span>{w}</span>
              </div>
            ))}
          </div>
        )}

        {/* Footer meta */}
        {v && (
          <div style={{ marginTop: 14, fontSize: 11, color: 'var(--fg3)', display: 'flex', gap: 10 }}>
            <span>v{v.version_number}</span>
            <span>·</span>
            <span>{new Date(v.created_at).toLocaleDateString('ru-RU')}</span>
            <span>·</span>
            <span>{v.results.solver_status}</span>
          </div>
        )}
      </div>
    </div>
  )
}

// ── Aggregated totals across all groups ───────────────────────────────────────
function AggregatedSummary({ rations }: { rations: RationData[] }) {
  const rationsWith = rations.filter(r => r.current_version?.items?.length)
  if (rationsWith.length < 2) return null

  // Collect all unique feed codes
  const feedMap: Record<string, { kgPerDayTotal: number; costPerDayTotal: number }> = {}
  for (const r of rationsWith) {
    const headCount = r.head_count ?? 1
    for (const item of (r.current_version?.items ?? [])) {
      if (!feedMap[item.feed_item_code]) feedMap[item.feed_item_code] = { kgPerDayTotal: 0, costPerDayTotal: 0 }
      feedMap[item.feed_item_code]!.kgPerDayTotal += item.quantity_kg_per_day * headCount
      feedMap[item.feed_item_code]!.costPerDayTotal += (item.cost_per_day ?? 0) * headCount
    }
  }

  const feeds = Object.entries(feedMap)
  const totalKgPerDay = feeds.reduce((s, [, v]) => s + v.kgPerDayTotal, 0)
  const totalCostPerDay = feeds.reduce((s, [, v]) => s + v.costPerDayTotal, 0)
  const totalHeads = rationsWith.reduce((s, r) => s + (r.head_count ?? 0), 0)

  return (
    <div style={{
      background: 'var(--bg-c)',
      border: '1px solid var(--bd)',
      borderRadius: 12,
      overflow: 'hidden',
      boxShadow: 'var(--sh-sm)',
    }}>
      <div style={{ padding: '14px 20px', borderBottom: '1px solid var(--bd)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700, color: 'var(--fg)' }}>Сводный рацион фермы</div>
          <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 2 }}>{totalHeads} гол · {rationsWith.length} групп</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--fg)' }}>{Math.round(totalKgPerDay).toLocaleString('ru-RU')} кг/сут</div>
          {totalCostPerDay > 0 && (
            <div style={{ fontSize: 11, color: 'var(--fg3)' }}>{totalCostPerDay.toLocaleString('ru-RU')} ₸/сут</div>
          )}
        </div>
      </div>
      <div style={{ padding: '12px 20px' }}>
        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 10 }}>
          Потребность в кормах (все группы / сутки)
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(160px, 1fr))', gap: 8 }}>
          {feeds.map(([code, val]) => (
            <div key={code} style={{ background: 'var(--bg)', border: '1px solid var(--bd)', borderRadius: 8, padding: '10px 12px' }}>
              <div style={{ fontSize: 11, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.03em', marginBottom: 4 }}>{code}</div>
              <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--fg)' }}>{Math.round(val.kgPerDayTotal).toLocaleString('ru-RU')}</div>
              <div style={{ fontSize: 11, color: 'var(--fg3)' }}>кг/сут · {Math.round(val.kgPerDayTotal * 30).toLocaleString('ru-RU')} кг/мес</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

// ── Group row (no ration yet) ─────────────────────────────────────────────────
function NoRationGroupRow({
  group,
  onCalculate,
  isCalculating,
}: {
  group: HerdGroup
  onCalculate: () => void
  isCalculating: boolean
}) {
  return (
    <div style={{
      background: 'var(--bg-c)',
      border: '1px solid var(--bd)',
      borderRadius: 12,
      padding: '16px 20px',
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      gap: 12,
    }}>
      <div>
        <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--fg)' }}>
          {group.animal_category_name}
          {group.breed_name && <span style={{ fontWeight: 400, color: 'var(--fg3)', fontSize: 13, marginLeft: 8 }}>{group.breed_name}</span>}
        </div>
        <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 3 }}>
          {group.head_count} гол · {group.avg_weight_kg ?? '—'} кг · рацион не рассчитан
        </div>
      </div>
      <button
        onClick={onCalculate}
        disabled={isCalculating}
        style={{
          display: 'flex', alignItems: 'center', gap: 6,
          fontSize: 12, fontWeight: 600, padding: '7px 14px', borderRadius: 8,
          border: 'none', background: 'var(--cta)', color: 'var(--cta-fg)', cursor: 'pointer',
          opacity: isCalculating ? 0.5 : 1, flexShrink: 0,
        }}
      >
        {isCalculating ? <Loader2 size={13} className="animate-spin" /> : <Calculator size={13} />}
        Рассчитать
      </button>
    </div>
  )
}

// ── Main page ─────────────────────────────────────────────────────────────────
export function RationViewer() {
  const navigate = useNavigate()
  const { organization, farm, userContext } = useAuth()
  // calculatingGroupId — id группы для которой идёт расчёт
  const [calculatingGroupId, setCalculatingGroupId] = useState<string | null>(null)

  const { data: rations, isLoading, refetch } = useRpc<RationData[]>(
    'rpc_get_current_ration',
    { p_organization_id: organization?.id, p_farm_id: farm?.id },
    { enabled: !!organization?.id && !!farm?.id },
  )

  // Все группы скота фермы из контекста
  const herdGroups = userContext?.farms?.[0]?.herd_groups ?? []

  async function handleCalculateGroup(group: HerdGroup) {
    if (!organization?.id || !farm?.id) return
    setCalculatingGroupId(group.id)
    try {
      const { error } = await supabase.functions.invoke('calculate-ration', {
        body: {
          organization_id: organization.id,
          farm_id: farm.id,
          herd_group_id: group.id,
          animal_category_id: group.animal_category_id,
          breed_id: group.breed_id,
          avg_weight_kg: group.avg_weight_kg || 300,
          head_count: group.head_count || 1,
        },
      })
      if (error) throw error
      toast.success('Рацион рассчитан')
      refetch()
    } catch (err: any) {
      toast.error(err.message || 'Ошибка расчёта')
    } finally {
      setCalculatingGroupId(null)
    }
  }

  if (isLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-24 w-full rounded-[12px]" style={{ background: 'var(--bg-m)' }} />
        <Skeleton className="h-24 w-full rounded-[12px]" style={{ background: 'var(--bg-m)' }} />
        <Skeleton className="h-24 w-full rounded-[12px]" style={{ background: 'var(--bg-m)' }} />
      </div>
    )
  }

  // Нет групп скота вообще
  if (herdGroups.length === 0) {
    return (
      <div className="page">
        <div style={{ background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12, padding: '40px 24px', textAlign: 'center' }}>
          <p style={{ color: 'var(--fg3)', fontSize: 14, marginBottom: 20 }}>
            Сначала добавьте группы скота на ферме
          </p>
          <button
            onClick={() => navigate('/cabinet-legacy/herd')}
            style={{ fontSize: 13, fontWeight: 600, padding: '8px 18px', borderRadius: 8, border: '1px solid var(--bd)', background: 'var(--bg)', color: 'var(--fg2)', cursor: 'pointer' }}
          >
            Перейти к стаду
          </button>
        </div>
      </div>
    )
  }

  // Индекс активных рационов по herd_group_id
  const rationByGroupId = (rations ?? []).reduce<Record<string, RationData>>((acc, r) => {
    if (r.herd_group_id) acc[r.herd_group_id] = r
    return acc
  }, {})

  return (
    <div className="page space-y-4">

      {/* Рационы по каждой группе */}
      {herdGroups.map((group) => {
        const ration = rationByGroupId[group.id]
        if (ration) {
          return (
            <RationCard
              key={group.id}
              ration={ration}
              onRecalculate={() => handleCalculateGroup(group)}
            />
          )
        }
        return (
          <NoRationGroupRow
            key={group.id}
            group={group}
            onCalculate={() => handleCalculateGroup(group)}
            isCalculating={calculatingGroupId === group.id}
          />
        )
      })}

      {/* Сводный агрегат (если 2+ групп с рационами) */}
      <AggregatedSummary rations={rations ?? []} />

      {/* Бюджет кормления */}
      <button
        onClick={() => navigate('/cabinet-legacy/ration/budget')}
        style={{
          width: '100%', padding: '11px 16px', borderRadius: 8,
          border: '1px solid var(--bd)', background: 'var(--bg-c)', color: 'var(--fg2)',
          fontSize: 13, fontWeight: 500, cursor: 'pointer', transition: 'all 80ms',
        }}
        onMouseEnter={e => { e.currentTarget.style.background = 'var(--bg-m)'; e.currentTarget.style.color = 'var(--fg)' }}
        onMouseLeave={e => { e.currentTarget.style.background = 'var(--bg-c)'; e.currentTarget.style.color = 'var(--fg2)' }}
      >
        Бюджет кормления →
      </button>

      <div style={{ fontSize: 11, color: 'var(--fg3)', borderTop: '1px solid var(--bd)', paddingTop: 10 }}>
        ⚠ Питательность кормов — приблизительная (NASEM 2016). Требует валидации зоотехника перед использованием в продакшне.
      </div>
    </div>
  )
}
