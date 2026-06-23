// AgOS · Этап 1 · Тост (p1/ui.jsx Toast). Авто-скрытие — в CabinetApp (2800 мс).

import type { ToastState } from '../types'

export function Toast({ toast }: { toast: ToastState | null }) {
  if (!toast) return null
  return <div className="toast" key={toast.id}>{toast.text}</div>
}
