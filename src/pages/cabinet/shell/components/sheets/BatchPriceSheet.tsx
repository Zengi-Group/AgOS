// AgOS · TSP-2 · Шторка «Изменить цену» для существующего батча (не путать с PriceSheet).

import { useEffect, useState } from 'react'
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

  // ARS-755 (ревью якоря 7): шторка остаётся смонтированной между открытиями, и раньше
  // это было безобидно — запись цены была no-op. Теперь она пишет по-настоящему, поэтому
  // оставленное с прошлого раза число — заряженная кнопка «Сохранить цену».
  useEffect(() => { if (open) setVal('') }, [open])
  const prot = protPrice(batch)
  const num = parseInt(val, 10)
  const belowProt = prot != null && !Number.isNaN(num) && num < prot
  // ARS-755 FR-002/M-012: те же правила, что в точке решения — верхней границы нет,
  // жёсткой нижней нет. Ниже защитной предупреждаем (FR-003), но назначить разрешаем.
  const valid = !Number.isNaN(num) && num > 0

  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">Изменить цену</div>
      <div className="sh-b">Текущая цена: {fmtMoney(batch.price ?? 0)}{NBSP}₸/кг</div>
      {/* ARS-755 FR-004: правило названо словами до нажатия. */}
      <div className="dec-actions-note">Цену назначаете вы — можно поднять, снизить или оставить прежней.</div>
      <input
        className="dec-price-input"
        type="text"
        inputMode="numeric"
        value={val}
        placeholder="Новая цена ₸/кг"
        // ARS-755 (ревью якоря 7): фильтр цифр — как в `DecisionActions`. Без него
        // parseInt('12abc') = 12 уходило бы в БД настоящей ценой. Верхней границы ввода
        // нет (FR-002) — ни по значению, ни по длине.
        onChange={(e) => setVal(e.target.value.replace(/\D/g, ''))}
        style={{ margin: '10px 0' }}
      />
      {prot != null && (
        <div className="dec-actions-note">Защитная цена: {fmtMoney(prot)}{NBSP}₸/кг</div>
      )}
      {belowProt && (
        <div className="bat-warn-note" style={{ marginTop: 6 }}>Ниже защитного уровня — назначить можно, цена запишется как введена</div>
      )}
      <Cta onClick={() => valid && onConfirm(num)} disabled={!valid}>Сохранить цену</Cta>
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
