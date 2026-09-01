import { useState, useEffect } from 'react'
import { useNavigate, useLocation, Link } from 'react-router-dom'
import { Phone } from 'lucide-react'
import { TuranLoader } from '@/components/TuranLoader'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { OtpInput } from '@/pages/registration/components/OtpInput'
import { PinInput } from '@/pages/registration/components/PinInput'

type Step = 'phone' | 'otp' | 'new_pin'

export function ForgotPin() {
  const navigate = useNavigate()
  const location = useLocation()
  const [step, setStep] = useState<Step>('phone')
  const [phone, setPhone] = useState(
    (location.state as { phone?: string })?.phone ?? '+7'
  )
  const [otp, setOtp] = useState('')
  const [verificationId, setVerificationId] = useState('')
  const [newPin, setNewPin] = useState('')
  const [pinConfirm, setPinConfirm] = useState('')
  const [pinStep, setPinStep] = useState<'enter' | 'confirm'>('enter')
  const [isLoading, setIsLoading] = useState(false)
  const [countdown, setCountdown] = useState(0)
  const [error, setError] = useState<string | null>(null)

  const phoneDigits = phone.replace(/\D/g, '').slice(1)
  const maskedPhone = phoneDigits.length >= 7
    ? `+7 (${phoneDigits.slice(0, 3)}) ${phoneDigits.slice(3, 6)}-••-••`
    : phone

  useEffect(() => {
    if (countdown <= 0) return
    const t = setTimeout(() => setCountdown((c) => c - 1), 1000)
    return () => clearTimeout(t)
  }, [countdown])

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

  const handleSendOtp = async () => {
    const digits = phone.replace(/\D/g, '')
    if (digits.length !== 11) {
      setError('Введите номер телефона полностью')
      return
    }
    setError(null)
    setIsLoading(true)
    try {
      const { data, error: fnErr } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'send', phone: `+7${phoneDigits}` },
      })
      if (fnErr || data?.error) {
        if (fnErr?.name === 'FunctionsFetchError') {
          console.error('[ForgotPin] bird-otp network error:', fnErr.message)
          setError('Не удаётся связаться с сервером — проверьте соединение')
        } else {
          setError(data?.error || fnErr?.message || 'Ошибка отправки кода')
        }
        return
      }
      setVerificationId(data.verificationId)
      setStep('otp')
      setCountdown(60)
    } catch {
      setError('Ошибка отправки кода')
    } finally {
      setIsLoading(false)
    }
  }

  const handleVerifyOtp = async (token: string) => {
    if (token.length < 6) return
    setError(null)
    setIsLoading(true)
    try {
      const { data, error: fnErr } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'check', verificationId, code: token },
      })
      if (fnErr || !data?.verified) {
        setError(data?.error || 'Неверный код — попробуйте ещё раз')
        setOtp('')
        return
      }
      setStep('new_pin')
    } catch {
      setError('Ошибка проверки кода')
    } finally {
      setIsLoading(false)
    }
  }

  const handleResend = async () => {
    if (countdown > 0 || isLoading) return
    setIsLoading(true)
    try {
      const { data, error: fnErr } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'send', phone: `+7${phoneDigits}` },
      })
      if (fnErr || data?.error) {
        if (fnErr?.name === 'FunctionsFetchError') {
          console.error('[ForgotPin] bird-otp network error:', fnErr.message)
          setError('Не удаётся связаться с сервером — проверьте соединение')
        } else {
          setError(data?.error || fnErr?.message)
        }
        return
      }
      setVerificationId(data.verificationId)
      setOtp('')
      setCountdown(60)
    } catch {
      setError('Ошибка отправки')
    } finally {
      setIsLoading(false)
    }
  }

  const handlePinEntered = (value: string) => {
    if (value.length < 6) return
    setNewPin(value)
    setPinStep('confirm')
    setPinConfirm('')
    setError(null)
  }

  const handlePinConfirm = async (value: string) => {
    if (value.length < 6) return
    if (value !== newPin) {
      setError('PIN-коды не совпадают — попробуйте снова')
      setPinConfirm('')
      setPinStep('enter')
      setNewPin('')
      return
    }
    setError(null)
    setIsLoading(true)
    try {
      const { data, error: fnErr } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'reset_pin', phone: `+7${phoneDigits}`, newPin: value },
      })
      if (fnErr || data?.error) {
        if (fnErr?.name === 'FunctionsFetchError') {
          console.error('[ForgotPin] bird-otp network error:', fnErr.message)
          toast.error('Не удаётся связаться с сервером — проверьте соединение')
        } else {
          toast.error(data?.error || fnErr?.message || 'Ошибка сброса PIN')
        }
        return
      }
      toast.success('PIN успешно изменён')
      navigate('/login', { replace: true })
    } catch {
      toast.error('Ошибка сети — проверьте соединение')
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="min-h-screen bg-[#fdf6ee] flex items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-[#2B180A] font-serif">ТУРАН</h1>
          <p className="text-sm text-[#6b5744] mt-1">Восстановление PIN-кода</p>
        </div>

        {step === 'phone' && (
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-[#2B180A] mb-1.5">
                Номер телефона
              </label>
              <div className="relative">
                <Phone className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-[#6b5744]" />
                <input
                  type="tel"
                  value={phone}
                  onChange={(e) => { setPhone(formatPhone(e.target.value)); setError(null) }}
                  onKeyDown={(e) => e.key === 'Enter' && handleSendOtp()}
                  placeholder="+7 (___) ___-__-__"
                  className="w-full pl-10 pr-4 py-2.5 border border-[#e8ddd0] rounded-xl bg-white text-[#2B180A] focus:outline-none focus:ring-2 focus:ring-[hsl(24,73%,54%)]/30 focus:border-[hsl(24,73%,54%)]"
                />
              </div>
            </div>
            {error && (
              <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>
            )}
            <button
              onClick={handleSendOtp}
              disabled={isLoading}
              className="w-full py-2.5 bg-[hsl(24,73%,54%)] text-white rounded-xl font-medium hover:bg-[hsl(24,73%,44%)] disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
            >
              {isLoading && <TuranLoader variant="spin" size={16} />}
              {isLoading ? 'Отправка…' : 'Получить код'}
            </button>
          </div>
        )}

        {step === 'otp' && (
          <div className="space-y-4">
            <div className="text-center space-y-1">
              <p className="text-sm font-medium text-[#2B180A]">Код из SMS</p>
              <p className="text-sm text-[#6b5744]">Отправили на {maskedPhone}</p>
            </div>

            <OtpInput
              value={otp}
              onChange={setOtp}
              onComplete={handleVerifyOtp}
              disabled={isLoading}
            />

            <button
              onClick={() => handleVerifyOtp(otp)}
              disabled={otp.length < 6 || isLoading}
              className="w-full py-2.5 bg-[hsl(24,73%,54%)] text-white rounded-xl font-medium hover:bg-[hsl(24,73%,44%)] disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
            >
              {isLoading && <TuranLoader variant="spin" size={16} />}
              {isLoading ? 'Проверка…' : 'Подтвердить'}
            </button>

            {error && (
              <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>
            )}

            <p className="text-center text-sm text-[#6b5744]">
              Не пришло?{' '}
              {countdown > 0 ? (
                <span className="text-[#6b5744]/50">через {countdown} сек.</span>
              ) : (
                <button
                  onClick={handleResend}
                  disabled={isLoading}
                  className="text-[hsl(24,73%,54%)] font-medium hover:underline"
                >
                  {isLoading ? 'Отправка…' : 'Отправить снова'}
                </button>
              )}
            </p>

            <button
              onClick={() => { setStep('phone'); setOtp(''); setError(null) }}
              className="w-full text-center text-sm text-[#6b5744]/50 hover:text-[#6b5744] transition-colors"
            >
              ← Изменить номер
            </button>
          </div>
        )}

        {step === 'new_pin' && (
          <div className="space-y-4">
            <div className="text-center space-y-1">
              <p className="text-sm font-medium text-[#2B180A]">
                {pinStep === 'enter' ? 'Новый PIN-код' : 'Повторите PIN-код'}
              </p>
              <p className="text-sm text-[#6b5744]">
                {pinStep === 'enter' ? '6 цифр для входа в аккаунт' : 'Введите PIN ещё раз'}
              </p>
            </div>

            {pinStep === 'enter' ? (
              <PinInput
                key="enter"
                value={newPin}
                onChange={setNewPin}
                onComplete={handlePinEntered}
                label="Введите новый PIN"
                disabled={isLoading}
              />
            ) : (
              <PinInput
                key="confirm"
                value={pinConfirm}
                onChange={setPinConfirm}
                onComplete={handlePinConfirm}
                label="Повторите PIN"
                error={error ?? undefined}
                disabled={isLoading}
              />
            )}

            {pinStep === 'confirm' && (
              <button
                onClick={() => handlePinConfirm(pinConfirm)}
                disabled={pinConfirm.length < 6 || isLoading}
                className="w-full py-2.5 bg-[hsl(24,73%,54%)] text-white rounded-xl font-medium hover:bg-[hsl(24,73%,44%)] disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
              >
                {isLoading && <TuranLoader variant="spin" size={16} />}
                {isLoading ? 'Сохранение…' : 'Сохранить PIN'}
              </button>
            )}
          </div>
        )}

        <p className="text-center text-sm text-[#6b5744]">
          <Link to="/login" className="text-[hsl(24,73%,54%)] font-medium hover:underline">
            ← Назад к входу
          </Link>
        </p>
      </div>
    </div>
  )
}
