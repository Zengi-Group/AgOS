// AgOS · Главная — стартовый модуль «С чего начать» (ARS-209, направление A «карта-лестница»,
// выровнено под язык Главной). Встаёт в зону пустых ярусов: заполняет пустоту по сетке, ведёт
// по шагам-ценностям (обмен «данные↔ценность»), растворяется по мере наполнения фермы.
// Стадия динамична, из membership + наличия стада: S0 (не член) и S3 (член без стада) → лестница;
// член + стадо (онбординг завершён) → null (зону держат задачи ЦТК / «Быстрый доступ»).
// Показывается только когда ярусы пусты (quiet) — решает HomeScreen.

import { useShell } from '../context'
import { PhIcon, type PhIconName } from './icons/PhIcon'
import { TierHead } from './TierHead'

type StepState = 'active' | 'done' | 'todo' | 'locked'
interface Step { key: string; icon: PhIconName; title: string; sub?: string; state: StepState; onClick?: () => void }

export function HomeStartLadder({ herdFilled }: { herdFilled: boolean }) {
  const ctx = useShell()
  const m = ctx.membership
  const isMember = m === 'active' || m === 'expiring' || m === 'grace'

  // S4 — член + стадо заведено → онбординг исчерпан, модуль не показываем (зону закрывают
  // задачи ЦТК / «Быстрый доступ»). Empty-state — только для стадий настройки (S0/S3).
  if (isMember && herdFilled) return null

  // S0 / S3 — лестница. «active» — единственный следующий шаг (акцент).
  // Шаг «Членство» отражает реальный статус заявки: подал → «на рассмотрении» (не даём
  // подать повторно); одобрено → «оплатить взнос»; отклонено → «подать заново».
  const stepJoin: Step =
    isMember
      ? { key: 'join', icon: 'check', title: 'Вы в ассоциации', state: 'done' }
      : m === 'pending'
        ? { key: 'join', icon: 'clock', title: 'Заявка на рассмотрении', sub: 'Ответим в течение 3 рабочих дней', state: 'done' }
        : m === 'approved'
          ? { key: 'join', icon: 'users', title: 'Оплатить членский взнос', sub: 'Заявка одобрена — оформите членство', state: 'active', onClick: () => ctx.memberAct('pay') }
          : { key: 'join', icon: 'users', title: m === 'rejected' ? 'Подать заявку заново' : 'Вступить в ассоциацию', sub: 'Откроются цены и продажа скота через TURAN', state: 'active', onClick: () => ctx.memberAct('apply') }

  const stepHerd: Step = herdFilled
    ? { key: 'herd', icon: 'check', title: 'Стадо заведено', state: 'done' }
    : {
        key: 'herd', icon: 'cow', title: 'Завести стадо',
        sub: isMember ? 'Получите план работ и напоминания по хозяйству' : undefined,
        state: isMember ? 'active' : 'todo', onClick: () => ctx.go({ name: 'farm' }),
      }

  const stepSell: Step = isMember
    ? { key: 'sell', icon: 'package', title: 'Продать первую партию', state: 'todo', onClick: () => ctx.go({ name: 'market' }) }
    : { key: 'sell', icon: 'package', title: 'Продать первую партию', state: 'locked' }

  const steps: Step[] = [stepJoin, stepHerd, stepSell]
  const eyebrow = isMember ? 'Настройка фермы' : 'С чего начать'

  return (
    <div className="blk">
      <TierHead label={eyebrow} />
      <div className="hsl">
        {steps.map((s) => {
          const clickable = !!s.onClick && s.state !== 'locked' && s.state !== 'done'
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
                {s.sub && <span className="hsl-s">{s.sub}</span>}
              </span>
              {s.state === 'locked'
                ? <span className="hsl-tr"><PhIcon name="lock" size={14} /></span>
                : s.state === 'done'
                  ? null
                  : <span className="hsl-tr"><PhIcon name="chevronRight" size={17} /></span>}
            </button>
          )
        })}
      </div>
    </div>
  )
}
