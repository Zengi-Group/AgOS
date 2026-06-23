/**
 * /cabinet-legacy/ration/budget — Бюджет кормов
 * Stock vs demand: how many days of each feed remains, deficit alerts, cost estimates.
 * Edge Function: get-feed-budget (POST /functions/v1/get-feed-budget)
 */
import { useState, useEffect } from 'react'
import { AlertTriangle, CheckCircle2, Package, TrendingDown, Loader2, AlertCircle } from 'lucide-react'
import { useAuth } from '@/hooks/useAuth'
import { supabase } from '@/lib/supabase'

// ── Types ──────────────────────────────────────────────────────────────────────
interface BudgetFeed {
  feed_item_id: string
  feed_code: string
  feed_name: string
  daily_kg_total: number
  required_kg_period: number
  available_kg: number
  deficit_kg: number
  cost_estimate: number
  days_left: number
}

interface BudgetResult {
  per_head_per_day: {
    total_cost: number
    head_count: number
    feeds: Array<{ feed_code: string; feed_name: string; cost_per_head_per_day: number }>
  }
  total_budget: {
    period_days: number
    total_cost: number
    deficit_count: number
    days_until_shortage: number
    feeds: BudgetFeed[]
  }
}

const PERIODS = [
  { days: 30, label: '30 дн' },
  { days: 60, label: '60 дн' },
  { days: 90, label: '90 дн' },
]

function formatKg(kg: number): string {
  if (kg >= 1000) return `${(kg / 1000).toFixed(1)} т`
  return `${Math.round(kg)} кг`
}

// ── FeedRow ───────────────────────────────────────────────────────────────────
function FeedRow({ feed }: { feed: BudgetFeed }) {
  const hasDeficit = feed.deficit_kg > 0
  const pct = feed.available_kg > 0
    ? Math.min(100, (feed.available_kg / feed.required_kg_period) * 100)
    : 0

  return (
    <div style={{
      padding: '12px 16px',
      borderBottom: '1px solid var(--bd)',
    }}>
      {/* Name row */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {hasDeficit
            ? <AlertTriangle size={14} style={{ color: 'var(--red)', flexShrink: 0 }} />
            : <CheckCircle2 size={14} style={{ color: 'var(--green)', flexShrink: 0 }} />}
          <div>
            <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--fg)' }}>{feed.feed_name}</div>
            <div style={{ fontSize: 11, color: 'var(--fg3)' }}>{feed.feed_code}</div>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{
            fontSize: 13, fontWeight: 700,
            color: feed.days_left < 14 ? 'var(--red)' : feed.days_left < 30 ? 'var(--amber)' : 'var(--green)',
          }}>
            {feed.days_left > 999 ? '∞' : `${feed.days_left} дн`}
          </div>
          <div style={{ fontSize: 11, color: 'var(--fg3)' }}>остаток</div>
        </div>
      </div>

      {/* Progress bar */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
        <div style={{ flex: 1, height: 6, background: 'var(--bg-m)', borderRadius: 3, overflow: 'hidden' }}>
          <div style={{
            height: '100%',
            width: `${pct}%`,
            background: hasDeficit ? 'var(--red)' : pct < 30 ? 'var(--amber)' : 'var(--green)',
            borderRadius: 3,
            transition: 'width 0.3s',
          }} />
        </div>
        <div style={{ fontSize: 11, color: 'var(--fg3)', whiteSpace: 'nowrap' }}>{Math.round(pct)}%</div>
      </div>

      {/* Detail row */}
      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        <DetailItem label="Есть" value={formatKg(feed.available_kg)} />
        <DetailItem label="Нужно" value={formatKg(feed.required_kg_period)} />
        <DetailItem
          label="Дефицит"
          value={hasDeficit ? formatKg(feed.deficit_kg) : 'Нет'}
          accent={hasDeficit ? 'var(--red)' : 'var(--green)'}
        />
        <DetailItem label="Стоимость" value={`${Math.round(feed.cost_estimate).toLocaleString()} ₸`} />
      </div>
    </div>
  )
}

function DetailItem({ label, value, accent }: { label: string; value: string; accent?: string }) {
  return (
    <div>
      <div style={{ fontSize: 10, color: 'var(--fg3)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>{label}</div>
      <div style={{ fontSize: 12, fontWeight: 600, color: accent ?? 'var(--fg)' }}>{value}</div>
    </div>
  )
}

// ── Main ───────────────────────────────────────────────────────────────────────
export function Budget() {
  const { organization, farm } = useAuth()
  const [periodDays, setPeriodDays] = useState(30)
  const [budget, setBudget] = useState<BudgetResult | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function loadBudget(days: number) {
    if (!organization?.id || !farm?.id) return
    setLoading(true)
    setError(null)
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const res = await supabase.functions.invoke('get-feed-budget', {
        body: {
          organization_id: organization.id,
          farm_id: farm.id,
          period_days: days,
        },
        headers: session?.access_token ? { Authorization: `Bearer ${session.access_token}` } : {},
      })
      if (res.error) throw res.error
      setBudget(res.data as BudgetResult)
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Ошибка загрузки бюджета')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    loadBudget(periodDays)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [periodDays, organization?.id, farm?.id])

  const tb = budget?.total_budget
  const phd = budget?.per_head_per_day

  return (
    <div style={{ padding: '0 16px 32px', maxWidth: 640, margin: '0 auto' }}>

      {/* Period selector */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        {PERIODS.map(p => (
          <button
            key={p.days}
            onClick={() => setPeriodDays(p.days)}
            style={{
              padding: '6px 16px',
              fontSize: 13, fontWeight: 600,
              borderRadius: 8,
              border: `1px solid ${periodDays === p.days ? 'var(--brand)' : 'var(--bd)'}`,
              background: periodDays === p.days ? 'color-mix(in srgb, var(--brand) 15%, transparent)' : 'var(--bg-c)',
              color: periodDays === p.days ? 'var(--brand)' : 'var(--fg2)',
              cursor: 'pointer',
            }}
          >
            {p.label}
          </button>
        ))}
      </div>

      {/* Error */}
      {error && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          background: 'color-mix(in srgb, var(--red) 12%, transparent)',
          border: '1px solid color-mix(in srgb, var(--red) 30%, transparent)',
          borderRadius: 10, padding: '12px 16px', marginBottom: 16,
          fontSize: 13, color: 'var(--red)',
        }}>
          <AlertCircle size={15} />
          {error}
        </div>
      )}

      {/* Loading */}
      {loading && (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '48px 0', color: 'var(--fg3)' }}>
          <Loader2 size={24} className="animate-spin" />
        </div>
      )}

      {/* Content */}
      {!loading && tb && (
        <>
          {/* Summary cards */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 16 }}>
            <div style={{ background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12, padding: '14px 16px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--fg3)', marginBottom: 8 }}>
                <TrendingDown size={13} />
                <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Бюджет {periodDays} дн</span>
              </div>
              <div style={{ fontSize: 22, fontWeight: 700, color: 'var(--fg)', lineHeight: 1 }}>
                {Math.round(tb.total_cost).toLocaleString()} ₸
              </div>
              {phd && (
                <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 4 }}>
                  {Math.round(phd.total_cost).toLocaleString()} ₸/гол/день
                </div>
              )}
            </div>

            <div style={{ background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12, padding: '14px 16px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--fg3)', marginBottom: 8 }}>
                <Package size={13} />
                <span style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '0.05em' }}>Нехватка кормов</span>
              </div>
              <div style={{
                fontSize: 22, fontWeight: 700, lineHeight: 1,
                color: tb.deficit_count > 0 ? 'var(--red)' : 'var(--green)',
              }}>
                {tb.deficit_count > 0 ? `${tb.deficit_count} вида` : 'Нет'}
              </div>
              <div style={{ fontSize: 12, color: 'var(--fg3)', marginTop: 4 }}>
                {tb.days_until_shortage > 0 && tb.days_until_shortage < 999
                  ? `Через ${tb.days_until_shortage} дн нехватка`
                  : 'Запасов достаточно'}
              </div>
            </div>
          </div>

          {/* Deficits first, then OK feeds */}
          {tb.feeds.length > 0 ? (
            <div style={{ background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12, overflow: 'hidden' }}>
              <div style={{ padding: '12px 16px', borderBottom: '1px solid var(--bd)' }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--fg2)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                  Корма · {tb.feeds.length} позиций
                </div>
              </div>
              {[...tb.feeds]
                .sort((a, b) => (b.deficit_kg > 0 ? 1 : 0) - (a.deficit_kg > 0 ? 1 : 0) || a.days_left - b.days_left)
                .map(feed => (
                  <FeedRow key={feed.feed_item_id} feed={feed} />
                ))
              }
            </div>
          ) : (
            <div style={{
              textAlign: 'center', padding: '48px 24px',
              background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
              color: 'var(--fg3)', fontSize: 14,
            }}>
              Нет данных по кормовым запасам.
              <br />
              <span style={{ fontSize: 13 }}>Добавьте корма в «Инвентаре кормов».</span>
            </div>
          )}
        </>
      )}

      {!loading && !tb && !error && (
        <div style={{
          textAlign: 'center', padding: '48px 24px',
          background: 'var(--bg-c)', border: '1px solid var(--bd)', borderRadius: 12,
          color: 'var(--fg3)', fontSize: 14,
        }}>
          Нет активных рационов для расчёта бюджета.
          <br />
          <span style={{ fontSize: 13 }}>Сначала рассчитайте рационы в «Рационы фермы».</span>
        </div>
      )}
    </div>
  )
}
