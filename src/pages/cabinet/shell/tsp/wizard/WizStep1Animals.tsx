// AgOS · TSP-1 · Шаг 1 · Животные — реcкин под прототип (market-wizard.jsx WizStep1).
// «Далее» всегда активна; по нажатию — скролл к первому проблемному полю + подсветка .mk-miss.

import { useRef, useState } from 'react'
import type { WizState } from '../types/batch'
import { BREEDS, FATNESS } from '../data/tsp-dicts'
import { WizShell, DraftNote } from './WizShell'
import { StepperCtl } from '../components/StepperCtl'
import { MkField } from '../components/MkField'
import { MkSelect } from '../components/MkSelect'
import { MkErr } from '../components/MkErr'
import { MkCta } from '../components/MkCta'
import { useShell } from '../../context'

// Скролл к проблемному полю. Контент живёт в <ion-content> (shadow-скроллер),
// поэтому используем его scrollToPoint; фоллбэк — обычный .phone-scroll.
function wizScrollTo(el: HTMLElement | null) {
  if (!el) return
  const content = el.closest('ion-content') as
    | (HTMLElement & { getScrollElement?: () => Promise<HTMLElement>; scrollToPoint?: (x: number, y: number, dur: number) => void })
    | null
  if (content?.getScrollElement && content.scrollToPoint) {
    content.getScrollElement().then((se) => {
      const top = el.getBoundingClientRect().top - se.getBoundingClientRect().top + se.scrollTop - 12
      content.scrollToPoint!(0, top, 300)
    })
    return
  }
  const sc = el.closest('.phone-scroll') as HTMLElement | null
  if (!sc) return
  sc.scrollTo({
    top: el.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop - 12,
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
  const { farmRegion } = useShell()
  const wErr = w.avgWeight < 100 || w.avgWeight > 800
  const aErr = w.age < 3 || w.age > 120
  const hErr = w.heads < 1 || w.heads > 500
  const [miss, setMiss] = useState<{ breed?: boolean; fatness?: boolean }>({})
  const breedRef = useRef<HTMLDivElement>(null)
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
      footer={<><MkCta onClick={tryNext}>Далее</MkCta><DraftNote /></>}>
      <div className="mk-kindrow">
        <span className="mk-lab" style={{ marginBottom: 0 }}>Вид</span>
        <span className="mk-fixbadge">КРС</span>
        <span className="mk-kindhint">Пока продаём только крупный рогатый скот</span>
      </div>
      <div ref={breedRef} className={miss.breed ? 'mk-miss' : ''}>
        <MkSelect label="Порода" placeholder="Выберите породу" options={BREEDS} value={w.breed} miss={miss.breed}
          onChange={(e) => { sw({ breed: e.target.value }); setMiss((m) => ({ ...m, breed: false })) }} />
      </div>
      {miss.breed && <MkErr amber>Выберите породу</MkErr>}
      <div ref={headsRef}>
        <MkField label="Количество голов" err={hErr}>
          <StepperCtl value={w.heads} onChange={(v) => sw({ heads: v })} min={1} max={500} />
        </MkField>
      </div>
      {hErr && <MkErr>Голов обычно от 1 до 500.</MkErr>}
      <div className="mk-grid2" ref={numsRef}>
        <MkField label="Ср. вес головы, кг" hint="примерно, по вашей оценке" err={wErr}>
          <input className="mk-input mk-mono" inputMode="numeric" value={w.avgWeight}
            onChange={(e) => sw({ avgWeight: parseInt(e.target.value.replace(/\D/g, '') || '0', 10) })} />
        </MkField>
        <MkField label="Возраст, месяцев" err={aErr}>
          <input className="mk-input mk-mono" inputMode="numeric" value={w.age}
            onChange={(e) => sw({ age: parseInt(e.target.value.replace(/\D/g, '') || '0', 10) })} />
        </MkField>
      </div>
      {wErr && <MkErr>Вес обычно от 100 до 800 кг. Проверьте, не указали ли общий вес вместо среднего.</MkErr>}
      {aErr && <MkErr>Возраст — от 3 до 120 месяцев.</MkErr>}
      <div ref={fatRef} className={miss.fatness ? 'mk-miss' : ''}>
        <MkField label="Упитанность">
          <div className="mk-fat">
            {FATNESS.map((f) => (
              <button key={f} className={'mk-fat-c' + (w.fatness === f ? ' sel' : '')} onClick={() => { sw({ fatness: f }); setMiss((m) => ({ ...m, fatness: false })) }}>{f}</button>
            ))}
          </div>
        </MkField>
      </div>
      {miss.fatness && <MkErr amber>Выберите упитанность</MkErr>}
      {/* Регион НЕ выбирается фермером — берётся из профиля хозяйства (см. BatchWizard.handlePublish). */}
      <div className="mk-kindrow" style={{ marginTop: 4 }}>
        <span className="mk-lab" style={{ marginBottom: 0 }}>Регион</span>
        <span className="mk-fixbadge">{farmRegion || 'из профиля хозяйства'}</span>
      </div>
    </WizShell>
  )
}
