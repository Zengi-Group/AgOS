// AgOS · TSP-2 · Шторка «Лимит активных партий» (максимум 5).

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'

interface Props {
  open: boolean
  onClose: () => void
  onToList: () => void
}

export function LimitSheet({ open, onClose, onToList }: Props) {
  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">Лимит активных партий</div>
      <div className="sh-b">
        Максимум 5 активных партий одновременно.
        Завершите или снимите одну из текущих партий, чтобы создать новую.
      </div>
      <Cta onClick={onToList}>Мои партии</Cta>
      <Cta variant="ghost" onClick={onClose}>Закрыть</Cta>
    </Sheet>
  )
}
