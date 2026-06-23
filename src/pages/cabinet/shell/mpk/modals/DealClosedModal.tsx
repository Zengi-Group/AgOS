// AgOS · TSP-3 · Завершение прямой сделки с маркет-борда.
// Фермер согласился → контакты раскрыты (D40) → итог сделки + оценка фермера.

import { useState } from 'react'
import { Cta } from '../../components/Cta'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { PendingDeal } from '../types'

interface Props {
  deal: PendingDeal
  onClose: () => void
  toast: (text: string) => void
}

function StarPicker({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <div style={{ display: 'flex', gap: 4 }}>
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          onClick={() => onChange(n)}
          style={{ fontSize: 24, color: n <= value ? 'var(--amber)' : 'var(--line)', background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}
          aria-label={`Оценка ${n}`}
        >
          ★
        </button>
      ))}
    </div>
  )
}

export function DealClosedModal({ deal, onClose, toast }: Props) {
  const [rating, setRating] = useState(0)
  const [comment, setComment] = useState('')

  const liveWeight = Math.round((deal.heads * deal.avgWeight) / 100) / 10  // тонны
  const total = deal.heads * deal.avgWeight * deal.price                    // ₸

  const finish = () => {
    if (rating > 0) toast('Оценка фермера отправлена')
    else toast('Сделка завершена')
    onClose()
  }

  return (
    <div className="mpk-modal">
      <div className="mpk-modal-head">
        <div className="mpk-modal-title">Сделка состоялась</div>
        <button className="mpk-modal-close" onClick={onClose} aria-label="Закрыть">×</button>
      </div>

      <div className="mpk-modal-body">
        <div className="mpk-banner ok">
          <div className="mpk-banner-t">Фермер принял предложение</div>
          <div className="mpk-banner-s">Контакты раскрыты после подтверждения сделки.</div>
        </div>

        <div className="supplier-row">
          <div className="supplier-row-t"><span>Ферма</span><span>{deal.farm}</span></div>
          <div className="supplier-row-s">{deal.catName} · {deal.region}</div>
          <div className="supplier-row-s">{deal.heads} гол · ~{deal.avgWeight} кг · {liveWeight} т живого веса</div>
          <div className="supplier-row-s">Цена: {fmtMoney(deal.price)}{NBSP}₸/кг</div>
          <div className="supplier-row-t" style={{ marginTop: 4 }}>
            <span>Итого</span><span>{fmtMoney(total)}{NBSP}₸</span>
          </div>
        </div>

        <div>
          <div className="mpk-field-label">Оцените фермера</div>
          <StarPicker value={rating} onChange={setRating} />
        </div>

        <div>
          <div className="mpk-field-label">Комментарий (необязательно)</div>
          <textarea
            className="mpk-input"
            rows={3}
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            placeholder="Качество скота, дисциплина поставки…"
            style={{ resize: 'none' }}
          />
        </div>

        <Cta onClick={finish}>Отправить оценку</Cta>
        <Cta variant="ghost" onClick={onClose}>Пропустить</Cta>
      </div>
    </div>
  )
}
