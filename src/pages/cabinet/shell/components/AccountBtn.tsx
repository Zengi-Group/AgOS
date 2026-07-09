// AgOS · Кнопка кабинета/аккаунта в шапке — тонкая минималистичная иконка (Phosphor User thin)
// вместо аватара-монограммы. Янтарная точка = требуется действие. Общая для HomeHead и TabHead.

import { useShell } from '../context'
import { PhIcon } from './icons/PhIcon'

export function AccountBtn() {
  const ctx = useShell()
  return (
    <button className="acct-btn" title="Кабинет хозяйства" aria-label="Кабинет хозяйства" onClick={() => ctx.go({ name: 'cabinet' })}>
      <PhIcon name="userThin" size={25} />
      {ctx.avatarDot && <i className="acct-dot" />}
    </button>
  )
}
