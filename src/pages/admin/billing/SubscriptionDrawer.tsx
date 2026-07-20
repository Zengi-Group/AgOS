/**
 * ARS-271 — subscription card drawer (admin). Opens over the subscriptions list.
 * Shows the subscription + plan + org + payment history, and exposes the six admin
 * operations backed by merged d13 RPCs (ARS-267):
 *   manual payment · extend (comp) · change plan · cancel · resume · disciplinary revoke.
 * Every action: confirm → disabled-on-submit → toast (auto via useRpcMutation) → refetch.
 * Admin zone: neutral `.light`, lucide icons, numbers in font-mono.
 */
import { useEffect, useState } from 'react'
import {
  Building2, HandCoins, CalendarPlus, ArrowLeftRight, XCircle, RotateCcw, Ban,
  ChevronDown, Loader2,
} from 'lucide-react'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/components/ui/select'
import { Sheet, SheetContent, SheetHeader, SheetTitle } from '@/components/ui/sheet'
import { BillingError } from './BillingStates'
import {
  SUB_STATE_META, PAY_STATUS_META, isLive, providerLabel,
  fmtPrice, fmtDate, fmtDateShort, fmtDateTime,
  type SubscriptionCard, type PlanRow, type PayStatus,
} from './billingShared'

export function SubscriptionDrawer({
  subscriptionId,
  plans,
  onClose,
  onChanged,
}: {
  subscriptionId: string
  plans: PlanRow[]
  onClose: () => void
  onChanged: () => void
}) {
  const { data: card, isLoading, isError, refetch } =
    useRpc<SubscriptionCard>('rpc_admin_get_subscription', { p_subscription_id: subscriptionId })

  const [active, setActive] = useState<string | null>(null)
  // manual payment
  const [payAmount, setPayAmount] = useState('')
  const [payRef, setPayRef] = useState('')
  const [payNote, setPayNote] = useState('')
  // extend
  const [extDays, setExtDays] = useState('30')
  const [extNote, setExtNote] = useState('')
  // change plan
  const [newPlan, setNewPlan] = useState('')
  // cancel
  const [cancelMode, setCancelMode] = useState<'period_end' | 'immediate'>('period_end')
  // revoke
  const [revokeReason, setRevokeReason] = useState('')

  const sub = card?.subscription
  const orgId = sub?.organization_id
  const periodEnd = sub?.current_period_end

  // prefill manual-payment amount with the locked price snapshot
  useEffect(() => {
    if (sub?.price_snapshot != null) setPayAmount(String(sub.price_snapshot))
  }, [sub?.price_snapshot])

  const done = () => { setActive(null); refetch(); onChanged() }

  const mp  = useRpcMutation('rpc_admin_record_manual_payment',  { successMessage: 'Оплата принята',            onSuccess: done })
  const ext = useRpcMutation('rpc_admin_extend_subscription',    { successMessage: 'Подписка продлена',          onSuccess: done })
  const chg = useRpcMutation('rpc_admin_change_subscription_plan',{ successMessage: 'План изменён',              onSuccess: done })
  const can = useRpcMutation('rpc_cancel_org_membership',        { successMessage: 'Подписка отменена',          onSuccess: done })
  const res = useRpcMutation('rpc_resume_org_membership',        { successMessage: 'Автопродление возобновлено', onSuccess: done })
  const rev = useRpcMutation('rpc_admin_revoke_membership',      { successMessage: 'Членство отозвано',          onSuccess: done })

  const state = sub?.state
  const terminal = state === 'canceled' || state === 'revoked'
  const live = state ? isLive(state) : false

  // ── action handlers (client validation mirrors the RPC; server is authoritative) ──
  const submitPay = () => {
    const amount = Number(payAmount)
    if (!Number.isFinite(amount) || amount < 0) return
    if (!payRef.trim() || !payNote.trim()) return
    if (!confirm(`Принять оплату ${fmtPrice(amount)} ₸? Период будет продлён, подписка — активна.`)) return
    mp.mutate({ p_subscription_id: subscriptionId, p_amount: amount, p_reference: payRef.trim(), p_note: payNote.trim() })
  }
  const submitExtend = () => {
    const days = Number(extDays)
    if (!Number.isInteger(days) || days < 1 || days > 90) return
    if (!extNote.trim()) return
    if (!confirm(`Продлить подписку на ${days} дн. без оплаты (комп/жест)?`)) return
    ext.mutate({ p_subscription_id: subscriptionId, p_days: days, p_note: extNote.trim() })
  }
  const submitChange = () => {
    if (!newPlan || newPlan === sub?.plan_code) return
    if (!confirm('Сменить план со следующего периода? Текущий период и цена не меняются.')) return
    chg.mutate({ p_subscription_id: subscriptionId, p_new_plan_code: newPlan })
  }
  const submitCancel = () => {
    if (!orgId) return
    const immediate = cancelMode === 'immediate'
    const msg = immediate
      ? 'Отменить подписку немедленно? Доступ пропадёт сразу.'
      : `Отменить в конце периода (${fmtDateShort(periodEnd)})? Доступ сохранится до конца оплаченного периода.`
    if (!confirm(msg)) return
    can.mutate({ p_organization_id: orgId, p_immediate: immediate })
  }
  const submitResume = () => {
    if (!orgId) return
    if (!confirm('Возобновить автопродление (отменить запланированную отмену)?')) return
    res.mutate({ p_organization_id: orgId })
  }
  const submitRevoke = () => {
    if (!orgId || !revokeReason.trim()) return
    if (!confirm('Дисциплинарно отозвать членство? Доступ пропадёт немедленно; для возврата нужна новая подписка.')) return
    rev.mutate({ p_organization_id: orgId, p_reason: revokeReason.trim() })
  }

  return (
    <Sheet open onOpenChange={v => { if (!v) onClose() }}>
      <SheetContent side="right" className="w-full sm:max-w-xl p-0 overflow-y-auto">
        <SheetHeader className="px-5 pt-5 pb-3 border-b border-border/60 text-left">
          <SheetTitle className="text-[15px] flex items-center gap-2">
            <Building2 className="h-4 w-4" />
            {card?.organization?.name || 'Подписка'}
          </SheetTitle>
          {card?.organization?.bin && (
            <span className="text-[11px] font-mono" style={{ color: 'var(--fg3)' }}>БИН {card.organization.bin}</span>
          )}
        </SheetHeader>

        {isLoading ? (
          <div className="p-5"><Skeleton className="h-64 w-full" /></div>
        ) : isError || !card || !sub ? (
          <div className="p-5"><BillingError onRetry={() => refetch()} message="Не удалось загрузить карточку" /></div>
        ) : (
          <div className="p-5 space-y-5">
            {/* Summary */}
            <div className="border border-border/60 rounded-[8px] bg-background p-4 space-y-3">
              <div className="flex items-center justify-between">
                <div className="min-w-0">
                  <div className="text-[13px] font-medium truncate">{card.plan?.title || sub.plan_code}</div>
                  <div className="text-[10px] font-mono" style={{ color: 'var(--fg3)' }}>{sub.plan_code}</div>
                </div>
                <StateBadge state={sub.state} />
              </div>
              <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[12px]">
                <Field label="Цена (snapshot)" value={`${fmtPrice(sub.price_snapshot)} ₸`} mono />
                <Field label="Период" value={`${fmtDate(sub.current_period_start)} — ${fmtDate(sub.current_period_end)}`} mono />
                <Field label="След. списание" value={fmtDate(sub.next_billing_at)} mono />
                <Field label="Автопродление" value={sub.cancel_at_period_end ? `отменится ${fmtDateShort(sub.current_period_end)}` : (live ? 'включено' : '—')} />
                {sub.trial_end && <Field label="Триал до" value={fmtDate(sub.trial_end)} mono />}
                <Field label="Членство (legacy)" value={card.membership_level || '—'} />
              </div>
              {sub.state === 'revoked' && sub.revoke_reason && (
                <div className="text-[12px] rounded bg-rose-500/10 text-rose-700 px-2.5 py-1.5">
                  Причина отзыва: {sub.revoke_reason}
                </div>
              )}
            </div>

            {/* Actions */}
            <div className="space-y-2">
              <div className="text-[11px] font-medium uppercase tracking-wide" style={{ color: 'var(--fg3)' }}>Операции</div>
              {terminal && (
                <div className="text-[12px] rounded bg-muted px-3 py-2" style={{ color: 'var(--fg2)' }}>
                  Подписка в терминальном состоянии — для возврата оформите новую подписку.
                </div>
              )}

              {/* Manual payment — allowed unless terminal (canceled/revoked) */}
              {!terminal && (
                <ActionRow id="pay" active={active} setActive={setActive} icon={HandCoins} label="Принять оплату вручную">
                  <div className="grid grid-cols-2 gap-2">
                    <div>
                      <Label className="text-[12px]">Сумма (₸)</Label>
                      <Input type="number" min={0} step="10" value={payAmount} onChange={e => setPayAmount(e.target.value)} className="h-8 text-[12px]" />
                    </div>
                    <div>
                      <Label className="text-[12px]">№ квитанции / референс *</Label>
                      <Input value={payRef} onChange={e => setPayRef(e.target.value)} placeholder="Kaspi #…" className="h-8 text-[12px]" />
                    </div>
                  </div>
                  <div>
                    <Label className="text-[12px]">Основание *</Label>
                    <Input value={payNote} onChange={e => setPayNote(e.target.value)} placeholder="напр. перевод по счёту №…" className="h-8 text-[12px]" />
                  </div>
                  <SubmitBtn onClick={submitPay} pending={mp.isPending}
                    disabled={!payRef.trim() || !payNote.trim() || !(Number(payAmount) >= 0)}>
                    Принять оплату
                  </SubmitBtn>
                </ActionRow>
              )}

              {/* Extend — allowed unless terminal */}
              {!terminal && (
                <ActionRow id="extend" active={active} setActive={setActive} icon={CalendarPlus} label="Продлить (комп/жест)">
                  <div className="grid grid-cols-2 gap-2">
                    <div>
                      <Label className="text-[12px]">Дней (1–90)</Label>
                      <Input type="number" min={1} max={90} value={extDays} onChange={e => setExtDays(e.target.value)} className="h-8 text-[12px]" />
                    </div>
                  </div>
                  <div>
                    <Label className="text-[12px]">Основание *</Label>
                    <Input value={extNote} onChange={e => setExtNote(e.target.value)} placeholder="напр. компенсация простоя" className="h-8 text-[12px]" />
                  </div>
                  <SubmitBtn onClick={submitExtend} pending={ext.isPending}
                    disabled={!extNote.trim() || !(Number(extDays) >= 1 && Number(extDays) <= 90)}>
                    Продлить
                  </SubmitBtn>
                </ActionRow>
              )}

              {/* Change plan — live subs only */}
              {live && (
                <ActionRow id="plan" active={active} setActive={setActive} icon={ArrowLeftRight} label="Сменить план">
                  <p className="text-[11px]" style={{ color: 'var(--fg3)' }}>Вступит в силу со следующего периода (перетарификация при продлении).</p>
                  <Select value={newPlan} onValueChange={setNewPlan}>
                    <SelectTrigger className="h-8 text-[12px]"><SelectValue placeholder="Выберите план" /></SelectTrigger>
                    <SelectContent>
                      {plans.filter(p => p.is_active && p.plan_code !== sub.plan_code).map(p => (
                        <SelectItem key={p.plan_code} value={p.plan_code}>{p.title} · {fmtPrice(p.price_amount)} ₸</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <SubmitBtn onClick={submitChange} pending={chg.isPending} disabled={!newPlan || newPlan === sub.plan_code}>
                    Сменить план
                  </SubmitBtn>
                </ActionRow>
              )}

              {/* Cancel — live subs only */}
              {live && (
                <ActionRow id="cancel" active={active} setActive={setActive} icon={XCircle} label="Отменить подписку" tone="text-rose-500">
                  <div className="space-y-1.5">
                    <RadioLine checked={cancelMode === 'period_end'} onChange={() => setCancelMode('period_end')}
                      label={`В конце периода (${fmtDateShort(periodEnd)})`} hint="Доступ сохранится до конца оплаченного периода" />
                    <RadioLine checked={cancelMode === 'immediate'} onChange={() => setCancelMode('immediate')}
                      label="Немедленно" hint="Доступ пропадёт сразу" />
                  </div>
                  <SubmitBtn onClick={submitCancel} pending={can.isPending} destructive>Отменить</SubmitBtn>
                </ActionRow>
              )}

              {/* Resume — only when a cancellation is scheduled */}
              {live && sub.cancel_at_period_end && (
                <ActionRow id="resume" active={active} setActive={setActive} icon={RotateCcw} label="Возобновить автопродление" tone="text-emerald-600">
                  <p className="text-[12px]" style={{ color: 'var(--fg2)' }}>Снять запланированную отмену — подписка продолжит продлеваться.</p>
                  <SubmitBtn onClick={submitResume} pending={res.isPending}>Возобновить</SubmitBtn>
                </ActionRow>
              )}

              {/* Disciplinary revoke — live subs only (Q5 = yes, D-BILL-REVOKE-01) */}
              {live && (
                <ActionRow id="revoke" active={active} setActive={setActive} icon={Ban} label="Дисциплинарный отзыв" tone="text-rose-600">
                  <p className="text-[11px]" style={{ color: 'var(--fg3)' }}>Терминальный отзыв членства (MS2 D-MEM-5). Доступ пропадёт немедленно; возврат — только новой подпиской.</p>
                  <div>
                    <Label className="text-[12px]">Причина *</Label>
                    <Input value={revokeReason} onChange={e => setRevokeReason(e.target.value)} placeholder="напр. нарушение устава ассоциации" className="h-8 text-[12px]" />
                  </div>
                  <SubmitBtn onClick={submitRevoke} pending={rev.isPending} disabled={!revokeReason.trim()} destructive>Отозвать членство</SubmitBtn>
                </ActionRow>
              )}
            </div>

            {/* Payment history */}
            <div className="space-y-2">
              <div className="text-[11px] font-medium uppercase tracking-wide" style={{ color: 'var(--fg3)' }}>История платежей</div>
              {card.payments.length === 0 ? (
                <div className="text-[12px] px-1 py-2" style={{ color: 'var(--fg3)' }}>Платежей пока нет.</div>
              ) : (
                <div className="border border-border/60 rounded-[8px] overflow-hidden">
                  {card.payments.map(p => (
                    <div key={p.id} className="flex items-center gap-2 px-3 py-2 border-b border-border/60 last:border-b-0 text-[12px]">
                      <span className="font-mono shrink-0" style={{ color: 'var(--fg2)' }}>{fmtDateTime(p.created_at)}</span>
                      <span className="font-mono font-medium shrink-0">{fmtPrice(p.amount)} ₸</span>
                      <PayBadge status={p.status} />
                      <span className="shrink-0" style={{ color: 'var(--fg3)' }}>{providerLabel(p.provider)}</span>
                      <span className="ml-auto truncate text-right" style={{ color: 'var(--fg3)' }} title={p.note || undefined}>
                        {p.provider_ref || (p.note ? p.note : '')}
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </SheetContent>
    </Sheet>
  )
}

// ── local presentational helpers ──────────────────────────────────────────────

function StateBadge({ state }: { state: SubscriptionCard['subscription']['state'] }) {
  const m = SUB_STATE_META[state]
  return <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${m.cls}`}>{m.label}</span>
}

function PayBadge({ status }: { status: PayStatus }) {
  const m = PAY_STATUS_META[status]
  return <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium shrink-0 ${m.cls}`}>{m.label}</span>
}

function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="min-w-0">
      <div className="text-[10px]" style={{ color: 'var(--fg3)' }}>{label}</div>
      <div className={`truncate ${mono ? 'font-mono' : ''}`}>{value}</div>
    </div>
  )
}

function ActionRow({
  id, active, setActive, icon: Icon, label, tone, children,
}: {
  id: string
  active: string | null
  setActive: (v: string | null) => void
  icon: React.ComponentType<{ className?: string }>
  label: string
  tone?: string
  children: React.ReactNode
}) {
  const open = active === id
  return (
    <div className="border border-border/60 rounded-[8px] overflow-hidden bg-background">
      <button
        type="button"
        onClick={() => setActive(open ? null : id)}
        className="w-full flex items-center gap-2 px-3 h-10 text-[13px] font-medium hover:bg-muted/40 transition-colors"
      >
        <Icon className={`h-4 w-4 ${tone || ''}`} />
        {label}
        <ChevronDown className={`ml-auto h-4 w-4 transition-transform ${open ? 'rotate-180' : ''}`} style={{ color: 'var(--fg3)' }} />
      </button>
      {open && <div className="px-3 pb-3 pt-2 border-t border-border/60 space-y-2">{children}</div>}
    </div>
  )
}

function SubmitBtn({
  onClick, pending, disabled, destructive, children,
}: {
  onClick: () => void
  pending: boolean
  disabled?: boolean
  destructive?: boolean
  children: React.ReactNode
}) {
  return (
    <Button
      size="sm"
      onClick={onClick}
      disabled={pending || disabled}
      variant={destructive ? 'destructive' : 'default'}
      className="h-8 px-3 text-[12px]"
    >
      {pending && <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" />}
      {children}
    </Button>
  )
}

function RadioLine({
  checked, onChange, label, hint,
}: {
  checked: boolean
  onChange: () => void
  label: string
  hint: string
}) {
  return (
    <label className="flex items-start gap-2 cursor-pointer">
      <input type="radio" checked={checked} onChange={onChange} className="mt-0.5" />
      <span className="text-[12px]">
        <span className="font-medium">{label}</span>
        <span className="block text-[11px]" style={{ color: 'var(--fg3)' }}>{hint}</span>
      </span>
    </label>
  )
}
