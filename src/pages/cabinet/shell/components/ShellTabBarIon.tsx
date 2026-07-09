// AgOS · Нижний таб-бар фермера — 4 таба как в прототипе (shell.jsx TABS):
// Главная · Ферма · Рынок · Сообщения. Phosphor-иконки, акцент на активном.
// Магазин доступен через грид сервисов Главной (не отдельным табом). Навигация — ctx.go.

import { IonTabBar, IonTabButton } from '@ionic/react'
import { useShell } from '../context'
import { PhIcon, type PhIconName } from './icons/PhIcon'
import type { RouteName } from '../types'

const TABS: [RouteName, string, PhIconName][] = [
  ['home', 'Главная', 'home'],
  ['farm', 'Ферма', 'sprout'],
  ['market', 'Рынок', 'market'],
  ['messages', 'Сообщения', 'chat'],
]

export function ShellTabBarIon() {
  const ctx = useShell()
  return (
    <IonTabBar className="agos-tabbar">
      {TABS.map(([k, t, ic]) => (
        <IonTabButton key={k} tab={k} selected={ctx.tab === k} onClick={() => ctx.go({ name: k })}>
          <span className="bn-ic">
            <PhIcon name={ic} size={22} />
            {k === 'market' && ctx.marketDot && <i className="tb-dot" />}
            {k === 'messages' && ctx.msgBadge > 0 && <i className="tb-badge mono">{ctx.msgBadge}</i>}
          </span>
          <span className="bn-t">{t}</span>
        </IonTabButton>
      ))}
    </IonTabBar>
  )
}
