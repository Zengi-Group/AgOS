// AgOS · TSP-1 · Поле формы модуля «Рынок» (порт market-ui.jsx MkField) — .mk-field.

import type { ReactNode } from 'react'

interface MkFieldProps {
  label?: string
  hint?: string
  miss?: boolean
  err?: boolean
  children: ReactNode
}

export function MkField({ label, hint, miss, err, children }: MkFieldProps) {
  return (
    <label className={'mk-field' + (miss ? ' miss' : '') + (err ? ' err' : '')}>
      {label && <span className="mk-lab">{label}</span>}
      {children}
      {hint && <span className="mk-hint">{hint}</span>}
    </label>
  )
}
