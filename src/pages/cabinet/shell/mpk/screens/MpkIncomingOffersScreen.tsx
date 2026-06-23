// AgOS · Слайс C · Входящие офферы МПК. Партии ферм без прямого матча, разосланные
// этому МПК (broadcast, FCFS, окно 24ч). Принять → rpc_self_accept_offer (партия в
// мою заявку, deal=мой бид ≥ ask). Отклонить → rpc_self_reject_offer.
// Личность фермера НЕ раскрыта до подтверждения сделки (D-M6-12). Без подталкивания (ст.171).

import { useState } from 'react'
import { ShellFrame } from '../../components/ShellFrame'
import { Cta } from '../../components/Cta'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { IncomingOffer } from '../types'

interface Props {
  offers: IncomingOffer[]
  onBack: () => void
  onAccept: (offerId: string) => Promise<void>
  onReject: (offerId: string) => Promise<void>
}

const CAT_RU: Record<string, string> = {
  bychki: 'Бычки',
  telki: 'Тёлки',
  korovy: 'Коровы',
  molodnyak: 'Молодняк',
}

function catLabel(o: IncomingOffer): string {
  const base = CAT_RU[o.cat] ?? 'Партия КРС'
  return o.breed ? `${base} · ${o.breed}` : base
}

// Часов до истечения окна ответа (FCFS).
function hoursLeft(expiresAt: Date): number {
  const ms = expiresAt.getTime() - Date.now()
  return ms > 0 ? Math.ceil(ms / 3_600_000) : 0
}

function OfferCard({ offer, onAccept, onReject }: {
  offer: IncomingOffer
  onAccept: (id: string) => Promise<void>
  onReject: (id: string) => Promise<void>
}) {
  const [sending, setSending] = useState(false)
  const tonnes = Math.round((offer.heads * offer.avgWeight) / 100) / 10
  const left = hoursLeft(offer.expiresAt)

  const accept = () => { setSending(true); onAccept(offer.id).catch(() => setSending(false)) }
  const reject = () => { setSending(true); onReject(offer.id).catch(() => setSending(false)) }

  return (
    <div className="mb-card" style={{ cursor: 'default' }}>
      <div className="mb-card-t">{catLabel(offer)}</div>
      <div className="mb-card-sub">{offer.region} · {offer.heads} гол. · ~{offer.avgWeight} кг</div>
      <div className="mb-card-sub">{tonnes} т живого веса · готовы {offer.windowLabel}</div>
      <div className="mb-card-price">Цена поставщика: {fmtMoney(offer.offeredPrice)}{NBSP}₸/кг</div>
      <div className="mpk-error-hint" style={{ color: 'var(--ink-3)' }}>
        {left > 0 ? `Осталось ответить: ~${left}${NBSP}ч` : 'Окно ответа истекает'}
      </div>
      <div className="mpk-error-hint" style={{ color: 'var(--ink-3)' }}>
        Личность поставщика раскроется при подтверждении сделки
      </div>
      <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
        <Cta onClick={accept} disabled={sending}>Принять</Cta>
        <Cta variant="ghost" onClick={reject} disabled={sending}>Отклонить</Cta>
      </div>
    </div>
  )
}

export function MpkIncomingOffersScreen({ offers, onBack, onAccept, onReject }: Props) {
  return (
    <ShellFrame noTabs label="МПК · Входящие офферы">
      <div className="mpk-head">
        <button className="mpk-back" onClick={onBack} aria-label="Назад">←</button>
        <div className="mpk-title">Входящие офферы</div>
        <span style={{ width: 40 }} />
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: '12px 14px' }}>
        {offers.length === 0 ? (
          <div className="mpk-lock" style={{ border: 'none' }}>
            <div className="mpk-lock-t">Нет входящих офферов</div>
            <div className="mpk-lock-s">
              Когда подходящая партия не найдёт прямого матча, поставщик пришлёт предложение — оно появится здесь.
            </div>
          </div>
        ) : (
          <>
            <div className="mpk-field-label" style={{ margin: 0 }}>
              <span className="mb-live-dot" />Предложения от поставщиков · {offers.length}
            </div>
            {offers.map((o) => (
              <OfferCard key={o.id} offer={o} onAccept={onAccept} onReject={onReject} />
            ))}
          </>
        )}
      </div>
    </ShellFrame>
  )
}
