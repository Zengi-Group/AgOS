// AgOS · ARS-207 · Шторка подписки на членство ассоциации (заменяет разовый взнос
// PayVznosSheet, решение CEO 2026-07-15). Тарифы + текущий статус подписки + оформление/
// отмена. Данные и действия — через RPC биллинга (d13): rpc_list_membership_plans,
// rpc_get_org_subscription, rpc_subscribe_org_membership, rpc_cancel_org_membership.

import { useCallback, useEffect, useState } from 'react'
import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { NBSP } from '../../store'
import { supabase } from '@/lib/supabase'

interface Plan {
  plan_code: string
  title: string
  billing_period: string
  price_amount: number
  currency: string
  trial_days: number
}

interface Sub {
  plan_code: string
  state: string
  trial_end: string | null
  current_period_end: string | null
  next_billing_at: string | null
  cancel_at_period_end: boolean
  plan_title: string | null
  plan_price: number | null
}

interface Props {
  open?: boolean
  orgId: string | null | undefined
  onClose: () => void
  onSubscribed: () => void          // родитель ставит membership='active' + тост
  toast: (text: string) => void
}

// '12 months' → 'год' и т.п. — краткая подпись периода для карточки плана.
const periodLabel = (p: string): string =>
  p === '1 month' ? 'в месяц' : p === '3 months' ? 'за 3 месяца' : p === '12 months' ? 'за год' : p

const fmtPrice = (n: number): string => Math.round(n).toLocaleString('ru-RU').replace(/ /g, NBSP)
const fmtDate = (iso: string | null): string =>
  iso ? new Date(iso).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' }) : '—'

const STATE_LABEL: Record<string, string> = {
  trialing: 'Пробный период',
  active: 'Активна',
  grace: 'Ожидает оплаты',
  past_due: 'Просрочена',
  expired: 'Истекла',
  canceled: 'Отменена',
}

export function SubscribeSheet({ open = true, orgId, onClose, onSubscribed, toast }: Props) {
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [plans, setPlans] = useState<Plan[]>([])
  const [sub, setSub] = useState<Sub | null>(null)
  const [selected, setSelected] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!orgId) { setLoading(false); return }
    setLoading(true)
    const [plansRes, subRes] = await Promise.all([
      // ARS-265: pass org id so the server filters the catalog by org type
      // (applies_org_type). orgId is non-null here (early return above).
      supabase.rpc('rpc_list_membership_plans', { p_organization_id: orgId }),
      supabase.rpc('rpc_get_org_subscription', { p_organization_id: orgId }),
    ])
    const loadedPlans = (plansRes.data as Plan[] | null) ?? []
    setPlans(loadedPlans)
    setSub((subRes.data as Sub | null) ?? null)
    // По умолчанию выбираем годовой план (лучшая цена), иначе первый.
    setSelected((cur) =>
      cur ?? loadedPlans.find((p) => p.billing_period === '12 months')?.plan_code ?? loadedPlans[0]?.plan_code ?? null)
    setLoading(false)
  }, [orgId])

  useEffect(() => { if (open) { setSelected(null); load() } }, [open, load])

  const doSubscribe = async () => {
    if (!orgId || !selected || busy) return
    setBusy(true)
    const { error } = await supabase.rpc('rpc_subscribe_org_membership', {
      p_organization_id: orgId,
      p_plan_code: selected,
    })
    setBusy(false)
    if (error) { toast('Не удалось оформить: ' + error.message); return }
    onSubscribed()
  }

  const doCancel = async () => {
    if (!orgId || busy) return
    setBusy(true)
    const { error } = await supabase.rpc('rpc_cancel_org_membership', {
      p_organization_id: orgId,
      p_immediate: false,
    })
    setBusy(false)
    if (error) { toast('Не удалось отменить: ' + error.message); return }
    toast('Подписка будет отменена в конце оплаченного периода')
    load()
  }

  // --- Нет организации: членство требует юр. хозяйства ---
  const renderNoOrg = () => (
    <>
      <div className="sh-t">Членство в ассоциации</div>
      <div className="sh-b">Чтобы оформить подписку, сначала завершите регистрацию хозяйства (БИН).</div>
      <Cta variant="ghost" onClick={onClose}>Закрыть</Cta>
    </>
  )

  // --- Активная/действующая подписка: статус + отмена ---
  const renderStatus = (s: Sub) => {
    const stateText = STATE_LABEL[s.state] ?? s.state
    const dateLine =
      s.state === 'trialing' ? `Пробный период до ${fmtDate(s.trial_end)}`
      : s.cancel_at_period_end ? `Доступ до ${fmtDate(s.current_period_end)} · продление отключено`
      : `Следующее продление ${fmtDate(s.next_billing_at)}`
    return (
      <>
        <div className="sh-t">Ваша подписка</div>
        <div className="win-sum" style={{ marginTop: 2 }}>
          <div className="ws-hint mono">{stateText.toUpperCase()}</div>
          <div className="ws-big" style={{ fontSize: 20 }}>{s.plan_title ?? s.plan_code}</div>
        </div>
        <div className="sh-b" style={{ marginTop: 10 }}>{dateLine}</div>
        {!s.cancel_at_period_end && s.state !== 'canceled' && (
          <Cta variant="danger" onClick={doCancel} disabled={busy}>Отменить подписку</Cta>
        )}
        <Cta variant="ghost" onClick={onClose}>Закрыть</Cta>
      </>
    )
  }

  // --- Нет подписки: выбор тарифа ---
  const renderPlans = () => {
    const sel = plans.find((p) => p.plan_code === selected)
    const trialDays = sel?.trial_days ?? 0
    return (
      <>
        <div className="sh-t">Членство в ассоциации</div>
        <div className="sh-b">Доступ к Рынку&nbsp;(TSP), справочным ценам и сообществу. Первый период бесплатно, дальше — автоматическое продление. Отменить можно в любой момент.</div>
        <div className="blk-h mono" style={{ margin: '12px 0 6px' }}>ТАРИФ</div>
        <div className="stack8">
          {plans.map((p) => (
            <button
              key={p.plan_code}
              className={'big-radio' + (selected === p.plan_code ? ' sel' : '')}
              onClick={() => setSelected(p.plan_code)}
            >
              <span className={'br-dot' + (selected === p.plan_code ? ' on' : '')} />
              <span>
                <span className="br-t">{p.title} · {fmtPrice(p.price_amount)}{NBSP}₸</span>
                <span className="br-s">{periodLabel(p.billing_period)}</span>
              </span>
            </button>
          ))}
        </div>
        <Cta variant="primary-green" onClick={doSubscribe} disabled={busy || !selected}>
          {trialDays > 0 ? `Оформить · ${trialDays} дней бесплатно` : 'Оформить'}
        </Cta>
        <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
      </>
    )
  }

  return (
    <Sheet open={open} onClose={onClose}>
      {loading ? (
        <div className="sh-b" style={{ padding: '18px 0', textAlign: 'center' }}>Загрузка…</div>
      ) : !orgId ? renderNoOrg()
      : sub ? renderStatus(sub)
      : renderPlans()}
    </Sheet>
  )
}
