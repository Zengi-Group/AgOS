// AgOS · TSP-1 · Обёртка шага визарда — реcкин под прототип (market-wizard.jsx WizTop + ShellFrame).
// Рендерится ВНУТРИ внешнего <IonPage className="agos-flow-page"> (CabinetApp.renderMarket, slide-up),
// поэтому даёт IonContent (скролл .phone-scroll) + WizTop + заголовок + контент + док-футер .sh-foot.
// Свой WizTop (.mk-wiz-bar), не SubHead — у визарда собственная прогресс-шапка.

import type { ReactNode } from 'react'
import { IonContent } from '@ionic/react'
import { WizProgress } from '../components/WizProgress'
import { PhIcon } from '../../components/icons/PhIcon'

const WIZ_LABELS = ['Животные', 'Готовность', 'Категория', 'Цена', 'Проверка']

// Подпись «черновик сохраняется после каждого шага» — под CTA в футере (useBatchDraft).
export function DraftNote() {
  return <div className="mk-note mk-mono">черновик сохраняется после каждого шага</div>
}

function WizTop({ step, onBack, onExit }: { step: number; onBack: () => void; onExit: () => void }) {
  return (
    <>
      <div className="mk-wiz-bar">
        <button className="mk-wiz-back" onClick={onBack} aria-label="Назад"><PhIcon name="chevronLeft" size={18} /></button>
        <WizProgress step={step} />
        <button className="mk-wiz-exit" onClick={onExit} aria-label="Выйти"><PhIcon name="x" size={16} /></button>
      </div>
      <div className="mk-wiz-step mk-mono">шаг {step} из 5 · {WIZ_LABELS[step - 1]}</div>
    </>
  )
}

interface WizShellProps {
  step: number
  onBack: () => void
  onExit: () => void
  title: string
  titleQ?: boolean          // .q — акцентный заголовок-вопрос (шаг 5)
  sub?: string
  footer?: ReactNode        // содержимое док-футера .sh-foot (CTA + подпись/ссылка)
  children: ReactNode
}

export function WizShell({ step, onBack, onExit, title, titleQ, sub, footer, children }: WizShellProps) {
  return (
    <>
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk mk-pt" data-screen-label={'SCR-02 · мастер · шаг ' + step}>
            <WizTop step={step} onBack={onBack} onExit={onExit} />
            <h1 className={'mk-h1' + (titleQ ? ' q' : '')}>{title}</h1>
            {sub && <p className="mk-sub">{sub}</p>}
            {children}
          </div>
        </div>
      </IonContent>
      {footer && <div className="sh-foot">{footer}</div>}
    </>
  )
}
