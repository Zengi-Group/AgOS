// AgOS · TSP-1 · Шаг 5 · Проверка и публикация — реcкин под прототип (market-wizard.jsx WizStep5):
// связный текст .mk-prose с точечным редактированием (goto) + .mk-pubwhen. Логика публикации
// (onPublish → BatchWizard.handlePublish: rpc_create_batch + автоматч) сохранена без изменений.

import type { ReactNode } from 'react'
import type { WizState } from '../types/batch'
import { NBSP, CATS } from '../data/tsp-dicts'
import { fmtD, fmtDGen, fmtMoney, publishInfo, wizWindow } from '../data/tsp-utils'
import { WizShell } from './WizShell'
import { MkCta } from '../components/MkCta'
import { PhIcon } from '../../components/icons/PhIcon'

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
  const total = w.heads * w.avgWeight * price

  // Инлайн-правка пункта: возвращает на нужный шаг (сохраняя черновик).
  const E = ({ to, children }: { to: number; children: ReactNode }) => (
    <button className="mk-prose-edit" onClick={() => goto(to)}>{children}<PhIcon name="pencil" size={11} /></button>
  )

  return (
    <WizShell step={5} onBack={onBack} onExit={onExit} title="Проверим перед публикацией." titleQ
      sub="Что-то нужно поправить — нажмите рядом с пунктом."
      footer={<>
        <MkCta disabled={isSubmitting} onClick={onPublish}>Опубликовать партию</MkCta>
        <button className="mk-link" onClick={onSaveDraft}>Сохранить черновик и выйти</button>
      </>}>
      <div className="mk-prose">
        <p>
          <E to={1}>{w.heads} голов</E> породы <E to={1}>{w.breed}</E>, средний вес <E to={1}>{w.avgWeight} кг</E>, возраст <E to={1}>{w.age} мес</E>, упитанность <E to={1}>{(w.fatness || '').toLowerCase()}</E>.
        </p>
        <p>
          Готовы к отгрузке <E to={2}>{fmtD(win.from)} — {fmtD(win.to)}</E>. Категория <span className="mk-prose-fix">{cat.name}</span>.
        </p>
        <p>
          Цена <E to={4}><span className="mk-mono">{fmtMoney(price)}{NBSP}₸/кг</span></E> — ориентировочная выручка <b className="mk-mono">{fmtMoney(total)}{NBSP}₸</b> за партию.
        </p>
      </div>
      <div className="mk-pubwhen">
        <span className="mk-sec-label">Выход в продажу</span>
        <div>{pi && pi.delayed && pi.at ? (<><b>{fmtDGen(pi.at)}</b> — за 7 дней до готовности</>) : (<>сразу после публикации</>)}</div>
      </div>
    </WizShell>
  )
}
