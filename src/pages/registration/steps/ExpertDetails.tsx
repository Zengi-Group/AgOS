import { useState } from 'react'
import { ChipSelect } from '../components/ChipSelect'
import { BottomSheet } from '../components/BottomSheet'
import { FloatingInput } from '../components/FloatingInput'
import { EXPERT_SPECIALIZATIONS, EXPERT_EXPERIENCE, REGIONS } from '../constants'
import type { RegistrationFormData } from '../constants'

interface ExpertDetailsProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

export function ExpertDetails({ formData, onChange, onNext }: ExpertDetailsProps) {
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [activeSheet, setActiveSheet] = useState<string | null>(null)

  const validate = () => {
    const errs: Record<string, string> = {}
    if (formData.expert_specializations.length === 0) {
      errs.expert_specializations = 'Выберите хотя бы одну специализацию'
    }
    if (!formData.expert_experience) {
      errs.expert_experience = 'Укажите опыт'
    }
    if (!formData.region_id) {
      errs.region_id = 'Укажите регион'
    }
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSubmit = () => {
    if (validate()) onNext()
  }

  const selectedExperience = EXPERT_EXPERIENCE.find(e => e.value === formData.expert_experience)
  const selectedRegion = REGIONS.find(r => r.id === formData.region_id)

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold text-[#2B180A] font-serif mb-1">
          О вас как эксперте
        </h2>
        <p className="text-sm text-[#6b5744]">
          Это увидят фермеры в каталоге «Сервисы»
        </p>
      </div>

      <div className="space-y-4">
        {/* ФИО из Contact — readonly */}
        <div className="w-full h-14 px-4 bg-[#faf7f3] border border-[#e8ddd0] rounded-xl flex flex-col justify-center">
          <span className="text-[10px] text-[#9c856e] uppercase tracking-wide font-mono">ФИО</span>
          <span className="text-sm text-[#4a3728]">{formData.full_name || '—'}</span>
        </div>

        <ChipSelect
          label="Специализация * · можно несколько"
          options={EXPERT_SPECIALIZATIONS}
          value={formData.expert_specializations}
          onChange={(v) => {
            onChange({ expert_specializations: v })
            if (errors.expert_specializations) setErrors(e => ({ ...e, expert_specializations: '' }))
          }}
          error={errors.expert_specializations}
        />

        <div className="grid grid-cols-2 gap-3">
          <div>
            <button
              type="button"
              onClick={() => setActiveSheet('experience')}
              className="w-full h-14 px-4 bg-white border rounded-xl text-left flex flex-col justify-center hover:border-[#2B180A]/30 transition-colors"
              style={{ borderColor: errors.expert_experience ? '#f87171' : '#e8ddd0' }}
            >
              <span className="text-[10px] text-[#9c856e] uppercase tracking-wide font-mono">Опыт *</span>
              <span className={`text-sm ${selectedExperience ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}`}>
                {selectedExperience?.label || '— ▾'}
              </span>
            </button>
            {errors.expert_experience && (
              <p className="text-xs mt-1 px-1 text-red-400">{errors.expert_experience}</p>
            )}
          </div>
          <div>
            <button
              type="button"
              onClick={() => setActiveSheet('region')}
              className="w-full h-14 px-4 bg-white border rounded-xl text-left flex flex-col justify-center hover:border-[#2B180A]/30 transition-colors"
              style={{ borderColor: errors.region_id ? '#f87171' : '#e8ddd0' }}
            >
              <span className="text-[10px] text-[#9c856e] uppercase tracking-wide font-mono">Регион *</span>
              <span className={`text-sm truncate ${selectedRegion ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}`}>
                {selectedRegion?.name || '— ▾'}
              </span>
            </button>
            {errors.region_id && (
              <p className="text-xs mt-1 px-1 text-red-400">{errors.region_id}</p>
            )}
          </div>
        </div>

        <FloatingInput
          label="Стоимость выезда (₸, необязательно)"
          value={formData.expert_visit_price}
          onChange={(v) => onChange({ expert_visit_price: v.replace(/\D/g, '').slice(0, 7) })}
        />

        <FloatingInput
          label="О себе (необязательно)"
          value={formData.expert_about}
          onChange={(v) => onChange({ expert_about: v })}
        />
      </div>

      <button onClick={handleSubmit} className="reg-btn-primary w-full">
        Далее →
      </button>

      <BottomSheet
        open={activeSheet === 'experience'}
        onClose={() => setActiveSheet(null)}
        title="Опыт работы"
        options={EXPERT_EXPERIENCE}
        value={formData.expert_experience}
        onChange={(v) => {
          onChange({ expert_experience: v })
          if (errors.expert_experience) setErrors(e => ({ ...e, expert_experience: '' }))
        }}
      />
      <BottomSheet
        open={activeSheet === 'region'}
        onClose={() => setActiveSheet(null)}
        title="Регион работы"
        options={REGIONS.map(r => ({ value: r.id, label: r.name }))}
        value={formData.region_id}
        onChange={(v) => {
          onChange({ region_id: v })
          if (errors.region_id) setErrors(e => ({ ...e, region_id: '' }))
        }}
      />
    </div>
  )
}
