// AgOS · ARS-212 · SCR-F3 · Отёл (ярус 2, только при маточном). BigRadio ×4; при сезонном
// ответе — чипы месяца первого отёла ОКНА СЕЗОНА (R-17: саб-вопрос наследует ответ родителя;
// spring=фев–май, autumn=сен–ноя) + «Другой месяц…» раскрывает полный грид 12 (P5: реальные
// отёлы могут начаться вне типичного окна). Месяц обязателен для «Дальше». «Круглый год» и
// «По-разному» — полноправные опции (легальный путь, F-D14), ничего не блокируют.
// fw-why (InfoNote): «зачем спрашиваем». Док — только CTA (R-27).

import { useState } from 'react'
import type { CalvingAnswer } from '../types'
import { FwShell } from './FwShell'
import { BigRadio } from '../../tsp/components/BigRadio'
import { MkCta } from '../../tsp/components/MkCta'
import { MkErr } from '../../tsp/components/MkErr'
import { FwWhy } from './FwWhy'

const MONTHS = ['янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек']

// Типичное окно сезона (совпадает с сабами опций) — месяцы 1..12.
const SEASON_WINDOW: Record<'spring' | 'autumn', number[]> = {
  spring: [2, 3, 4, 5],
  autumn: [9, 10, 11],
}

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
  onBack: () => void
  onExit: () => void
}

export function FwStepCalving({ progress, dots, value, month, setValue, setMonth, onNext, onBack, onExit }: Props) {
  const [miss, setMiss] = useState(false)
  const [allMonths, setAllMonths] = useState(
    // черновик содержит месяц вне окна сезона → сразу полный грид, чтобы выбор был виден
    () => (value === 'spring' || value === 'autumn') && month != null && !SEASON_WINDOW[value].includes(month)
  )
  const seasonal = value === 'spring' || value === 'autumn'
  const shownMonths = seasonal && !allMonths ? SEASON_WINDOW[value] : MONTHS.map((_, i) => i + 1)

  const pickSeason = (v: CalvingAnswer) => {
    if (v !== value) { setMonth(null); setAllMonths(false) }  // смена сезона = новое окно, старый месяц не тащим
    setValue(v)
    setMiss(false)
  }

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
      title="Когда у вас обычно телятся?"
      titleQ
      screenLabel="SCR-F3 · мастер · отёл"
      footer={<MkCta onClick={tryNext}>Дальше</MkCta>}
    >
      <div className="mk-stack8 fw-opts">
        {OPTS.map((o) => (
          <BigRadio key={o.v} sel={value === o.v} title={o.t} sub={o.s} onClick={() => pickSeason(o.v)} />
        ))}
      </div>

      {seasonal && (
        <div style={{ marginTop: 20 }}>
          <span className="mk-lab">С какого месяца первые отёлы?</span>
          <div className={'fw-months' + (allMonths ? ' full' : '') + (miss ? ' mk-miss' : '')}>
            {shownMonths.map((n) => (
              <button key={n} className={'fw-mon' + (month === n ? ' sel' : '')}
                onClick={() => { setMonth(n); setMiss(false) }}>{MONTHS[n - 1]}</button>
            ))}
          </div>
          {!allMonths && (
            <button className="mk-link fw-mon-more" onClick={() => setAllMonths(true)}>
              У нас иначе — другой месяц
            </button>
          )}
          {miss && <MkErr amber>Укажите месяц — хотя бы примерно</MkErr>}
        </div>
      )}

      <FwWhy>От этого месяца построим весь календарь года</FwWhy>
    </FwShell>
  )
}
