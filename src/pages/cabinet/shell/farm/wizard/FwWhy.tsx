// AgOS · ARS-212 · Строка «зачем спрашиваем» под каждым вопросом яруса «План» (дизайн-ход #2,
// Dok6 Slice7 §2): критерий F-D14 «каждый вопрос виден в результате» → видимый элемент UI.
// Иконка info (Phosphor, §7). Класс .fw-why — из токенов палитры (market-proto.css).

import type { ReactNode } from 'react'
import { PhIcon } from '../../components/icons/PhIcon'

export function FwWhy({ children }: { children: ReactNode }) {
  return (
    <div className="fw-why">
      <PhIcon name="info" size={15} />
      <span>{children}</span>
    </div>
  )
}
