// AgOS · ARS-212 · SCR-F3 · Отёл (ярус 2, только при маточном). BigRadio ×4; при сезонном
// ответе — блок чипов месяца первого отёла (обязателен для «Дальше»). «Круглый год» и
// «По-разному» — полноправные опции (легальный путь, F-D14), ничего не блокируют.
// fw-why (InfoNote): «зачем спрашиваем». Skip-link пишет null и идёт дальше (порог не достигнут).

import { useState } from 'react'
import type { CalvingAnswer } from '../types'
import { FwShell, DraftNote } from './FwShell'
import { BigRadio } from '../../tsp/components/BigRadio'
import { MkCta } from '../../tsp/components/MkCta'
import { MkErr } from '../../tsp/components/MkErr'
import { FwWhy } from './FwWhy'

const MONTHS = ['янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек']

const OPTS: { v: CalvingAnswer; t: string; s: string }[] = [
  { v: 'spring',     t: 'Весной',      s: 'обычно февраль–май' },
  { v: 'autumn',     t: 'Осенью',      s: 'сентябрь–ноябрь' },
  { v: 'year_round', t: 'Круглый год', s: 'случка не ограничена по сезону' },
  { v: 'varies',     t: 'По-разному',  s: 'как получится — тоже нормально' },
]

interface Props {
  progress: { count: number; step: number }
  dots: boolean                    // ярус 2: >1 вопроса → точки; 1 вопрос → без точек (шум)
  value: CalvingAnswer
  month: number | null
  setValue: (v: CalvingAnswer) => void
  setMonth: (m: number | null) => void
  onNext: () => void
  onSkip: () => void
  onBack: () => void
  onExit: () => void
}

export function FwStepCalving({ progress, dots, value, month, setValue, setMonth, onNext, onSkip, onBack, onExit }: Props) {
  const [miss, setMiss] = useState(false)
  const seasonal = value === 'spring' || value === 'autumn'

  const tryNext = () => {
    if (seasonal && month == null) { setMiss(true); return }
    onNext()
  }

  return (
    <FwShell
      onExit={onExit}
      onBack={onBack}
      bar
      progress={dots ? progress : undefined}
      stepLabel={`вопрос ${progress.step} из ${progress.count} · отёл`}
      title="Когда у вас обычно телятся?"
      titleQ
      screenLabel="SCR-F3 · мастер · отёл"
      footer={<>
        <MkCta onClick={tryNext}>Дальше</MkCta>
        <button className="mk-link" onClick={onSkip}>Пропустить вопрос</button>
        <DraftNote />
      </>}
    >
      <div className="mk-stack8">
        {OPTS.map((o) => (
          <BigRadio key={o.v} sel={value === o.v} title={o.t} sub={o.s}
            onClick={() => { setValue(o.v); if (o.v !== 'spring' && o.v !== 'autumn') setMonth(null); setMiss(false) }} />
        ))}
      </div>

      {seasonal && (
        <div style={{ marginTop: 16 }}>
          <span className="mk-lab">С какого месяца первые отёлы?</span>
          <div className={'fw-months' + (miss ? ' mk-miss' : '')}>
            {MONTHS.map((m, i) => (
              <button key={m} className={'mk-fat-c' + (month === i + 1 ? ' sel' : '')}
                onClick={() => { setMonth(i + 1); setMiss(false) }}>{m}</button>
            ))}
          </div>
          {miss && <MkErr amber>Укажите месяц — хотя бы примерно</MkErr>}
        </div>
      )}

      <FwWhy>От этого месяца построим весь календарь года</FwWhy>
    </FwShell>
  )
}
