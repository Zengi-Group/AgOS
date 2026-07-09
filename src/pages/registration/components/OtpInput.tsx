import { useEffect, useRef } from 'react'
import { T } from '@/lib/auth-ui/tokens'

interface OtpInputProps {
  value: string
  onChange: (value: string) => void
  onComplete?: (value: string) => void
  error?: string
  disabled?: boolean
}

/**
 * OTP-ввод в дизайне прототипа: 6 отдельных клеток (mono, accent-рамка при
 * заполнении) с авто-переходом. Контракт props сохранён — Contact работает как прежде.
 */
export function OtpInput({ value, onChange, onComplete, error, disabled }: OtpInputProps) {
  const refs = useRef<Array<HTMLInputElement | null>>([])

  useEffect(() => {
    if (!disabled) refs.current[0]?.focus()
  }, [disabled])

  useEffect(() => {
    if (value.length === 6 && onComplete) onComplete(value)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value])

  const set = (i: number, v: string) => {
    const d = v.replace(/\D/g, '').slice(-1)
    const arr = value.split('')
    arr[i] = d
    const next = arr.join('').slice(0, 6)
    onChange(next)
    if (d && i < 5) refs.current[i + 1]?.focus()
  }

  const onKey = (i: number, e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Backspace' && !value[i] && i > 0) refs.current[i - 1]?.focus()
  }

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6, minmax(0, 1fr))', gap: 6 }}>
        {Array.from({ length: 6 }).map((_, i) => (
          <input
            key={i}
            ref={(el) => {
              refs.current[i] = el
            }}
            value={value[i] || ''}
            onChange={(e) => set(i, e.target.value)}
            onKeyDown={(e) => onKey(i, e)}
            inputMode="numeric"
            enterKeyHint="next"
            maxLength={1}
            disabled={disabled}
            style={{
              width: '100%',
              minWidth: 0,
              height: 56,
              padding: 0,
              textAlign: 'center',
              background: T.bgC,
              border: `1px solid ${error ? T.red : value[i] ? T.accent : T.bd}`,
              borderRadius: 12,
              color: T.fg,
              fontFamily: T.mono,
              fontSize: 22,
              fontWeight: 600,
              outline: 'none',
              boxSizing: 'border-box',
              transition: 'border-color 80ms',
            }}
          />
        ))}
      </div>
      {error && <div style={{ marginTop: 10, fontSize: 13, textAlign: 'center', color: T.red }}>{error}</div>}
    </div>
  )
}
