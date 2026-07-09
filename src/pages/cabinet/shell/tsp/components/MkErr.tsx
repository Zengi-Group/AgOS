// AgOS · TSP-1 · Строка ошибки поля модуля «Рынок» (порт market-ui.jsx MkErr) — .mk-err.

import type { ReactNode } from 'react'

export function MkErr({ children, amber }: { children: ReactNode; amber?: boolean }) {
  return <div className={'mk-err' + (amber ? ' amber' : '')}>{children}</div>
}
