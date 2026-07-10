// AgOS · ARS-212 · SCR-F5 · Содержание (всем веткам). Каркас = F3. Сезонный хребет работ КЗ:
// заготовка сена, зимовка, перегоны, дегельминтизация. CTA последнего вопроса ветки:
// «Собрать план работ» если порог достигнут, иначе «Готово». Skip-link есть.

import type { HousingAnswer } from '../types'
import { FwShell, DraftNote } from './FwShell'
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
  onSkip: () => void
  onBack: () => void
  onExit: () => void
}

export function FwStepHousing({ progress, dots, value, willBuildPlan, setValue, onNext, onSkip, onBack, onExit }: Props) {
  return (
    <FwShell
      onExit={onExit}
      onBack={onBack}
      bar
      progress={dots ? progress : undefined}
      stepLabel={`вопрос ${progress.step} из ${progress.count} · содержание`}
      title="Как содержите скот?"
      titleQ
      screenLabel="SCR-F5 · мастер · содержание"
      footer={<>
        <MkCta onClick={onNext}>{willBuildPlan ? 'Собрать план работ' : 'Готово'}</MkCta>
        <button className="mk-link" onClick={onSkip}>Пропустить вопрос</button>
        <DraftNote />
      </>}
    >
      <div className="mk-stack8">
        {OPTS.map((o) => (
          <BigRadio key={o.v} sel={value === o.v} title={o.t} sub={o.s} onClick={() => setValue(o.v)} />
        ))}
      </div>
      <FwWhy>Сено, зимовка, перегоны — впишем работы под ваш уклад</FwWhy>
    </FwShell>
  )
}
