// AgOS · Этап 1 · Офлайн-баннер (shell/ui.jsx).

import { useContext } from 'react'
import { ShellCtx } from '../context'

export function OfflineBar() {
  // Читаем контекст напрямую: ShellFrame переиспользуется и в оболочке МПК,
  // где ShellProvider отсутствует. Без провайдера офлайн-баннер просто не нужен.
  const ctx = useContext(ShellCtx)
  // Без провайдера (оболочка МПК) баннер не нужен — не монтируем вовсе.
  if (!ctx) return null
  // L3 (аудит 2026-07-13): держим смонтированным и анимируем высоту (grid-rows 0fr↔1fr)
  // + opacity — иначе mount/unmount при каждом флапе сети скачком двигает весь экран на ~30px.
  return (
    <div className={'offline-bar-wrap' + (ctx.offline ? ' is-on' : '')} aria-hidden={!ctx.offline}>
      <div className="offline-bar">Нет связи — показаны последние данные</div>
    </div>
  )
}
