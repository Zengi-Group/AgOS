// AgOS · ARS-212 · SCR-F4 · Молодняк (при маточном или телятах). Каркас = F3. Модификатор
// доращивания (F-D2): хвост плана после отъёма, окно продажи, зимний запас кормов, сигнал TSP.
// Док — только CTA (R-27).

import type { YoungAnswer } from '../types'
import { FwShell } from './FwShell'
import { BigRadio } from '../../tsp/components/BigRadio'
import { MkCta } from '../../tsp/components/MkCta'
import { FwWhy } from './FwWhy'

const OPTS: { v: YoungAnswer; t: string; s: string }[] = [
  { v: 'weaners',  t: 'Продаю отъёмышей',       s: '~6 месяцев, сразу после отъёма' },
  { v: 'yearling', t: 'Держу до года и продаю', s: 'доращиваю и продаю подрощенных' },
  { v: 'keep',     t: 'Оставляю себе',          s: 'растите стадо — учтём в плане' },
]

interface Props {
  progress: { count: number; step: number }
  dots: boolean
  value: YoungAnswer
  setValue: (v: YoungAnswer) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
}

export function FwStepYoung({ progress, dots, value, setValue, onNext, onBack, onExit }: Props) {
  return (
    <FwShell
      onExit={onExit}
      onBack={onBack}
      bar
      progress={dots ? progress : undefined}
      title="Что обычно делаете с телятами?"
      titleQ
      screenLabel="SCR-F4 · мастер · молодняк"
      footer={<MkCta onClick={onNext}>Дальше</MkCta>}
    >
      <div className="mk-stack8 fw-opts">
        {OPTS.map((o) => (
          <BigRadio key={o.v} sel={value === o.v} title={o.t} sub={o.s} onClick={() => setValue(o.v)} />
        ))}
      </div>
      <FwWhy>Допишем план после отъёма — и подскажем окно продажи</FwWhy>
    </FwShell>
  )
}
