/**
 * ARS-207 — Конструктор планов членства TURAN (admin).
 * /admin/billing/plans — CRUD над справочником membership_plan (P8: стандарт как
 * данные). Админ задаёт название, срок (только 1/3/12 мес — CEO ARS-202), цену,
 * trial и уровень доступа; правки применяются без деплоя.
 * Backend: d13_billing.sql — rpc_admin_list_membership_plans (read),
 * rpc_admin_upsert_membership_plan (create/update),
 * rpc_admin_set_membership_plan_active (retire/restore).
 */
import { useState } from 'react'
import { CreditCard, Pencil, Plus, Archive, RotateCcw } from 'lucide-react'
import { useAdminGuard } from '@/hooks/useAdminGuard'
import { useRpc, useRpcMutation } from '@/hooks/useRpc'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Skeleton } from '@/components/ui/skeleton'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog'
import { toast } from 'sonner'
import { BILLING_TABS } from './billingShared'
import { BillingError } from './BillingStates'

interface Plan {
  id: string
  plan_code: string
  title: string
  billing_period: string
  price_amount: number
  currency: string
  trial_days: number
  applies_org_type: string | null
  grants_tier: string
  version: number
  is_active: boolean
  created_at: string
  updated_at: string
}

// Единственные допустимые сроки — CEO ARS-202. Совпадают с CHECK в membership_plan.
const PERIOD_OPTIONS = [
  { value: '1 month',   label: '1 месяц' },
  { value: '3 months',  label: '3 месяца' },
  { value: '12 months', label: '12 месяцев (год)' },
] as const
const PERIOD_LABEL: Record<string, string> = Object.fromEntries(PERIOD_OPTIONS.map(o => [o.value, o.label]))

const TIER_OPTIONS = [
  { value: 'standard', label: 'Standard' },
  { value: 'premium',  label: 'Premium' },
] as const

// applies_org_type: null = «все типы». Значения совпадают с CHECK в membership_plan.
const ORG_TYPE_ANY = '__any__'
const ORG_TYPE_OPTIONS = [
  { value: ORG_TYPE_ANY, label: 'Все типы хозяйств' },
  { value: 'farmer',     label: 'Фермер' },
  { value: 'mpk',        label: 'МПК' },
  { value: 'supplier',   label: 'Поставщик' },
  { value: 'consultant', label: 'Консультант' },
  { value: 'other',      label: 'Другое' },
] as const
const ORG_TYPE_LABEL: Record<string, string> = Object.fromEntries(ORG_TYPE_OPTIONS.map(o => [o.value, o.label]))

const fmtPrice = (n: number): string => n.toLocaleString('ru-RU')

export function BillingPlansAdmin() {
  const { isAdmin, checking } = useAdminGuard()
  const [editItem, setEditItem] = useState<Plan | null>(null)
  const [showCreate, setShowCreate] = useState(false)

  const { data: rows, isLoading, isError, refetch } = useRpc<Plan[]>('rpc_admin_list_membership_plans', {})

  useSetTopbar({ title: 'Планы членства', titleIcon: <CreditCard size={15} />, tabs: BILLING_TABS })

  const setActive = useRpcMutation('rpc_admin_set_membership_plan_active', {
    onSuccess: () => refetch(),
  })

  if (checking) return <div className="page"><Skeleton className="h-48 w-full" /></div>
  if (!isAdmin) return null

  const COL = 'minmax(180px,1.8fr) 130px 120px 90px 110px 90px 44px'

  const toggleActive = (p: Plan) => {
    const restoring = !p.is_active
    if (!restoring && !confirm(`Снять план «${p.title}» с публикации? Он исчезнет из витрины, но продолжит обслуживать активные подписки.`)) return
    setActive.mutate(
      { p_plan_code: p.plan_code, p_is_active: restoring },
      { onSuccess: () => toast.success(restoring ? 'План возвращён в витрину' : 'План снят с публикации') },
    )
  }

  return (
    <div className="page space-y-4">
      {/* Пояснение */}
      <div className="flex items-start gap-3">
        <p className="text-[12px] leading-relaxed" style={{ color: 'var(--fg2)' }}>
          Справочник тарифов членства в ассоциации. Срок ограничен вариантами <b>1 / 3 / 12 месяцев</b> (решение CEO).
          Правки применяются сразу, без деплоя (P8). Активные подписки сохраняют цену на момент оформления —
          изменение цены плана их не затрагивает.
        </p>
        <Button
          size="sm"
          onClick={() => setShowCreate(true)}
          className="ml-auto h-7 px-3 text-[12px] font-medium shrink-0"
        >
          <Plus className="mr-1.5 h-3 w-3" /> Новый план
        </Button>
      </div>

      {isLoading ? <Skeleton className="h-48 w-full" /> : isError ? (
        <BillingError onRetry={() => refetch()} message="Не удалось загрузить планы" />
      ) : (
        <div className="flex flex-col border border-border/60 rounded-[8px] overflow-hidden bg-background">
          {/* Header */}
          <div className="grid border-b border-border/60 bg-muted/40" style={{ gridTemplateColumns: COL }}>
            {[
              { label: 'План' },
              { label: 'Срок' },
              { label: 'Цена (₸)', right: true },
              { label: 'Trial (дн)', right: true },
              { label: 'Уровень' },
              { label: 'Статус' },
              { label: '' },
            ].map((h, i) => (
              <div key={i}
                className={`h-[34px] px-3 flex items-center text-[11px] font-medium border-r border-border/60 last:border-r-0 ${h.right ? 'justify-end' : ''}`}
                style={{ color: 'var(--fg2)' }}>
                {h.label}
              </div>
            ))}
          </div>

          {/* Rows */}
          {(rows || []).length === 0 ? (
            <div className="h-[120px] flex items-center justify-center text-[13px]" style={{ color: 'var(--fg3)' }}>
              Нет планов. Добавьте первый через «+ Новый план».
            </div>
          ) : (rows || []).map(p => (
            <div
              key={p.plan_code}
              onClick={() => setEditItem(p)}
              className={`grid border-b border-border/60 cursor-pointer hover:bg-muted/40 transition-colors group last:border-b-0 ${p.is_active ? '' : 'opacity-60'}`}
              style={{ gridTemplateColumns: COL }}
            >
              <div className="h-[42px] px-3 flex flex-col justify-center border-r border-border/60 min-w-0">
                <span className="text-[13px] font-medium truncate">{p.title}</span>
                <span className="text-[10px] font-mono truncate" style={{ color: 'var(--fg3)' }}>{p.plan_code}</span>
              </div>
              <div className="h-[42px] px-3 flex items-center border-r border-border/60 text-[12px]">
                {PERIOD_LABEL[p.billing_period] || p.billing_period}
              </div>
              <div className="h-[42px] px-3 flex items-center justify-end border-r border-border/60 font-mono text-[13px] font-medium">
                {fmtPrice(p.price_amount)}
              </div>
              <div className="h-[42px] px-3 flex items-center justify-end border-r border-border/60 font-mono text-[12px]">
                {p.trial_days}
              </div>
              <div className="h-[42px] px-3 flex items-center border-r border-border/60">
                <span className={`text-[10px] px-1.5 py-0.5 rounded font-medium ${p.grants_tier === 'premium' ? 'bg-amber-500/15 text-amber-600' : 'bg-muted'}`}>
                  {p.grants_tier}
                </span>
              </div>
              <div className="h-[42px] px-3 flex items-center border-r border-border/60">
                <span className={`text-[11px] font-medium ${p.is_active ? 'text-emerald-600' : ''}`} style={p.is_active ? undefined : { color: 'var(--fg3)' }}>
                  {p.is_active ? 'Активен' : 'Скрыт'}
                </span>
              </div>
              <div className="h-[42px] px-3 flex items-center justify-center text-muted-foreground group-hover:text-foreground">
                <Pencil className="h-3 w-3" />
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Create/Edit dialog */}
      {(showCreate || editItem) && (
        <PlanDialog
          item={editItem}
          existingCodes={(rows || []).map(p => p.plan_code)}
          onClose={() => { setShowCreate(false); setEditItem(null) }}
          onSaved={() => { refetch(); setShowCreate(false); setEditItem(null) }}
          onToggleActive={toggleActive}
        />
      )}
    </div>
  )
}

// ─── Dialog (create + edit + retire/restore) ────────────────────────────────

function PlanDialog({
  item,
  existingCodes,
  onClose,
  onSaved,
  onToggleActive,
}: {
  item: Plan | null
  existingCodes: string[]
  onClose: () => void
  onSaved: () => void
  onToggleActive: (p: Plan) => void
}) {
  const isEdit = !!item
  const [planCode, setPlanCode] = useState(item?.plan_code || '')
  const [title, setTitle] = useState(item?.title || '')
  const [billingPeriod, setBillingPeriod] = useState<string>(item?.billing_period || '12 months')
  const [priceAmount, setPriceAmount] = useState<string>(item ? String(item.price_amount) : '')
  const [trialDays, setTrialDays] = useState<string>(item ? String(item.trial_days) : '30')
  const [grantsTier, setGrantsTier] = useState<string>(item?.grants_tier || 'standard')
  const [orgType, setOrgType] = useState<string>(item?.applies_org_type || ORG_TYPE_ANY)

  const upsert = useRpcMutation('rpc_admin_upsert_membership_plan', {
    successMessage: 'План сохранён',
    onSuccess: () => onSaved(),
  })

  const handleSave = () => {
    const code = planCode.trim()
    if (!isEdit && !/^[a-z0-9_]+$/.test(code)) {
      toast.error('Код плана: только латиница в нижнем регистре, цифры и «_» (напр. org_monthly)')
      return
    }
    // B8: не создавать план поверх существующего кода (upsert иначе тихо перезапишет)
    if (!isEdit && existingCodes.includes(code)) {
      toast.error(`План с кодом «${code}» уже существует — выберите другой код`)
      return
    }
    if (!title.trim()) { toast.error('Укажите название'); return }
    const price = Number(priceAmount)
    if (!Number.isFinite(price) || price < 0) { toast.error('Цена должна быть числом ≥ 0'); return }
    const trial = Number(trialDays)
    if (!Number.isInteger(trial) || trial < 0) { toast.error('Trial — целое число дней ≥ 0'); return }

    upsert.mutate({
      p_plan_code:        isEdit ? item!.plan_code : code,
      p_title:            title.trim(),
      p_billing_period:   billingPeriod,
      p_price_amount:     price,
      p_trial_days:       trial,
      p_grants_tier:      grantsTier,
      p_applies_org_type: orgType === ORG_TYPE_ANY ? null : orgType,
      p_currency:         item?.currency || 'KZT',
    })
  }

  return (
    <Dialog open onOpenChange={v => !v && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{isEdit ? `Изменить план · ${item!.title}` : 'Новый план'}</DialogTitle>
        </DialogHeader>

        <div className="space-y-3 py-2">
          <div>
            <Label className="text-sm">Код плана</Label>
            <Input
              type="text"
              value={planCode}
              onChange={e => setPlanCode(e.target.value)}
              placeholder="org_monthly"
              disabled={isEdit}
            />
            {isEdit
              ? <p className="text-[10px] text-muted-foreground mt-1">Код — стабильный идентификатор, менять нельзя. Для смены создайте новый план.</p>
              : <p className="text-[10px] text-muted-foreground mt-1">Латиница в нижнем регистре, цифры, «_». Напр. <code>org_monthly</code>.</p>}
          </div>

          <div>
            <Label className="text-sm">Название</Label>
            <Input type="text" value={title} onChange={e => setTitle(e.target.value)} placeholder="Год" />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-sm">Срок</Label>
              <Select value={billingPeriod} onValueChange={setBillingPeriod}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {PERIOD_OPTIONS.map(o => <SelectItem key={o.value} value={o.value}>{o.label}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div>
              <Label className="text-sm">Цена (₸)</Label>
              <Input type="number" value={priceAmount} onChange={e => setPriceAmount(e.target.value)} placeholder="52380" min={0} step="10" />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-sm">Trial (дней бесплатно)</Label>
              <Input type="number" value={trialDays} onChange={e => setTrialDays(e.target.value)} placeholder="30" min={0} max={365} />
            </div>
            <div>
              <Label className="text-sm">Уровень доступа</Label>
              <Select value={grantsTier} onValueChange={setGrantsTier}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  {TIER_OPTIONS.map(o => <SelectItem key={o.value} value={o.value}>{o.label}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div>
            <Label className="text-sm">Для типа хозяйства</Label>
            <Select value={orgType} onValueChange={setOrgType}>
              <SelectTrigger><SelectValue /></SelectTrigger>
              <SelectContent>
                {ORG_TYPE_OPTIONS.map(o => <SelectItem key={o.value} value={o.value}>{o.label}</SelectItem>)}
              </SelectContent>
            </Select>
            {orgType !== ORG_TYPE_ANY && (
              <p className="text-[10px] text-muted-foreground mt-1">План будет предлагаться только хозяйствам типа «{ORG_TYPE_LABEL[orgType]}».</p>
            )}
          </div>
        </div>

        <DialogFooter className="gap-2">
          {isEdit && (
            <Button
              variant="outline"
              onClick={() => { onToggleActive(item!); onClose() }}
              className="mr-auto gap-1.5"
            >
              {item!.is_active
                ? <><Archive className="h-3.5 w-3.5" /> Снять с публикации</>
                : <><RotateCcw className="h-3.5 w-3.5" /> Вернуть в витрину</>}
            </Button>
          )}
          <Button variant="outline" onClick={onClose}>Отмена</Button>
          <Button onClick={handleSave} disabled={upsert.isPending}>
            {upsert.isPending ? 'Сохранение…' : isEdit ? 'Сохранить' : 'Создать'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
