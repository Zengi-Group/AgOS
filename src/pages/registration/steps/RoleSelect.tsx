import { useNavigate } from 'react-router-dom'
import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede } from '@/lib/auth-ui/primitives'
import type { RoleType } from '../constants'

const ROLES: { value: RoleType; title: string; sub: string; meta: string }[] = [
  { value: 'farmer', title: 'Фермер', sub: 'Продаю партии, читаю цены, беру услуги.', meta: 'Доступ откроется сразу' },
  { value: 'mpk', title: 'МПК / Откормплощадка', sub: 'Мясоперерабатывающий комбинат. Закупаю скот у ферм.', meta: 'После проверки TURAN — 1–3 дня' },
  { value: 'services', title: 'Сервисная компания', sub: 'Оказываю услуги фермерам.', meta: 'После проверки TURAN' },
  { value: 'feed_producer', title: 'Кормопроизводитель', sub: 'Произвожу и продаю корма.', meta: 'После проверки TURAN' },
  { value: 'expert', title: 'Эксперт / консультант', sub: 'Консультирую фермеров.', meta: 'После проверки TURAN — 1–3 дня' },
]

interface RoleSelectProps {
  onSelect: (role: RoleType) => void
}

export function RoleSelect({ onSelect }: RoleSelectProps) {
  const navigate = useNavigate()

  return (
    <>
      <H1>Кто вы в TURAN?</H1>
      <Lede>Кабинет и лента подстроятся под роль. От неё зависят поля регистрации.</Lede>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {ROLES.map((r) => (
          <button
            key={r.value}
            onClick={() => onSelect(r.value)}
            style={{
              textAlign: 'left',
              padding: '18px 18px',
              borderRadius: 14,
              background: T.bgC,
              border: `1px solid ${T.bd}`,
              color: T.fg,
              fontFamily: T.font,
              cursor: 'pointer',
              transition: 'all 120ms',
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6, gap: 10 }}>
              <div style={{ fontSize: 20, fontWeight: 600, letterSpacing: '-0.01em' }}>{r.title}</div>
              <span style={{ color: T.fg3, fontSize: 22, lineHeight: 1 }}>›</span>
            </div>
            <div style={{ fontSize: 14, color: T.fg2, lineHeight: 1.45, marginBottom: 10 }}>{r.sub}</div>
            <div style={{ fontSize: 11, color: T.fg3, letterSpacing: '.06em', textTransform: 'uppercase' }}>{r.meta}</div>
          </button>
        ))}
      </div>

      <div style={{ marginTop: 24, textAlign: 'center' }}>
        <button
          onClick={() => navigate('/login')}
          style={{ background: 'transparent', border: 'none', padding: '12px 16px', minHeight: 44, color: T.fg2, fontFamily: T.font, fontSize: 15, cursor: 'pointer', WebkitTapHighlightColor: 'transparent' }}
        >
          Уже есть аккаунт? <span style={{ color: T.accent, fontWeight: 500 }}>Войти ›</span>
        </button>
      </div>
    </>
  )
}
