// AgOS · TSP-1 · Шаг 2 · Когда готова к отгрузке (p1/wizard.jsx WizStep2).

import { useState } from 'react'
import type { WizState } from '../types/batch'
import { addDays, fmtD, fmtDGen, publishInfo, TODAY, windowPresets, wizWindow } from '../data/tsp-utils'
import { WizShell } from './WizShell'
import { BigRadio } from '../components/BigRadio'
import { InfoNote } from '../components/InfoNote'

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
      cta="Далее →" onCta={tryNext}>
      <div className={'stack8' + (miss && !win ? ' miss-ring' : '')}>
        {windowPresets().map((p) => (
          <BigRadio key={p.k} sel={w.windowPreset === p.k} onClick={() => { sw({ windowPreset: p.k }); setMiss(false) }}
            title={p.t} sub={p.from && p.to ? fmtD(p.from) + ' — ' + fmtD(p.to) : 'выбрать в календаре'} />
        ))}
      </div>
      {miss && !win && w.windowPreset !== 'own' && <div className="field-err amber" style={{ marginTop: 6 }}>Выберите, когда животные будут готовы</div>}
      {w.windowPreset === 'own' && (
        <div className="grid2" style={{ marginTop: 8 }}>
          <label className={'field nomb' + (miss && !win ? ' miss' : '')}>
            <div className="lab">с</div>
            <input type="date" className="finput mono" value={w.customFrom} onChange={(e) => { sw({ customFrom: e.target.value }); setMiss(false) }} />
          </label>
          <label className={'field nomb' + (miss && !win ? ' miss' : '')}>
            <div className="lab">по</div>
            <input type="date" className="finput mono" value={w.customTo} onChange={(e) => { sw({ customTo: e.target.value }); setMiss(false) }} />
          </label>
        </div>
      )}
      {miss && !win && w.windowPreset === 'own' && <div className="field-err amber" style={{ marginTop: 4 }}>Укажите обе даты</div>}
      {ownBad && <div className="field-err">«По» должно быть не раньше «с», а «с» — не раньше сегодня.</div>}
      {win && !ownBad && (
        <div className="win-sum">
          <div className="ws-big">Окно отгрузки: {fmtD(win.from)} — {fmtD(win.to)}</div>
          <div className="ws-edit">Готов держать животных до: <b>{fmtDGen(win.to)}</b> <span className="kv-edit-inline">✎</span></div>
          <div className="ws-hint">если покупатель не найдётся раньше</div>
        </div>
      )}
      {pi && pi.delayed && pi.at && (
        <InfoNote tone="plain" title="ВЫХОД В ПРОДАЖУ">
          Партия выйдет в продажу {fmtDGen(pi.at)} — за неделю до готовности. Так покупатель найдётся к нужному сроку.
        </InfoNote>
      )}
    </WizShell>
  )
}
