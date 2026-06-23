import { useNavigate } from 'react-router-dom'
import { cn } from '@/lib/utils'
import type { RoleType } from '../constants'

const ROLES: { value: RoleType; title: string; desc: string; icon: string }[] = [
  { value: 'farmer', title: 'Фермер', desc: 'Я выращиваю скот', icon: '/icons/cow.svg' },
  { value: 'mpk', title: 'Мясокомбинат / Откормплощадка', desc: 'Я закупаю скот', icon: '/icons/factory.svg' },
  { value: 'services', title: 'Сервисная компания', desc: 'Я оказываю услуги фермерам', icon: '/icons/wrench.svg' },
  { value: 'feed_producer', title: 'Кормопроизводитель', desc: 'Я произвожу/продаю корма', icon: '/icons/wheat.svg' },
  { value: 'expert', title: 'Эксперт / консультант', desc: 'Я консультирую фермеров', icon: '/icons/wrench.svg' },
]

// Simple icon fallbacks using unicode
const ROLE_ICONS: Record<RoleType, string> = {
  farmer: '\uD83D\uDC04',
  mpk: '\uD83C\uDFED',
  services: '\uD83D\uDD27',
  feed_producer: '\uD83C\uDF3E',
  expert: '\uD83D\uDC68\u200D\u2695\uFE0F',
}

interface RoleSelectProps {
  onSelect: (role: RoleType) => void
}

export function RoleSelect({ onSelect }: RoleSelectProps) {
  const navigate = useNavigate()

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-2xl font-semibold text-[#2B180A] font-serif leading-tight">
          Кто вы?
        </h1>
        <p className="text-sm text-[#6b5744] mt-1">
          Выберите роль — от неё зависят поля и кабинет
        </p>
      </div>

      <div className="space-y-2.5">
        {ROLES.map((role) => (
          <button
            key={role.value}
            onClick={() => onSelect(role.value)}
            className={cn(
              'w-full flex items-center gap-3 p-3.5 bg-white rounded-xl border border-[#e8ddd0]',
              'hover:border-[hsl(24,73%,54%)] hover:bg-[#fdf6ee] active:scale-[0.99]',
              'transition-all text-left group'
            )}
          >
            <div className="w-10 h-10 rounded-lg bg-[#fdf6ee] group-hover:bg-white flex items-center justify-center text-xl shrink-0 transition-colors">
              {ROLE_ICONS[role.value]}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-[14px] font-semibold text-[#2B180A] leading-tight">
                {role.title}
              </p>
              <p className="text-[12px] text-[#6b5744] mt-0.5">{role.desc}</p>
            </div>
            <span className="text-[#6b5744]/30 group-hover:text-[hsl(24,73%,54%)] transition-colors text-xl leading-none">›</span>
          </button>
        ))}
      </div>

      <p className="text-center text-sm text-[#6b5744] pt-2">
        Уже есть аккаунт?{' '}
        <button
          onClick={() => navigate('/login')}
          className="text-[hsl(24,73%,54%)] font-medium hover:underline"
        >
          Войти
        </button>
      </p>
    </div>
  )
}
