// AgOS · TSP-2 · SCR-08 «Отзыв о покупателе» — две оценки + комментарий (мок).

import { useState } from 'react'
import type { Batch } from '../types'
import { Cta } from '../components/Cta'
import { ShellFrame } from '../components/ShellFrame'
import { catLabel } from '../data/status'

interface Props {
  batch: Batch
  onBack: () => void
  onPatch: (patch: Partial<Batch>) => void
  toast: (text: string) => void
}

function StarPicker({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <div style={{ display: 'flex', gap: 6 }}>
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          onClick={() => onChange(n)}
          style={{ fontSize: 24, color: n <= value ? 'var(--amber)' : 'var(--line)', background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}
        >
          ★
        </button>
      ))}
    </div>
  )
}

export function ReviewScreen({ batch, onBack, onPatch, toast }: Props) {
  const [rating1, setRating1] = useState(0)
  const [rating2, setRating2] = useState(0)
  const [comment, setComment] = useState('')
  const canSubmit = rating1 > 0 && rating2 > 0

  const submit = () => {
    if (!canSubmit) return
    onPatch({ review: { r1: rating1, r2: rating2, comment, date: 'сегодня' } })
    toast('Отзыв сохранён · спасибо')
    onBack()
  }

  return (
    <ShellFrame noTabs label="Отзыв">
      <div className="rev-wrap">
        <div className="bat-back-row" style={{ padding: 0 }}>
        <button className="bat-back" onClick={onBack} aria-label="Назад">←</button>
      </div>

      <div>
        <div className="rev-head">Покупатель принял вашу партию</div>
        <div className="rev-sub">{catLabel(batch)} · {batch.heads} гол.</div>
      </div>

      <div>
        <div className="rev-section-label">Общая оценка</div>
        <StarPicker value={rating1} onChange={setRating1} />
      </div>

      <div>
        <div className="rev-section-label">Честность взвешивания</div>
        <StarPicker value={rating2} onChange={setRating2} />
      </div>

      <div>
        <div className="rev-section-label">Комментарий (необязательно)</div>
        <textarea
          className="rev-textarea"
          placeholder="Ваш опыт работы с покупателем..."
          value={comment}
          onChange={(e) => setComment(e.target.value)}
        />
      </div>

        <Cta onClick={submit} disabled={!canSubmit}>Отправить отзыв</Cta>
      </div>
    </ShellFrame>
  )
}
