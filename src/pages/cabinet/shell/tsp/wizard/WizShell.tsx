// AgOS · TSP-1 · Обёртка шага визарда (p1/wizard.jsx WizShell) — full-screen, прогресс, назад/выйти, CTA.

import type { ReactNode } from 'react'
import { Cta } from '../../components/Cta'
import { WizProgress } from '../components/WizProgress'

const WIZ_LABELS = ['Животные', 'Готовность', 'Категория', 'Цена', 'Проверка']

interface WizShellProps {
  step: number
  onBack: () => void
  onExit: () => void
  title: string
  sub?: string
  cta?: string
  ctaDisabled?: boolean
  onCta?: () => void
  secondary?: string
  onSecondary?: () => void
  children: ReactNode
}

export function WizShell({ step, onBack, onExit, title, sub, cta, ctaDisabled, onCta, secondary, onSecondary, children }: WizShellProps) {
  return (
    <div className="phone" data-screen-label={'SCR-02 · мастер · шаг ' + step}>
      <div className="phone-body wiz-container">
        <WizProgress step={step} />
        <div className="h-back">
          <button className="linkbtn" onClick={onBack}><span className="arrow">‹</span> Назад</button>
          <span className="mono" style={{ fontSize: 10 }}>шаг {step}/5 · {WIZ_LABELS[step - 1]}</span>
          <button className="linkbtn" onClick={onExit}>Выйти ✕</button>
        </div>
        <h2 className="step-h1">{title}</h2>
        {sub && <div className="step-sub">{sub}</div>}
        <div className="wiz-scroll">{children}</div>
        {cta && <Cta disabled={ctaDisabled} onClick={onCta}>{cta}</Cta>}
        {secondary && <button className="link-skip" onClick={onSecondary}>{secondary}</button>}
        <div className="footnote mono">черновик сохраняется после каждого шага</div>
      </div>
    </div>
  )
}
