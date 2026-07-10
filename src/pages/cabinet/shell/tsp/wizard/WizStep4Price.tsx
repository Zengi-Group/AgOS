// AgOS · TSP-1 · Шаг 4 · Цена — реcкин под прототип (market-wizard.jsx WizStep4).
// Сохранены: защитный пол по сорту МПК (mpkSortFloor), lowOk-подтверждение,
// дисклеймер ст.171 (.mk-ref-d — справочная, не обязательная цена).

import { useState } from 'react'
import type { WizState } from '../types/batch'
import { NBSP, CATS } from '../data/tsp-dicts'
import { fmtMoney, deriveMpkGrade, mpkSortFloor, mpkSortLabel } from '../data/tsp-utils'
import { useGradeFormula } from '@/hooks/useGradeFormula'
import { WizShell, DraftNote } from './WizShell'
import { MkField } from '../components/MkField'
import { MkErr } from '../components/MkErr'
import { MkCta } from '../components/MkCta'
import { CheckRow } from '../components/CheckRow'

interface Props {
  w: WizState
  sw: (patch: Partial<WizState>) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
}

export function WizStep4Price({ w, sw, onNext, onBack, onExit }: Props) {
  useGradeFormula()
  const cat = CATS[w.catKey!]
  // Защитный пол — по сорту МПК (единый источник правды для фермера и МПК).
  // Если сорт не определяется (нестандартная упитанность) — падаем на пол категории.
  const mpkSort = deriveMpkGrade(w)
  const floor = mpkSort ? mpkSortFloor(mpkSort) : cat.prot
  const price = parseInt(w.price || '0', 10)
  const low = price > 0 && price < floor
  const valid = price > 0 && (!low || w.lowOk)
  const sum = w.heads * w.avgWeight * price
  const [miss, setMiss] = useState(false)
  const tryNext = () => { if (!valid) { setMiss(true); return } onNext() }

  return (
    <WizShell step={4} onBack={onBack} onExit={onExit} title="Цена"
      footer={<><MkCta onClick={tryNext}>Далее</MkCta><DraftNote /></>}>
      <div className="mk-ref">
        <div className="mk-ref-t">Рекомендуемая цена по категории «{cat.name}»: <b className="mk-mono">{fmtMoney(cat.rec)}{NBSP}₸/кг</b></div>
        <div className="mk-ref-d">Справочная информация ассоциации. Не является обязательной — цену вы назначаете сами.</div>
      </div>
      <MkField label="Ваша цена, ₸/кг" miss={miss && !(price > 0)}>
        <input className="mk-input mk-mono price" inputMode="numeric" placeholder="0"
          value={w.price} onChange={(e) => { sw({ price: e.target.value.replace(/\D/g, '').slice(0, 5), lowOk: false }); setMiss(false) }} />
      </MkField>
      {miss && !(price > 0) && <MkErr amber>Укажите цену</MkErr>}
      {price > 0 && (
        <div className="mk-calc"><span className="mk-mono">≈ {w.heads} × {w.avgWeight} кг × {fmtMoney(price)} = <b>{fmtMoney(sum)}{NBSP}₸</b></span> за партию <span className="mk-calc-n">(ориентировочно)</span></div>
      )}
      {low && (
        <div className="mk-warn">
          <div className="mk-warn-t">Цена ниже защитной цены ассоциации — {fmtMoney(floor)}{NBSP}₸/кг</div>
          <div className="mk-warn-b">{mpkSort ? `Защитная цена сорта «${mpkSortLabel(mpkSort)}» — это уровень, ниже которого ассоциация не рекомендует продавать. ` : 'Защитная цена — это уровень, ниже которого ассоциация не рекомендует продавать. '}Вы можете опубликовать и по своей цене.</div>
          <div className={miss && !w.lowOk ? 'mk-miss' : ''}>
            <CheckRow warn checked={w.lowOk} onClick={() => { sw({ lowOk: !w.lowOk }); setMiss(false) }}>Понимаю и подтверждаю цену {fmtMoney(price)}{NBSP}₸/кг</CheckRow>
          </div>
          {miss && !w.lowOk && <MkErr amber>Подтвердите цену, чтобы продолжить</MkErr>}
        </div>
      )}
    </WizShell>
  )
}
