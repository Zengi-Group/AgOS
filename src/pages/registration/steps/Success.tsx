import { useNavigate } from 'react-router-dom'
import type { RoleType } from '../constants'

interface SuccessProps {
  role: RoleType
  phone?: string
  companyName?: string
}

const CABINET_CONTENT: Record<
  RoleType,
  {
    kpi: { n: string; t: string }[]
    tasks: string[]
    cta: string
    route: string
  }
> = {
  farmer: {
    kpi: [{ n: '0', t: 'голов' }, { n: '0', t: 'групп' }, { n: '—', t: 'корма' }],
    tasks: ['Добавить группы стада', 'Указать остатки кормов', 'Первый чекап здоровья'],
    cta: 'В кабинет →',
    route: '/cabinet',
  },
  mpk: {
    kpi: [{ n: '0', t: 'пулов' }, { n: '—', t: 'закуп' }, { n: '0', t: 'команда' }],
    tasks: ['Посмотреть доступные пулы', 'Настроить критерии закупа', 'Пригласить команду'],
    cta: 'В кабинет →',
    route: '/cabinet',
  },
  services: {
    kpi: [{ n: '0', t: 'услуг' }, { n: '0', t: 'зон' }, { n: 'off', t: 'приём' }],
    tasks: ['Заполнить прайс-лист', 'Указать зоны обслуживания', 'Включить приём заявок'],
    cta: 'В кабинет →',
    route: '/cabinet',
  },
  feed_producer: {
    kpi: [{ n: '0', t: 'позиций' }, { n: '0', t: 'складов' }, { n: 'off', t: 'заказы' }],
    tasks: ['Настроить каталог кормов', 'Указать склады', 'Запустить приём заказов'],
    cta: 'В кабинет →',
    route: '/cabinet',
  },
  expert: {
    kpi: [{ n: '0', t: 'заявок' }, { n: '0', t: 'клиентов' }, { n: '—', t: 'рейтинг' }],
    tasks: ['Дождаться одобрения профиля', 'Настроить расписание', 'Принять первую заявку'],
    cta: 'В кабинет →',
    route: '/cabinet',
  },
}

export function Success({ role, companyName = '' }: SuccessProps) {
  const navigate = useNavigate()
  const content = CABINET_CONTENT[role]

  return (
    <div className="space-y-4 reg-benefit-enter">
      {/* Mini app chrome */}
      <div className="flex items-center gap-2.5 pb-3 border-b border-dashed border-[#e8ddd0]">
        <div className="w-7 h-7 rounded-lg bg-[hsl(24,73%,54%)] flex items-center justify-center text-white font-bold text-sm shrink-0">
          Т
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-[13px] font-semibold text-[#2B180A] truncate leading-tight">
            {companyName || 'Ваша организация'}
          </div>
          <div className="text-[10px] text-[#6b5744]/60 uppercase tracking-wide font-mono">
            TURAN · на рассмотрении
          </div>
        </div>
      </div>

      {/* Welcome */}
      <div>
        <h2 className="text-[22px] font-semibold text-[#2B180A] font-serif leading-tight">
          Добро пожаловать
        </h2>
        <p className="text-sm text-[#6b5744] mt-1">
          Кабинет создан. Вот что сделать первым.
        </p>
      </div>

      {/* KPI grid */}
      <div className="grid grid-cols-3 gap-2">
        {content.kpi.map((k, i) => (
          <div
            key={i}
            className="border border-[#e8ddd0] rounded-xl p-2.5 bg-white text-center"
          >
            <div className="text-[22px] font-semibold text-[#2B180A] font-serif leading-tight">
              {k.n}
            </div>
            <div className="text-[9px] text-[#6b5744] uppercase tracking-wide font-mono mt-0.5">
              {k.t}
            </div>
          </div>
        ))}
      </div>

      {/* Task list */}
      <div className="border border-[#e8ddd0] rounded-xl overflow-hidden bg-white">
        <div className="px-3 py-2 bg-[#fdf6ee] border-b border-[#e8ddd0] flex justify-between items-center">
          <span className="text-[10px] text-[#6b5744] uppercase tracking-wide font-mono">
            Первые шаги
          </span>
          <span className="text-[10px] text-[#6b5744]/60 font-mono">0 / 3</span>
        </div>
        {content.tasks.map((task, i) => (
          <div
            key={i}
            className="flex items-center gap-2.5 px-3 py-2.5 text-sm text-[#2B180A]"
            style={{ borderTop: i === 0 ? 'none' : '1px dashed #e8ddd0' }}
          >
            <div className="w-3.5 h-3.5 border border-[hsl(24,73%,54%)] rounded shrink-0" />
            <span className="flex-1">{task}</span>
            <span className="text-[#6b5744]/40 text-xs">→</span>
          </div>
        ))}
      </div>

      {/* Membership pending banner */}
      <div className="flex gap-2.5 items-start p-3 rounded-xl border border-dashed border-[hsl(24,73%,54%)] bg-[hsl(24,73%,54%)]/5">
        <span className="text-[hsl(24,73%,54%)] text-base leading-none mt-0.5">⧗</span>
        <div className="text-[12px] text-[#2B180A]/70 leading-relaxed">
          <span className="font-semibold text-[#2B180A]">Заявка в ТУРАН · на рассмотрении</span>
          <br />Обычно 1–3 дня. Уведомим в WhatsApp.
        </div>
      </div>

      <button
        onClick={() => navigate(content.route)}
        className="reg-btn-primary w-full"
      >
        {content.cta}
      </button>
    </div>
  )
}
