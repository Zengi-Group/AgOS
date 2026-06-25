import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { FloatingInput } from '../components/FloatingInput'
import { PhoneInput } from '../components/PhoneInput'
import { OtpInput } from '../components/OtpInput'
import type { RegistrationFormData } from '../constants'

interface ContactProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

export function Contact({ formData, onChange, onNext }: ContactProps) {
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [isSending, setIsSending] = useState(false)
  const [isVerifying, setIsVerifying] = useState(false)
  const [otpValue, setOtpValue] = useState('')
  const [countdown, setCountdown] = useState(0)

  const maskedPhone = formData.phone.length >= 7
    ? `+7 (${formData.phone.slice(0, 3)}) ${formData.phone.slice(3, 6)}-••-••`
    : `+7 ${formData.phone}`

  useEffect(() => {
    if (countdown <= 0) return
    const t = setTimeout(() => setCountdown((c) => c - 1), 1000)
    return () => clearTimeout(t)
  }, [countdown])

  const validateContact = () => {
    const errs: Record<string, string> = {}
    if (!formData.full_name.trim() || formData.full_name.trim().length < 2) {
      errs.full_name = 'Введите ваше имя'
    }
    if (formData.phone.length < 10) {
      errs.phone = 'Введите номер телефона'
    }
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSendOtp = async () => {
    if (!validateContact()) return
    setIsSending(true)
    try {
      const { data, error } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'send', phone: `+7${formData.phone}` },
      })
      if (error || data?.error) {
        toast.error(data?.error || error?.message || 'Ошибка отправки кода')
        return
      }
      onChange({ otp_sent: true, verification_id: data.verificationId })
      setCountdown(60)
    } catch {
      toast.error('Ошибка отправки кода')
    } finally {
      setIsSending(false)
    }
  }

  const handleVerifyOtp = async (token: string) => {
    if (token.length < 6) return
    setIsVerifying(true)
    try {
      const { data, error } = await supabase.functions.invoke('bird-otp', {
        body: {
          action: 'check',
          verificationId: formData.verification_id,
          code: token,
        },
      })
      if (error || !data?.verified) {
        toast.error(data?.error || 'Неверный код — попробуйте ещё раз')
        setOtpValue('')
        return
      }
      onChange({ otp_verified: true })
      onNext()
    } catch {
      toast.error('Ошибка проверки кода')
    } finally {
      setIsVerifying(false)
    }
  }

  const handleResend = async () => {
    if (countdown > 0 || isSending) return
    setIsSending(true)
    try {
      const { data, error } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'send', phone: `+7${formData.phone}` },
      })
      if (error || data?.error) { toast.error(data?.error || error?.message); return }
      onChange({ verification_id: data.verificationId })
      setOtpValue('')
      setCountdown(60)
    } catch {
      toast.error('Ошибка отправки')
    } finally {
      setIsSending(false)
    }
  }

  // Phase 2: OTP verification
  if (formData.otp_sent) {
    return (
      <div className="space-y-6">
        <div className="text-center space-y-2">
          <h2 className="text-xl font-semibold text-[#2B180A] font-serif">
            Код из SMS
          </h2>
          <p className="text-sm text-[#6b5744]">
            Отправили на {maskedPhone}
          </p>
        </div>

        <OtpInput
          value={otpValue}
          onChange={setOtpValue}
          onComplete={handleVerifyOtp}
          disabled={isVerifying}
        />

        <button
          onClick={() => handleVerifyOtp(otpValue)}
          disabled={otpValue.length < 6 || isVerifying}
          className="reg-btn-primary w-full flex items-center justify-center gap-2"
        >
          {isVerifying && <Loader2 className="h-4 w-4 animate-spin" />}
          {isVerifying ? 'Проверка…' : 'Подтвердить'}
        </button>

        <p className="text-center text-sm text-[#6b5744]">
          Не пришло?{' '}
          {countdown > 0 ? (
            <span className="text-[#6b5744]/50">через {countdown} сек.</span>
          ) : (
            <button
              onClick={handleResend}
              disabled={isSending}
              className="text-[hsl(24,73%,54%)] font-medium hover:underline"
            >
              {isSending ? 'Отправка…' : 'Отправить снова'}
            </button>
          )}
        </p>

        <button
          onClick={() => { onChange({ otp_sent: false }); setOtpValue('') }}
          className="w-full text-center text-sm text-[#6b5744]/50 hover:text-[#6b5744] transition-colors"
        >
          ← Изменить номер
        </button>
      </div>
    )
  }

  // Phase 1: contact form
  return (
    <div className="space-y-6">
      <div className="text-center space-y-2">
        <h2 className="text-xl font-semibold text-[#2B180A] font-serif">
          Как с вами связаться?
        </h2>
        <p className="text-sm text-[#6b5744]">
          SMS-код придёт на указанный номер
        </p>
      </div>

      <div className="space-y-4">
        <FloatingInput
          label="Ваше имя"
          value={formData.full_name}
          onChange={(v) => {
            onChange({ full_name: v })
            if (errors.full_name) setErrors((e) => ({ ...e, full_name: '' }))
          }}
          error={errors.full_name}
        />

        <PhoneInput
          value={formData.phone}
          onChange={(v) => {
            onChange({ phone: v })
            if (errors.phone) setErrors((e) => ({ ...e, phone: '' }))
          }}
          error={errors.phone}
        />
      </div>

      <button
        onClick={handleSendOtp}
        disabled={isSending}
        className="reg-btn-primary w-full flex items-center justify-center gap-2"
      >
        {isSending && <Loader2 className="h-4 w-4 animate-spin" />}
        {isSending ? 'Отправка…' : 'Получить код'}
      </button>

      <p className="text-center text-sm text-[#6b5744]">
        Уже есть аккаунт?{' '}
        <Link to="/login" className="text-[hsl(24,73%,54%)] font-medium hover:underline">
          Войти
        </Link>
      </p>
    </div>
  )
}
