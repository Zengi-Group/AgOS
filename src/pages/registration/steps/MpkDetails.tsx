import { useState } from 'react'
import { FloatingInput } from '../components/FloatingInput'
import { BottomSheet } from '../components/BottomSheet'
import { ChipSelect } from '../components/ChipSelect'
import { H1, Lede, StickyDock, CTA } from '@/lib/auth-ui/primitives'
import {
  COMPANY_TYPES,
  MONTHLY_VOLUMES,
  BREEDS,
  TARGET_WEIGHTS,
  PROCUREMENT_FREQUENCIES,
} from '../constants'
import type { RegistrationFormData } from '../constants'

interface MpkDetailsProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

export function MpkDetails({ formData, onChange, onNext }: MpkDetailsProps) {
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [activeSheet, setActiveSheet] = useState<string | null>(null)

  const validate = () => {
    const errs: Record<string, string> = {}
    if (!formData.company_name.trim() || formData.company_name.trim().length < 2) {
      errs.company_name = 'Введите название компании'
    }
    if (!formData.bin || formData.bin.length !== 12) {
      errs.bin = 'БИН должен содержать 12 цифр'
    }
    if (!formData.company_type) {
      errs.company_type = 'Выберите тип компании'
    }
    if (!formData.monthly_volume) {
      errs.monthly_volume = 'Укажите объём закупок'
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
    <div>
      <H1>О предприятии</H1>
      <Lede>Данные для доступа к закупкам и Рынку. Изменить можно потом.</Lede>

      <div className="space-y-4">
        <FloatingInput
          label="Название компании"
          value={formData.company_name}
          onChange={(v) => {
            onChange({ company_name: v })
            if (errors.company_name) setErrors((e) => ({ ...e, company_name: '' }))
          }}
          error={errors.company_name}
        />

        <FloatingInput
          label="БИН"
          value={formData.bin}
          onChange={(v) => {
            const digits = v.replace(/\D/g, '').slice(0, 12)
            onChange({ bin: digits })
            if (errors.bin) setErrors((e) => ({ ...e, bin: '' }))
          }}
          error={errors.bin}
          maxLength={12}
          autoAdvanceAt={12}
          inputMode="numeric"
        />

        <button
          type="button"
          onClick={() => setActiveSheet('company_type')}
          className="w-full h-14 px-4 bg-white border rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
          style={{ borderColor: errors.company_type ? '#f87171' : '#e8ddd0' }}
        >
          <span className={formData.company_type ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(COMPANY_TYPES, formData.company_type) || 'Тип компании *'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        {errors.company_type && <p className="text-xs -mt-2 px-1" style={{ color: 'var(--red)' }}>{errors.company_type}</p>}

        <button
          type="button"
          onClick={() => setActiveSheet('monthly_volume')}
          className="w-full h-14 px-4 bg-white border rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
          style={{ borderColor: errors.monthly_volume ? '#f87171' : '#e8ddd0' }}
        >
          <span className={formData.monthly_volume ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(MONTHLY_VOLUMES, formData.monthly_volume) || 'Объём закупок в месяц *'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
        {errors.monthly_volume && <p className="text-xs -mt-2 px-1" style={{ color: 'var(--red)' }}>{errors.monthly_volume}</p>}

        {/* MPK extra fields (Step 5b equivalent) */}
        <ChipSelect
          label="Целевые породы (необязательно)"
          options={BREEDS.map((b) => ({ value: b.id, label: b.name }))}
          value={formData.target_breeds}
          onChange={(v) => onChange({ target_breeds: v })}
        />

        <button
          type="button"
          onClick={() => setActiveSheet('target_weight')}
          className="w-full h-14 px-4 bg-white border border-[#e8ddd0] rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
        >
          <span className={formData.target_weight ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(TARGET_WEIGHTS, formData.target_weight) || 'Целевой вес (необязательно)'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>

        <button
          type="button"
          onClick={() => setActiveSheet('procurement_frequency')}
          className="w-full h-14 px-4 bg-white border border-[#e8ddd0] rounded-xl text-left flex items-center justify-between hover:border-[#2B180A]/30 transition-colors"
        >
          <span className={formData.procurement_frequency ? 'text-[#2B180A]' : 'text-[#6b5744]/60'}>
            {getLabel(PROCUREMENT_FREQUENCIES, formData.procurement_frequency) || 'Частота закупок (необязательно)'}
          </span>
          <svg className="h-4 w-4 text-[#6b5744]/40" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
          </svg>
        </button>
      </div>

      <StickyDock>
        <CTA onClick={handleSubmit}>Далее</CTA>
      </StickyDock>

      <BottomSheet
        open={activeSheet === 'company_type'}
        onClose={() => setActiveSheet(null)}
        title="Тип компании"
        options={COMPANY_TYPES}
        value={formData.company_type}
        onChange={(v) => {
          onChange({ company_type: v })
          if (errors.company_type) setErrors((e) => ({ ...e, company_type: '' }))
        }}
      />
      <BottomSheet
        open={activeSheet === 'monthly_volume'}
        onClose={() => setActiveSheet(null)}
        title="Объём закупок в месяц"
        options={MONTHLY_VOLUMES}
        value={formData.monthly_volume}
        onChange={(v) => {
          onChange({ monthly_volume: v })
          if (errors.monthly_volume) setErrors((e) => ({ ...e, monthly_volume: '' }))
        }}
      />
      <BottomSheet
        open={activeSheet === 'target_weight'}
        onClose={() => setActiveSheet(null)}
        title="Целевой вес"
        options={TARGET_WEIGHTS}
        value={formData.target_weight}
        onChange={(v) => onChange({ target_weight: v })}
      />
      <BottomSheet
        open={activeSheet === 'procurement_frequency'}
        onClose={() => setActiveSheet(null)}
        title="Частота закупок"
        options={PROCUREMENT_FREQUENCIES}
        value={formData.procurement_frequency}
        onChange={(v) => onChange({ procurement_frequency: v })}
      />
    </div>
  )
}
