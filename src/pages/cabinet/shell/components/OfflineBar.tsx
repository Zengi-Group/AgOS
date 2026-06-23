// AgOS · Этап 1 · Офлайн-баннер (shell/ui.jsx).

import { useContext } from 'react'
import { ShellCtx } from '../context'

export function OfflineBar() {
  // Читаем контекст напрямую: ShellFrame переиспользуется и в оболочке МПК,
  // где ShellProvider отсутствует. Без провайдера офлайн-баннер просто не нужен.
  const ctx = useContext(ShellCtx)
  if (!ctx || !ctx.offline) return null
  return <div className="offline-bar">Нет связи — показаны последние данные</div>
}
