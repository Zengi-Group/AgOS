// AgOS · Заголовок яруса Главной (прототип home.jsx TierHead): левый лейбл (18px) +
// счётчик-пилюля + правый слот. Токены DS daylight.

import type { ReactNode } from 'react'

export function TierHead({ label, count, right }: { label: string; count?: number; right?: ReactNode }) {
  return (
    <div className="tier-h">
      <span className="tier-h-l">
        <span className="tier-label">{label}</span>
        {count != null && <span className="tier-count">{count}</span>}
      </span>
      {right}
    </div>
  )
}
