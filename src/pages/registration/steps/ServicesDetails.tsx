import { useState } from 'react'
import { FloatingInput } from '../components/FloatingInput'
import { ChipSelect } from '../components/ChipSelect'
import { H1, Lede, StickyDock, CTA } from '@/lib/auth-ui/primitives'
import { SERVICE_TYPES, REGIONS } from '../constants'
import type { RegistrationFormData } from '../constants'

interface ServicesDetailsProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

export function ServicesDetails({ formData, onChange, onNext }: ServicesDetailsProps) {
  const [errors, setErrors] = useState<Record<string, string>>({})

  const validate = () => {
    const errs: Record<string, string> = {}
    if (!formData.company_name.trim() || formData.company_name.trim().length < 2) {
      errs.company_name = 'Введите название компании'
    }
    if (!formData.bin || formData.bin.length !== 12) {
      errs.bin = 'БИН должен содержать 12 цифр'
    }
    if (formData.service_types.length === 0) {
      errs.service_types = 'Выберите хотя бы один вид услуг'
    }
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSubmit = () => {
    if (validate()) onNext()
  }

  return (
    <div>
      <H1>О компании</H1>
      <Lede>Данные для каталога сервисов TURAN. Изменить можно потом.</Lede>

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
        />

        <ChipSelect
          label="Виды услуг *"
          options={SERVICE_TYPES}
          value={formData.service_types}
          onChange={(v) => {
            onChange({ service_types: v })
            if (errors.service_types) setErrors((e) => ({ ...e, service_types: '' }))
          }}
          error={errors.service_types}
        />

        <ChipSelect
          label="Регионы обслуживания (необязательно)"
          options={REGIONS.map((r) => ({ value: r.id, label: r.name }))}
          value={formData.service_regions}
          onChange={(v) => onChange({ service_regions: v })}
        />
      </div>

      <StickyDock>
        <CTA onClick={handleSubmit}>Далее</CTA>
      </StickyDock>
    </div>
  )
}
