// AgOS · TSP-1 · Шаг 1 · Животные (p1/wizard.jsx WizStep1).
// «Далее →» всегда активна; по нажатию — скролл к первому проблемному полю + янтарная подсветка.

import { useRef, useState } from 'react'
import type { WizState } from '../types/batch'
import { BREEDS, DISTRICTS, FATNESS } from '../data/tsp-dicts'
import { WizShell } from './WizShell'
import { StepperCtl } from '../components/StepperCtl'

function wizScrollTo(el: HTMLElement | null) {
  if (!el) return
  const sc = el.closest('.wiz-scroll') as HTMLElement | null
  if (!sc) return
  sc.scrollTo({
    top: el.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop - 10,
    behavior: 'smooth',
  })
}

interface Props {
  w: WizState
  sw: (patch: Partial<WizState>) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
}

export function WizStep1Animals({ w, sw, onNext, onBack, onExit }: Props) {
  const wErr = w.avgWeight < 100 || w.avgWeight > 800
  const aErr = w.age < 3 || w.age > 120
  const hErr = w.heads < 1 || w.heads > 500
  const [miss, setMiss] = useState<{ breed?: boolean; fatness?: boolean }>({})
  const breedRef = useRef<HTMLLabelElement>(null)
  const headsRef = useRef<HTMLDivElement>(null)
  const numsRef = useRef<HTMLDivElement>(null)
  const fatRef = useRef<HTMLDivElement>(null)

  const tryNext = () => {
    const m = { breed: !w.breed, fatness: !w.fatness }
    setMiss(m)
    const target = m.breed ? breedRef : hErr ? headsRef : (wErr || aErr) ? numsRef : m.fatness ? fatRef : null
    if (target) { wizScrollTo(target.current); return }
    onNext()
  }

  return (
    <WizShell step={1} onBack={onBack} onExit={onExit} title="Животные"
      sub="Опишите партию — по этим данным определится категория"
      cta="Далее →" onCta={tryNext}>
      <div className="kind-row">
        <span className="kr-k">вид</span>
        <span className="fix-badge">КРС</span>
        <span className="hint-inline">Пока продаём только крупный рогатый скот</span>
      </div>
      <label className={'field' + (miss.breed ? ' miss' : '')} ref={breedRef}>
        <div className="lab">порода</div>
        <span className="selwrap">
          <select className="fselect" value={w.breed} onChange={(e) => { sw({ breed: e.target.value }); setMiss((m) => ({ ...m, breed: false })) }}>
            <option value="">Выберите породу</option>
            {BREEDS.map((b) => <option key={b}>{b}</option>)}
          </select>
        </span>
      </label>
      {miss.breed && <div className="field-err amber">Выберите породу</div>}
      <div className={'field' + (hErr ? ' err' : '')} ref={headsRef}>
        <div className="lab">количество голов</div>
        <StepperCtl value={w.heads} onChange={(v) => sw({ heads: v })} min={1} max={500} />
      </div>
      {hErr && <div className="field-err">Голов обычно от 1 до 500.</div>}
      <div className="grid2" ref={numsRef}>
        <label className={'field nomb' + (wErr ? ' err' : '')}>
          <div className="lab">ср. вес головы, кг</div>
          <input className="finput mono" inputMode="numeric" value={w.avgWeight}
            onChange={(e) => sw({ avgWeight: parseInt(e.target.value.replace(/\D/g, '') || '0', 10) })} />
          <div className="hint">примерно, по вашей оценке</div>
        </label>
        <label className={'field nomb' + (aErr ? ' err' : '')}>
          <div className="lab">возраст, месяцев</div>
          <input className="finput mono" inputMode="numeric" value={w.age}
            onChange={(e) => sw({ age: parseInt(e.target.value.replace(/\D/g, '') || '0', 10) })} />
        </label>
      </div>
      {wErr && <div className="field-err">Вес обычно от 100 до 800 кг. Проверьте, не указали ли общий вес вместо среднего.</div>}
      {aErr && <div className="field-err">Возраст — от 3 до 120 месяцев.</div>}
      <div className="sep" />
      <div className={'field' + (miss.fatness ? ' miss' : '')} ref={fatRef}>
        <div className="lab">упитанность</div>
        <div className="fat-row">
          {FATNESS.map((f) => (
            <button key={f} className={'fat-card' + (w.fatness === f ? ' sel' : '')} onClick={() => { sw({ fatness: f }); setMiss((m) => ({ ...m, fatness: false })) }}>{f}</button>
          ))}
        </div>
      </div>
      {miss.fatness && <div className="field-err amber">Выберите упитанность</div>}
      <label className="field nomb">
        <div className="lab">район</div>
        <span className="selwrap">
          <select className="fselect" value={w.district} onChange={(e) => sw({ district: e.target.value })}>
            {DISTRICTS.map((d) => <option key={d}>{d}</option>)}
          </select>
        </span>
        <div className="hint">предзаполнен из профиля хозяйства</div>
      </label>
    </WizShell>
  )
}
