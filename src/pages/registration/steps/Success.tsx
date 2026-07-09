import { useNavigate } from 'react-router-dom'
import { T } from '@/lib/auth-ui/tokens'
import { StickyDock, CTA, Check } from '@/lib/auth-ui/primitives'
import type { RoleType } from '../constants'

interface SuccessProps {
  role: RoleType
  phone?: string
  companyName?: string
}

const CONTENT: Record<
  RoleType,
  { title: string; body: string; route: string }
> = {
  farmer: {
    title: 'Почти всё готово',
    body: 'Для полного доступа к торгам и услугам подайте заявку на членство. Или зайдите в кабинет и оформите её позже.',
    route: '/cabinet',
  },
  mpk: {
    title: 'Готово',
    body: 'Аккаунт создан. Заходите в кабинет — доступные пулы и настройки закупа уже ждут.',
    route: '/mpk',
  },
  services: {
    title: 'Готово',
    body: 'Аккаунт создан. Заполните прайс-лист и включите приём заявок в кабинете.',
    route: '/cabinet',
  },
  feed_producer: {
    title: 'Готово',
    body: 'Аккаунт создан. Настройте каталог кормов и запустите приём заказов в кабинете.',
    route: '/cabinet',
  },
  expert: {
    title: 'Заявка отправлена',
    body: 'Профиль отправлен на проверку. Мы уведомим вас о решении — загляните в кабинет.',
    route: '/cabinet',
  },
}

export function Success({ role }: SuccessProps) {
  const navigate = useNavigate()
  const c = CONTENT[role]

  return (
    <div
      style={{
        fontFamily: T.font,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        textAlign: 'center',
        paddingTop: 48,
      }}
    >
      {/* Success mark */}
      <div
        style={{
          width: 80,
          height: 80,
          borderRadius: 999,
          background: T.accent,
          display: 'grid',
          placeItems: 'center',
          marginBottom: 28,
        }}
      >
        <Check size={38} stroke={T.ctaFg} width={3} />
      </div>

      <h1
        style={{
          fontFamily: T.font,
          fontSize: 30,
          fontWeight: 700,
          letterSpacing: '-0.02em',
          lineHeight: 1.15,
          color: T.fg,
          margin: 0,
        }}
      >
        {c.title}
      </h1>
      <p
        style={{
          fontFamily: T.font,
          fontSize: 15,
          lineHeight: 1.5,
          color: T.fg2,
          margin: '12px 0 0',
          maxWidth: 320,
        }}
      >
        {c.body}
      </p>

      <StickyDock>
        {role === 'farmer' ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            <CTA onClick={() => navigate('/membership')}>Подать заявку на членство</CTA>
            <CTA variant="ghost" onClick={() => navigate(c.route)}>Перейти в кабинет</CTA>
          </div>
        ) : (
          <CTA onClick={() => navigate(c.route)}>Перейти в кабинет →</CTA>
        )}
      </StickyDock>
    </div>
  )
}
