import { useState } from 'react'
import { useNavigate, useLocation, Link } from 'react-router-dom'
import { Loader2, Phone } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { loadMyContext, pickShellPath } from '@/lib/account'
import { toast } from 'sonner'
import { PinInput } from '@/pages/registration/components/PinInput'

export function Login() {
  const navigate = useNavigate()
  const location = useLocation()
  const [phone, setPhone] = useState('+7')
  const [pin, setPin] = useState('')
  const [step, setStep] = useState<'phone' | 'pin'>('phone')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const phoneDigits = phone.replace(/\D/g, '').slice(1)
  const maskedPhone = phoneDigits.length >= 7
    ? `+7 (${phoneDigits.slice(0, 3)}) ${phoneDigits.slice(3, 6)}-••-••`
    : phone

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

  const handlePhoneSubmit = () => {
    const digits = phone.replace(/\D/g, '')
    if (digits.length !== 11) {
      setError('Введите номер телефона полностью')
      return
    }
    setError(null)
    setStep('pin')
  }

  const handlePinSubmit = async (value: string) => {
    if (value.length < 6) return
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

  return (
    <div className="min-h-screen bg-[#fdf6ee] flex items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-[#2B180A] font-serif">ТУРАН</h1>
          <p className="text-sm text-[#6b5744] mt-1">Вход в личный кабинет</p>
        </div>

        {step === 'phone' ? (
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
                  onKeyDown={(e) => e.key === 'Enter' && handlePhoneSubmit()}
                  placeholder="+7 (___) ___-__-__"
                  className="w-full pl-10 pr-4 py-2.5 border border-[#e8ddd0] rounded-xl bg-white text-[#2B180A] focus:outline-none focus:ring-2 focus:ring-[hsl(24,73%,54%)]/30 focus:border-[hsl(24,73%,54%)]"
                />
              </div>
            </div>

            {error && (
              <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>
            )}

            <button
              onClick={handlePhoneSubmit}
              className="w-full py-2.5 bg-[hsl(24,73%,54%)] text-white rounded-xl font-medium hover:bg-[hsl(24,73%,44%)] transition-colors"
            >
              Продолжить
            </button>
          </div>
        ) : (
          <div className="space-y-4">
            <div className="text-center space-y-1">
              <p className="text-sm font-medium text-[#2B180A]">Введите PIN-код</p>
              <p className="text-sm text-[#6b5744]">{maskedPhone}</p>
            </div>

            <PinInput
              value={pin}
              onChange={setPin}
              onComplete={handlePinSubmit}
              label="Ваш 6-значный PIN"
              disabled={isLoading}
            />

            <button
              onClick={() => handlePinSubmit(pin)}
              disabled={pin.length < 6 || isLoading}
              className="w-full py-2.5 bg-[hsl(24,73%,54%)] text-white rounded-xl font-medium hover:bg-[hsl(24,73%,44%)] disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
            >
              {isLoading && <Loader2 className="h-4 w-4 animate-spin" />}
              {isLoading ? 'Проверка…' : 'Войти'}
            </button>

            {error && (
              <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>
            )}

            <div className="flex justify-between text-sm">
              <button
                onClick={() => { setStep('phone'); setPin(''); setError(null) }}
                className="text-[#6b5744]/50 hover:text-[#6b5744] transition-colors"
              >
                ← Изменить номер
              </button>
              <Link
                to="/forgot-pin"
                state={{ phone: `+7${phoneDigits}` }}
                className="text-[hsl(24,73%,54%)] hover:underline"
              >
                Забыл PIN
              </Link>
            </div>
          </div>
        )}

        <p className="text-center text-sm text-[#6b5744]">
          Нет аккаунта?{' '}
          <Link to="/register" className="text-[hsl(24,73%,54%)] font-medium hover:underline">
            Зарегистрироваться
          </Link>
        </p>
      </div>
    </div>
  )
}
