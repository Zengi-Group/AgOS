import { useNavigate } from 'react-router-dom'
import { CaretRight } from '@phosphor-icons/react'
import { T } from '@/lib/auth-ui/tokens'
import { H1, Lede, StickyDock, AuthAltAction } from '@/lib/auth-ui/primitives'
import { ROLE_ICONS } from '../roleIcons'
import type { RoleType } from '../constants'

const ROLES: { value: RoleType; title: string; sub: string }[] = [
  { value: 'farmer', title: 'Фермер', sub: 'Продаю партии, читаю цены, беру услуги.' },
  { value: 'mpk', title: 'МПК / Откормплощадка', sub: 'Закупаю скот у ферм.' },
  { value: 'services', title: 'Сервисная компания', sub: 'Оказываю услуги фермерам.' },
  { value: 'feed_producer', title: 'Кормопроизводитель', sub: 'Произвожу и продаю корма.' },
  { value: 'expert', title: 'Эксперт / консультант', sub: 'Консультирую фермеров.' },
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

      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {ROLES.map((r) => {
          const Icon = ROLE_ICONS[r.value]
          return (
            <button
              key={r.value}
              onClick={() => onSelect(r.value)}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 14,
                textAlign: 'left',
                padding: '13px 16px',
                borderRadius: 14,
                background: T.bgC,
                border: `1px solid ${T.bd}`,
                color: T.fg,
                fontFamily: T.font,
                cursor: 'pointer',
                transition: 'all 120ms',
              }}
            >
              <Icon size={26} weight="light" color={T.fg} style={{ flexShrink: 0 }} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 20, fontWeight: 600, letterSpacing: '-0.01em', lineHeight: 1.15 }}>{r.title}</div>
                <div style={{ fontSize: 13, color: T.fg2, lineHeight: 1.4, marginTop: 2 }}>{r.sub}</div>
              </div>
              <CaretRight size={18} weight="light" color={T.fg3} style={{ flexShrink: 0 }} />
            </button>
          )
        })}
      </div>

      <StickyDock>
        <AuthAltAction prefix="Уже есть аккаунт?" action="Войти" onClick={() => navigate('/login')} />
      </StickyDock>
    </>
  )
}
