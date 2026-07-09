// AgOS · TSP-1 · Шаг 3 · Категория — реcкин под прототип (market-wizard.jsx WizStep3):
// загрузка (.mk-loader) → unknown (.mk-catcard) → ok (.mk-catcard + карточка сорта МПК).
// Определение категории — мок-таймаут 1400мс (не RPC). Сохранены useGradeFormula,
// deriveCategory/deriveMpkGrade и карточка сорта для покупателя (богаче прототипа).

import { useEffect } from 'react'
import type { WizState } from '../types/batch'
import { CATS } from '../data/tsp-dicts'
import { deriveCategory, deriveMpkGrade, mpkSortLabel } from '../data/tsp-utils'
import { useGradeFormula } from '@/hooks/useGradeFormula'
import { WizShell, DraftNote } from './WizShell'
import { MkCta } from '../components/MkCta'

interface Props {
  w: WizState
  sw: (patch: Partial<WizState>) => void
  onNext: () => void
  onBack: () => void
  onExit: () => void
  onTuran: () => void
}

export function WizStep3Category({ w, sw, onNext, onBack, onExit, onTuran }: Props) {
  useGradeFormula()
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
        <div className="mk-loader">
          <div className="mk-spin" />
          <div>Определяем категорию по вашим данным…</div>
        </div>
      </WizShell>
    )
  }

  if (w.catUnknown) {
    return (
      <WizShell step={3} onBack={onBack} onExit={onExit} title="Категория">
        <div className="mk-catcard unknown">
          <div className="mk-cc-h">Не получилось определить категорию</div>
          <div className="mk-cc-b">По указанным данным партия не подходит ни под одну категорию справочника. Такое бывает с редкими породами и нестандартными партиями.</div>
        </div>
        <div className="mk-sec-label" style={{ marginTop: 16 }}>Что делать</div>
        <p className="mk-cc-note">Проверьте вес и возраст — возможно, опечатка.</p>
        <MkCta variant="ghost" onClick={() => { sw({ catKey: null, catUnknown: false }); onBack() }}>Вернуться к данным</MkCta>
        <p className="mk-cc-note" style={{ marginTop: 14 }}>Если данные верны — напишите в TURAN, мы добавим категорию.</p>
        <MkCta variant="ghost" onClick={onTuran}>Написать в TURAN</MkCta>
        <div className="mk-note mk-mono" style={{ marginTop: 10 }}>черновик сохранён · публикация недоступна</div>
      </WizShell>
    )
  }

  const cat = CATS[w.catKey!]
  const mpkSort = deriveMpkGrade(w)
  return (
    <WizShell step={3} onBack={onBack} onExit={onExit} title="Категория"
      footer={<><MkCta onClick={onNext}>Далее</MkCta><DraftNote /></>}>
      <div className="mk-catcard">
        <div className="mk-cc-k">КАТЕГОРИЯ</div>
        <div className="mk-cc-name">{cat.name}</div>
        <div className="mk-cc-b">Определяется автоматически по породе, весу, возрасту и упитанности. Категорию нельзя выбрать вручную — так все партии оцениваются одинаково.</div>
      </div>
      {mpkSort && (
        <div className="mk-catcard" style={{ marginTop: 10 }}>
          <div className="mk-cc-k">СОРТ ДЛЯ ПОКУПАТЕЛЯ</div>
          <div className="mk-cc-name">{mpkSortLabel(mpkSort)}</div>
          <div className="mk-cc-b">По упитанности «{w.fatness}» мясокомбинаты видят вашу партию как сорт «{mpkSortLabel(mpkSort)}» и могут закупить именно эту категорию.</div>
        </div>
      )}
    </WizShell>
  )
}
