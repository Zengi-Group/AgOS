// AgOS · Главная — стартовый модуль «С чего начать» (ARS-209, направление A «карта-лестница»,
// выровнено под язык Главной). Единая поверхность онбординга в зоне ярусов: ведёт по шагам-
// ценностям (членство → стадо → продажа), растворяется по мере наполнения фермы.
// Стадия динамична, из реального membership + наличия стада. Шаг «Членство» отражает статус
// заявки: none→вступить · pending→«на рассмотрении» (не даём подать повторно) · approved→
// оплатить взнос · член→✓. Акцент — первый ДЕЙСТВЕННЫЙ шаг (для pending это «Завести стадо»).
// Член + стадо (онбординг завершён) → null (зону держат задачи ЦТК / «Быстрый доступ»).

import { useShell } from '../context'
import { PhIcon, type PhIconName } from './icons/PhIcon'
import { TierHead } from './TierHead'

type StepState = 'active' | 'done' | 'todo' | 'locked' | 'wait'
interface Step { key: string; icon: PhIconName; title: string; sub?: string; state: StepState; onClick?: () => void }

export function HomeStartLadder({ herdFilled }: { herdFilled: boolean }) {
  const ctx = useShell()
  const m = ctx.membership
  const isMember = m === 'active' || m === 'expiring' || m === 'grace'
  const sellOk = isMember || m === 'approved'

  // Онбординг завершён (член + стадо заведено) → модуль не показываем.
  if (isMember && herdFilled) return null

  // Шаг 1 · Членство — реальный статус заявки.
  let join: Step
  if (isMember) {
    join = { key: 'join', icon: 'check', title: 'Вы в ассоциации', state: 'done' }
  } else if (m === 'pending') {
    join = { key: 'join', icon: 'clock', title: 'Заявка на рассмотрении', sub: 'Ответим в течение 3 рабочих дней', state: 'wait' }
  } else if (m === 'approved') {
    join = { key: 'join', icon: 'userCheck', title: 'Оплатить членский взнос', sub: 'Заявка одобрена — оформите членство', state: 'todo', onClick: () => ctx.memberAct('pay') }
  } else {
    join = { key: 'join', icon: 'users', title: m === 'rejected' ? 'Подать заявку заново' : 'Вступить в ассоциацию', sub: 'Откроются цены и продажа скота через TURAN', state: 'todo', onClick: () => ctx.memberAct('apply') }
  }

  // Шаг 2 · Стадо (не зависит от членства — можно заводить сразу).
  const herd: Step = herdFilled
    ? { key: 'herd', icon: 'check', title: 'Стадо заведено', state: 'done' }
    : { key: 'herd', icon: 'cow', title: 'Завести стадо', sub: 'Получите план работ и напоминания по хозяйству', state: 'todo', onClick: () => ctx.go({ name: 'farm' }) }

  // Шаг 3 · Первая продажа (заперта, пока продажа недоступна).
  const sell: Step = sellOk
    ? { key: 'sell', icon: 'package', title: 'Продать первую партию', state: 'todo', onClick: () => ctx.go({ name: 'market' }) }
    : { key: 'sell', icon: 'package', title: 'Продать первую партию', state: 'locked' }

  const steps: Step[] = [join, herd, sell]
  // Акцент — первый действенный шаг (todo). done/wait/locked не акцентируем: для pending
  // членство ждёт (wait) → акцент уходит на «Завести стадо».
  const primary = steps.find((s) => s.state === 'todo')
  if (primary) primary.state = 'active'

  const eyebrow = isMember ? 'Настройка фермы' : 'С чего начать'

  return (
    <div className="blk">
      <TierHead label={eyebrow} />
      <div className="hsl">
        {steps.map((s) => {
          const clickable = !!s.onClick && (s.state === 'active' || s.state === 'todo')
          const showSub = !!s.sub && (s.state === 'active' || s.state === 'wait')
          return (
            <button
              key={s.key}
              className={'hsl-step s-' + s.state}
              disabled={!clickable}
              onClick={clickable ? s.onClick : undefined}
            >
              <span className="hsl-ic"><PhIcon name={s.icon} size={22} /></span>
              <span className="hsl-body">
                <span className="hsl-t">{s.title}</span>
                {showSub && <span className="hsl-s">{s.sub}</span>}
              </span>
              {s.state === 'locked'
                ? <span className="hsl-tr"><PhIcon name="lock" size={14} /></span>
                : s.state === 'done' || s.state === 'wait'
                  ? null
                  : <span className="hsl-tr"><PhIcon name="chevronRight" size={17} /></span>}
            </button>
          )
        })}
      </div>
    </div>
  )
}
