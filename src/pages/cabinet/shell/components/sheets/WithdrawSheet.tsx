// AgOS · TSP-2 · Слайс 9 (S1b) · Шторка «Снять с продажи?» с учётом дробления.
// Три режима:
//   • partial — часть продана: снять ТОЛЬКО остаток (безплатно) ИЛИ + отменить
//     проданные куски (за штраф). Подтверждённые куски снять нельзя (RLS/RPC).
//   • matched — покупатель найден, остатка нет: снятие = отмена проданного (штраф).
//   • default — ничего не продано: обычное снятие без последствий.
// onConfirm(includeMatched) — true = отменить и matched-куски (за штраф).

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
  const matchedHeads = typeof batch.matchedHeads === 'number' ? batch.matchedHeads : 0
  const total = typeof batch.heads === 'number' ? batch.heads : 0
  const remaining = typeof batch.remainingHeads === 'number'
    ? batch.remainingHeads
    : Math.max(total - matchedHeads, 0)

  return (
    <Sheet open={open} onClose={onClose}>
      {batch.state === 'partial' ? (
        <>
          <div className="sh-t">Снять с продажи?</div>
          <div className="sh-b">
            Продано {matchedHeads} из {total} гол.{remaining > 0 ? `, на рынке ещё ${remaining}.` : '.'}{' '}
            Можно снять только непроданный остаток — проданные куски останутся.
          </div>
          {remaining > 0 && (
            <Cta variant="danger" onClick={() => onConfirm(false)}>
              Снять остаток ({remaining} гол.)
            </Cta>
          )}
          <div className="sh-b" style={{ marginTop: 8 }}>
            ⚠ Отмена уже проданных кусков будет отмечена и повлияет на рейтинг.
            Подтверждённые сделки (пул заполнен) снять нельзя.
          </div>
          <Cta variant="danger" onClick={() => onConfirm(true)}>
            Снять остаток и отменить проданное
          </Cta>
          <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
        </>
      ) : batch.state === 'matched' ? (
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
