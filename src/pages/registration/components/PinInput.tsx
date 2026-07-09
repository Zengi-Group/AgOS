import { useEffect, useRef } from 'react'
import { T } from '@/lib/auth-ui/tokens'
import { PinCells } from '@/lib/auth-ui/primitives'

interface PinInputProps {
  value: string
  onChange: (value: string) => void
  onComplete?: (value: string) => void
  label?: string
  error?: string
  disabled?: boolean
}

/**
 * PIN-ввод в дизайне прототипа (светлая «бумажная» тема): 6 клеток-точек +
 * скрытый input для нативной цифровой клавиатуры. Контракт props сохранён
 * (value/onChange/onComplete/label/error/disabled) — CreatePin работает как прежде.
 */
export function PinInput({ value, onChange, onComplete, label, error, disabled }: PinInputProps) {
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!disabled) inputRef.current?.focus()
  }, [disabled])

  const handleChange = (val: string) => {
    const clean = val.replace(/\D/g, '').slice(0, 6)
    onChange(clean)
    if (clean.length === 6 && onComplete) onComplete(clean)
  }

  return (
    <div onClick={() => inputRef.current?.focus()} style={{ display: 'flex', flexDirection: 'column', cursor: 'text' }}>
      {label && (
        <div style={{ fontSize: 11, fontWeight: 500, letterSpacing: '.08em', textTransform: 'uppercase', color: T.fg3, textAlign: 'center' }}>
          {label}
        </div>
      )}
      <PinCells value={value} error={!!error} />
      <div style={{ minHeight: 20, marginTop: 14, color: T.red, fontSize: 13, textAlign: 'center' }}>{error}</div>
      <input
        ref={inputRef}
        type="tel"
        inputMode="numeric"
        enterKeyHint="done"
        pattern="[0-9]*"
        autoComplete="one-time-code"
        maxLength={6}
        value={value}
        disabled={disabled}
        onChange={(e) => handleChange(e.target.value)}
        style={{ position: 'absolute', opacity: 0, pointerEvents: 'none', width: 1, height: 1, border: 0, padding: 0, margin: 0 }}
      />
    </div>
  )
}
