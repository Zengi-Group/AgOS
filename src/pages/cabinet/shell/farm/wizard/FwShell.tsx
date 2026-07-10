// AgOS · ARS-212 · Каркас шага мастера фермы. Тонкая обёртка на тех же mk-классах, что и
// tsp/wizard/WizShell (§5: допустимая альтернатива обобщению — TSP не трогаем, HS-1/5).
// Рендерится ВНУТРИ внешнего <IonPage className="agos-flow-page"> (CabinetApp.renderFarm,
// slide-up, как BatchWizard): даёт IonContent + шапку + заголовок + контент + док-футер .sh-foot.
//
// Ярусная прогресс-модель (D-FW-1): F1 — wiz-bar без точек; ярус 2 (F3–F5) — WizProgress по
// ветке (count/step); Payoff/финал — без wiz-bar (передаются bar=false).

import type { ReactNode } from 'react'
import { IonContent } from '@ionic/react'
import { WizProgress } from '../../tsp/components/WizProgress'
import { PhIcon } from '../../components/icons/PhIcon'

// Строка-подпись «сохраняется после каждого ответа» — под CTA в футере (useFarmDraft, P11).
export function DraftNote() {
  return <div className="mk-note">сохраняется после каждого ответа</div>
}

interface FwShellProps {
  onExit: () => void
  onBack?: () => void            // задан → стрелка «назад» в wiz-bar (иначе скрыта)
  bar?: boolean                  // true → полная wiz-bar (F1/F3–F5)
  exitTop?: boolean              // bar=false, но нужен X справа сверху (Payoff-1)
  progress?: { count: number; step: number }  // ярус 2: точки по ветке (omit → без точек)
  stepLabel?: string             // mk-wiz-step (mono)
  titleIcon?: ReactNode          // тихая иконка-идентичность над заголовком (PhIcon, fg3)
  title?: string
  titleQ?: boolean               // .q — акцентный заголовок-вопрос
  sub?: string
  footer?: ReactNode
  screenLabel?: string
  children: ReactNode
}

export function FwShell({
  onExit, onBack, bar, exitTop, progress, stepLabel, titleIcon, title, titleQ, sub, footer, screenLabel, children,
}: FwShellProps) {
  return (
    <>
      <IonContent className="agos-ion-content">
        <div className="phone-scroll">
          <div className="mk mk-pt" data-screen-label={screenLabel}>
            {bar && (
              <>
                <div className="mk-wiz-bar">
                  {onBack
                    ? <button className="mk-wiz-back" onClick={onBack} aria-label="Назад"><PhIcon name="chevronLeft" size={18} /></button>
                    : <span style={{ width: 36 }} />}
                  {progress
                    ? <WizProgress step={progress.step} count={progress.count} />
                    : <span style={{ flex: 1 }} />}
                  <button className="mk-wiz-exit" onClick={onExit} aria-label="Выйти"><PhIcon name="x" size={16} /></button>
                </div>
                {stepLabel && <div className="mk-wiz-step">{stepLabel}</div>}
              </>
            )}
            {!bar && exitTop && (
              <div className="fw-exit-row">
                <button className="mk-wiz-exit" onClick={onExit} aria-label="Выйти"><PhIcon name="x" size={16} /></button>
              </div>
            )}
            {titleIcon && <div className="fw-title-icon">{titleIcon}</div>}
            {title && <h1 className={'mk-h1' + (titleQ ? ' q' : '')}>{title}</h1>}
            {sub && <p className="mk-sub">{sub}</p>}
            {children}
          </div>
        </div>
      </IonContent>
      {footer && <div className="sh-foot">{footer}</div>}
    </>
  )
}
