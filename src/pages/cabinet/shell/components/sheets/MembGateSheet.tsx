// AgOS · Этап 1 · Гейт «Доступно членам TURAN» (shell/app.jsx kind="membgate").
// Тексты — слово в слово из прототипа.

import { Sheet } from '../Sheet'
import { Cta } from '../Cta'
import type { MembershipStatus } from '../../types'

function gateCopy(membership: MembershipStatus): { t: string; b: string; cta: string | null; act?: string } {
  if (membership === 'expired')
    return { t: 'Членство истекло', b: 'Текущие сделки можно довести до конца. Чтобы создавать и публиковать новые партии — оплатите взнос.', cta: 'Оплатить', act: 'pay' }
  if (membership === 'pending')
    return { t: 'Заявка на рассмотрении', b: 'Продажа партий откроется после одобрения заявки и оплаты взноса. Ответим в течение 3 рабочих дней.', cta: null }
  return { t: 'Доступно членам TURAN', b: 'Продажа партий, справочные цены и защита сделок — для членов ассоциации.', cta: 'Подать заявку', act: 'apply' }
}

interface Props {
  membership: MembershipStatus
  onClose: () => void
  onAct: (act: string) => void
}

export function MembGateSheet({ membership, onClose, onAct }: Props) {
  const copy = gateCopy(membership)
  return (
    <Sheet open onClose={onClose}>
      <div className="sh-t">{copy.t}</div>
      <div className="sh-b">{copy.b}</div>
      {copy.cta && <Cta onClick={() => onAct(copy.act as string)}>{copy.cta}</Cta>}
      <Cta variant="ghost" onClick={onClose}>Понятно</Cta>
    </Sheet>
  )
}
