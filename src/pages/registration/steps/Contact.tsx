import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede, Field, inputStyle, StickyDock, CTA, AuthAltAction } from '@/lib/auth-ui/primitives'
import { OtpInput } from '../components/OtpInput'
import { PhonePicker } from '@/components/PhonePicker'
import { maskPhoneE164 } from '@/lib/phone'
import { isValidPhoneNumber } from 'libphonenumber-js'
import type { RegistrationFormData } from '../constants'

interface ContactProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

// formData.phone хранит международный номер в формате E.164 («+77001234567»).
// Для KZ (страна по умолчанию в PhonePicker) значение == прежний контракт `+7`+10 цифр.

export function Contact({ formData, onChange, onNext }: ContactProps) {
  const navigate = useNavigate()
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [isSending, setIsSending] = useState(false)
  const [isVerifying, setIsVerifying] = useState(false)
  const [otpValue, setOtpValue] = useState('')
  const [countdown, setCountdown] = useState(0)

  const maskedPhone = maskPhoneE164(formData.phone)

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
    if (!isValidPhoneNumber(formData.phone)) {
      errs.phone = 'Введите номер телефона полностью'
    }
    setErrors(errs)
    return Object.keys(errs).length === 0
  }

  const handleSendOtp = async () => {
    if (!validateContact()) return
    setIsSending(true)
    try {
      const { data, error } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'send', phone: formData.phone },
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
        body: { action: 'check', verificationId: formData.verification_id, code: token },
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
        body: { action: 'send', phone: formData.phone },
      })
      if (error || data?.error) {
        toast.error(data?.error || error?.message)
        return
      }
      onChange({ verification_id: data.verificationId })
      setOtpValue('')
      setCountdown(60)
    } catch {
      toast.error('Ошибка отправки')
    } finally {
      setIsSending(false)
    }
  }

  // ── Phase 2: OTP verification ──
  if (formData.otp_sent) {
    return (
      <>
        <H1>Код из SMS</H1>
        <Lede>Отправили 6-значный код на {maskedPhone}. Введите его ниже.</Lede>
        <OtpInput value={otpValue} onChange={setOtpValue} onComplete={handleVerifyOtp} disabled={isVerifying} />

        <div style={{ marginTop: 24, fontSize: 13, color: T.fg3, textAlign: 'center' }}>
          {countdown > 0 ? (
            <>Отправить снова через {countdown} c</>
          ) : (
            <button
              onClick={handleResend}
              disabled={isSending}
              style={{ background: 'none', border: 'none', color: T.fg, textDecoration: 'underline', cursor: 'pointer', fontFamily: T.font, fontSize: 14, minHeight: 44, padding: '10px 16px', WebkitTapHighlightColor: 'transparent' }}
            >
              {isSending ? 'Отправка…' : 'Отправить снова'}
            </button>
          )}
        </div>

        <div style={{ textAlign: 'center' }}>
          <button
            onClick={() => {
              onChange({ otp_sent: false })
              setOtpValue('')
            }}
            style={{ background: 'transparent', border: 'none', padding: '12px 16px', minHeight: 44, color: T.fg3, fontFamily: T.font, fontSize: 14, cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}
          >
            ← Изменить номер
          </button>
        </div>

        <StickyDock>
          <CTA disabled={otpValue.length !== 6 || isVerifying} onClick={() => handleVerifyOtp(otpValue)}>
            {isVerifying ? 'Проверка…' : 'Подтвердить'}
          </CTA>
        </StickyDock>
      </>
    )
  }

  // ── Phase 1: contact form ──
  return (
    <>
      <H1>С чего начнём?</H1>
      <Lede>Один номер — вход навсегда. Пароль не нужен, только SMS-код.</Lede>

      <Field label="Ваше имя">
        <input
          style={inputStyle}
          value={formData.full_name}
          onChange={(e) => {
            onChange({ full_name: e.target.value })
            if (errors.full_name) setErrors((prev) => ({ ...prev, full_name: '' }))
          }}
          placeholder="Как к вам обращаться"
          autoComplete="name"
          autoCapitalize="words"
          autoFocus
        />
        {errors.full_name && <div style={{ fontSize: 12, color: T.red, marginTop: 6 }}>{errors.full_name}</div>}
      </Field>

      <Field label="Мобильный номер">
        <PhonePicker
          value={formData.phone}
          onChange={(v) => {
            onChange({ phone: v })
            if (errors.phone) setErrors((prev) => ({ ...prev, phone: '' }))
          }}
          error={!!errors.phone}
        />
        {errors.phone && <div style={{ fontSize: 12, color: T.red, marginTop: 6 }}>{errors.phone}</div>}
      </Field>

      <StickyDock>
        <CTA disabled={isSending} onClick={handleSendOtp}>
          {isSending ? 'Отправка…' : 'Получить код'}
        </CTA>
        <AuthAltAction prefix="Есть аккаунт?" action="Войти" onClick={() => navigate('/login')} />
      </StickyDock>
    </>
  )
}
