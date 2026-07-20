/**
 * ARS-271 — «Платежи» (admin). Membership payments ledger with status + date-range
 * filters and a "money in" footer. Read-only over rpc_admin_list_membership_payments
 * (ARS-266). NOTE: that RPC filters by status/org/date only — provider is narrowed
 * client-side over the loaded page (few rows at pilot volume). Admin zone: neutral
 * `.light`, lucide, numbers in font-mono, D-UI-TOPBAR-01 (CreditCard tab).
 */
import { useState } from 'react'
import { CreditCard } from 'lucide-react'
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useRpc } from '@/hooks/useRpc'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { BillingError, BillingEmpty } from './BillingStates'
import {
  BILLING_TABS, PAY_STATUS_META, PAY_STATUSES, PROVIDERS, providerLabel,
  fmtPrice, fmtDateTime,
  type ListPaymentsResult, type PayStatus,
} from './billingShared'

const ALL = '__all__'
const startOfDay = (d: string) => new Date(`${d}T00:00:00`).toISOString()
const endOfDay = (d: string) => new Date(`${d}T23:59:59`).toISOString()

export function BillingPaymentsAdmin() {
  const { isAdmin, checking } = useAdminGuard()
  const [status, setStatus] = useState<PayStatus | null>(null)
  const [provider, setProvider] = useState<string>(ALL) // client-side (RPC has no provider filter)
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')

  useSetTopbar({ title: 'Платежи', titleIcon: <CreditCard size={15} />, tabs: BILLING_TABS })

  const { data, isLoading, isError, refetch } = useRpc<ListPaymentsResult>(
    'rpc_admin_list_membership_payments',
    {
      p_status: status,
      p_from: from ? startOfDay(from) : null,
      p_to: to ? endOfDay(to) : null,
    },
  )

  if (checking) return <div className="page"><Skeleton className="h-48 w-full" /></div>
  if (!isAdmin) return null

  const total = data?.total ?? 0
  const allRows = data?.rows || []
  const rows = provider === ALL ? allRows : allRows.filter(r => r.provider === provider)

  const COL = 'minmax(150px,1fr) minmax(160px,1.4fr) 110px 100px 96px minmax(130px,1.2fr) 92px'

  return (
    <div className="page space-y-4">
      {/* Filters + money-in footer */}
      <div className="flex flex-wrap items-end gap-3">
        <div>
          <div className="text-[11px] mb-1" style={{ color: 'var(--fg3)' }}>Статус</div>
          <Select value={status ?? ALL} onValueChange={v => setStatus(v === ALL ? null : v as PayStatus)}>
            <SelectTrigger className="h-8 w-36 text-[12px]"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>Все статусы</SelectItem>
              {PAY_STATUSES.map(s => <SelectItem key={s} value={s}>{PAY_STATUS_META[s].label}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
        <div>
          <div className="text-[11px] mb-1" style={{ color: 'var(--fg3)' }}>Провайдер</div>
          <Select value={provider} onValueChange={setProvider}>
            <SelectTrigger className="h-8 w-36 text-[12px]"><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>Все</SelectItem>
              {PROVIDERS.map(p => <SelectItem key={p} value={p}>{providerLabel(p)}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
        <div>
          <div className="text-[11px] mb-1" style={{ color: 'var(--fg3)' }}>С даты</div>
          <Input type="date" value={from} onChange={e => setFrom(e.target.value)} className="h-8 w-40 text-[12px]" />
        </div>
        <div>
          <div className="text-[11px] mb-1" style={{ color: 'var(--fg3)' }}>По дату</div>
          <Input type="date" value={to} onChange={e => setTo(e.target.value)} className="h-8 w-40 text-[12px]" />
        </div>
        <div className="ml-auto text-right">
          <div className="text-[11px]" style={{ color: 'var(--fg3)' }}>Поступления за период (успешные)</div>
          <div className="text-[18px] font-semibold font-mono">{fmtPrice(data?.sum_succeeded ?? 0)} ₸</div>
        </div>
      </div>

      {/* Table */}
      {isLoading ? <Skeleton className="h-64 w-full" />
        : isError ? <BillingError onRetry={() => refetch()} message="Не удалось загрузить платежи" />
        : rows.length === 0 ? <BillingEmpty message="Платежей по фильтру нет" />
        : (
          <>
            <div className="flex flex-col border border-border/60 rounded-[8px] overflow-hidden bg-background">
              <div className="grid border-b border-border/60 bg-muted/40" style={{ gridTemplateColumns: COL }}>
                {['Дата', 'Организация', 'Сумма ₸', 'Статус', 'Провайдер', 'Референс / основание', 'Кто внёс'].map((h, i) => (
                  <div
                    key={i}
                    className={`h-[34px] px-3 flex items-center text-[11px] font-medium border-r border-border/60 last:border-r-0 ${i === 2 ? 'justify-end' : ''}`}
                    style={{ color: 'var(--fg2)' }}
                  >
                    {h}
                  </div>
                ))}
              </div>
              {rows.map(p => (
                <div key={p.id} className="grid border-b border-border/60 last:border-b-0" style={{ gridTemplateColumns: COL }}>
                  <div className="h-[42px] px-3 flex items-center border-r border-border/60 text-[12px] font-mono" style={{ color: 'var(--fg2)' }}>{fmtDateTime(p.created_at)}</div>
                  <div className="h-[42px] px-3 flex items-center border-r border-border/60 text-[12px] truncate">{p.org_name || '—'}</div>
                  <div className="h-[42px] px-3 flex items-center justify-end border-r border-border/60 font-mono text-[13px] font-medium">{fmtPrice(p.amount)}</div>
                  <div className="h-[42px] px-3 flex items-center border-r border-border/60">
                    <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${PAY_STATUS_META[p.status].cls}`}>
                      {PAY_STATUS_META[p.status].label}
                    </span>
                  </div>
                  <div className="h-[42px] px-3 flex items-center border-r border-border/60 text-[12px]" style={{ color: 'var(--fg2)' }}>{providerLabel(p.provider)}</div>
                  <div className="h-[42px] px-3 flex items-center border-r border-border/60 text-[12px] truncate" title={p.note || undefined}>
                    {p.provider_ref || p.note || '—'}
                  </div>
                  <div className="h-[42px] px-3 flex items-center text-[12px]" style={{ color: 'var(--fg3)' }}>{p.created_by ? 'админ' : '—'}</div>
                </div>
              ))}
            </div>
            <div className="text-[11px]" style={{ color: 'var(--fg3)' }}>
              Показано {rows.length}
              {provider !== ALL && ` из ${allRows.length} на странице`}
              {' · '}всего по фильтру: {total}
              {total > allRows.length && ' (показаны первые 50)'}
            </div>
          </>
        )}
    </div>
  )
}
