import { useState } from 'react'
import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede, StickyDock, CTA, Check } from '@/lib/auth-ui/primitives'
import { BottomSheet } from '../components/BottomSheet'
import { HOW_HEARD, HERD_SIZES, COMPANY_TYPES, MONTHLY_VOLUMES } from '../constants'
import type { RegistrationFormData } from '../constants'

function formatPhoneDisplay(digits: string): string {
  if (digits.length !== 10) return `+7${digits}`
  return `+7 (${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6, 8)}-${digits.slice(8)}`
}

interface AgreementProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onSubmit: () => Promise<void>
  isSubmitting: boolean
}

export function Agreement({ formData, onChange, onSubmit, isSubmitting }: AgreementProps) {
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [howHeardOpen, setHowHeardOpen] = useState(false)

  const selectedHowHeard = HOW_HEARD.find((h) => h.value === formData.how_heard)

  const validate = () => {
    const errs: Record<string, string> = {}
    if (!formData.consent_terms) errs.consent_terms = 'Необходимо согласие'
    if (!formData.consent_data) errs.consent_data = 'Необходимо согласие'
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSubmit = async () => {
    if (!validate()) return
    await onSubmit()
  }

  // Summary (role-aware) — preserved from previous version
  const summaryItems: { label: string; value: string }[] = []
  summaryItems.push({ label: 'Имя', value: formData.full_name })
  if (formData.phone) summaryItems.push({ label: 'Телефон', value: formatPhoneDisplay(formData.phone) })
  if (formData.role === 'farmer') {
    if (formData.farm_name) summaryItems.push({ label: 'Хозяйство', value: formData.farm_name })
    if (formData.bin_iin) summaryItems.push({ label: 'БИН/ИИН', value: formData.bin_iin })
    const herdLabel = HERD_SIZES.find((h) => h.value === formData.herd_size)?.label
    if (herdLabel) summaryItems.push({ label: 'Поголовье', value: herdLabel })
  } else {
    if (formData.company_name) summaryItems.push({ label: 'Компания', value: formData.company_name })
    if (formData.bin) summaryItems.push({ label: 'БИН', value: formData.bin })
    if (formData.role === 'mpk') {
      const typeLabel = COMPANY_TYPES.find((t) => t.value === formData.company_type)?.label
      if (typeLabel) summaryItems.push({ label: 'Тип', value: typeLabel })
      const volLabel = MONTHLY_VOLUMES.find((v) => v.value === formData.monthly_volume)?.label
      if (volLabel) summaryItems.push({ label: 'Объём', value: volLabel })
    }
  }

  const consentRows = [
    {
      key: 'consent_terms' as const,
      checked: formData.consent_terms,
      title: 'Согласен с условиями TURAN AgOS',
      desc: 'Правила использования кабинета и торговой площадки.',
    },
    {
      key: 'consent_data' as const,
      checked: formData.consent_data,
      title: 'Согласен на обработку персональных данных',
      desc: 'Хранение и обработка данных согласно закону РК.',
    },
  ]

  return (
    <>
      <H1>Согласия</H1>
      <Lede>Последний шаг перед входом в кабинет. Оба пункта обязательны.</Lede>

      {/* Summary */}
      {summaryItems.length > 0 && (
        <div style={{ borderRadius: 14, border: `1px solid ${T.bd}`, background: T.bgC, padding: 16, marginBottom: 16 }}>
          {summaryItems.map((item, i) => (
            <div key={i} style={{ display: 'flex', gap: 8, fontSize: 14, color: T.fg2, lineHeight: 1.6 }}>
              <span style={{ color: T.fg, fontWeight: 500 }}>{item.label}:</span>
              <span>{item.value}</span>
            </div>
          ))}
        </div>
      )}

      {/* Consent cards */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {consentRows.map((r) => (
          <button
            key={r.key}
            onClick={() => {
              onChange({ [r.key]: !r.checked } as Partial<RegistrationFormData>)
              if (errors[r.key]) setErrors((prev) => ({ ...prev, [r.key]: '' }))
            }}
            aria-pressed={r.checked}
            style={{
              textAlign: 'left',
              padding: 16,
              borderRadius: 14,
              background: T.bgC,
              border: `1px solid ${r.checked ? T.accent : errors[r.key] ? T.red : T.bd}`,
              color: T.fg,
              fontFamily: T.font,
              cursor: 'pointer',
              display: 'flex',
              gap: 14,
              alignItems: 'flex-start',
            }}
          >
            <div
              style={{
                width: 24,
                height: 24,
                borderRadius: 6,
                flexShrink: 0,
                marginTop: 2,
                border: `1.5px solid ${r.checked ? T.accent : T.bdH}`,
                background: r.checked ? T.accent : 'transparent',
                display: 'grid',
                placeItems: 'center',
              }}
            >
              {r.checked && <Check size={14} />}
            </div>
            <div>
              <div style={{ fontSize: 15, fontWeight: 500, lineHeight: 1.4 }}>{r.title}</div>
              <div style={{ fontSize: 13, color: T.fg2, marginTop: 4, lineHeight: 1.45 }}>{r.desc}</div>
            </div>
          </button>
        ))}
      </div>

      {/* How heard (optional) */}
      <button
        type="button"
        onClick={() => setHowHeardOpen(true)}
        style={{
          width: '100%',
          height: 52,
          padding: '0 16px',
          marginTop: 16,
          background: T.bgC,
          border: `1px solid ${T.bd}`,
          borderRadius: 12,
          color: selectedHowHeard ? T.fg : T.fg3,
          fontFamily: T.font,
          fontSize: 16,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          cursor: 'pointer',
        }}
      >
        <span>{selectedHowHeard?.label || 'Как узнали о нас? (необязательно)'}</span>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke={T.fg3} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <StickyDock>
        <CTA disabled={isSubmitting} onClick={handleSubmit}>
          {isSubmitting ? 'Регистрация…' : 'Принять и продолжить'}
        </CTA>
      </StickyDock>

      <BottomSheet
        open={howHeardOpen}
        onClose={() => setHowHeardOpen(false)}
        title="Как узнали о нас?"
        options={HOW_HEARD}
        value={formData.how_heard}
        onChange={(v) => onChange({ how_heard: v })}
      />
    </>
  )
}
