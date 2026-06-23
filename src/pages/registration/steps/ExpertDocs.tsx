import type { RegistrationFormData } from '../constants'

interface ExpertDocsProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

const DOC_SLOTS = [
  { key: 'id',      name: 'Удостоверение личности', hint: 'JPG / PDF', required: true },
  { key: 'diploma', name: 'Диплом / свидетельство',  hint: 'PDF',       required: true },
  { key: 'license', name: 'Лицензия',                hint: 'если есть', required: false },
  { key: 'certs',   name: 'Сертификаты',             hint: 'если есть', required: false },
]

export function ExpertDocs({ formData, onChange, onNext }: ExpertDocsProps) {
  const docs = formData.expert_docs

  const toggleDoc = (key: string) => {
    onChange({ expert_docs: { ...docs, [key]: !docs[key] } })
  }

  const valid = !!docs['id'] && !!docs['diploma']

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold text-[#2B180A] font-serif mb-1">
          Документы
        </h2>
        <p className="text-sm text-[#6b5744]">
          Подтвердим квалификацию
        </p>
      </div>

      <div className="space-y-2">
        {DOC_SLOTS.map(slot => {
          const uploaded = !!docs[slot.key]
          return (
            <button
              key={slot.key}
              onClick={() => toggleDoc(slot.key)}
              className={[
                'w-full flex items-center gap-3 px-4 py-3.5 rounded-xl border text-left transition-all',
                uploaded
                  ? 'border-[#2B180A] bg-[#2B180A] text-white'
                  : 'border-[#e8ddd4] bg-white text-[#2B180A] hover:border-[#c4a882]',
              ].join(' ')}
            >
              <span className="text-lg flex-shrink-0">{uploaded ? '✓' : '⬆'}</span>
              <div className="flex-1 min-w-0">
                <div className="font-medium text-sm">
                  {slot.name}{slot.required ? ' *' : ''}
                </div>
                <div className={`text-xs mt-0.5 ${uploaded ? 'text-[#c4a882]' : 'text-[#9c856e]'}`}>
                  {uploaded ? 'Загружено · нажмите чтобы убрать' : slot.hint}
                </div>
              </div>
            </button>
          )
        })}
      </div>

      <div className="rounded-xl bg-[#faf7f3] border border-[#e8ddd4] px-4 py-3">
        <div className="text-[10px] text-[#9c856e] font-mono uppercase tracking-wide mb-1">Модерация</div>
        <p className="text-sm text-[#6b5744]">
          Администратор AgOS проверит документы вручную. До одобрения вы не появляетесь в каталоге «Сервисы».
        </p>
      </div>

      <button
        onClick={onNext}
        disabled={!valid}
        className={[
          'w-full py-3.5 rounded-xl font-medium text-sm transition-all',
          valid
            ? 'bg-[#2B180A] text-white hover:bg-[#3d2410] active:scale-[0.98]'
            : 'bg-[#e8ddd4] text-[#9c856e] cursor-not-allowed',
        ].join(' ')}
      >
        Отправить на проверку
      </button>
    </div>
  )
}
