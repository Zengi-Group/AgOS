// AgOS · TSP-1 · Строка-чекбокс модуля «Рынок» (порт market-ui.jsx CheckRow) — .mk-cb.

import type { ReactNode } from 'react'
import { PhIcon } from '../../components/icons/PhIcon'

interface CheckRowProps {
  checked: boolean
  onClick: () => void
  children: ReactNode
  warn?: boolean
}

export function CheckRow({ checked, onClick, children, warn }: CheckRowProps) {
  return (
    <button className={'mk-cb' + (warn ? ' warn' : '')} onClick={onClick}>
      <span className={'mk-cb-box' + (checked ? ' ch' : '')}>
        {checked && <PhIcon name="check" size={12} color="#fff" />}
      </span>
      <span>{children}</span>
    </button>
  )
}
