// AgOS · S2 (ARS-148) · Нативный таб-бар ×5 на IonTabBar/IonTabButton.
// Контент и бейджи — 1:1 из ShellTabBar.tsx (marketDot, msgBadge); ShellTabBar
// сохраняется для оболочки МПК до S6 (ARS-152).

import { IonTabBar, IonTabButton } from '@ionic/react'
import { useShell } from '../context'
import { ShIc } from './icons/ShIc'
import { SHELL_TABS } from './ShellTabBar'

export function ShellTabBarIon() {
  const ctx = useShell()
  return (
    <IonTabBar className="agos-tabbar" selectedTab={ctx.tab}>
      {SHELL_TABS.map(([k, t, ic]) => (
        <IonTabButton
          key={k}
          tab={k}
          selected={ctx.tab === k}
          onClick={() => ctx.go({ name: k })}
        >
          <span className="bn-ic">
            <ShIc k={ic} />
            {k === 'market' && ctx.marketDot && <i className="tb-dot" />}
            {k === 'messages' && ctx.msgBadge > 0 && <i className="tb-badge mono">{ctx.msgBadge}</i>}
          </span>
          <span className="bn-t">{t}</span>
        </IonTabButton>
      ))}
    </IonTabBar>
  )
}
