// AgOS · TSP-2 · Оценка звёздами (порт market-ui.jsx Stars) — .mk-stars/.mk-star + PhIcon.
// Только для чтения, если onChange не передан (disabled-режим).

import { PhIcon } from '../../components/icons/PhIcon'

interface StarsProps {
  value: number
  onChange?: (n: number) => void
  size?: 'lg' | 'sm'
}

export function Stars({ value, onChange, size }: StarsProps) {
  const sz = size === 'lg' ? 28 : 17
  return (
    <div className="mk-stars">
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} className="mk-star" onClick={onChange ? () => onChange(n) : undefined} disabled={!onChange} aria-label={n + ' из 5'}>
          <PhIcon name="starOutline" size={sz} color={n <= value ? 'var(--amber)' : 'var(--fg3)'} />
        </button>
      ))}
    </div>
  )
}
