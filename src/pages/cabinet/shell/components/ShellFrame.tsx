// AgOS · Этап 1 · Каркас экрана оболочки (shell/ui.jsx).

import type { ReactNode } from 'react'
import { OfflineBar } from './OfflineBar'
import { ShellTabBar } from './ShellTabBar'

export function ShellFrame({ label, children, noTabs }: { label?: string; children: ReactNode; noTabs?: boolean }) {
  return (
    <div className="phone" data-screen-label={label || ''}>
      <div className="phone-body">
        <OfflineBar />
        <div className="phone-scroll">{children}</div>
        {!noTabs && <ShellTabBar />}
      </div>
    </div>
  )
}
