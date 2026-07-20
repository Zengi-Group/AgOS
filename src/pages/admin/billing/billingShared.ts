/**
 * ARS-271 — shared building blocks for the admin billing section
 * (/admin/billing/{plans|subscriptions|payments}).
 *
 * Topbar tabs (D-UI-TOPBAR-01, RationPage pattern), FSM/status badge metadata,
 * ru-RU formatters, and TS types bound to the merged d13_billing.sql RPC returns
 * (ARS-266 read-RPC + ARS-267 write-RPC). Admin zone = neutral `.light`, lucide,
 * numbers in Tailwind `font-mono` (mirrors BillingPlansAdmin).
 */
import type { TopbarTab } from '@/components/layout/TopbarContext'

// ── Topbar tabs ──────────────────────────────────────────────────────────────
// Each billing leaf screen declares this same array; Header renders it with a
// per-path `useMatch` active state, so no layout wrapper is needed.
export const BILLING_TABS: TopbarTab[] = [
  { label: 'Планы',    path: '/admin/billing/plans' },
  { label: 'Подписки', path: '/admin/billing/subscriptions' },
  { label: 'Платежи',  path: '/admin/billing/payments' },
]

// ── Subscription FSM (d13 CHECK: membership_subscription.state) ───────────────
export type SubState =
  | 'trialing' | 'active' | 'grace' | 'past_due' | 'expired' | 'canceled' | 'revoked'

export const SUB_STATE_META: Record<SubState, { label: string; cls: string }> = {
  trialing: { label: 'Триал',     cls: 'bg-sky-500/15 text-sky-600' },
  active:   { label: 'Активна',   cls: 'bg-emerald-500/15 text-emerald-600' },
  grace:    { label: 'Льготный',  cls: 'bg-amber-500/15 text-amber-600' },
  past_due: { label: 'Просрочка', cls: 'bg-orange-500/15 text-orange-600' },
  expired:  { label: 'Истекла',   cls: 'bg-muted text-muted-foreground' },
  canceled: { label: 'Отменена',  cls: 'bg-muted text-muted-foreground' },
  revoked:  { label: 'Отозвана',  cls: 'bg-rose-500/15 text-rose-600' },
}

// Order for the filter chips + display. Live = capabilities ON (d13).
export const SUB_STATES: SubState[] =
  ['trialing', 'active', 'grace', 'past_due', 'expired', 'canceled', 'revoked']
export const LIVE_STATES: SubState[] = ['trialing', 'active', 'grace', 'past_due']
export const isLive = (s: SubState): boolean => LIVE_STATES.includes(s)

// ── Payment status / provider (d13: membership_payment) ───────────────────────
export type PayStatus = 'pending' | 'succeeded' | 'failed'

export const PAY_STATUS_META: Record<PayStatus, { label: string; cls: string }> = {
  pending:   { label: 'Ожидает', cls: 'bg-amber-500/15 text-amber-600' },
  succeeded: { label: 'Успешно', cls: 'bg-emerald-500/15 text-emerald-600' },
  failed:    { label: 'Ошибка',  cls: 'bg-rose-500/15 text-rose-600' },
}
export const PAY_STATUSES: PayStatus[] = ['succeeded', 'pending', 'failed']

// provider is an open text column ('stub' engine charge, 'manual' admin-recorded).
export const PROVIDER_LABEL: Record<string, string> = {
  stub:   'Движок',
  manual: 'Вручную',
}
export const PROVIDERS = ['stub', 'manual'] as const
export const providerLabel = (p: string): string => PROVIDER_LABEL[p] ?? p

// ── ru-RU formatters ──────────────────────────────────────────────────────────
export const fmtPrice = (n: number | null | undefined): string =>
  n == null || !Number.isFinite(Number(n)) ? '—' : Number(n).toLocaleString('ru-RU')

const parse = (iso: string | null | undefined): Date | null => {
  if (!iso) return null
  const d = new Date(iso)
  return isNaN(d.getTime()) ? null : d
}

/** DD.MM.YYYY */
export const fmtDate = (iso: string | null | undefined): string => {
  const d = parse(iso)
  return d ? d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', year: 'numeric' }) : '—'
}

/** DD.MM (for the "отменится DD.MM" autorenew hint) */
export const fmtDateShort = (iso: string | null | undefined): string => {
  const d = parse(iso)
  return d ? d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' }) : '—'
}

/** DD.MM.YYYY, HH:MM */
export const fmtDateTime = (iso: string | null | undefined): string => {
  const d = parse(iso)
  return d
    ? d.toLocaleString('ru-RU', {
        day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
      })
    : '—'
}

/** whole days from now until iso; negative if past; null if no date */
export const daysUntil = (iso: string | null | undefined): number | null => {
  const d = parse(iso)
  if (!d) return null
  return Math.ceil((d.getTime() - Date.now()) / 86_400_000)
}

// ── Types — bound to d13 RPC returns ──────────────────────────────────────────

/** Raw membership_subscription row (to_jsonb of the table). */
export interface SubscriptionBase {
  id: string
  organization_id: string
  membership_id: string | null
  plan_code: string
  state: SubState
  trial_end: string | null
  current_period_start: string | null
  current_period_end: string | null
  next_billing_at: string | null
  cancel_at_period_end: boolean
  price_snapshot: number | null
  revoke_reason: string | null
  created_at: string
  updated_at: string
}

/** rpc_admin_list_subscriptions row — base + org/plan enrichment. */
export interface SubscriptionRow extends SubscriptionBase {
  org_name: string
  org_bin: string | null
  plan_title: string
  last_payment_at: string | null
}

export interface ListSubscriptionsResult {
  total: number
  counts_by_state: Record<SubState, number>
  rows: SubscriptionRow[]
}

/** membership_plan row (rpc_admin_list_membership_plans / card.plan). */
export interface PlanRow {
  id: string
  plan_code: string
  title: string
  billing_period: string
  price_amount: number
  currency: string
  trial_days: number
  applies_org_type: string | null
  grants_tier: string
  grace_days?: number
  version: number
  is_active: boolean
  created_at: string
  updated_at: string
}

/** membership_payment row; list RPC adds org_name + plan_code. */
export interface PaymentRow {
  id: string
  subscription_id: string
  organization_id: string
  amount: number
  currency: string
  status: PayStatus
  provider: string
  provider_ref: string | null
  note: string | null
  created_by: string | null
  created_at: string
  org_name?: string
  plan_code?: string | null
}

export interface ListPaymentsResult {
  total: number
  sum_succeeded: number
  rows: PaymentRow[]
}

/** rpc_admin_get_subscription — one subscription card. */
export interface SubscriptionCard {
  subscription: SubscriptionBase
  plan: PlanRow | null
  organization: { id: string; name: string; bin: string | null } | null
  membership_level: string | null
  payments: PaymentRow[]
}
