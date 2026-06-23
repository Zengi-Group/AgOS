// AgOS · Этап 1 · Таб-бар ×5: Главная · Ферма · Рынок · Маркет · Сообщения (shell/ui.jsx).
// Бейджи: «Сообщения» — счётчик; «Рынок» — янтарная точка. Колокольчика нет.

import { useShell } from '../context'
import { ShIc, type IconKey } from './icons/ShIc'
import type { RouteName } from '../types'

export const SHELL_TABS: [RouteName, string, IconKey][] = [
  ['home', 'Главная', 'home'],
  ['farm', 'Ферма', 'farm'],
  ['market', 'Рынок', 'market'],
  ['shop', 'Маркет', 'bag'],
  ['messages', 'Сообщения', 'chat'],
]

export function ShellTabBar() {
  const ctx = useShell()
  return (
    <div className="bottom-nav tab5">
      {SHELL_TABS.map(([k, t, ic]) => (
        <button key={k} className={'bn-item' + (ctx.tab === k ? ' on' : '')} onClick={() => ctx.go({ name: k })}>
          <span className="bn-ic">
            <ShIc k={ic} />
            {k === 'market' && ctx.marketDot && <i className="tb-dot" />}
            {k === 'messages' && ctx.msgBadge > 0 && <i className="tb-badge mono">{ctx.msgBadge}</i>}
          </span>
          <span className="bn-t">{t}</span>
        </button>
      ))}
    </div>
  )
}
