/**
 * Общие UI-примитивы вход-фаннела (Welcome / Register / Login / Membership).
 * Портировано 1:1 из прототипа agos-farmer (routes/register.tsx, login.tsx).
 * Светлая «бумажная» тема из T (auth-ui/tokens.ts). Только презентация — без логики.
 */
import type { CSSProperties, ReactNode } from 'react'
import { T } from './tokens'

/* ── Внешний контейнер экрана (fixed, safe-area, maxWidth 480) ──────── */
export function AuthShell({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        position: 'fixed',
        inset: 0,
        background: T.bg,
        color: T.fg,
        fontFamily: T.font,
        WebkitFontSmoothing: 'antialiased',
        display: 'flex',
        justifyContent: 'center',
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          width: '100%',
          maxWidth: 480,
          display: 'flex',
          flexDirection: 'column',
          paddingTop: 'env(safe-area-inset-top)',
          paddingBottom: 'env(safe-area-inset-bottom)',
        }}
      >
        {children}
      </div>
    </div>
  )
}

/* Скролл-контент под TopBar с местом под StickyDock */
export function AuthBody({ children }: { children: ReactNode }) {
  return <div style={{ flex: 1, overflowY: 'auto', padding: '8px 20px 140px' }}>{children}</div>
}

export const iconBtnStyle: CSSProperties = {
  width: 44,
  height: 44,
  display: 'grid',
  placeItems: 'center',
  background: 'transparent',
  border: 'none',
  color: T.fg,
  cursor: 'pointer',
  borderRadius: 999,
  WebkitTapHighlightColor: 'transparent',
  touchAction: 'manipulation',
}

export function Chevron() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M15 18l-6-6 6-6" />
    </svg>
  )
}

export function Check({ size = 12, stroke = T.ctaFg, width = 3 }: { size?: number; stroke?: string; width?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={stroke} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 6L9 17l-5-5" />
    </svg>
  )
}

/**
 * iOS-style навбар (44pt). Заголовок центрирован; back слева абсолютно, чтобы
 * заголовок не смещался. Если переданы idx/total — рисуется сегментный прогресс
 * и счётчик N/total (режим регистрации). Без них — простой режим (логин).
 */
export function TopBar({
  label,
  onBack,
  idx,
  total,
  showCounter = true,
  hideBack = false,
}: {
  label: string
  onBack: () => void
  idx?: number
  total?: number
  showCounter?: boolean
  hideBack?: boolean
}) {
  const hasProgress = typeof idx === 'number' && typeof total === 'number'
  return (
    <div
      style={{
        position: 'sticky',
        top: 0,
        zIndex: 5,
        background: `color-mix(in oklab, ${T.bg} 82%, transparent)`,
        backdropFilter: 'saturate(180%) blur(20px)',
        WebkitBackdropFilter: 'saturate(180%) blur(20px)',
        borderBottom: `0.5px solid ${T.bdS}`,
        userSelect: 'none',
        WebkitUserSelect: 'none',
      }}
    >
      <div style={{ position: 'relative', height: 44, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        {!hideBack && (
          <button onClick={onBack} aria-label="Назад" style={{ ...iconBtnStyle, position: 'absolute', left: 4, top: '50%', transform: 'translateY(-50%)' }}>
            <Chevron />
          </button>
        )}
        <div
          style={{
            fontSize: 17,
            fontWeight: 600,
            color: T.fg,
            letterSpacing: '-0.01em',
            lineHeight: 1,
            maxWidth: '60%',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >
          {label}
        </div>
        {hasProgress && showCounter && !hideBack && (
          <div style={{ position: 'absolute', right: 16, top: '50%', transform: 'translateY(-50%)', fontSize: 12, color: T.fg3, fontFamily: T.mono, letterSpacing: '.02em' }}>
            {idx! + 1}/{total}
          </div>
        )}
      </div>
      {hasProgress && (
        <div style={{ display: 'flex', gap: 3, padding: '0 16px 8px' }}>
          {Array.from({ length: total! }).map((_, i) => (
            <div
              key={i}
              style={{
                flex: 1,
                height: 2,
                borderRadius: 2,
                background: i <= idx! ? T.accent : T.bd,
                transition: 'background 240ms cubic-bezier(0.16,1,0.3,1)',
              }}
            />
          ))}
        </div>
      )}
    </div>
  )
}

export function H1({ children }: { children: ReactNode }) {
  // fontFamily задаём явно: глобальное правило h1 { font-family: 'PT Serif' }
  // из базового слоя иначе перебивает наследуемый Geist.
  return <h1 style={{ fontFamily: T.font, fontSize: 28, lineHeight: 1.15, letterSpacing: '-0.02em', fontWeight: 600, margin: '20px 0 8px' }}>{children}</h1>
}

export function Lede({ children }: { children: ReactNode }) {
  return <p style={{ fontFamily: T.font, fontSize: 15, lineHeight: 1.45, color: T.fg2, margin: '0 0 28px', maxWidth: 340 }}>{children}</p>
}

/* Прижатая к низу зона с CTA (градиентный фейд) */
export function StickyDock({ children }: { children: ReactNode }) {
  return (
    <div
      style={{
        position: 'fixed',
        left: 0,
        right: 0,
        bottom: 0,
        padding: '12px 20px calc(20px + env(safe-area-inset-bottom))',
        background: `linear-gradient(180deg, transparent 0%, ${T.bg} 40%)`,
        pointerEvents: 'none',
        display: 'flex',
        justifyContent: 'center',
      }}
    >
      <div style={{ width: '100%', maxWidth: 440, pointerEvents: 'auto' }}>{children}</div>
    </div>
  )
}

export function CTA({
  disabled,
  onClick,
  children,
  variant = 'primary',
  type,
}: {
  disabled?: boolean
  onClick?: () => void
  children: ReactNode
  variant?: 'primary' | 'ghost'
  type?: 'button' | 'submit'
}) {
  const isPrimary = variant === 'primary'
  return (
    <button
      type={type ?? 'button'}
      onClick={onClick}
      disabled={disabled}
      style={{
        width: '100%',
        height: 52,
        borderRadius: 12,
        border: isPrimary ? 'none' : `1px solid ${T.bd}`,
        background: disabled ? T.bgM : isPrimary ? T.cta : 'transparent',
        color: disabled ? T.fg3 : isPrimary ? T.ctaFg : T.fg,
        fontFamily: T.font,
        fontSize: 16,
        fontWeight: 600,
        letterSpacing: '-0.01em',
        cursor: disabled ? 'not-allowed' : 'pointer',
        transition: 'background 80ms',
      }}
    >
      {children}
    </button>
  )
}

/* iOS-inline поле: uppercase-лейбл + контент + подсказка */
export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 11, fontWeight: 500, letterSpacing: '.08em', textTransform: 'uppercase', color: T.fg3, marginBottom: 8 }}>{label}</div>
      {children}
      {hint && <div style={{ fontSize: 12, color: T.fg3, marginTop: 6 }}>{hint}</div>}
    </div>
  )
}

export const inputStyle: CSSProperties = {
  width: '100%',
  height: 52,
  padding: '0 16px',
  background: T.bgC,
  border: `1px solid ${T.bd}`,
  borderRadius: 12,
  color: T.fg,
  fontFamily: T.font,
  fontSize: 17,
  fontWeight: 500,
  letterSpacing: '-0.01em',
  outline: 'none',
  transition: 'border-color 80ms',
  boxSizing: 'border-box',
}

/**
 * PIN/код ячейки (6 клеток-точек) + скрытый input для нативной цифровой
 * клавиатуры. value/onChange управляются извне. error/mismatch → красный.
 */
export function PinCells({
  value,
  error = false,
  length = 6,
}: {
  value: string
  error?: boolean
  length?: number
}) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: `repeat(${length}, minmax(0, 1fr))`, gap: 8, marginTop: 24, maxWidth: 360, alignSelf: 'center', width: '100%' }}>
      {Array.from({ length }).map((_, i) => {
        const filled = i < value.length
        const borderColor = error ? T.red : filled ? T.accent : T.bd
        return (
          <div key={i} style={{ height: 60, borderRadius: 14, background: T.bgC, border: `1px solid ${borderColor}`, display: 'grid', placeItems: 'center', transition: 'border-color 120ms' }}>
            {filled && <div style={{ width: 12, height: 12, borderRadius: 999, background: error ? T.red : T.fg }} />}
          </div>
        )
      })}
    </div>
  )
}
