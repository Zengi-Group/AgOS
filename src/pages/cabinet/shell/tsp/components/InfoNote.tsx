// AgOS · TSP-1 · Информационная заметка (порт market-ui.jsx InfoNote) — .mk-infonote.

import type { ReactNode } from 'react'

export function InfoNote({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <div className="mk-infonote">
      {title && <div className="mk-infonote-t">{title}</div>}
      <div className="mk-infonote-b">{children}</div>
    </div>
  )
}
