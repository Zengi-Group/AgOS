import { useEffect } from 'react'
import { X, Check } from 'lucide-react'
import { T } from '@/lib/auth-ui/tokens'

interface BottomSheetOption {
  value: string
  label: string
}

interface BottomSheetProps {
  open: boolean
  onClose: () => void
  title: string
  options: BottomSheetOption[]
  value: string
  onChange: (value: string) => void
}

/** Селектор-шторка в дизайне прототипа (светлая «бумажная» тема). */
export function BottomSheet({ open, onClose, title, options, value, onChange }: BottomSheetProps) {
  useEffect(() => {
    document.body.style.overflow = open ? 'hidden' : ''
    return () => {
      document.body.style.overflow = ''
    }
  }, [open])

  if (!open) return null

  return (
    <div style={{ position: 'fixed', inset: 0, zIndex: 50, fontFamily: T.font }}>
      <div className="reg-backdrop-enter" style={{ position: 'absolute', inset: 0, background: 'rgba(20,19,18,0.35)' }} onClick={onClose} />
      <div
        className="reg-sheet-enter"
        style={{
          position: 'absolute',
          bottom: 0,
          left: 0,
          right: 0,
          background: T.bgC,
          borderRadius: '20px 20px 0 0',
          maxHeight: '70vh',
          display: 'flex',
          flexDirection: 'column',
          boxShadow: '0 -8px 40px rgba(20,19,18,0.16)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '16px 20px', borderBottom: `1px solid ${T.bd}` }}>
          <h3 style={{ fontSize: 16, fontWeight: 600, color: T.fg, letterSpacing: '-0.01em' }}>{title}</h3>
          <button onClick={onClose} style={{ padding: 4, background: 'transparent', border: 'none', color: T.fg3, cursor: 'pointer' }}>
            <X style={{ width: 20, height: 20 }} />
          </button>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: '6px 0' }}>
          {options.map((opt) => {
            const sel = value === opt.value
            return (
              <button
                key={opt.value}
                onClick={() => {
                  onChange(opt.value)
                  onClose()
                }}
                style={{
                  width: '100%',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'space-between',
                  padding: '14px 20px',
                  textAlign: 'left',
                  background: sel ? T.bgM : 'transparent',
                  border: 'none',
                  color: T.fg,
                  fontFamily: T.font,
                  fontSize: 15,
                  cursor: 'pointer',
                }}
              >
                <span>{opt.label}</span>
                {sel && <Check style={{ width: 16, height: 16, color: T.accent }} />}
              </button>
            )
          })}
        </div>
      </div>
    </div>
  )
}
