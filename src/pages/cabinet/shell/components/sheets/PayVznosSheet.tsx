// AgOS · Этап 1 · Шторка оплаты членского взноса (shell/app.jsx kind="payvznos").
// Тексты — слово в слово из прототипа.

import { useState } from 'react'
import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { NBSP } from '../../store'
import type { MembershipStatus } from '../../types'

const METHODS: [string, string][] = [
  ['Kaspi Pay', 'быстрая оплата через Kaspi'],
  ['Банковская карта', 'Visa, Mastercard'],
  ['Счёт на оплату', 'для юр. лиц'],
]

interface Props {
  membership: MembershipStatus
  onClose: () => void
  onDone: () => void
}

export function PayVznosSheet({ membership, onClose, onDone }: Props) {
  const renewal = ['active', 'expiring', 'grace', 'expired'].includes(membership)
  // Выбор способа оплаты (по умолчанию первый). Оплата — мок на пилоте: выбор способа →
  // «Оплатить» → onDone (членство активируется, Рынок открывается). Реальной платёжной
  // системы пока нет, поэтому клик по способу только выбирает, а оплачивает кнопка снизу.
  const [selected, setSelected] = useState(0)
  return (
    <Sheet open onClose={onClose}>
      <div className="sh-t">{renewal ? 'Продление членства' : 'Членский взнос'}</div>
      <div className="sh-b">Доступ к Рынку (TSP), справочным ценам и сообществу ассоциации на 12 месяцев.</div>
      <div className="win-sum" style={{ marginTop: 2 }}>
        <div className="ws-hint mono">К ОПЛАТЕ · ЧЛЕНСТВО НА ГОД</div>
        <div className="ws-big" style={{ fontSize: 22 }}>120 000{NBSP}₸</div>
      </div>
      <div className="blk-h mono" style={{ margin: '12px 0 6px' }}>СПОСОБ ОПЛАТЫ</div>
      <div className="stack8">
        {METHODS.map((m, i) => (
          <button
            key={m[0]}
            className={'big-radio' + (selected === i ? ' sel' : '')}
            onClick={() => setSelected(i)}
          >
            <span className={'br-dot' + (selected === i ? ' on' : '')} />
            <span><span className="br-t">{m[0]}</span><span className="br-s">{m[1]}</span></span>
          </button>
        ))}
      </div>
      <Cta variant="primary-green" onClick={onDone}>Оплатить 120 000{NBSP}₸</Cta>
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
