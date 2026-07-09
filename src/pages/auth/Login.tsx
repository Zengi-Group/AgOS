import { useEffect, useRef, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { loadMyContext, pickShellPath } from '@/lib/account'
import { toast } from 'sonner'
import { T } from '@/lib/auth-ui/tokens'
import { AuthShell, AuthBody, TopBar, H1, Lede, StickyDock, CTA, Field, inputStyle, PinCells } from '@/lib/auth-ui/primitives'

type Step = 'phone' | 'pin'

const STEP_LABELS: Record<Step, string> = { phone: 'Номер', pin: 'PIN' }

export function Login() {
  const navigate = useNavigate()
  const location = useLocation()
  const [phone, setPhone] = useState('+7')
  const [pin, setPin] = useState('')
  const [step, setStep] = useState<Step>('phone')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const pinRef = useRef<HTMLInputElement>(null)

  // ── auth logic preserved from previous Login (Supabase phone+PIN) ──
  const phoneDigits = phone.replace(/\D/g, '').slice(1)
  const maskedPhone =
    phoneDigits.length >= 7 ? `+7 (${phoneDigits.slice(0, 3)}) ${phoneDigits.slice(3, 6)}-••-••` : phone

  const formatPhone = (value: string) => {
    const digits = value.replace(/\D/g, '')
    if (digits.length <= 1) return '+7'
    const rest = digits.slice(1, 11)
    let formatted = '+7'
    if (rest.length > 0) formatted += ' (' + rest.slice(0, 3)
    if (rest.length >= 3) formatted += ') ' + rest.slice(3, 6)
    if (rest.length >= 6) formatted += '-' + rest.slice(6, 8)
    if (rest.length >= 8) formatted += '-' + rest.slice(8, 10)
    return formatted
  }

  const phoneValid = phone.replace(/\D/g, '').length === 11

  const handlePhoneSubmit = () => {
    if (!phoneValid) {
      setError('Введите номер телефона полностью')
      return
    }
    setError(null)
    setStep('pin')
  }

  const handlePinSubmit = async (value: string) => {
    if (value.length < 6 || isLoading) return
    setError(null)
    setIsLoading(true)
    try {
      const { error: authError } = await supabase.auth.signInWithPassword({
        phone: `+7${phoneDigits}`,
        password: value,
      })
      if (authError) {
        setError('Неверный PIN — попробуйте ещё раз')
        setPin('')
        return
      }
      toast.success('Вход выполнен')
      // Deep-link (куда вёл RequireAuth) имеет приоритет; иначе шелл по роли орг-ии.
      const from = (location.state as { from?: { pathname?: string } })?.from?.pathname
      if (from) {
        navigate(from, { replace: true })
      } else {
        const ctx = await loadMyContext()
        navigate(pickShellPath(ctx), { replace: true })
      }
    } catch {
      setError('Ошибка входа')
    } finally {
      setIsLoading(false)
    }
  }

  // авто-submit при вводе 6 цифр PIN
  useEffect(() => {
    if (pin.length === 6) void handlePinSubmit(pin)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pin])

  useEffect(() => {
    if (step === 'pin') pinRef.current?.focus()
  }, [step])

  const back = () => {
    if (step === 'pin') {
      setStep('phone')
      setPin('')
      setError(null)
      return
    }
    navigate('/')
  }

  return (
    <AuthShell>
      <TopBar label={STEP_LABELS[step]} onBack={back} />
      <AuthBody>
        {step === 'phone' ? (
          <>
            <H1>Вход в кабинет</H1>
            <Lede>Введите номер, который использовали при регистрации. Далее введёте PIN.</Lede>
            <Field label="Мобильный номер">
              <input
                type="tel"
                inputMode="tel"
                autoFocus
                value={phone}
                onChange={(e) => {
                  setPhone(formatPhone(e.target.value))
                  setError(null)
                }}
                onKeyDown={(e) => e.key === 'Enter' && handlePhoneSubmit()}
                placeholder="+7 (___) ___-__-__"
                style={inputStyle}
              />
            </Field>
            {error && (
              <div style={{ marginTop: 4, color: T.red, fontSize: 13 }}>{error}</div>
            )}
            <div style={{ marginTop: 24, textAlign: 'center' }}>
              <button
                onClick={() => navigate('/register')}
                style={{
                  background: 'transparent',
                  border: 'none',
                  padding: '12px 16px',
                  minHeight: 44,
                  color: T.fg2,
                  fontFamily: T.font,
                  fontSize: 15,
                  cursor: 'pointer',
                  WebkitTapHighlightColor: 'transparent',
                }}
              >
                Нет аккаунта? <span style={{ color: T.accent, fontWeight: 500 }}>Зарегистрироваться ›</span>
              </button>
            </div>
            <StickyDock>
              <CTA disabled={!phoneValid} onClick={handlePhoneSubmit}>
                Продолжить
              </CTA>
            </StickyDock>
          </>
        ) : (
          <div onClick={() => pinRef.current?.focus()} style={{ display: 'flex', flexDirection: 'column', cursor: 'text' }}>
            <H1>Введите PIN</H1>
            <Lede>6 цифр для входа. Номер: {maskedPhone}</Lede>
            <PinCells value={pin} error={!!error} />
            <div style={{ minHeight: 20, marginTop: 14, color: T.red, fontSize: 13, textAlign: 'center' }}>
              {error}
            </div>
            <div style={{ marginTop: 8, textAlign: 'center' }}>
              <button
                onClick={() => navigate('/forgot-pin', { state: { phone: `+7${phoneDigits}` } })}
                style={{
                  background: 'transparent',
                  border: 'none',
                  padding: '12px 16px',
                  minHeight: 44,
                  color: T.accent,
                  fontFamily: T.font,
                  fontSize: 15,
                  fontWeight: 500,
                  cursor: 'pointer',
                  WebkitTapHighlightColor: 'transparent',
                }}
              >
                Забыли PIN?
              </button>
            </div>
            {isLoading && (
              <div style={{ marginTop: 8, textAlign: 'center', fontSize: 13, color: T.fg3 }}>Проверка…</div>
            )}
            <input
              ref={pinRef}
              type="tel"
              inputMode="numeric"
              enterKeyHint="done"
              pattern="[0-9]*"
              autoComplete="one-time-code"
              maxLength={6}
              value={pin}
              disabled={isLoading}
              onChange={(e) => {
                setPin(e.target.value.replace(/\D/g, '').slice(0, 6))
                setError(null)
              }}
              style={{ position: 'absolute', opacity: 0, pointerEvents: 'none', width: 1, height: 1, border: 0, padding: 0, margin: 0 }}
            />
          </div>
        )}
      </AuthBody>
    </AuthShell>
  )
}
