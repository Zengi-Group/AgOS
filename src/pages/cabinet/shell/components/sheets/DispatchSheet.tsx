// AgOS · TSP-2 · Шторка «Подтвердите отгрузку».

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { catLabel } from '../../data/status'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { Batch } from '../../types'

interface Props {
  batch: Batch
  open: boolean
  onClose: () => void
  onConfirm: () => void
}

export function DispatchSheet({ batch, open, onClose, onConfirm }: Props) {
  const price = batch.dealPrice ?? batch.price ?? 0
  // Слайс 9 S3: отгружаем только готовые (confirmed) куски. Если батч дроблёный —
  // показываем именно их сумму голов, а не всю партию (остаток ещё продаётся).
  const allocs = Array.isArray(batch.allocations) ? batch.allocations : []
  const readyHeads = allocs.filter((a) => a.status === 'confirmed').reduce((s, a) => s + a.heads, 0)
  const dispHeads = readyHeads > 0 ? readyHeads : batch.heads
  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">Подтвердите отгрузку</div>
      <div className="sh-b">Покупатель получит уведомление.</div>
      <div className="bat-price-sum" style={{ marginBottom: 10 }}>
        {catLabel(batch)} · {dispHeads} гол.<br />
        Цена сделки: {fmtMoney(price)}{NBSP}₸/кг
      </div>
      <Cta onClick={onConfirm}>Подтвердить отгрузку</Cta>
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
