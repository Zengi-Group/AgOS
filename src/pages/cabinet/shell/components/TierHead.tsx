// AgOS · Этап 2 · Заголовок яруса Главной с точкой-индикатором (shell/ui.jsx TierHead).

import type { ReactNode } from 'react'

export function TierHead({ tone, label, count, right }: { tone?: 'amber' | 'gray'; label: string; count?: number; right?: ReactNode }) {
  return (
    <div className="tier-h mono">
      <span className="tier-h-l">
        {tone && <i className={'tier-dot ' + tone} />}
        {label}{count != null ? ' · ' + count : ''}
      </span>
      {right}
    </div>
  )
}
