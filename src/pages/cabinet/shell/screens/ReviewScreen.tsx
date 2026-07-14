// AgOS · TSP-2 · SCR-08 «Отзыв о покупателе» — реcкин под прототип (market-wizard.jsx ReviewScreen):
// две оценки (Stars) + комментарий → onPatch({review}) → useBatches вызывает rpc_submit_review
// (контракт review = { r1, r2, comment }). Экран благодарности — .mk-res + пояснение перекрёстной оценки.

import { useState } from 'react'
import type { Batch } from '../types'
import { useShell } from '../context'
import { IonShellFrame } from '../components/IonShellFrame'
import { SubHead } from '../components/SubHead'
import { PhIcon } from '../components/icons/PhIcon'
import { catLabel } from '../data/status'
import { MkCta } from '../tsp/components/MkCta'
import { MkField } from '../tsp/components/MkField'
import { Stars } from '../tsp/components/Stars'
import { InfoNote } from '../tsp/components/InfoNote'

interface Props {
  batch: Batch
  onBack: () => void
  // S4=A · C4+D7: successToast показывается в CabinetApp.patchBatch ПОСЛЕ round-trip.
  onPatch: (patch: Partial<Batch>, successToast?: string) => void
}

export function ReviewScreen({ batch, onBack, onPatch }: Props) {
  const { offline, offlineToast } = useShell()
  const [rating1, setRating1] = useState(0)
  const [rating2, setRating2] = useState(0)
  const [comment, setComment] = useState('')
  const [sent, setSent] = useState(false)
  const canSubmit = rating1 > 0 && rating2 > 0

  // Этап 2 · D5: отзыв фиксируется в МОМЕНТ «Отправить» (rpc_submit_review через onPatch),
  // а не на «К партии». Раньше уход с экрана-спасибо back/свайпом терял отзыв, хотя экран
  // уже сказал «отправлен». Контракт review = {r1,r2,comment} — useBatches.
  const submit = () => {
    // S4=A · C4: офлайн — гейт ДО setSent, иначе экран скажет «отправлено» без сохранения.
    if (offline) { offlineToast(); return }
    onPatch({ review: { r1: rating1, r2: rating2, comment, date: 'сегодня' } }, 'Отзыв сохранён · спасибо')
    setSent(true)
  }

  if (sent) {
    return (
      <IonShellFrame noTabs label="Отзыв · отправлен" footer={<MkCta onClick={onBack}>К партии</MkCta>}>
        <SubHead onBack={onBack} backLabel="Партия" />
        <div className="mk">
          <div className="mk-res">
            <div className="mk-res-ic tone-green"><PhIcon name="checkCircle" size={30} /></div>
            <h1 className="mk-res-h">Спасибо! Ваш отзыв отправлен</h1>
            <div className="mk-res-b">
              <InfoNote title="Перекрёстная оценка">Отзыв покупателя о вас откроется, когда он оставит свой — или через 7 дней. Так отзывы остаются честными: никто не видит чужую оценку до своей.</InfoNote>
            </div>
          </div>
        </div>
      </IonShellFrame>
    )
  }

  return (
    <IonShellFrame noTabs label="Отзыв" footer={<MkCta disabled={!canSubmit} onClick={submit}>Отправить отзыв</MkCta>}>
      <SubHead onBack={onBack} backLabel="Партия" />
      <div className="mk mk-pt">
        <h1 className="mk-h1">Покупатель принял вашу партию</h1>
        <p className="mk-sub">{catLabel(batch)} · {batch.heads} гол.</p>
        <div className="mk-rev-q">
          <div className="mk-rev-k">Общая оценка</div>
          <Stars value={rating1} onChange={setRating1} size="lg" />
        </div>
        <div className="mk-rev-q">
          <div className="mk-rev-k">Честность взвешивания</div>
          <div className="mk-rev-sub">Совпал ли вес на приёмке с вашими ожиданиями, было ли взвешивание прозрачным</div>
          <Stars value={rating2} onChange={setRating2} size="lg" />
        </div>
        <MkField label="Подробнее (необязательно)">
          <textarea className="mk-input area" rows={3} value={comment} placeholder="Расскажите подробнее — что было хорошо, что нет" onChange={(e) => setComment(e.target.value)} />
        </MkField>
      </div>
    </IonShellFrame>
  )
}
