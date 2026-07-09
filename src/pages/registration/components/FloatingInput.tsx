import { useState, useRef } from 'react'
import { T } from '@/lib/auth-ui/tokens'

interface FloatingInputProps {
  label: string
  value: string
  onChange: (value: string) => void
  type?: string
  maxLength?: number
  error?: string
  disabled?: boolean
  className?: string
  autoAdvanceAt?: number // blur input when value reaches this length
}

/**
 * Плавающий лейбл в дизайне прототипа (светлая «бумажная» тема, Geist).
 * Поведение сохранено (floating label, autoAdvanceAt).
 */
export function FloatingInput({
  label,
  value,
  onChange,
  type = 'text',
  maxLength,
  error,
  disabled,
  className,
  autoAdvanceAt,
}: FloatingInputProps) {
  const [focused, setFocused] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const hasValue = value.length > 0
  const floated = focused || hasValue

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = e.target.value
    onChange(val)
    if (autoAdvanceAt && val.length >= autoAdvanceAt) {
      setTimeout(() => inputRef.current?.blur(), 80)
    }
  }

  return (
    <div className={className} style={{ position: 'relative' }}>
      <input
        ref={inputRef}
        type={type}
        value={value}
        onChange={handleChange}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        maxLength={maxLength}
        disabled={disabled}
        className="reg-input"
        style={{
          width: '100%',
          height: 56,
          padding: '20px 16px 8px',
          background: T.bgC,
          border: `1px solid ${error ? T.red : focused ? T.fg : T.bd}`,
          borderRadius: 12,
          color: T.fg,
          fontFamily: T.font,
          fontWeight: 500,
          letterSpacing: '-0.01em',
          outline: 'none',
          transition: 'border-color 80ms',
          boxSizing: 'border-box',
          opacity: disabled ? 0.5 : 1,
        }}
      />
      <label
        style={{
          position: 'absolute',
          left: 16,
          pointerEvents: 'none',
          transition: 'all 160ms',
          color: T.fg3,
          fontFamily: T.font,
          top: floated ? 8 : 17,
          fontSize: floated ? 11 : 16,
          fontWeight: floated ? 500 : 400,
          letterSpacing: floated ? '.06em' : 0,
          textTransform: floated ? 'uppercase' : 'none',
        }}
      >
        {label}
      </label>
      {error && <div style={{ fontSize: 12, color: T.red, marginTop: 6, paddingLeft: 4 }}>{error}</div>}
    </div>
  )
}
