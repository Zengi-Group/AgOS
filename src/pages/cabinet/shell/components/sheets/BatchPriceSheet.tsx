// AgOS · TSP-2 · Шторка «Изменить цену» для существующего батча (не путать с PriceSheet).

import { useState } from 'react'
import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { protPrice } from '../../data/status'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { Batch } from '../../types'

interface Props {
  batch: Batch
  open: boolean
  onClose: () => void
  onConfirm: (newPrice: number) => void
}

export function BatchPriceSheet({ batch, open, onClose, onConfirm }: Props) {
  const [val, setVal] = useState('')
  const prot = protPrice(batch)
  const num = parseInt(val, 10)
  const belowProt = prot != null && !Number.isNaN(num) && num < prot
  const valid = !Number.isNaN(num) && num > 0 && !belowProt

  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">Изменить цену</div>
      <div className="sh-b">Текущая цена: {fmtMoney(batch.price ?? 0)}{NBSP}₸/кг</div>
      <input
        className="dec-price-input"
        type="number"
        min={1}
        value={val}
        placeholder="Новая цена ₸/кг"
        onChange={(e) => setVal(e.target.value)}
        style={{ margin: '10px 0' }}
      />
      {prot != null && (
        <div className="dec-actions-note">Защитная цена: {fmtMoney(prot)}{NBSP}₸/кг</div>
      )}
      {belowProt && (
        <div className="bat-warn-note" style={{ marginTop: 6 }}>Ниже защитного уровня</div>
      )}
      <Cta onClick={() => valid && onConfirm(num)} disabled={!valid}>Сохранить цену</Cta>
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
