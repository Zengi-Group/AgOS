// AgOS · Универсальная шапка вкладок (Рынок / Ферма / Сообщения) — крупный заголовок
// раздела + кнопка кабинета справа. НЕ ask-бар Главной (тот только на Главной).
// Sticky, сплошной фон (без backdrop-blur → без артефактов при нативном переходе).

import type { ReactNode } from 'react'
import { AccountBtn } from './AccountBtn'

export function TabHead({ title, right }: { title: string; right?: ReactNode }) {
  return (
    <div className="tab-head" data-screen-label={'шапка ' + title}>
      <h1 className="tab-head-t">{title}</h1>
      {right ?? <AccountBtn />}
    </div>
  )
}
