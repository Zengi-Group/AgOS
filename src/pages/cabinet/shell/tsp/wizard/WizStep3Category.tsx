// AgOS · TSP-1 · Шаг 3 · Категория (p1/wizard.jsx WizStep3) — загрузка → unknown → ok.

import { useEffect } from 'react'
import type { WizState } from '../types/batch'
import { CATS } from '../data/tsp-dicts'
import { deriveCategory, deriveMpkGrade, MPK_SORT_LABEL } from '../data/tsp-utils'
import { WizShell } from './WizShell'
import { Cta } from '../../components/Cta'

interface Props {
  w: WizState
  sw: (patch: Partial<WizState>) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
  onTuran: () => void
}

export function WizStep3Category({ w, sw, onNext, onBack, onExit, onTuran }: Props) {
  // запустить определение, если категория ещё не определена
  useEffect(() => {
    if (!w.catKey && !w.catUnknown && !w.catLoading) sw({ catLoading: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // мок-определение с задержкой 1400 мс
  useEffect(() => {
    if (!w.catLoading) return
    const t = setTimeout(() => {
      const k = deriveCategory(w)
      sw({ catLoading: false, catKey: k, catUnknown: !k })
    }, 1400)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [w.catLoading])

  if (w.catLoading || (!w.catKey && !w.catUnknown)) {
    return (
      <WizShell step={3} onBack={onBack} onExit={onExit} title="Категория">
        <div className="cat-loader">
          <div className="spin" />
          <div>Определяем категорию по вашим данным…</div>
        </div>
      </WizShell>
    )
  }

  if (w.catUnknown) {
    return (
      <WizShell step={3} onBack={onBack} onExit={onExit} title="Категория">
        <div className="cat-card unknown">
          <div className="cc-h">Не получилось определить категорию</div>
          <div className="cc-b">По указанным данным партия не подходит ни под одну категорию справочника. Такое бывает с редкими породами и нестандартными партиями.</div>
        </div>
        <div className="sep" />
        <div className="cc-what mono">ЧТО ДЕЛАТЬ</div>
        <div className="cc-b" style={{ margin: '4px 2px 8px' }}>Проверьте вес и возраст — возможно, опечатка.</div>
        <Cta variant="ghost" onClick={() => { sw({ catKey: null, catUnknown: false }); onBack() }}>Вернуться к данным</Cta>
        <div className="cc-b" style={{ margin: '10px 2px 8px' }}>Если данные верны — напишите в TURAN, мы добавим категорию.</div>
        <Cta variant="ghost" onClick={onTuran}>Написать в TURAN</Cta>
        <div className="footnote mono">черновик сохранён · публикация недоступна</div>
      </WizShell>
    )
  }

  const cat = CATS[w.catKey!]
  const mpkSort = deriveMpkGrade(w)
  return (
    <WizShell step={3} onBack={onBack} onExit={onExit} title="Категория"
      cta="Далее →" onCta={onNext}>
      <div className="cat-card ok">
        <div className="cc-k mono">КАТЕГОРИЯ</div>
        <div className="cc-name">{cat.name}</div>
        <div className="cc-b">Определяется автоматически по породе, весу, возрасту и упитанности. Категорию нельзя выбрать вручную — так все партии оцениваются одинаково.</div>
      </div>
      {mpkSort && (
        <div className="cat-card ok" style={{ marginTop: 10 }}>
          <div className="cc-k mono">СОРТ ДЛЯ ПОКУПАТЕЛЯ</div>
          <div className="cc-name">{MPK_SORT_LABEL[mpkSort]}</div>
          <div className="cc-b">По упитанности «{w.fatness}» мясокомбинаты видят вашу партию как сорт «{MPK_SORT_LABEL[mpkSort]}» и могут закупить именно эту категорию.</div>
        </div>
      )}
    </WizShell>
  )
}
