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

// rpc_get_org_subscription отдаёт только живые состояния (trialing|active|grace|past_due);
// терминальные (expired/canceled) сюда не приходят, поэтому их лейблов нет (B10, ARS-261).
const STATE_LABEL: Record<string, string> = {
  trialing: 'Пробный период',
  active: 'Активна',
  grace: 'Ожидает оплаты',
  past_due: 'Просрочена',
}

export function SubscribeSheet({ open = true, orgId, onClose, onSubscribed, toast }: Props) {
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [plans, setPlans] = useState<Plan[]>([])
  const [sub, setSub] = useState<Sub | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [err, setErr] = useState(false)             // B5: ошибка загрузки каталога/подписки
  const [confirmCancel, setConfirmCancel] = useState(false) // B3: шаг подтверждения отмены

  const load = useCallback(async () => {
    if (!orgId) { setLoading(false); return }
    setLoading(true)
    setErr(false)
    const [plansRes, subRes] = await Promise.all([
      // ARS-265: pass org id so the server filters the catalog by org type
      // (applies_org_type). orgId is non-null here (early return above).
      supabase.rpc('rpc_list_membership_plans', { p_organization_id: orgId }),
      supabase.rpc('rpc_get_org_subscription', { p_organization_id: orgId }),
    ])
    // B5 (ARS-261): раньше ошибки RPC глотались → фермер видел пустой список. Теперь —
    // явный экран ошибки с «Повторить».
    if (plansRes.error || subRes.error) { setErr(true); setLoading(false); return }
    const loadedPlans = (plansRes.data as Plan[] | null) ?? []
    setPlans(loadedPlans)
    setSub((subRes.data as Sub | null) ?? null)
    // По умолчанию выбираем годовой план (лучшая цена), иначе первый.
    setSelected((cur) =>
      cur ?? loadedPlans.find((p) => p.billing_period === '12 months')?.plan_code ?? loadedPlans[0]?.plan_code ?? null)
    setLoading(false)
  }, [orgId])

  useEffect(() => { if (open) { setSelected(null); setConfirmCancel(false); load() } }, [open, load])

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
    setConfirmCancel(false)
    toast('Подписка будет отменена в конце оплаченного периода')
    load()
  }

  // B3 (ARS-261): возобновление до конца оплаченного периода — снимает cancel_at_period_end.
  // Self-serve RPC (грант authenticated, guard member-or-admin; d13 ARS-267).
  const doResume = async () => {
    if (!orgId || busy) return
    setBusy(true)
    const { error } = await supabase.rpc('rpc_resume_org_membership', {
      p_organization_id: orgId,
    })
    setBusy(false)
    if (error) { toast('Не удалось возобновить: ' + error.message); return }
    toast('Подписка возобновлена — продление снова включено')
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

  // --- Активная/действующая подписка: статус + отмена/возобновление ---
  const renderStatus = (s: Sub) => {
    // B3 (ARS-261): отмена — через отдельный шаг подтверждения, а не один тап.
    if (confirmCancel) {
      return (
        <>
          <div className="sh-t">Отменить подписку?</div>
          <div className="sh-b" style={{ marginTop: 6 }}>
            Продление отключится. Доступ к Рынку и справочным ценам сохранится до конца оплаченного периода — {fmtDate(s.current_period_end)}.
          </div>
          <Cta variant="danger" onClick={doCancel} disabled={busy}>Да, отключить продление</Cta>
          <Cta variant="ghost" onClick={() => setConfirmCancel(false)}>Оставить подписку</Cta>
        </>
      )
    }
    const stateText = STATE_LABEL[s.state] ?? s.state
    const dateLine =
      s.state === 'trialing' ? `Пробный период до ${fmtDate(s.trial_end)}`
      : s.cancel_at_period_end ? `Доступ до ${fmtDate(s.current_period_end)} · продление отключено`
      : `Следующее продление ${fmtDate(s.next_billing_at)}`
    return (
      <>
        <div className="sh-t">Ваша подписка</div>
        <div className="win-sum" style={{ marginTop: 2 }}>
          <div className="ws-hint">{stateText.toUpperCase()}</div>
          <div className="ws-big" style={{ fontSize: 20 }}>{s.plan_title ?? s.plan_code}</div>
        </div>
        <div className="sh-b" style={{ marginTop: 10 }}>{dateLine}</div>
        {s.cancel_at_period_end ? (
          // B3: продление отключено — предлагаем вернуть подписку до конца периода.
          <Cta variant="primary-green" onClick={doResume} disabled={busy}>Возобновить подписку</Cta>
        ) : (
          <Cta variant="danger" onClick={() => setConfirmCancel(true)} disabled={busy}>Отменить подписку</Cta>
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
        <div className="blk-h" style={{ margin: '12px 0 6px' }}>ТАРИФ</div>
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
        {/* Ст.171 ПК РК: тариф членства устанавливает ассоциация; участие добровольное. */}
        <div className="mk-ref-d">Членство и участие в ассоциации — добровольные. Тарифы устанавливает TURAN; подписку можно отменить в любой момент (ст. 171 ПК РК).</div>
        <Cta variant="primary-green" onClick={doSubscribe} disabled={busy || !selected}>
          {trialDays > 0 ? `Оформить · ${trialDays} дней бесплатно` : 'Оформить'}
        </Cta>
        <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
      </>
    )
  }

  // --- B5: ошибка загрузки — сообщение + повтор, а не пустой список ---
  const renderError = () => (
    <>
      <div className="sh-t">Не удалось загрузить</div>
      <div className="sh-b">Проверьте соединение и попробуйте ещё раз.</div>
      <Cta variant="primary-green" onClick={load}>Повторить</Cta>
      <Cta variant="ghost" onClick={onClose}>Закрыть</Cta>
    </>
  )

  // --- B5: пустой каталог (все планы retired) — не показываем пустой список ---
  const renderEmpty = () => (
    <>
      <div className="sh-t">Тарифы недоступны</div>
      <div className="sh-b">Сейчас нет доступных тарифов членства. Обратитесь в TURAN или попробуйте позже.</div>
      <Cta variant="primary-green" onClick={load}>Обновить</Cta>
      <Cta variant="ghost" onClick={onClose}>Закрыть</Cta>
    </>
  )

  return (
    <Sheet open={open} onClose={onClose}>
      {loading ? (
        <div className="sh-b" style={{ padding: '18px 0', textAlign: 'center' }}>Загрузка…</div>
      ) : !orgId ? renderNoOrg()
      : err ? renderError()
      : sub ? renderStatus(sub)
      : plans.length === 0 ? renderEmpty()
      : renderPlans()}
    </Sheet>
  )
}
