import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede, StickyDock, CTA } from '@/lib/auth-ui/primitives'
import type { RegistrationFormData } from '../constants'

interface ExpertDocsProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

const DOC_SLOTS = [
  { key: 'id', name: 'Удостоверение личности', hint: 'JPG / PDF', required: true },
  { key: 'diploma', name: 'Диплом / свидетельство', hint: 'PDF', required: true },
  { key: 'license', name: 'Лицензия', hint: 'если есть', required: false },
  { key: 'certs', name: 'Сертификаты', hint: 'если есть', required: false },
]

export function ExpertDocs({ formData, onChange, onNext }: ExpertDocsProps) {
  const docs = formData.expert_docs

  const toggleDoc = (key: string) => {
    onChange({ expert_docs: { ...docs, [key]: !docs[key] } })
  }

  const valid = !!docs['id'] && !!docs['diploma']
  const mono: React.CSSProperties = { fontFamily: T.mono }

  return (
    <div style={{ fontFamily: T.font }}>
      <H1>Документы</H1>
      <Lede>Подтвердим квалификацию. Формат JPG / PDF.</Lede>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {DOC_SLOTS.map((slot) => {
          const uploaded = !!docs[slot.key]
          return (
            <button
              key={slot.key}
              onClick={() => toggleDoc(slot.key)}
              style={{
                width: '100%',
                display: 'flex',
                alignItems: 'center',
                gap: 12,
                padding: '14px 16px',
                borderRadius: 14,
                textAlign: 'left',
                transition: 'all 120ms',
                cursor: 'pointer',
                fontFamily: T.font,
                border: `1px solid ${uploaded ? T.accent : T.bd}`,
                background: uploaded ? T.bgM : T.bgC,
                color: T.fg,
              }}
            >
              <span style={{ fontSize: 18, flexShrink: 0, color: uploaded ? T.accent : T.fg3 }}>{uploaded ? '✓' : '⬆'}</span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 500, fontSize: 14 }}>
                  {slot.name}
                  {slot.required ? ' *' : ''}
                </div>
                <div style={{ fontSize: 12, marginTop: 2, color: uploaded ? T.accent : T.fg3 }}>
                  {uploaded ? 'Загружено · нажмите чтобы убрать' : slot.hint}
                </div>
              </div>
            </button>
          )
        })}
      </div>

      <div style={{ borderRadius: 12, background: T.bgS, border: `1px solid ${T.bd}`, padding: '12px 16px', marginTop: 16 }}>
        <div style={{ ...mono, fontSize: 10, color: T.fg3, textTransform: 'uppercase', letterSpacing: '.06em', marginBottom: 4 }}>Модерация</div>
        <p style={{ fontSize: 14, color: T.fg2, lineHeight: 1.5, margin: 0 }}>
          Администратор AgOS проверит документы вручную. До одобрения вы не появляетесь в каталоге «Сервисы».
        </p>
      </div>

      <StickyDock>
        <CTA disabled={!valid} onClick={onNext}>
          Отправить на проверку
        </CTA>
      </StickyDock>
    </div>
  )
}
