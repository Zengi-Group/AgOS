import { useState } from 'react'
import type { ReactNode } from 'react'
import { Check, CaretDown, User, Phone, House, Buildings, IdentificationCard, Cow, Tag, ChartBar, type Icon as PhosphorIcon } from '@phosphor-icons/react'
import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede, StickyDock, CTA } from '@/lib/auth-ui/primitives'
import { BottomSheet } from '../components/BottomSheet'
import { HOW_HEARD, HERD_SIZES, COMPANY_TYPES, MONTHLY_VOLUMES } from '../constants'
import type { RegistrationFormData } from '../constants'

// Ссылки на юридические документы. Реальные URL/текст подставим позже.
const TERMS_URL = '#'
const PRIVACY_URL = '#'

function formatPhoneDisplay(digits: string): string {
  if (digits.length !== 10) return `+7${digits}`
  return `+7 (${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6, 8)}-${digits.slice(8)}`
}

// Кликабельная ссылка внутри строки согласия (не тогглит чекбокс — stopPropagation).
function ConsentLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a
      href={href}
      onClick={(e) => {
        e.stopPropagation()
        if (href === '#') e.preventDefault()
      }}
      style={{ color: T.accent, fontWeight: 500, textDecoration: 'underline', textUnderlineOffset: 2 }}
    >
      {children}
    </a>
  )
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
  const summaryItems: { icon: PhosphorIcon; label: string; value: string }[] = []
  summaryItems.push({ icon: User, label: 'Имя', value: formData.full_name })
  if (formData.phone) summaryItems.push({ icon: Phone, label: 'Телефон', value: formatPhoneDisplay(formData.phone) })
  if (formData.role === 'farmer') {
    if (formData.farm_name) summaryItems.push({ icon: House, label: 'Хозяйство', value: formData.farm_name })
    if (formData.bin_iin) summaryItems.push({ icon: IdentificationCard, label: 'БИН/ИИН', value: formData.bin_iin })
    const herdLabel = HERD_SIZES.find((h) => h.value === formData.herd_size)?.label
    if (herdLabel) summaryItems.push({ icon: Cow, label: 'Поголовье', value: herdLabel })
  } else {
    if (formData.company_name) summaryItems.push({ icon: Buildings, label: 'Компания', value: formData.company_name })
    if (formData.bin) summaryItems.push({ icon: IdentificationCard, label: 'БИН', value: formData.bin })
    if (formData.role === 'mpk') {
      const typeLabel = COMPANY_TYPES.find((t) => t.value === formData.company_type)?.label
      if (typeLabel) summaryItems.push({ icon: Tag, label: 'Тип', value: typeLabel })
      const volLabel = MONTHLY_VOLUMES.find((v) => v.value === formData.monthly_volume)?.label
      if (volLabel) summaryItems.push({ icon: ChartBar, label: 'Объём', value: volLabel })
    }
  }

  const consentRows: { key: 'consent_terms' | 'consent_data'; checked: boolean; label: ReactNode }[] = [
    {
      key: 'consent_terms',
      checked: formData.consent_terms,
      label: (
        <>Принимаю <ConsentLink href={TERMS_URL}>условия использования</ConsentLink> TURAN AgOS</>
      ),
    },
    {
      key: 'consent_data',
      checked: formData.consent_data,
      label: (
        <>Даю согласие на <ConsentLink href={PRIVACY_URL}>обработку персональных данных</ConsentLink> по закону РК</>
      ),
    },
  ]

  return (
    <>
      <H1>Согласия</H1>
      <Lede>Последний шаг перед входом в кабинет. Оба пункта обязательны.</Lede>

      {/* Summary */}
      {summaryItems.length > 0 && (
        <div style={{ borderRadius: 14, border: `1px solid ${T.bd}`, background: T.bgC, padding: '6px 16px', marginBottom: 20 }}>
          {summaryItems.map((item, i) => {
            const RowIcon = item.icon
            return (
              <div
                key={i}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: 12,
                  padding: '10px 0',
                  borderTop: i === 0 ? 'none' : `1px solid ${T.bdS}`,
                }}
              >
                <RowIcon size={18} weight="light" color={T.fg3} style={{ flexShrink: 0 }} />
                <span style={{ fontSize: 13, color: T.fg3, minWidth: 78 }}>{item.label}</span>
                <span style={{ fontSize: 14, color: T.fg, fontWeight: 500, marginLeft: 'auto', textAlign: 'right' }}>{item.value}</span>
              </div>
            )
          })}
        </div>
      )}

      {/* Consents — минималистичные строки без подложек */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        {consentRows.map((r) => {
          const toggle = () => {
            onChange({ [r.key]: !r.checked } as Partial<RegistrationFormData>)
            if (errors[r.key]) setErrors((prev) => ({ ...prev, [r.key]: '' }))
          }
          return (
            <div
              key={r.key}
              role="checkbox"
              aria-checked={r.checked}
              tabIndex={0}
              onClick={toggle}
              onKeyDown={(e) => {
                if (e.key === ' ' || e.key === 'Enter') {
                  e.preventDefault()
                  toggle()
                }
              }}
              style={{
                display: 'flex',
                gap: 12,
                alignItems: 'flex-start',
                padding: '10px 2px',
                cursor: 'pointer',
                color: T.fg,
                fontFamily: T.font,
              }}
            >
              <span
                style={{
                  width: 22,
                  height: 22,
                  borderRadius: 6,
                  flexShrink: 0,
                  marginTop: 1,
                  border: `1.5px solid ${r.checked ? T.accent : errors[r.key] ? T.red : T.bdH}`,
                  background: r.checked ? T.accent : 'transparent',
                  display: 'grid',
                  placeItems: 'center',
                  transition: 'all 120ms',
                }}
              >
                {r.checked && <Check size={13} weight="bold" color={T.ctaFg} />}
              </span>
              <div style={{ fontSize: 14, lineHeight: 1.45, paddingTop: 1 }}>{r.label}</div>
            </div>
          )
        })}
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
        <CaretDown size={16} weight="light" color={T.fg3} />
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
