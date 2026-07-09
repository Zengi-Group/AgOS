// AgOS · Шапка внутренних страниц (Партия / Диалог / Отзыв / TURAN) — порт прототипа
// shell.jsx SubHead: [‹ back-label] · [опц. иконка/звезда/аватар] · [title/sub] · [right].
// Sticky, сплошной фон. Единый нативный внутренний хедер вместо разрозненных back-строк.

import type { ReactNode } from 'react'
import { PhIcon, type PhIconName } from './icons/PhIcon'
import { TuranStar } from './icons/TuranStar'

interface Props {
  onBack?: () => void
  backLabel?: string          // подпись к «‹» — куда ведёт назад (нативный iOS-стиль)
  icon?: PhIconName           // круглый аватар-слот: иконка …
  star?: boolean              // … либо звезда TURAN …
  avatar?: string             // … либо монограмма
  tone?: 'neutral' | 'accent' | 'amber' | 'green' | 'cta'
  title?: ReactNode
  sub?: ReactNode
  right?: ReactNode
}

export function SubHead({ onBack, backLabel, icon, star, avatar, tone = 'neutral', title, sub, right }: Props) {
  const hasAv = !!(icon || star || avatar)
  return (
    <div className="sub-head">
      {onBack && (
        <button className="sub-back" onClick={onBack} aria-label="Назад">
          <PhIcon name="chevronLeft" size={20} />
          {backLabel && <span className="sub-back-l">{backLabel}</span>}
        </button>
      )}
      {hasAv && (
        <span className={'sub-av tone-' + tone}>
          {star ? <TuranStar size={16} /> : avatar ? <span className="sub-av-l">{avatar}</span> : <PhIcon name={icon!} size={16} />}
        </span>
      )}
      {(title || sub) && (
        <span className="sub-head-t">{title && <b>{title}</b>}{sub && <span>{sub}</span>}</span>
      )}
      <span className="sub-head-sp" />
      {right ?? null}
    </div>
  )
}
