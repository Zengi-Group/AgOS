import { useNavigate } from 'react-router-dom'
import { useAuth } from '@/hooks/useAuth'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { Stethoscope, Leaf, ChevronRight, LayoutDashboard } from 'lucide-react'
import { Skeleton } from '@/components/ui/skeleton'

export function CabinetDashboard() {
  useSetTopbar({ title: 'Главная', titleIcon: <LayoutDashboard size={15} /> })
  const { userContext, isContextLoading } = useAuth()
  const navigate = useNavigate()

  if (isContextLoading) {
    return (
      <div className="page space-y-4">
        <Skeleton className="h-8 w-48" style={{ background: 'var(--bg-m)' }} />
        <Skeleton className="h-24 w-full rounded-[10px]" style={{ background: 'var(--bg-m)' }} />
        <Skeleton className="h-24 w-full rounded-[10px]" style={{ background: 'var(--bg-m)' }} />
      </div>
    )
  }

  const farm = userContext?.farms?.[0]
  const orgName = userContext?.organizations?.[0]?.name || 'Моя ферма'

  return (
    <div className="page">
      <div className="mb-6">
        <p className="text-base font-semibold text-foreground">{orgName}</p>
        <p className="text-sm mt-1 text-[var(--fg2)]">
          Добро пожаловать в кабинет фермера
        </p>
      </div>

      <div className="space-y-2">
        <button
          onClick={() => navigate('/cabinet-legacy/vet/new')}
          className="group w-full flex items-center gap-4 p-4 rounded-[10px] border cursor-pointer transition-all duration-100 text-left"
          style={{
            background: 'var(--bg-c)',
            borderColor: 'var(--bd)',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.background = 'var(--bg-m)'
            e.currentTarget.style.borderColor = 'var(--bd-h)'
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.background = 'var(--bg-c)'
            e.currentTarget.style.borderColor = 'var(--bd)'
          }}
        >
          <div
            className="w-11 h-11 rounded-[10px] flex items-center justify-center shrink-0"
            style={{ background: 'rgba(224,96,80,0.12)' }}
          >
            <Stethoscope className="w-5 h-5" style={{ color: 'var(--red)' }} />
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-sm font-medium text-foreground">Сообщить о болезни</p>
            <p className="text-xs mt-0.5 text-[var(--fg2)]">
              AI проанализирует симптомы и предложит рекомендации
            </p>
          </div>
          <ChevronRight className="w-4 h-4 shrink-0 transition-colors text-[var(--fg3)]" />
        </button>

        <button
          onClick={() => navigate('/cabinet-legacy/farm')}
          className="group w-full flex items-center gap-4 p-4 rounded-[10px] border cursor-pointer transition-all duration-100 text-left"
          style={{
            background: 'var(--bg-c)',
            borderColor: 'var(--bd)',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.background = 'var(--bg-m)'
            e.currentTarget.style.borderColor = 'var(--bd-h)'
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.background = 'var(--bg-c)'
            e.currentTarget.style.borderColor = 'var(--bd)'
          }}
        >
          <div
            className="w-11 h-11 rounded-[10px] flex items-center justify-center shrink-0"
            style={{ background: 'rgba(94,196,122,0.12)' }}
          >
            <Leaf className="w-5 h-5" style={{ color: 'var(--green)' }} />
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-sm font-medium text-foreground">Профиль фермы</p>
            <p className="text-xs mt-0.5 text-[var(--fg2)]">
              {farm
                ? `${farm.name} — ${farm.herd_groups?.length || 0} групп`
                : 'Заполните данные о ферме'}
            </p>
          </div>
          <ChevronRight className="w-4 h-4 shrink-0 transition-colors text-[var(--fg3)]" />
        </button>
      </div>
    </div>
  )
}
