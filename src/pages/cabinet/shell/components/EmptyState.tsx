// AgOS · Общий пустой / «coming-soon» экран — иконка в рамке + заголовок + подпись + опц. действие.
// Свои классы .es-* (а не .mk-empty, где полиш ДС прячет арт-бокс) — чтобы иконка была видимой.

import type { ReactNode } from 'react'
import { PhIcon, type PhIconName } from './icons/PhIcon'

interface EmptyStateProps {
  icon: PhIconName
  title: string
  sub?: string
  action?: ReactNode
}

export function EmptyState({ icon, title, sub, action }: EmptyStateProps) {
  return (
    <div className="es">
      <div className="es-art"><PhIcon name={icon} size={46} /></div>
      <div className="es-h">{title}</div>
      {sub && <div className="es-s">{sub}</div>}
      {action && <div className="es-act">{action}</div>}
    </div>
  )
}
