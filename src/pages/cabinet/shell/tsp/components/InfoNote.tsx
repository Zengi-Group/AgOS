// AgOS · TSP-1 · Информационная заметка (p1/ui.jsx InfoNote).

import type { ReactNode } from 'react'

export function InfoNote({ tone, title, children }: { tone?: string; title?: string; children: ReactNode }) {
  return (
    <div className={'note ' + (tone || '')}>
      {title && <div className="note-t mono">{title}</div>}
      <div className="note-b">{children}</div>
    </div>
  )
}
