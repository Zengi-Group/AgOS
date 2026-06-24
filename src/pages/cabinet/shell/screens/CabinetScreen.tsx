// AgOS · Этап 1 · Кабинет хозяйства (shell/cabinet.jsx CabinetScreen).
// Вход через аватар на Главной. Тексты — слово в слово из прототипа.

import type { ReactNode } from 'react'
import { ShellFrame } from '../components/ShellFrame'
import { ShellHead } from '../components/ShellHead'
import { ShIc } from '../components/icons/ShIc'
import { MEMBERSHIP_DICT, FARM } from '../store'
import type { MembershipStatus } from '../types'
import type { AccountProfile } from '@/lib/account'

function CabRow({ k, v, amber }: { k: string; v: ReactNode; amber?: boolean }) {
  return (
    <div className={'cab-row' + (amber ? ' amber' : '')}>
      <span className="cab-k mono">{k}</span>
      <span className="cab-v">{v}</span>
    </div>
  )
}

function CabToggle({ on, onChange, locked, t, sub }: { on: boolean; onChange?: () => void; locked?: boolean; t: string; sub?: string }) {
  return (
    <button className={'cab-tgl' + (locked ? ' locked' : '')} onClick={locked ? undefined : onChange} disabled={locked}>
      <span className="cab-tgl-body">
        <span className="cab-tgl-t">{t}</span>
        {sub && <span className="cab-tgl-s">{sub}</span>}
      </span>
      <span className={'sw' + (on ? ' on' : '')}><i /></span>
    </button>
  )
}

// Правовая форма из регистрации (user_metadata.legal_form) → подпись для кабинета.
const LEGAL_FORM_LABELS: Record<string, string> = {
  kh: 'Крестьянское хозяйство',
  ip: 'ИП',
  too: 'ТОО',
  individual: 'Физлицо',
}

interface Props {
  membership: MembershipStatus
  profileIncomplete: boolean
  newsOn: boolean
  onNewsToggle: () => void
  memberAct: (act: string) => void
  onBack: () => void
  onTuran: () => void
  onLogout: () => void
  profile?: AccountProfile | null
}

export function CabinetScreen({ membership, profileIncomplete, newsOn, onNewsToggle, memberAct, onBack, onTuran, onLogout, profile }: Props) {
  const m = MEMBERSHIP_DICT[membership]
  const plate = m.plate

  // Реальный аккаунт перекрывает демо-данные; при отсутствии профиля — демо-фолбэк.
  const farmName = profile?.name || FARM.name
  const district = profile?.district || FARM.district
  const binValue = profile?.bin ?? (profileIncomplete ? null : '880712301234')
  const binMissing = !binValue
  const ownerName = profile?.ownerName || 'Аскар Жумабеков'
  const phoneText = profile?.phone || '+7 705 4XX XX XX'
  const legalFormText = (profile?.legalForm && LEGAL_FORM_LABELS[profile.legalForm]) || 'Крестьянское хозяйство'

  return (
    <ShellFrame label={'Кабинет · ' + membership}>
      <button className="back-strip" onClick={onBack}><span className="arrow mono">‹</span> Главная</button>
      <ShellHead big title="Кабинет" sub={farmName} />
      <div className="home-stack">
        <div className="blk">
          <div className="blk-h mono">ХОЗЯЙСТВО</div>
          <div className="cab-card">
            <CabRow k="НАЗВАНИЕ" v={farmName} />
            <CabRow k="ФОРМА" v={legalFormText} />
            <CabRow k="БИН" v={binMissing ? 'не указан' : binValue} amber={binMissing} />
            <CabRow k="РАЙОН" v={district} />
            {binMissing && (
              <div className="cab-warn">Профиль неполный — добавьте БИН, чтобы ускорить проверку заявок.</div>
            )}
          </div>
        </div>
        <div className="blk">
          <div className="blk-h mono">ЧЛЕНСТВО TURAN</div>
          <div className="cab-card">
            <div className="cab-memb">
              <span className={'cab-memb-dot ' + (membership === 'active' ? 'ok' : ['approved', 'expiring', 'grace'].includes(membership) ? 'warn' : 'off')} />
              <span className="cab-memb-t">{m.cab}</span>
            </div>
            {m.cabSub && <div className="cab-memb-sub">{m.cabSub}</div>}
            {plate && plate.cta && (
              <button className="mp-cta wide" onClick={() => memberAct(plate.act as string)}>{plate.cta}</button>
            )}
          </div>
        </div>
        <div className="blk">
          <div className="blk-h mono">ЛИЧНЫЕ ДАННЫЕ</div>
          <div className="cab-card">
            <CabRow k="ИМЯ" v={ownerName} />
            <CabRow k="ТЕЛЕФОН" v={<span className="mono">{phoneText}</span>} />
          </div>
        </div>
        <div className="blk">
          <div className="blk-h mono">УВЕДОМЛЕНИЯ</div>
          <div className="cab-card">
            <CabToggle on locked t="Системные" sub="сделки, решения, членство — обязательные" />
            <CabToggle on={newsOn} onChange={onNewsToggle} t="Новости TURAN" sub="семинары, объявления ассоциации" />
          </div>
        </div>
        <div className="blk">
          <div className="blk-h mono">О ПРИЛОЖЕНИИ</div>
          <div className="cab-card">
            <button className="cab-link" onClick={onTuran}>Обратиться в TURAN <span className="att-arr"><ShIc k="chev" size={13} /></span></button>
            <button className="cab-link quiet" onClick={onLogout}>Выйти из аккаунта</button>
            <div className="cab-ver mono">AgOS · пилот · версия P1c</div>
          </div>
        </div>
      </div>
    </ShellFrame>
  )
}
