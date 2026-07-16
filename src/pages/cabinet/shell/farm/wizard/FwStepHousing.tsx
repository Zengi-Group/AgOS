// AgOS · ARS-212 · SCR-F5 · Содержание (всем веткам). Каркас = F3. Сезонный хребет работ КЗ:
// заготовка сена, зимовка, перегоны, дегельминтизация. CTA последнего вопроса ветки:
// «Собрать план работ» если порог достигнут, иначе «Готово». Док — только CTA (R-27).

import type { HousingAnswer } from '../types'
import { FwShell } from './FwShell'
import { BigRadio } from '../../tsp/components/BigRadio'
import { MkCta } from '../../tsp/components/MkCta'
import { FwWhy } from './FwWhy'

const OPTS: { v: HousingAnswer; t: string; s: string }[] = [
  { v: 'pasture', t: 'Пастбище',      s: 'круглый год на выпасе' },
  { v: 'stall',   t: 'Стойлово',      s: 'в базе круглый год' },
  { v: 'mixed',   t: 'Смешанно',      s: 'летом пастбище, зимой база' },
  { v: 'feedlot', t: 'Откормплощадка', s: 'промышленный откорм' },
]

interface Props {
  progress: { count: number; step: number }
  dots: boolean
  value: HousingAnswer
  willBuildPlan: boolean          // порог достигнут → CTA «Собрать план работ»
  setValue: (v: HousingAnswer) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
}

export function FwStepHousing({ progress, dots, value, willBuildPlan, setValue, onNext, onBack, onExit }: Props) {
  return (
    <FwShell
      onExit={onExit}
      onBack={onBack}
      bar
      progress={dots ? progress : undefined}
      title="Как содержите скот?"
      titleQ
      screenLabel="SCR-F5 · мастер · содержание"
      footer={<MkCta onClick={onNext}>{willBuildPlan ? 'Собрать план работ' : 'Готово'}</MkCta>}
    >
      <div className="mk-stack8 fw-opts">
        {OPTS.map((o) => (
          <BigRadio key={o.v} sel={value === o.v} title={o.t} sub={o.s} onClick={() => setValue(o.v)} />
        ))}
      </div>
      <FwWhy>Сено, зимовка, перегоны — впишем работы под ваш уклад</FwWhy>
    </FwShell>
  )
}
