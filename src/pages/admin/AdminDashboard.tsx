import { useNavigate } from 'react-router-dom'
import { Users, Stethoscope, Syringe, Activity, BarChart3, BookOpen, Shield, FileText, Package, DollarSign, LayoutDashboard, Store } from 'lucide-react'
import { useSetTopbar } from '@/components/layout/TopbarContext'
import { useAuth } from '@/hooks/useAuth'

interface DashCard {
  icon: React.ElementType
  label: string
  description: string
  route: string
  color: string
}

const EXPERT_CARDS: DashCard[] = [
  {
    icon: Stethoscope,
    label: 'Ветеринарные кейсы',
    description: 'Очередь обращений от фермеров, диагностика, рекомендации',
    route: '/admin/expert/queue',
    color: 'var(--blue)',
  },
  {
    icon: Syringe,
    label: 'Планы вакцинации',
    description: 'Расписание вакцинации стад, запись выполненных процедур',
    route: '/admin/expert/vaccination',
    color: 'var(--green)',
  },
  {
    icon: Activity,
    label: 'Эпидемиология',
    description: 'Мониторинг эпидемиологических сигналов по регионам',
    route: '/admin/expert/epidemic',
    color: 'var(--amber)',
  },
  {
    icon: BarChart3,
    label: 'Мои показатели',
    description: 'Статистика консультаций и среднее время ответа',
    route: '/admin/expert/kpi',
    color: 'var(--blue)',
  },
]

const ADMIN_ONLY_CARDS: DashCard[] = [
  {
    icon: Users,
    label: 'Заявки на членство',
    description: 'Рассмотрение и управление заявками на вступление в ассоциацию',
    route: '/admin/membership',
    color: 'var(--blue)',
  },
  {
    icon: BookOpen,
    label: 'База знаний',
    description: 'Управление статьями, инструкциями, ветеринарными протоколами',
    route: '/admin/knowledge',
    color: 'var(--green)',
  },
  {
    icon: Shield,
    label: 'Ограничения',
    description: 'Ветеринарные ограничения на реализацию скота',
    route: '/admin/restrictions',
    color: 'var(--amber)',
  },
  {
    icon: Store,
    label: 'Торговая площадка',
    description: 'Все батчи, пулы и сделки с полными данными (обзор)',
    route: '/admin/marketplace',
    color: 'var(--green)',
  },
  {
    icon: Package,
    label: 'Пулы',
    description: 'Управление торговыми пулами и согласование сделок',
    route: '/admin/pools',
    color: 'var(--blue)',
  },
  {
    icon: DollarSign,
    label: 'Ценообразование',
    description: 'Справочные цены и прайс-листы по регионам',
    route: '/admin/pricing',
    color: 'var(--green)',
  },
  {
    icon: FileText,
    label: 'Журнал аудита',
    description: 'История операций и системных событий',
    route: '/admin/audit',
    color: 'var(--blue)',
  },
]

function DashboardCard({ card, onClick }: { card: DashCard; onClick: () => void }) {
  const Icon = card.icon
  return (
    <button
      onClick={onClick}
      className="p-5 bg-card rounded-[10px] border border-border hover:border-[var(--blue)] hover:shadow-sm transition-all text-left"
    >
      <div className="flex items-center gap-3 mb-2">
        <div
          className="w-11 h-11 rounded-[10px] flex items-center justify-center"
          style={{ background: `color-mix(in srgb, ${card.color} 15%, transparent)` }}
        >
          <Icon className="h-5 w-5" style={{ color: card.color }} />
        </div>
        <h3 className="font-medium text-[var(--fg)]">{card.label}</h3>
      </div>
      <p className="text-sm text-[var(--fg2)]">{card.description}</p>
    </button>
  )
}

export function AdminDashboard() {
  const navigate = useNavigate()
  const { isAdmin } = useAuth()
  useSetTopbar({ title: 'Панель управления', titleIcon: <LayoutDashboard size={15} /> })

  return (
    <div className="page space-y-8">
      <p className="text-sm text-[var(--fg2)] mb-6">{isAdmin ? 'Администрирование TURAN' : 'Консоль эксперта TURAN'}</p>

      <section className="space-y-3">
        <h2 className="text-sm font-medium text-[var(--fg2)] uppercase tracking-wider">
          Ветеринария и здоровье
        </h2>
        <div className="grid gap-4 sm:grid-cols-2">
          {EXPERT_CARDS.map(card => (
            <DashboardCard key={card.route} card={card} onClick={() => navigate(card.route)} />
          ))}
        </div>
      </section>

      {isAdmin && (
        <section className="space-y-3">
          <h2 className="text-sm font-medium text-[var(--fg2)] uppercase tracking-wider">
            Администрирование
          </h2>
          <div className="grid gap-4 sm:grid-cols-2">
            {ADMIN_ONLY_CARDS.map(card => (
              <DashboardCard key={card.route} card={card} onClick={() => navigate(card.route)} />
            ))}
          </div>
        </section>
      )}
    </div>
  )
}
