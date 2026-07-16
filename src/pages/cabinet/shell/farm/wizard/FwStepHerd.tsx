// AgOS · ARS-212 · SCR-F1 · Состав стада (ярус 1, один вопрос). Полевой язык; архетип
// выводится из состава (фермеру не показывается). CTA = «Показать цены» (обещание Payoff-1).
// Сумма голов = 0 → подсветка .mk-miss + MkErr amber (паттерн TSP-шага 1).

import { useRef, useState } from 'react'
import { HERD_FIELDS, totalHeads, type FwState, type HerdKey } from '../types'
import { FwShell, DraftNote } from './FwShell'
import { StepperCtl } from '../../tsp/components/StepperCtl'
import { MkCta } from '../../tsp/components/MkCta'
import { MkErr } from '../../tsp/components/MkErr'

interface Props {
  heads: FwState['heads']
  setHeads: (patch: Partial<FwState['heads']>) => void
  prefilled: boolean                 // стадо подставлено из БД (TSP/legacy) → показать note
  onNext: () => void
  onExit: () => void                 // X и ← (F1: назад = выход на F0)
}

export function FwStepHerd({ heads, setHeads, prefilled, onNext, onExit }: Props) {
  const [miss, setMiss] = useState(false)
  const listRef = useRef<HTMLDivElement>(null)

  const tryNext = () => {
    if (totalHeads(heads) <= 0) {
      setMiss(true)
      const el = listRef.current
      const sc = el?.closest('.phone-scroll') as HTMLElement | null
      if (el && sc) sc.scrollTo({ top: 0, behavior: 'smooth' })
      return
    }
    onNext()
  }

  return (
    <FwShell
      onExit={onExit}
      onBack={onExit}
      bar
      title="Кто у вас в стаде?"
      titleQ
      sub="Сколько примерно голов в каждой группе"
      screenLabel="SCR-F1 · мастер · состав стада"
      footer={<><MkCta onClick={tryNext}>Показать цены</MkCta><DraftNote /></>}
    >
      {prefilled && (
        <div className="mk-note" style={{ textAlign: 'left', marginTop: 0, marginBottom: 14 }}>
          мы уже кое-что знаем из ваших продаж — поправьте, если изменилось
        </div>
      )}
      <div ref={listRef} className={'fw-cats' + (miss ? ' mk-miss' : '')}>
        {HERD_FIELDS.map((f) => {
          const v = heads[f.key as HerdKey]
          return (
            <div className="fw-cat" key={f.key}>
              <div className="fw-cat-l">
                <div className="fw-cat-t">{f.label}</div>
                <div className="fw-cat-s">{f.sub}</div>
              </div>
              <div className={'fw-cat-stp' + (v > 0 ? '' : ' fw-zero')}>
                <StepperCtl value={v} min={0} max={9999}
                  onChange={(n) => { setHeads({ [f.key]: n } as Partial<FwState['heads']>); if (miss) setMiss(false) }} />
              </div>
            </div>
          )
        })}
      </div>
      {miss && <MkErr amber>Укажите хотя бы одну группу — хотя бы примерно</MkErr>}
    </FwShell>
  )
}
