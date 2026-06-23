import { useState } from 'react'
import { FloatingInput } from '../components/FloatingInput'
import { BottomSheet } from '../components/BottomSheet'
import { HERD_SIZES, LEGAL_FORMS, BREEDS, READY_TO_SELL, REGIONS, DISTRICTS } from '../constants'
import type { RegistrationFormData } from '../constants'

interface FarmerDetailsProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

export function FarmerDetails({ formData, onChange, onNext }: FarmerDetailsProps) {
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [activeSheet, setActiveSheet] = useState<string | null>(null)

  const districtOptions = formData.region_id ? DISTRICTS[formData.region_id] ?? [] : []

  const validate = () => {
    const errs: Record<string, string> = {}
    if (!formData.farm_name.trim() || formData.farm_name.trim().length < 2) {
      errs.farm_name = 'Введите название хозяйства'
    }
    if (formData.bin_iin && formData.bin_iin.length !== 12) {
      errs.bin_iin = 'БИН/ИИН должен содержать 12 цифр'
    }
    if (!formData.herd_size) {
      errs.herd_size = 'Укажите размер поголовья'
    }
    if (!formData.region_id) {
      errs.region_id = 'Укажите область'
    }
    if (formData.region_id && districtOptions.length > 0 && !formData.district_id) {
      errs.district_id = 'Укажите район'
    }
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSubmit = () => {
    if (validate()) onNext()
  }

  const getLabel = (options: { value: string; label: string }[], value: string) =>
    options.find((o) => o.value === value)?.label

  return (
    <div className="space-y-6">
      <div className="text-center space-y-2">
        <h2 className="text-xl font-semibold text-[#2B180A] font-serif">
          О вашем хозяйстве
        </h2>
        <p className="text-sm text-[#6b5744]">
          Расскажите о ферме
        </p>
      </div>

      <div className="space-y-4">
        <FloatingInput
          label="Название хозяйства"
          value={formData.farm_name}
          onChange={(v) => {
            onChange({ farm_name: v })
            if (errors.farm_name) setErrors((e) => ({ ...e, farm_name: '' }))
          }}
          error={errors.farm_name}
        />

        <FloatingInput
          label="БИН/ИИН (если есть)"
          value={formData.bin_iin}
          onChange={(v) => {
            const digits = v.replace(/\D/g, '').slice(0, 12)
            onChange({ bin_iin: digits })
            if (errors.bin_iin) setErrors((e) => ({ ...e, bin_iin: '' }))
          }}
          error={errors.bin_iin}
          maxLength={12}
          autoAdvanceAt={12}
        />

        <button
          type="button"
          onClick={() => setActiveSheet('legal_form')}
          className="w-full h-14 px-4 bg-white border border-[#e8ddd0] rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
        >
          <span className={formData.legal_form ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(LEGAL_FORMS, formData.legal_form) || 'Правовая форма (необязательно)'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>

        <button
          type="button"
          onClick={() => setActiveSheet('herd_size')}
          className="w-full h-14 px-4 bg-white border rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
          style={{ borderColor: errors.herd_size ? '#f87171' : '#e8ddd0' }}
        >
          <span className={formData.herd_size ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(HERD_SIZES, formData.herd_size) || 'Размер поголовья *'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        {errors.herd_size && (
          <p className="text-xs -mt-2 px-1" style={{ color: 'var(--red)' }}>{errors.herd_size}</p>
        )}

        <button
          type="button"
          onClick={() => setActiveSheet('region')}
          className="w-full h-14 px-4 bg-white border rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
          style={{ borderColor: errors.region_id ? '#f87171' : '#e8ddd0' }}
        >
          <span className={formData.region_id ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {REGIONS.find((r) => r.id === formData.region_id)?.name || 'Область *'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        {errors.region_id && (
          <p className="text-xs -mt-2 px-1" style={{ color: 'var(--red)' }}>{errors.region_id}</p>
        )}

        <button
          type="button"
          onClick={() => formData.region_id && setActiveSheet('district')}
          disabled={!formData.region_id || districtOptions.length === 0}
          className="w-full h-14 px-4 bg-white border rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          style={{ borderColor: errors.district_id ? '#f87171' : '#e8ddd0' }}
        >
          <span className={formData.district_id ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(districtOptions, formData.district_id)
              || (!formData.region_id ? 'Сначала выберите область' : 'Район *')}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        {errors.district_id && (
          <p className="text-xs -mt-2 px-1" style={{ color: 'var(--red)' }}>{errors.district_id}</p>
        )}

        <button
          type="button"
          onClick={() => setActiveSheet('breed')}
          className="w-full h-14 px-4 bg-white border border-[#e8ddd0] rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
        >
          <span className={formData.primary_breed ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(BREEDS.map(b => ({ value: b.id, label: b.name })), formData.primary_breed) || 'Основная порода (необязательно)'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>

        <button
          type="button"
          onClick={() => setActiveSheet('ready_to_sell')}
          className="w-full h-14 px-4 bg-white border border-[#e8ddd0] rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
        >
          <span className={formData.ready_to_sell ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(READY_TO_SELL, formData.ready_to_sell) || 'Готовность к продаже (необязательно)'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
      </div>

      <button onClick={handleSubmit} className="reg-btn-primary w-full">
        Далее
      </button>

      <BottomSheet
        open={activeSheet === 'legal_form'}
        onClose={() => setActiveSheet(null)}
        title="Правовая форма"
        options={LEGAL_FORMS}
        value={formData.legal_form}
        onChange={(v) => onChange({ legal_form: v })}
      />
      <BottomSheet
        open={activeSheet === 'herd_size'}
        onClose={() => setActiveSheet(null)}
        title="Размер поголовья"
        options={HERD_SIZES}
        value={formData.herd_size}
        onChange={(v) => {
          onChange({ herd_size: v })
          if (errors.herd_size) setErrors((e) => ({ ...e, herd_size: '' }))
        }}
      />
      <BottomSheet
        open={activeSheet === 'region'}
        onClose={() => setActiveSheet(null)}
        title="Область хозяйства"
        options={REGIONS.map((r) => ({ value: r.id, label: r.name }))}
        value={formData.region_id}
        onChange={(v) => {
          // Смена области сбрасывает ранее выбранный район
          onChange({ region_id: v, district_id: '' })
          if (errors.region_id) setErrors((e) => ({ ...e, region_id: '' }))
        }}
      />
      <BottomSheet
        open={activeSheet === 'district'}
        onClose={() => setActiveSheet(null)}
        title="Район"
        options={districtOptions}
        value={formData.district_id}
        onChange={(v) => {
          onChange({ district_id: v })
          if (errors.district_id) setErrors((e) => ({ ...e, district_id: '' }))
        }}
      />
      <BottomSheet
        open={activeSheet === 'breed'}
        onClose={() => setActiveSheet(null)}
        title="Основная порода"
        options={BREEDS.map((b) => ({ value: b.id, label: b.name }))}
        value={formData.primary_breed}
        onChange={(v) => onChange({ primary_breed: v })}
      />
      <BottomSheet
        open={activeSheet === 'ready_to_sell'}
        onClose={() => setActiveSheet(null)}
        title="Готовность к продаже"
        options={READY_TO_SELL}
        value={formData.ready_to_sell}
        onChange={(v) => onChange({ ready_to_sell: v })}
      />
    </div>
  )
}
