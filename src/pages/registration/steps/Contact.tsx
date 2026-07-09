import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede, Field, inputStyle, StickyDock, CTA } from '@/lib/auth-ui/primitives'
import { OtpInput } from '../components/OtpInput'
import type { RegistrationFormData } from '../constants'

interface ContactProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

// formData.phone хранит 10 цифр национального номера (без кода +7).
function fmtNational(digits: string): string {
  const d = digits.replace(/\D/g, '').slice(0, 10)
  let out = ''
  if (d.length > 0) out += '(' + d.slice(0, 3)
  if (d.length >= 3) out += ') ' + d.slice(3, 6)
  if (d.length >= 6) out += '-' + d.slice(6, 8)
  if (d.length >= 8) out += '-' + d.slice(8, 10)
  return out
}

export function Contact({ formData, onChange, onNext }: ContactProps) {
  const navigate = useNavigate()
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [isSending, setIsSending] = useState(false)
  const [isVerifying, setIsVerifying] = useState(false)
  const [otpValue, setOtpValue] = useState('')
  const [countdown, setCountdown] = useState(0)

  const maskedPhone =
    formData.phone.length >= 7
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
        body: { action: 'send', phone: `+7${formData.phone}` },
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
          autoFocus
        />
        {errors.full_name && <div style={{ fontSize: 12, color: T.red, marginTop: 6 }}>{errors.full_name}</div>}
      </Field>

      <Field label="Мобильный номер">
        <div style={{ display: 'flex', alignItems: 'stretch', gap: 8 }}>
          <div
            style={{
              display: 'grid',
              placeItems: 'center',
              height: 52,
              padding: '0 16px',
              background: T.bgM,
              border: `1px solid ${T.bd}`,
              borderRadius: 12,
              color: T.fg,
              fontFamily: T.font,
              fontSize: 17,
              fontWeight: 500,
            }}
          >
            +7
          </div>
          <input
            style={{ ...inputStyle, flex: 1 }}
            type="tel"
            inputMode="numeric"
            value={fmtNational(formData.phone)}
            onChange={(e) => {
              onChange({ phone: e.target.value.replace(/\D/g, '').slice(0, 10) })
              if (errors.phone) setErrors((prev) => ({ ...prev, phone: '' }))
            }}
            placeholder="(___) ___-__-__"
          />
        </div>
        {errors.phone && <div style={{ fontSize: 12, color: T.red, marginTop: 6 }}>{errors.phone}</div>}
      </Field>

      <div style={{ marginTop: 24, textAlign: 'center' }}>
        <button
          onClick={() => navigate('/login')}
          style={{ background: 'transparent', border: 'none', padding: '12px 16px', minHeight: 44, color: T.fg2, fontFamily: T.font, fontSize: 15, cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}
        >
          Есть аккаунт? <span style={{ color: T.accent, fontWeight: 500 }}>Войти ›</span>
        </button>
      </div>

      <StickyDock>
        <CTA disabled={isSending} onClick={handleSendOtp}>
          {isSending ? 'Отправка…' : 'Получить код'}
        </CTA>
      </StickyDock>
    </>
  )
}
