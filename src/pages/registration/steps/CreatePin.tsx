import { useState } from 'react'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { H1, Lede, StickyDock, CTA } from '@/lib/auth-ui/primitives'
import { PinInput } from '../components/PinInput'
import type { RegistrationFormData } from '../constants'

interface CreatePinProps {
  formData: RegistrationFormData
  onChange: (updates: Partial<RegistrationFormData>) => void
  onNext: () => void
}

export function CreatePin({ formData, onChange, onNext }: CreatePinProps) {
  const [pin, setPin] = useState('')
  const [pinConfirm, setPinConfirm] = useState('')
  const [step, setStep] = useState<'enter' | 'confirm'>('enter')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const phone = `+7${formData.phone}`

  const handlePinEntered = (value: string) => {
    if (value.length < 6) return
    setPin(value)
    setStep('confirm')
    setPinConfirm('')
    setError(null)
  }

  const handleConfirm = async (value: string) => {
    if (value.length < 6) return
    if (value !== pin) {
      setError('PIN-коды не совпадают — попробуйте снова')
      setPinConfirm('')
      setStep('enter')
      setPin('')
      return
    }
    setError(null)
    setIsLoading(true)
    try {
      const { data, error: fnErr } = await supabase.functions.invoke('bird-otp', {
        body: { action: 'register', phone, pin: value },
      })
      if (fnErr || data?.error) {
        toast.error(data?.error || fnErr?.message || 'Ошибка создания аккаунта')
        return
      }

      // Sign in immediately after account creation
      const { error: signInError } = await supabase.auth.signInWithPassword({ phone, password: value })
      if (signInError) {
        toast.error('Аккаунт создан — войдите через /login')
        return
      }

      onChange({ password: value })
      onNext()
    } catch {
      toast.error('Ошибка сети — проверьте соединение')
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <>
      <H1>{step === 'enter' ? 'Придумайте PIN' : 'Повторите PIN'}</H1>
      <Lede>{step === 'enter' ? '6 цифр для быстрого входа в приложение.' : 'Введите те же 6 цифр ещё раз.'}</Lede>

      {step === 'enter' ? (
        <PinInput key="enter" value={pin} onChange={setPin} onComplete={handlePinEntered} disabled={isLoading} error={error ?? undefined} />
      ) : (
        <PinInput key="confirm" value={pinConfirm} onChange={setPinConfirm} onComplete={handleConfirm} disabled={isLoading} error={error ?? undefined} />
      )}

      {step === 'confirm' && (
        <StickyDock>
          <CTA disabled={pinConfirm.length < 6 || isLoading} onClick={() => handleConfirm(pinConfirm)}>
            {isLoading ? 'Создание аккаунта…' : 'Подтвердить'}
          </CTA>
        </StickyDock>
      )}
    </>
  )
}
