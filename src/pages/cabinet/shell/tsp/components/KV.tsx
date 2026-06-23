// AgOS · TSP-1 · Пара «ключ-значение» с кнопкой правки (p1/ui.jsx KV).

import type { ReactNode } from 'react'

export function KV({ k, children, onEdit }: { k: string; children: ReactNode; onEdit?: () => void }) {
  return (
    <div className="kv">
      <div className="kv-k mono">{k}</div>
      <div className="kv-v">{children}</div>
      {onEdit && <button className="kv-edit" onClick={onEdit} title="Изменить">✎</button>}
    </div>
  )
}
