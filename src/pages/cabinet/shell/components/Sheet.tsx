// AgOS · Этап 1 · Нижний лист (p1/ui.jsx Sheet). Закрывается по тапу на фон.
// S2 (ARS-148): обёртка → IonModal-sheet (drag-to-dismiss с пружиной, spec §7).
// Контент и API (open/onClose/children) сохранены — 9 шторок работают без правок.

import type { ReactNode } from 'react'
import { IonModal } from '@ionic/react'

interface SheetProps {
  open: boolean
  onClose: () => void
  children: ReactNode
}

export function Sheet({ open, onClose, children }: SheetProps) {
  return (
    <IonModal
      isOpen={open}
      onDidDismiss={onClose}
      breakpoints={[0, 1]}
      initialBreakpoint={1}
      className="agos-sheet-modal"
    >
      <div className="sheet">
        <div className="sheet-grip" />
        {children}
      </div>
    </IonModal>
  )
}
