// AgOS · TSP-1 · Шаг 5 · Проверка и публикация (p1/wizard.jsx WizStep5).

import type { WizState } from '../types/batch'
import { NBSP, CATS } from '../data/tsp-dicts'
import { fmtD, fmtDGen, fmtMoney, publishInfo, wizWindow } from '../data/tsp-utils'
import { WizShell } from './WizShell'
import { KV } from '../components/KV'

interface Props {
  w: WizState
  onPublish: () => void
  onSaveDraft: () => void
  onBack: () => void
  onExit: () => void
  goto: (step: number) => void
  isSubmitting: boolean
}

export function WizStep5Review({ w, onPublish, onSaveDraft, onBack, onExit, goto, isSubmitting }: Props) {
  const cat = CATS[w.catKey!]
  const win = wizWindow(w)!
  const pi = publishInfo(win)
  const price = parseInt(w.price, 10)

  return (
    <WizShell step={5} onBack={onBack} onExit={onExit} title="Проверка и публикация"
      cta="Опубликовать партию" ctaDisabled={isSubmitting} onCta={onPublish}
      secondary="Сохранить черновик и выйти" onSecondary={onSaveDraft}>
      <div className="sum-card">
        <KV k="ЖИВОТНЫЕ" onEdit={() => goto(1)}>{w.breed} · {w.heads} голов · ср. {w.avgWeight} кг · {w.age} мес · {w.fatness.toLowerCase()}</KV>
        <KV k="ОКНО ОТГРУЗКИ" onEdit={() => goto(2)}>{fmtD(win.from)} — {fmtD(win.to)}</KV>
        <KV k="КАТЕГОРИЯ">{cat.name}</KV>
        <KV k="ЦЕНА" onEdit={() => goto(4)}><span className="mono">{fmtMoney(price)}{NBSP}₸/кг</span></KV>
        <KV k="ИТОГО ≈"><b className="mono">{fmtMoney(w.heads * w.avgWeight * price)}{NBSP}₸</b> <span className="hint-inline">ориентировочно</span></KV>
      </div>
      <div className="pub-when">
        Выйдет в продажу: <b>{pi && pi.delayed && pi.at ? fmtDGen(pi.at) + ' (за 7 дней до готовности)' : 'сразу после публикации'}</b>
      </div>
    </WizShell>
  )
}
