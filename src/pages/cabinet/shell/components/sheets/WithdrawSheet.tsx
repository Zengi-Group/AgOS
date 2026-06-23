// AgOS · TSP-2 · Шторка «Снять с продажи?» — отдельный текст для state=matched.

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import type { Batch } from '../../types'

interface Props {
  batch: Batch
  open: boolean
  onClose: () => void
  onConfirm: () => void
}

export function WithdrawSheet({ batch, open, onClose, onConfirm }: Props) {
  const matched = batch.state === 'matched'
  return (
    <Sheet open={open} onClose={onClose}>
      {matched ? (
        <>
          <div className="sh-t">Снять партию с продажи?</div>
          <div className="sh-b">
            ⚠ Покупатель уже найден — снятие может нарушить договорённость.
            Свяжитесь с поддержкой TURAN, если есть проблема с поставкой.
          </div>
          <Cta variant="danger" onClick={onConfirm}>Всё равно снять</Cta>
          <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
        </>
      ) : (
        <>
          <div className="sh-t">Снять с продажи?</div>
          <div className="sh-b">Партию можно выставить заново в любой момент.</div>
          <Cta variant="danger" onClick={onConfirm}>Снять с продажи</Cta>
          <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
        </>
      )}
    </Sheet>
  )
}
