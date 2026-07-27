// AgOS · Кабинет · Шторка подтверждения удаления аккаунта.
// B6 (ARS-110, релиз в сторы): Apple 5.1.1(v) / Google Play data-deletion —
// in-app путь удаления обязателен для сабмита.

import { useState } from 'react'
import { Sheet } from '../Sheet'
import { Cta } from '../Cta'

interface Props {
  open: boolean
  onClose: () => void
  onConfirm: () => Promise<void>
}

export function DeleteAccountSheet({ open, onClose, onConfirm }: Props) {
  const [pending, setPending] = useState(false)

  const handleConfirm = async () => {
    setPending(true)
    try {
      await onConfirm()
    } finally {
      setPending(false)
    }
  }

  return (
    <Sheet open={open} onClose={pending ? () => {} : onClose}>
      <div className="sh-t">Удалить аккаунт</div>
      <div className="sh-b">
        Вход в приложение станет недоступен. Данные хозяйства и история сделок ТСП
        сохраняются для отчётности ассоциации (ст. 171 ПК РК). Чтобы восстановить
        доступ после удаления — обратитесь в TURAN.
      </div>
      <Cta variant="danger" onClick={handleConfirm} disabled={pending}>
        {pending ? 'Удаление…' : 'Удалить аккаунт'}
      </Cta>
      <Cta variant="ghost" onClick={onClose} disabled={pending}>Отмена</Cta>
    </Sheet>
  )
}
