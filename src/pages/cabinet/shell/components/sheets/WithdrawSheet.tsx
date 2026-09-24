// AgOS · TSP-2 · Слайс 9 (S1b) · Шторка «Снять с продажи?».
// Два режима:
//   • matched — покупатель найден: снятие = отмена проданного (штраф).
//   • default — ничего не продано: обычное снятие без последствий.
// onConfirm(includeMatched) — true = отменить matched-сделку (за штраф).
// ARS-754 (FR-008 ④): партия продаётся только целиком — режима «часть продана,
// снять остаток» больше нет, ветка `partial` убрана.

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import type { Batch } from '../../types'

interface Props {
  batch: Batch
  open: boolean
  onClose: () => void
  onConfirm: (includeMatched: boolean) => void
}

export function WithdrawSheet({ batch, open, onClose, onConfirm }: Props) {
  return (
    <Sheet open={open} onClose={onClose}>
      {batch.state === 'matched' ? (
        <>
          <div className="sh-t">Снять партию с продажи?</div>
          <div className="sh-b">
            ⚠ Покупатель уже найден. Отмена будет отмечена и повлияет на рейтинг.
            Если пул уже заполнен — снять нельзя, свяжитесь с TURAN.
          </div>
          <Cta variant="danger" onClick={() => onConfirm(true)}>Всё равно снять</Cta>
          <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
        </>
      ) : (
        <>
          <div className="sh-t">Снять с продажи?</div>
          <div className="sh-b">Партию можно выставить заново в любой момент.</div>
          <Cta variant="danger" onClick={() => onConfirm(false)}>Снять с продажи</Cta>
          <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
        </>
      )}
    </Sheet>
  )
}
