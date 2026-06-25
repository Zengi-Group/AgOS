// AgOS · Вход в админку по логину/паролю (минуя phone+PIN).
// Аккаунт создаётся скриптом scripts/seed_admin.mjs (service-role, серверный ключ).
// Пароль НЕ хранится во фронте — его вводит человек здесь. Логин → синтетический email.
//
// Доступ к /admin/* по-прежнему охраняет RequireExpert (fn_is_admin живой fallback).

import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2, Lock, User } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

// Логин «admin» отображается в синтетический email «admin@agos.local».
// Должно совпадать с ADMIN_EMAIL в scripts/seed_admin.mjs.
const ADMIN_EMAIL_DOMAIN = 'agos.local'

export function AdminLogin() {
  const navigate = useNavigate()
  const [login, setLogin] = useState('admin')
  const [password, setPassword] = useState('')
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async () => {
    if (!login.trim() || !password) return
    setError(null)
    setIsLoading(true)
    try {
      // Логин без @ → достроить синтетический email; с @ — использовать как есть.
      const email = login.includes('@') ? login.trim().toLowerCase() : `${login.trim().toLowerCase()}@${ADMIN_EMAIL_DOMAIN}`
      const { error: authError } = await supabase.auth.signInWithPassword({ email, password })
      if (authError) {
        setError('Неверный логин или пароль')
        setPassword('')
        return
      }
      toast.success('Вход выполнен')
      navigate('/admin', { replace: true })
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
          <p className="text-sm text-[#6b5744] mt-1">Вход в администрирование</p>
        </div>

        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-[#2B180A] mb-1.5">Логин</label>
            <div className="relative">
              <User className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-[#6b5744]" />
              <input
                type="text"
                value={login}
                autoComplete="username"
                onChange={(e) => { setLogin(e.target.value); setError(null) }}
                onKeyDown={(e) => e.key === 'Enter' && submit()}
                placeholder="admin"
                className="w-full pl-10 pr-4 py-2.5 border border-[#e8ddd0] rounded-xl bg-white text-[#2B180A] focus:outline-none focus:ring-2 focus:ring-[hsl(24,73%,54%)]/30 focus:border-[hsl(24,73%,54%)]"
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-[#2B180A] mb-1.5">Пароль</label>
            <div className="relative">
              <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-[#6b5744]" />
              <input
                type="password"
                value={password}
                autoComplete="current-password"
                onChange={(e) => { setPassword(e.target.value); setError(null) }}
                onKeyDown={(e) => e.key === 'Enter' && submit()}
                placeholder="••••••••"
                className="w-full pl-10 pr-4 py-2.5 border border-[#e8ddd0] rounded-xl bg-white text-[#2B180A] focus:outline-none focus:ring-2 focus:ring-[hsl(24,73%,54%)]/30 focus:border-[hsl(24,73%,54%)]"
              />
            </div>
          </div>

          {error && (
            <p className="text-sm text-red-600 bg-red-50 px-3 py-2 rounded-lg">{error}</p>
          )}

          <button
            onClick={submit}
            disabled={!login.trim() || !password || isLoading}
            className="w-full py-2.5 bg-[hsl(24,73%,54%)] text-white rounded-xl font-medium hover:bg-[hsl(24,73%,44%)] disabled:opacity-50 transition-colors flex items-center justify-center gap-2"
          >
            {isLoading && <Loader2 className="h-4 w-4 animate-spin" />}
            {isLoading ? 'Проверка…' : 'Войти'}
          </button>
        </div>
      </div>
    </div>
  )
}
