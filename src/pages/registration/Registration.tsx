import { useState, useEffect, useCallback, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { useAuth } from '@/hooks/useAuth'
import { ProgressBar } from './components/ProgressBar'
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

const STEP_ORDER: Step[] = [
  'contact',
  'create_pin',
  'role_select',
  'benefit_1',
  'role_details',
  'expert_docs',
  'agreement',
]

export function Registration() {
  const { session } = useAuth()
  const navigate = useNavigate()
  const [step, setStep] = useState<Step>('contact')
  const [direction, setDirection] = useState<'forward' | 'backward'>('forward')
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
  const stepRef = useRef<HTMLDivElement>(null)

  // If already authenticated with context, redirect to cabinet
  useEffect(() => {
    if (session && step === 'contact') {
      // User already logged in — they may be coming back.
      // Don't redirect automatically — they might want to re-register.
    }
  }, [session, step])

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
      if (step !== 'contact') {
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
    const curIdx = STEP_ORDER.indexOf(step)
    const nextIdx = STEP_ORDER.indexOf(nextStep)
    setDirection(nextIdx > curIdx ? 'forward' : 'backward')
    setStep(nextStep)
    // Scroll to top on step change
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }, [step])

  const goBack = useCallback(() => {
    if (step === 'contact' && formData.otp_sent) {
      updateForm({ otp_sent: false })
      return
    }
    const curIdx = STEP_ORDER.indexOf(step)
    if (curIdx > 0) {
      const prev = STEP_ORDER[curIdx - 1]
      if (prev) goTo(prev)
    }
  }, [step, formData.otp_sent, updateForm, goTo])

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
        p_phone: `+7${formData.phone}`,
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
      // Go straight to the cabinet.
      navigate('/cabinet')
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
      default:
        return null
    }
  }

  const showBackButton = step !== 'contact'
  const stepIndex = STEP_ORDER.indexOf(step) + 1

  return (
    <div className="min-h-screen bg-[#fdf6ee] flex flex-col">
      {/* Top bar */}
      <div className="px-4 pt-4 pb-2 max-w-[480px] mx-auto w-full">
        <div className="flex items-center gap-3 mb-4">
          {showBackButton && (
            <button
              onClick={goBack}
              className="p-1.5 -ml-1.5 text-[#6b5744] hover:text-[#2B180A] transition-colors"
            >
              <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
              </svg>
            </button>
          )}
          <div className="flex-1">
            <ProgressBar current={stepIndex} total={STEP_ORDER.length} />
          </div>
        </div>
      </div>

      {/* Step content */}
      <div className="flex-1 px-4 pb-8 max-w-[480px] mx-auto w-full">
        <div
          ref={stepRef}
          key={step}
          className={direction === 'forward' ? 'reg-slide-forward' : 'reg-slide-backward'}
        >
          {renderStep()}
        </div>
      </div>
    </div>
  )
}
