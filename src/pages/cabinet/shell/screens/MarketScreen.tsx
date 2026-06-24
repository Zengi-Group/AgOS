// AgOS · TSP-1 · Экран таба «Рынок» — точка входа в визард «Новая партия» (shell/market.jsx MarketScreen).
// Гейт для не-членов; для членов — кнопка «+ Продать партию» и список активных партий.

import type { Batch, MembershipStatus, Route } from '../types'
import { gated } from '../store'
import { ACTIVE_STATES, catName } from '../data/batches'
import { fmtMoney } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import { ShellFrame } from '../components/ShellFrame'
import { ShellHead } from '../components/ShellHead'
import { SkeletonBlocks } from '../components/SkeletonBlocks'

// тизер-гейт «Продаю» (shell/market.jsx SellGate)
function SellGate({ membership, onApply }: { membership: MembershipStatus; onApply: () => void }) {
  const note = membership === 'pending'
    ? 'Заявка на рассмотрении. Ответим в течение 3 рабочих дней.'
    : membership === 'rejected' ? 'Заявка отклонена: нужна выписка о регистрации хозяйства.' : null
  return (
    <div className="sell-gate">
      <div className="sg-t">Продажа партий — для членов ассоциации TURAN</div>
      <div className="gate-list">
        {['Покупатели-комбинаты без посредников', 'Справочные цены по категориям', 'Защита сделки ассоциацией'].map((t) => (
          <div className="gate-row" key={t}><span className="gate-ck">✓</span>{t}</div>
        ))}
      </div>
      {note
        ? <div className="sg-note">{note}{membership === 'rejected' && <button className="ws-btn" style={{ marginTop: 8 }} onClick={onApply}>Подать заново</button>}</div>
        : <button className="ws-btn" onClick={onApply}>Подать заявку на вступление</button>}
    </div>
  )
}

// Плашка оформления членства: заявка одобрена, но взнос не оплачен (TSP-вход в оплату).
function ApprovedPlate({ onPay }: { onPay: () => void }) {
  return (
    <div className="sell-gate">
      <div className="sg-t">Заявка одобрена — оформите членство</div>
      <div className="sg-note" style={{ marginBottom: 8 }}>
        Ассоциация одобрила вашу заявку. Оплатите членский взнос, чтобы оформить членство и открыть продажу партий.
      </div>
      <button className="ws-btn" onClick={onPay}>Оплатить взнос</button>
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
}

export function MarketScreen({ membership, batches, loading, onNew, onApply, onPay, go }: Props) {
  const isGate = gated(membership)
  const expired = membership === 'expired'
  const active = batches
    .filter((b) => ACTIVE_STATES.includes(b.state) || b.state === 'draft')
    .sort((a, b2) => (a.state === 'decision' ? -1 : 0) - (b2.state === 'decision' ? -1 : 0))

  return (
    <ShellFrame label={'Рынок · ' + membership}>
      <ShellHead big title="Рынок" sub="продажа скота" />
      {loading ? <SkeletonBlocks n={4} /> : (
        <div className="home-stack">
          {isGate ? (
            <SellGate membership={membership} onApply={onApply} />
          ) : membership === 'approved' ? (
            // Заявка одобрена, но взнос не оплачен → Рынок (TSP) заблокирован до оплаты:
            // показываем только плашку оформления членства, без кнопки продажи и списка.
            <ApprovedPlate onPay={onPay} />
          ) : (
            <div className="stack8">
              {!expired && <button className="mkt-sell-btn" onClick={onNew}>+ Продать партию</button>}
              {expired && (
                <div className="sg-note">Членство истекло. Текущие сделки можно довести до конца, новые партии — после оплаты.</div>
              )}
              {active.length === 0 ? (
                !expired && (
                  <div className="work-start">
                    <div className="ws-t">Выставьте первую партию</div>
                    <div className="ws-s">Опишите животных — покупателя найдёт TURAN.</div>
                  </div>
                )
              ) : (
                <>
                  {active.slice(0, 4).map((b) => (
                    <button key={b.id} className="obs-card" onClick={() => go({ name: 'batch', batchId: b.id })}>
                      <span className="obs-tx">
                        <span className="obs-t">{catName(b)} · {b.heads} голов</span>
                        <span className="obs-s mono">{fmtMoney((b.price ?? 0))}{NBSP}₸/кг</span>
                      </span>
                    </button>
                  ))}
                  <button className="mkt-all-link" onClick={() => go({ name: 'p1list' })}>Все партии ({batches.length}) →</button>
                </>
              )}
            </div>
          )}
        </div>
      )}
    </ShellFrame>
  )
}
