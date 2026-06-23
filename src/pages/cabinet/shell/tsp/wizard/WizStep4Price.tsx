// AgOS · TSP-1 · Шаг 4 · Цена (p1/wizard.jsx WizStep4).

import { useState } from 'react'
import type { WizState } from '../types/batch'
import { NBSP, CATS } from '../data/tsp-dicts'
import { fmtMoney } from '../data/tsp-utils'
import { WizShell } from './WizShell'

interface Props {
  w: WizState
  sw: (patch: Partial<WizState>) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
}

export function WizStep4Price({ w, sw, onNext, onBack, onExit }: Props) {
  const cat = CATS[w.catKey!]
  const price = parseInt(w.price || '0', 10)
  const low = price > 0 && price < cat.prot
  const valid = price > 0 && (!low || w.lowOk)
  const sum = w.heads * w.avgWeight * price
  const [miss, setMiss] = useState(false)
  const tryNext = () => { if (!valid) { setMiss(true); return } onNext() }

  return (
    <WizShell step={4} onBack={onBack} onExit={onExit} title="Цена"
      cta="Далее →" onCta={tryNext}>
      <div className="ref-block">
        <div className="rb-t">Рекомендуемая цена по категории «{cat.name}»: <b className="mono">{fmtMoney(cat.rec)}{NBSP}₸/кг</b></div>
        <div className="rb-disc">Справочная информация ассоциации. Не является обязательной — цену вы назначаете сами.</div>
      </div>
      <label className={'field price-field' + (miss && !(price > 0) ? ' miss' : '')}>
        <div className="lab">ваша цена, ₸/кг</div>
        <input className="finput mono big" inputMode="numeric" placeholder="0"
          value={w.price} onChange={(e) => { sw({ price: e.target.value.replace(/\D/g, '').slice(0, 5), lowOk: false }); setMiss(false) }} />
      </label>
      {miss && !(price > 0) && <div className="field-err amber">Укажите цену</div>}
      {price > 0 && (
        <div className="calc mono">≈ {w.heads} × {w.avgWeight} кг × {fmtMoney(price)} = <b>{fmtMoney(sum)}{NBSP}₸</b> за партию <span className="calc-note">(ориентировочно)</span></div>
      )}
      {low && (
        <div className="warn-panel">
          <div className="wp-t">Цена ниже защитной цены ассоциации — {fmtMoney(cat.prot)}{NBSP}₸/кг</div>
          <div className="wp-b">Защитная цена — это уровень, ниже которого ассоциация не рекомендует продавать. Вы можете опубликовать и по своей цене.</div>
          <button className={'cb-row warn' + (miss && !w.lowOk ? ' miss' : '')} onClick={() => { sw({ lowOk: !w.lowOk }); setMiss(false) }}>
            <div className={'cb-box' + (w.lowOk ? ' ch' : '')}>{w.lowOk ? '✓' : ''}</div>
            <div>Понимаю и подтверждаю цену {fmtMoney(price)}{NBSP}₸/кг</div>
          </button>
          {miss && !w.lowOk && <div className="field-err amber" style={{ marginBottom: 0 }}>Подтвердите цену, чтобы продолжить</div>}
        </div>
      )}
    </WizShell>
  )
}
