// AgOS · TSP-1 · Шаг 2 · Когда готова к отгрузке — реcкин под прототип (market-wizard.jsx WizStep2).

import { useState } from 'react'
import type { WizState } from '../types/batch'
import { addDays, fmtD, fmtDGen, publishInfo, TODAY, windowPresets, wizWindow } from '../data/tsp-utils'
import { WizShell, DraftNote } from './WizShell'
import { BigRadio } from '../components/BigRadio'
import { InfoNote } from '../components/InfoNote'
import { MkField } from '../components/MkField'
import { MkErr } from '../components/MkErr'
import { MkCta } from '../components/MkCta'

interface Props {
  w: WizState
  sw: (patch: Partial<WizState>) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
}

export function WizStep2Window({ w, sw, onNext, onBack, onExit }: Props) {
  const win = wizWindow(w)
  const pi = publishInfo(win)
  const ownBad = w.windowPreset === 'own' && !!w.customFrom && !!w.customTo &&
    (new Date(w.customTo) < new Date(w.customFrom) || new Date(w.customFrom) < addDays(TODAY, -1))
  const [miss, setMiss] = useState(false)
  const tryNext = () => { if (!win || ownBad) { setMiss(true); return } onNext() }

  return (
    <WizShell step={2} onBack={onBack} onExit={onExit} title="Когда животные будут готовы к отгрузке?"
      footer={<><MkCta onClick={tryNext}>Далее</MkCta><DraftNote /></>}>
      <div className={'mk-radio-list' + (miss && !win ? ' mk-miss' : '')}>
        {windowPresets().map((p) => (
          <BigRadio key={p.k} sel={w.windowPreset === p.k} onClick={() => { sw({ windowPreset: p.k }); setMiss(false) }}
            title={p.t} sub={p.from && p.to ? fmtD(p.from) + ' — ' + fmtD(p.to) : 'выбрать в календаре'} />
        ))}
      </div>
      {miss && !win && w.windowPreset !== 'own' && <MkErr amber>Выберите, когда животные будут готовы</MkErr>}
      {w.windowPreset === 'own' && (
        <div className="mk-grid2" style={{ marginTop: 10 }}>
          <MkField label="С" miss={miss && !win}>
            <input type="date" className="mk-input mk-mono" value={w.customFrom} onChange={(e) => { sw({ customFrom: e.target.value }); setMiss(false) }} />
          </MkField>
          <MkField label="По" miss={miss && !win}>
            <input type="date" className="mk-input mk-mono" value={w.customTo} onChange={(e) => { sw({ customTo: e.target.value }); setMiss(false) }} />
          </MkField>
        </div>
      )}
      {miss && !win && w.windowPreset === 'own' && <MkErr amber>Укажите обе даты</MkErr>}
      {ownBad && <MkErr>«По» должно быть не раньше «с», а «с» — не раньше сегодня.</MkErr>}
      {win && !ownBad && (
        <div className="mk-winsum">
          <div className="mk-ws-big">Окно отгрузки: {fmtD(win.from)} — {fmtD(win.to)}</div>
          <div className="mk-ws-edit">Готов держать животных до: <b>{fmtDGen(win.to)}</b></div>
          <div className="mk-ws-hint">если покупатель не найдётся раньше</div>
        </div>
      )}
      {pi && pi.delayed && pi.at && (
        <InfoNote title="Выход в продажу">
          Партия выйдет в продажу {fmtDGen(pi.at)} — за неделю до готовности. Так покупатель найдётся к нужному сроку.
        </InfoNote>
      )}
    </WizShell>
  )
}
