import { useNavigate } from 'react-router-dom'
import { T } from '@/lib/auth-ui/tokens'
import { StickyDock, CTA } from '@/lib/auth-ui/primitives'
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
    route: '/mpk',
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

  const mono: React.CSSProperties = { fontFamily: T.mono }
  return (
    <div style={{ fontFamily: T.font, display: 'flex', flexDirection: 'column', gap: 16, paddingTop: 8 }}>
      {/* Mini app chrome */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, paddingBottom: 12, borderBottom: `1px dashed ${T.bd}` }}>
        <div style={{ width: 28, height: 28, borderRadius: 8, background: T.accent, display: 'grid', placeItems: 'center', color: T.ctaFg, fontWeight: 700, fontSize: 14, flexShrink: 0 }}>Т</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: T.fg, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', lineHeight: 1.2 }}>
            {companyName || 'Ваша организация'}
          </div>
          <div style={{ ...mono, fontSize: 10, color: T.fg3, textTransform: 'uppercase', letterSpacing: '.06em' }}>TURAN · на рассмотрении</div>
        </div>
      </div>

      {/* Welcome */}
      <div>
        <h2 style={{ fontFamily: T.font, fontSize: 22, fontWeight: 600, color: T.fg, lineHeight: 1.2, letterSpacing: '-0.02em', margin: 0 }}>Добро пожаловать</h2>
        <p style={{ fontSize: 14, color: T.fg2, marginTop: 4 }}>Кабинет создан. Вот что сделать первым.</p>
      </div>

      {/* KPI grid */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
        {content.kpi.map((k, i) => (
          <div key={i} style={{ border: `1px solid ${T.bd}`, borderRadius: 12, padding: 10, background: T.bgC, textAlign: 'center' }}>
            <div style={{ fontSize: 22, fontWeight: 600, color: T.fg, lineHeight: 1.2 }}>{k.n}</div>
            <div style={{ ...mono, fontSize: 9, color: T.fg3, textTransform: 'uppercase', letterSpacing: '.06em', marginTop: 2 }}>{k.t}</div>
          </div>
        ))}
      </div>

      {/* Task list */}
      <div style={{ border: `1px solid ${T.bd}`, borderRadius: 12, overflow: 'hidden', background: T.bgC }}>
        <div style={{ padding: '8px 12px', background: T.bgS, borderBottom: `1px solid ${T.bd}`, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ ...mono, fontSize: 10, color: T.fg3, textTransform: 'uppercase', letterSpacing: '.06em' }}>Первые шаги</span>
          <span style={{ ...mono, fontSize: 10, color: T.fg3 }}>0 / 3</span>
        </div>
        {content.tasks.map((task, i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', fontSize: 14, color: T.fg, borderTop: i === 0 ? 'none' : `1px dashed ${T.bd}` }}>
            <div style={{ width: 14, height: 14, border: `1px solid ${T.accent}`, borderRadius: 4, flexShrink: 0 }} />
            <span style={{ flex: 1 }}>{task}</span>
            <span style={{ color: T.fg3, fontSize: 12 }}>→</span>
          </div>
        ))}
      </div>

      {/* Membership pending banner */}
      <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', padding: 12, borderRadius: 12, border: `1px dashed ${T.accent}`, background: 'rgba(184,113,10,0.06)' }}>
        <span style={{ color: T.accent, fontSize: 16, lineHeight: 1, marginTop: 2 }}>⧗</span>
        <div style={{ fontSize: 12, color: T.fg2, lineHeight: 1.5 }}>
          <span style={{ fontWeight: 600, color: T.fg }}>Заявка в ТУРАН · на рассмотрении</span>
          <br />Обычно 1–3 дня. Уведомим в WhatsApp.
        </div>
      </div>

      <StickyDock>
        {role === 'farmer' ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <CTA onClick={() => navigate('/membership')}>Подать заявку на членство</CTA>
            <CTA variant="ghost" onClick={() => navigate(content.route)}>Перейти в кабинет</CTA>
          </div>
        ) : (
          <CTA onClick={() => navigate(content.route)}>{content.cta}</CTA>
        )}
      </StickyDock>
    </div>
  )
}
