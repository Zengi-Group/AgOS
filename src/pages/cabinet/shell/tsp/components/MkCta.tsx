// AgOS · TSP-1 · Кнопка действия модуля «Рынок» (порт market-ui.jsx MkCta) — .mk-cta.

import type { ReactNode } from 'react'

interface MkCtaProps {
  children: ReactNode
  onClick?: () => void
  variant?: 'primary' | 'ghost'
  disabled?: boolean
}

export function MkCta({ children, onClick, variant = 'primary', disabled }: MkCtaProps) {
  return (
    <button className={'mk-cta ' + variant} disabled={disabled} onClick={disabled ? undefined : onClick}>
      {children}
    </button>
  )
}
