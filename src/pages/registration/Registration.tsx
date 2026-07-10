import { useState, useEffect, useCallback, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { useAuth } from '@/hooks/useAuth'
import { AuthShell, AuthBody, TopBar } from '@/lib/auth-ui/primitives'
import { RoleSelect } from './steps/RoleSelect'
import { Contact } from './steps/Contact'
import { BenefitScreen } from './steps/BenefitScreen'
import { CreatePin } from './steps/CreatePin'
import { FarmerDetails } from './steps/FarmerDetails'
import { MpkDetails } from './steps/MpkDetails'
import { ServicesDetails } from './steps/ServicesDetails'
import { FeedProducerDetails } from './steps/FeedProducerDetails'
import { ExpertDetails } from './steps/ExpertDetails'
import { ExpertDocs } from './steps/ExpertDocs'
import { Agreement } from './steps/Agreement'
import { Success } from './steps/Success'
import { INITIAL_FORM_DATA } from './constants'
import type { RegistrationFormData, RoleType } from './constants'

const STORAGE_KEY = 'agos_reg_form'

type Step =
  | 'contact'
  | 'create_pin'
  | 'role_select'
  | 'benefit_1'
  | 'role_details'
  | 'expert_docs'
  | 'agreement'
  | 'success'

const STEP_ORDER: Step[] = [
  'contact',
  'create_pin',
  'role_select',
  'benefit_1',
  'role_details',
  'expert_docs',
  'agreement',
  'success',
]

const STEP_LABELS: Record<Step, string> = {
  contact: 'Номер',
  create_pin: 'PIN',
  role_select: 'Роль',
  benefit_1: 'Возможности',
  role_details: 'Данные',
  expert_docs: 'Документы',
  agreement: 'Согласия',
  success: 'Готово',
}

// Шаги для счётчика/прогресса в шапке. expert_docs проходят только эксперты,
// поэтому остальные роли видят 7 шагов (7/7 на Success), а эксперты — 8.
function visibleSteps(role: RoleType | null): Step[] {
  return role === 'expert' ? STEP_ORDER : STEP_ORDER.filter((s) => s !== 'expert_docs')
}

// Отображаемое название организации на экране Success (ONB-SUCCESS-ORPHAN-01) —
// зеркалит выбор name в handleRegister, только для UI, не влияет на сабмит.
function getDisplayName(role: RoleType | null, formData: RegistrationFormData): string {
  switch (role) {
    case 'farmer':
      return formData.farm_name
    case 'mpk':
    case 'services':
    case 'feed_producer':
      return formData.company_name
    case 'expert':
      return formData.full_name
    default:
      return ''
  }
}

export function Registration() {
  const { session, organization, userContext } = useAuth()
  const navigate = useNavigate()
  const [step, setStep] = useState<Step>('contact')
  // Достройка регистрации: аутентифицирован, но организации нет (бросил регистрацию до
  // создания орга). Возобновляем с выбора роли — телефон/PIN уже пройдены.
  const resumingRef = useRef(false)
  const [formData, setFormData] = useState<RegistrationFormData>(() => {
    try {
      const saved = sessionStorage.getItem(STORAGE_KEY)
      if (saved) {
        const parsed = JSON.parse(saved)
        // Merge with defaults to handle new fields added after save
        return { ...INITIAL_FORM_DATA, ...parsed, otp_sent: false, otp_verified: false, password: '' }
      }
    } catch { /* ignore */ }
    return INITIAL_FORM_DATA
  })
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Persist form to sessionStorage
  useEffect(() => {
    try {
      // Never persist sensitive auth fields to storage
      const { password: _p, verification_id: _v, ...safeData } = formData
      sessionStorage.setItem(STORAGE_KEY, JSON.stringify(safeData))
    } catch { /* ignore */ }
  }, [formData])

  // Warn on leaving with unsaved changes
  useEffect(() => {
    const handler = (e: BeforeUnloadEvent) => {
      if (step !== 'contact' && step !== 'success') {
        e.preventDefault()
      }
    }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [step])

  const updateForm = useCallback((updates: Partial<RegistrationFormData>) => {
    setFormData((prev) => ({ ...prev, ...updates }))
  }, [])

  const goTo = useCallback((nextStep: Step) => {
    setStep(nextStep)
    // Scroll to top on step change
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }, [])

  // Аутентифицирован, но организации нет (незавершённая регистрация) → пропускаем телефон/PIN
  // и начинаем с выбора роли. Гейтим по userContext (загружен, но организаций нет), чтобы не
  // прыгнуть до резолва контекста и не сбить валидного пользователя. Один раз — со шага 'contact'.
  useEffect(() => {
    if (userContext && !organization && step === 'contact') {
      resumingRef.current = true
      goTo('role_select')
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userContext, organization, step])

  const goBack = useCallback(() => {
    if (step === 'contact' && formData.otp_sent) {
      updateForm({ otp_sent: false })
      return
    }
    // Достройка регистрации: телефон/PIN уже пройдены — с первого шага (role_select) назад
    // ведём в кабинет, а не на create_pin/contact.
    if (resumingRef.current && step === 'role_select') {
      navigate('/cabinet')
      return
    }
    const curIdx = STEP_ORDER.indexOf(step)
    if (curIdx > 0) {
      const prev = STEP_ORDER[curIdx - 1]
      if (prev) goTo(prev)
    }
  }, [step, formData.otp_sent, updateForm, goTo, navigate])

  const handleRegister = async () => {
    setIsSubmitting(true)
    try {
      const role = formData.role!
      let name = ''
      let bin = ''
      let roleData: Record<string, unknown> = {}

      if (role === 'farmer') {
        name = formData.farm_name
        bin = formData.bin_iin
        roleData = {
          farm_name: formData.farm_name,
          herd_size: formData.herd_size,
          primary_breed: formData.primary_breed || null,
          ready_to_sell: formData.ready_to_sell || null,
          legal_form: formData.legal_form || null,
          district_id: formData.district_id || null,
        }
      } else if (role === 'mpk') {
        name = formData.company_name
        bin = formData.bin
        roleData = {
          company_type: formData.company_type,
          monthly_volume: formData.monthly_volume,
          target_breeds: formData.target_breeds.length > 0 ? formData.target_breeds : null,
          target_weight: formData.target_weight || null,
          procurement_frequency: formData.procurement_frequency || null,
        }
      } else if (role === 'services') {
        name = formData.company_name
        bin = formData.bin
        roleData = {
          service_types: formData.service_types,
          service_regions: formData.service_regions.length > 0 ? formData.service_regions : null,
        }
      } else if (role === 'feed_producer') {
        name = formData.company_name
        bin = formData.bin
        roleData = {
          feed_types: formData.feed_types,
          production_volume: formData.production_volume || null,
          delivery_regions: formData.delivery_regions.length > 0 ? formData.delivery_regions : null,
        }
      } else if (role === 'expert') {
        name = formData.full_name
        bin = ''
        roleData = {
          expert_specializations: formData.expert_specializations,
          expert_experience: formData.expert_experience || null,
          expert_visit_price: formData.expert_visit_price || null,
          expert_about: formData.expert_about || null,
        }
      }

      // Create organization via RPC (user already authenticated via OTP)
      const enrichedRoleData = {
        ...roleData,
        full_name: formData.full_name,
        how_heard: formData.how_heard || null,
      }

      // UI-роли → org_type схемы (CHECK: farmer, mpk, supplier, consultant, other) — IDENTITY-07 + expert→consultant
      const orgTypeMap: Record<RoleType, string> = {
        farmer: 'farmer',
        mpk: 'mpk',
        services: 'supplier',
        feed_producer: 'supplier',
        expert: 'consultant',
      }

      const { error } = await supabase.rpc('rpc_register_organization', {
        p_organization_id: '00000000-0000-0000-0000-000000000000', // ignored, P-AI-2 signature consistency
        p_org_type: orgTypeMap[role] ?? 'other',
        p_name: name,
        p_bin: bin || null,
        p_region_id: formData.region_id || null,
        p_phone: formData.phone,
        p_role_data: enrichedRoleData,
      })

      if (error) {
        if (error.message?.includes('BIN_DUPLICATE')) {
          toast.error('Организация с таким БИН уже зарегистрирована')
        } else {
          toast.error(error.message || 'Ошибка регистрации')
        }
        return
      }

      // ФИО и (для фермера) правовая форма не попадают в queryable-колонки при регистрации
      // (role_data уходит только в platform_events). Кабинет читает их из user_metadata
      // (см. loadAccountProfile), поэтому фиксируем их в метаданных аккаунта здесь.
      const { data: updatedAuth } = await supabase.auth.updateUser({
        data: {
          full_name: formData.full_name,
          ...(role === 'farmer' ? { legal_form: formData.legal_form || null } : {}),
        },
      })

      // Триггер handle_new_user создаёт public.users ещё на этапе OTP/PIN — ДО того как
      // собрано ФИО, поэтому users.full_name остаётся null (в админке «Пользователи» — прочерк).
      // Дописываем имя в public.users явно (RLS users_update_own: auth_id = auth.uid()).
      const authId = updatedAuth?.user?.id ?? session?.user?.id
      if (authId && formData.full_name) {
        await supabase.from('users').update({ full_name: formData.full_name }).eq('auth_id', authId)
      }

      // Членство НЕ подаётся автоматически: после регистрации организация в состоянии
      // «не член». Заявку с документами пользователь подаёт сам из кабинета/Рынка (TSP)
      // — флоу покупки членства (документы → одобрение админом → оплата взноса).

      // Clear saved form data
      sessionStorage.removeItem(STORAGE_KEY)

      // Registration complete — user already has a session (signed in after PIN).
      // Экран Success (ONB-SUCCESS-ORPHAN-01): показываем KPI/«первые шаги»/баннер
      // заявки перед переходом в кабинет — кнопка на самом экране ведёт в /cabinet
      // или /mpk (см. Success.tsx CABINET_CONTENT, совпадает с pickShellPath).
      goTo('success')
    } catch (err) {
      toast.error('Ошибка регистрации')
      console.error(err)
    } finally {
      setIsSubmitting(false)
    }
  }

  const renderStep = () => {
    switch (step) {
      case 'contact':
        return (
          <Contact
            formData={formData}
            onChange={updateForm}
            onNext={() => goTo('create_pin')}
          />
        )
      case 'create_pin':
        return (
          <CreatePin
            formData={formData}
            onChange={updateForm}
            onNext={() => goTo('role_select')}
          />
        )
      case 'role_select':
        return (
          <RoleSelect
            onSelect={(role: RoleType) => {
              updateForm({ role })
              goTo('benefit_1')
            }}
          />
        )
      case 'benefit_1':
        return (
          <BenefitScreen
            role={formData.role!}
            step={1}
            onNext={() => goTo('role_details')}
          />
        )
      case 'role_details':
        switch (formData.role) {
          case 'farmer':
            return (
              <FarmerDetails
                formData={formData}
                onChange={updateForm}
                onNext={() => goTo('agreement')}
              />
            )
          case 'mpk':
            return (
              <MpkDetails
                formData={formData}
                onChange={updateForm}
                onNext={() => goTo('agreement')}
              />
            )
          case 'services':
            return (
              <ServicesDetails
                formData={formData}
                onChange={updateForm}
                onNext={() => goTo('agreement')}
              />
            )
          case 'feed_producer':
            return (
              <FeedProducerDetails
                formData={formData}
                onChange={updateForm}
                onNext={() => goTo('agreement')}
              />
            )
          case 'expert':
            return (
              <ExpertDetails
                formData={formData}
                onChange={updateForm}
                onNext={() => goTo('expert_docs')}
              />
            )
          default:
            return null
        }
      case 'expert_docs':
        return (
          <ExpertDocs
            formData={formData}
            onChange={updateForm}
            onNext={() => goTo('agreement')}
          />
        )
      case 'agreement':
        return (
          <Agreement
            formData={formData}
            onChange={updateForm}
            onSubmit={handleRegister}
            isSubmitting={isSubmitting}
          />
        )
      case 'success':
        return (
          <Success
            role={formData.role!}
            phone={formData.phone}
            companyName={getDisplayName(formData.role, formData)}
          />
        )
      default:
        return null
    }
  }

  const isSuccess = step === 'success'
  const steps = visibleSteps(formData.role)
  const idx = steps.indexOf(step)
  const topLabel = step === 'contact' && formData.otp_sent ? 'Код' : STEP_LABELS[step]
  const topBack = () => {
    // На первом экране (номер, до отправки кода) назад = выход на лендинг.
    if (step === 'contact' && !formData.otp_sent) {
      navigate('/')
      return
    }
    goBack()
  }

  return (
    <AuthShell>
      <TopBar label={topLabel} onBack={topBack} idx={idx} total={steps.length} hideBack={isSuccess} />
      <AuthBody>
        <div key={step}>{renderStep()}</div>
      </AuthBody>
    </AuthShell>
  )
}
