// AgOS · Этап 1 · Гейт Консультанта — предложение Platform Pro (shell/app.jsx kind="progate").
// Тексты — слово в слово из прототипа.

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import { NBSP } from '../../store'

export function ProGateSheet({ onClose, onPay }: { onClose: () => void; onPay: () => void }) {
  return (
    <Sheet open onClose={onClose}>
      <div className="sh-t">Консультант — в Platform Pro</div>
      <div className="sh-b">
        AI-зоотехник TURAN доступен с подпиской Platform Pro — 4 900{NBSP}₸/мес. Помогает с рационом, болезнями, отёлом и ценой.
      </div>
      <Cta variant="primary-green" onClick={onPay}>Подключить Pro</Cta>
      <Cta variant="ghost" onClick={onClose}>Позже</Cta>
    </Sheet>
  )
}
