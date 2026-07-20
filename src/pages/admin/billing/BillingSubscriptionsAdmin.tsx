/**
 * ARS-271 — «Подписки» (admin). List of every membership subscription with a KPI
 * strip, state/plan/search filters, and a click-through to the subscription card
 * drawer. Read-only over rpc_admin_list_subscriptions (ARS-266). Admin zone:
 * neutral `.light`, lucide, numbers in font-mono, D-UI-TOPBAR-01 (CreditCard tab).
 */
import { useMemo, useState } from 'react'
import { CreditCard, Search } from 'lucide-react'
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useRpc } from '@/hooks/useRpc'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { BillingError, BillingEmpty } from './BillingStates'
import { SubscriptionDrawer } from './SubscriptionDrawer'
import {
  BILLING_TABS, SUB_STATES, SUB_STATE_META, isLive,
  fmtPrice, fmtDate, fmtDateShort, daysUntil,
  type ListSubscriptionsResult, type ListPaymentsResult, type SubState, type PlanRow,
} from './billingShared'

const ALL = '__all__'

export function BillingSubscriptionsAdmin() {
  const { isAdmin, checking } = useAdminGuard()
  const [stateFilter, setStateFilter] = useState<SubState | null>(null)
  const [search, setSearch] = useState('')
  const [planFilter, setPlanFilter] = useState<string>(ALL)
  const [openId, setOpenId] = useState<string | null>(null)

  useSetTopbar({ title: 'Подписки', titleIcon: <CreditCard size={15} />, tabs: BILLING_TABS })

  const { data, isLoading, isError, refetch } = useRpc<ListSubscriptionsResult>(
    'rpc_admin_list_subscriptions',
    {
      p_state: stateFilter,
      p_plan_code: planFilter === ALL ? null : planFilter,
      p_search: search.trim() || null,
    },
  )

  // plans — filter dropdown + passed to the drawer for change-plan
  const { data: plans } = useRpc<PlanRow[]>('rpc_admin_list_membership_plans', {})

  // KPI: money-in over the last 30 days (accurate footer from the payments RPC).
  // Compute the boundary once so the query key stays stable across renders.
  const from30 = useMemo(() => new Date(Date.now() - 30 * 86_400_000).toISOString(), [])
  const { data: pay30 } = useRpc<ListPaymentsResult>(
    'rpc_admin_list_membership_payments',
    { p_status: 'succeeded', p_from: from30, p_limit: 1 },
  )

  if (checking) return <div className="page"><Skeleton className="h-48 w-full" /></div>
  if (!isAdmin) return null

  const counts = data?.counts_by_state
  const rows = data?.rows || []
  // "истекают ≤7 дн" is computed from the loaded page (prod scale « page limit);
  // exact enough at pilot volume — revisit with a dedicated counter if lists grow.
  const expiring = rows.filter(r => isLive(r.state) && (daysUntil(r.current_period_end) ?? 999) <= 7).length

  const COL = 'minmax(190px,2fr) 150px 110px 115px 115px 150px 96px'

  return (
    <div className="page space-y-4">
      {/* KPI strip */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
        <Kpi label="Активные" value={counts?.active ?? 0} />
        <Kpi label="В триале" value={counts?.trialing ?? 0} />
        <Kpi label="Риск (льгота+просрочка)" value={(counts?.grace ?? 0) + (counts?.past_due ?? 0)} />
        <Kpi label="Истекают ≤7 дн" value={expiring} />
        <Kpi label="Оплат за 30 дн, ₸" value={fmtPrice(pay30?.sum_succeeded ?? 0)} />
      </div>

      {/* Filters */}
      <div className="flex flex-wrap items-center gap-2">
        <Chip active={stateFilter === null} onClick={() => setStateFilter(null)}>Все</Chip>
        {SUB_STATES.map(s => (
          <Chip key={s} active={stateFilter === s} onClick={() => setStateFilter(s)}>
            {SUB_STATE_META[s].label}
          </Chip>
        ))}
        <div className="ml-auto flex items-center gap-2">
          <div className="relative">
            <Search className="absolute left-2 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground" />
            <Input
              value={search}
              onChange={e => setSearch(e.target.value)}
              placeholder="Название или БИН"
              className="h-8 w-56 pl-7 text-[12px]"
            />
          </div>
          <Select value={planFilter} onValueChange={setPlanFilter}>
            <SelectTrigger className="h-8 w-44 text-[12px]"><SelectValue placeholder="Все планы" /></SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>Все планы</SelectItem>
              {(plans || []).map(p => <SelectItem key={p.plan_code} value={p.plan_code}>{p.title}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* Table */}
      {isLoading ? <Skeleton className="h-64 w-full" />
        : isError ? <BillingError onRetry={() => refetch()} message="Не удалось загрузить подписки" />
        : rows.length === 0 ? <BillingEmpty message="Подписок пока нет" />
        : (
          <div className="flex flex-col border border-border/60 rounded-[8px] overflow-hidden bg-background">
            <div className="grid border-b border-border/60 bg-muted/40" style={{ gridTemplateColumns: COL }}>
              {['Организация', 'План', 'Состояние', 'Период до', 'След. списание', 'Автопродление', 'Цена ₸'].map((h, i) => (
                <div
                  key={i}
                  className={`h-[34px] px-3 flex items-center text-[11px] font-medium border-r border-border/60 last:border-r-0 ${i === 6 ? 'justify-end' : ''}`}
                  style={{ color: 'var(--fg2)' }}
                >
                  {h}
                </div>
              ))}
            </div>
            {rows.map(r => (
              <div
                key={r.id}
                onClick={() => setOpenId(r.id)}
                className="grid border-b border-border/60 cursor-pointer hover:bg-muted/40 transition-colors last:border-b-0"
                style={{ gridTemplateColumns: COL }}
              >
                <div className="h-[46px] px-3 flex flex-col justify-center border-r border-border/60 min-w-0">
                  <span className="text-[13px] font-medium truncate">{r.org_name}</span>
                  <span className="text-[10px] font-mono truncate" style={{ color: 'var(--fg3)' }}>{r.org_bin || '—'}</span>
                </div>
                <div className="h-[46px] px-3 flex items-center border-r border-border/60 text-[12px] truncate">{r.plan_title}</div>
                <div className="h-[46px] px-3 flex items-center border-r border-border/60">
                  <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${SUB_STATE_META[r.state].cls}`}>
                    {SUB_STATE_META[r.state].label}
                  </span>
                </div>
                <div className="h-[46px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono">{fmtDate(r.current_period_end)}</div>
                <div className="h-[46px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono">{fmtDate(r.next_billing_at)}</div>
                <div className="h-[46px] px-3 flex items-center border-r border-border/60 text-[12px]">
                  {r.cancel_at_period_end
                    ? <span className="text-rose-600">отменится {fmtDateShort(r.current_period_end)}</span>
                    : isLive(r.state) ? <span style={{ color: 'var(--fg2)' }}>вкл.</span> : <span style={{ color: 'var(--fg3)' }}>—</span>}
                </div>
                <div className="h-[46px] px-3 flex items-center justify-end font-mono text-[13px] font-medium">{fmtPrice(r.price_snapshot)}</div>
              </div>
            ))}
          </div>
        )}

      {openId && (
        <SubscriptionDrawer
          subscriptionId={openId}
          plans={plans || []}
          onClose={() => setOpenId(null)}
          onChanged={() => refetch()}
        />
      )}
    </div>
  )
}

// ── local helpers ─────────────────────────────────────────────────────────────

function Kpi({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="border border-border/60 rounded-[8px] bg-background px-3 py-2">
      <div className="text-[11px] truncate" style={{ color: 'var(--fg3)' }}>{label}</div>
      <div className="text-[18px] font-semibold font-mono">{value}</div>
    </div>
  )
}

function Chip({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`h-7 px-2.5 rounded-full text-[12px] font-medium border transition-colors ${
        active ? 'bg-foreground text-background border-foreground' : 'border-border/60 hover:bg-muted/60'
      }`}
    >
      {children}
    </button>
  )
}
