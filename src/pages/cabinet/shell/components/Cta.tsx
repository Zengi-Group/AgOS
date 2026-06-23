// AgOS · Этап 1 · Кнопка действия (p1/ui.jsx Cta).

import type { ReactNode } from 'react'

interface CtaProps {
  children: ReactNode
  onClick?: () => void
  variant?: 'ghost' | 'danger' | 'warn' | 'primary-green'
  disabled?: boolean
}

export function Cta({ children, onClick, variant, disabled }: CtaProps) {
  const v =
    variant === 'ghost' ? 'ghost'
    : variant === 'danger' ? 'danger'
    : variant === 'warn' ? 'warnv'
    : variant === 'primary-green' ? 'green'
    : ''
  return (
    <button
      className={'cta ' + v + (disabled ? ' is-disabled' : '')}
      disabled={disabled}
      onClick={disabled ? undefined : onClick}
    >
      {children}
    </button>
  )
}
