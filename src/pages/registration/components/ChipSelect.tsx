import { T } from '@/lib/auth-ui/tokens'

interface ChipOption {
  value: string
  label: string
}

interface ChipSelectProps {
  label: string
  options: ChipOption[]
  value: string[]
  onChange: (value: string[]) => void
  error?: string
}

/** Мульти-выбор чипами в дизайне прототипа (светлая «бумажная» тема). */
export function ChipSelect({ label, options, value, onChange, error }: ChipSelectProps) {
  const toggle = (optValue: string) => {
    if (value.includes(optValue)) onChange(value.filter((v) => v !== optValue))
    else onChange([...value, optValue])
  }

  return (
    <div>
      <div style={{ fontSize: 11, fontWeight: 500, letterSpacing: '.08em', textTransform: 'uppercase', color: T.fg3, marginBottom: 8, fontFamily: T.font }}>
        {label}
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {options.map((opt) => {
          const sel = value.includes(opt.value)
          return (
            <button
              key={opt.value}
              type="button"
              onClick={() => toggle(opt.value)}
              style={{
                padding: '9px 14px',
                borderRadius: 999,
                fontSize: 14,
                fontFamily: T.font,
                cursor: 'pointer',
                transition: 'all 120ms',
                background: sel ? T.cta : T.bgC,
                color: sel ? T.ctaFg : T.fg2,
                border: `1px solid ${sel ? T.cta : T.bd}`,
              }}
            >
              {opt.label}
            </button>
          )
        })}
      </div>
      {error && <div style={{ fontSize: 12, color: T.red, marginTop: 6 }}>{error}</div>}
    </div>
  )
}
