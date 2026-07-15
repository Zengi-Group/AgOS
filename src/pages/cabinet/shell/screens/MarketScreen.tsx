// AgOS · TSP-1 · Экран таба «Рынок» — полный список «Мои партии» (порт прототипа
// market.jsx MarketScreen + BatchCard + StatusChip). Гейт для не-членов; для членов —
// табы (Все/В работе/Завершённые), группы (Требуют решения / В работе / Завершённые),
// док-футер «Продать». Логика членства/гейта и все пропсы сохранены (реcкин, не ре-логика).

import { useState } from 'react'
import type { Batch, MembershipStatus, Route } from '../types'
import { gated } from '../store'
import { DONE_STATES_SET } from '../data/status'
import { IonShellFrame } from '../components/IonShellFrame'
import { TabHead } from '../components/TabHead'
import { PhIcon } from '../components/icons/PhIcon'
import { BatchCard } from '../components/BatchListCard'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import { DemandBoard } from '../components/DemandBoard'

// тизер-гейт «Продаю» (shell/market.jsx SellGate) — для не-членов; вне прототипа, стиль сохранён
function SellGate({ membership, onApply }: { membership: MembershipStatus; onApply: () => void }) {
  const note = membership === 'pending'
    ? 'Заявка на рассмотрении. Ответим в течение 3 рабочих дней.'
    : membership === 'rejected' ? 'Заявка отклонена: нужна выписка о регистрации хозяйства.' : null
  return (
    <div className="mk-offer">
      <div className="mk-empty-art"><PhIcon name="market" size={46} /></div>
      <div className="mk-offer-h">Продажа партий — для членов ассоциации TURAN</div>
      <div className="mk-offer-list">
        {['Покупатели-комбинаты без посредников', 'Справочные цены по категориям', 'Защита сделки ассоциацией'].map((t) => (
          <div className="mk-offer-row" key={t}><span className="mk-offer-ck"><PhIcon name="check" size={15} color="var(--green)" /></span>{t}</div>
        ))}
      </div>
      {note
        ? <div className="sg-note">{note}{membership === 'rejected' && <button className="mk-cta primary" style={{ marginTop: 10 }} onClick={onApply}>Подать заново</button>}</div>
        : <button className="mk-cta primary" onClick={onApply}>Подать заявку на вступление</button>}
    </div>
  )
}

// Плашка оформления членства: заявка одобрена, но взнос не оплачен (TSP-вход в оплату).
function ApprovedPlate({ onPay }: { onPay: () => void }) {
  return (
    <div className="sell-gate">
      <div className="sg-t">Заявка одобрена — оформите членство</div>
      <div className="sg-note" style={{ marginBottom: 10 }}>
        Ассоциация одобрила вашу заявку. Оплатите членский взнос, чтобы оформить членство и открыть продажу партий.
      </div>
      <button className="mk-cta primary" onClick={onPay}>Оплатить взнос</button>
    </div>
  )
}

interface Props {
  membership: MembershipStatus
  batches: Batch[]
  loading: boolean
  onNew: () => void
  onApply: () => void
  onPay: () => void
  go: (r: Route) => void
  onRefresh?: () => Promise<unknown>   // S2: pull-to-refresh (spec §7)
  orgId?: string | null                // ARS-229: доска спроса МПК (обезличенный агрегат)
}

export function MarketScreen({ membership, batches, loading, onNew, onApply, onPay, go, onRefresh, orgId }: Props) {
  const isGate = gated(membership)
  const approved = membership === 'approved'
  const expired = membership === 'expired'
  const grace = membership === 'grace' || expired
  const [tab, setTab] = useState<'all' | 'active' | 'done'>('all')

  const nAll = batches.length
  const nActive = batches.filter((b) => !DONE_STATES_SET.has(b.state)).length
  const nDone = nAll - nActive
  const visible = batches.filter((b) => tab === 'all' ? true : tab === 'active' ? !DONE_STATES_SET.has(b.state) : DONE_STATES_SET.has(b.state))
  const dec = visible.filter((b) => b.state === 'decision')
  const act = visible.filter((b) => b.state !== 'decision' && !DONE_STATES_SET.has(b.state))
  const fin = visible.filter((b) => DONE_STATES_SET.has(b.state))

  const openBatch = (b: Batch) => go({ name: 'batch', batchId: b.id, back: { name: 'market' } })
  const showList = !isGate && !approved
  const canSell = showList && !expired   // gating: expired ведёт текущие сделки, но не создаёт новые
  const footer = canSell && nAll > 0
    ? <button className="mk-cta primary" style={{ margin: 0 }} onClick={onNew}><PhIcon name="plus" size={16} />Продать</button>
    : undefined

  const group = (title: string, items: Batch[], urgent: boolean) => items.length > 0 && (
    <div className={'mk-grp' + (urgent ? ' urgent' : '')} key={title}>
      <div className="tier-h mk-grp-h">
        <span className="tier-h-l"><span className={'tier-label' + (urgent ? ' urgent' : '')}>{title}</span></span>
      </div>
      <div className="mk-stack8">{items.map((b) => <BatchCard key={b.id} b={b} onOpen={() => openBatch(b)} />)}</div>
    </div>
  )

  return (
    <IonShellFrame label={'Рынок · ' + membership} footer={footer} footBare onRefresh={onRefresh}>
      <TabHead title="Рынок" />
      <div className="mk">
        {loading ? <ScreenSkeleton variant="market" /> : isGate ? (
          <SellGate membership={membership} onApply={onApply} />
        ) : approved ? (
          // Заявка одобрена, но взнос не оплачен → Рынок (TSP) заблокирован до оплаты.
          <ApprovedPlate onPay={onPay} />
        ) : (
          <>
            {grace && (
              <div className="mk-grace">
                <span className="badge"><i />{expired ? 'Членство истекло' : 'Льготный период'}</span>
                <div className="mk-grace-t">
                  {expired
                    ? 'Текущие сделки можно довести до конца. Для новых партий — продлите членский взнос.'
                    : 'Продажа доступна — продлите членство, чтобы не прерывать работу.'}
                </div>
                <button className="mk-grace-b" onClick={onPay}>Продлить членство</button>
              </div>
            )}

            <DemandBoard orgId={orgId} />

            {nAll > 0 && (
              <div className="mk-tabs">
                {([['all', 'Все', nAll], ['active', 'В работе', nActive], ['done', 'Завершённые', nDone]] as const).map(([k, t, n]) => (
                  <button key={k} className={'mk-tab' + (tab === k ? ' on' : '')} onClick={() => setTab(k)}>
                    <span className="mk-tab-t">{t}</span><span className="mk-tab-n mk-mono">{n}</span>
                  </button>
                ))}
              </div>
            )}

            {nAll === 0 ? (
              <div className="mk-empty">
                <div className="mk-empty-art"><PhIcon name="market" size={46} /></div>
                <div className="mk-empty-h">Пока нет ни одной партии</div>
                <div className="mk-empty-t">Создайте первую — на это уйдёт пара минут.</div>
                {canSell && <button className="mk-cta primary" onClick={onNew}>Новая партия</button>}
              </div>
            ) : visible.length === 0 ? (
              <div className="mk-empty"><div className="mk-empty-t">В этом фильтре партий нет.</div></div>
            ) : (
              <div className="mk-listgroups">
                {group('Требуют решения', dec, true)}
                {group('В работе', act, false)}
                {group('Завершённые', fin, false)}
              </div>
            )}
          </>
        )}
      </div>
    </IonShellFrame>
  )
}
