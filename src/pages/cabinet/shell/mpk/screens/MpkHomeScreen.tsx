// AgOS · TSP-3 · Главная МПК. Герой + два гейт-баннера + TSP-замок/вход + первые шаги.

import { ShellFrame } from '../../components/ShellFrame'
import { Cta } from '../../components/Cta'
import type { MpkMembership, MpkTypeStatus, Pool, PoolStatus } from '../types'

interface Props {
  typeStatus: MpkTypeStatus
  membership: MpkMembership
  pools: Pool[]
  tspOpen: boolean
  orgName: string
  region: string
  bin: string
  onOpenTsp: () => void
  onOpenOffers: () => void
  offersCount: number
  onOpenPool: (id: string) => void
  onOpenContactTuran: (topic?: string) => void
  realAccount?: boolean   // реальный аккаунт МПК (orgId есть) → кнопка членства не «демо»
  onSimulateApprove: () => void
  onSimulateMember: () => void
}

const CHIP_LABEL: Record<PoolStatus, string> = {
  filling: 'Набирается',
  filled: 'Набран',
  executing: 'Приёмка',
  expired: 'Истёк',
  closed: 'Закрыт',
  executed: 'Завершён',
}

function chipClass(s: PoolStatus): string {
  if (s === 'filling') return 'filling'
  if (s === 'executing' || s === 'executed') return 'executing'
  if (s === 'expired' || s === 'closed') return 'expired'
  return ''
}

function MpkTypeBanner({ typeStatus, onSimulateApprove, onOpenContactTuran }: {
  typeStatus: MpkTypeStatus
  onSimulateApprove: () => void
  onOpenContactTuran: (topic?: string) => void
}) {
  if (typeStatus === 'approved') {
    return (
      <div className="mpk-banner ok">
        <div className="mpk-banner-t">✓ Тип МПК подтверждён</div>
      </div>
    )
  }
  if (typeStatus === 'rejected') {
    return (
      <div className="mpk-banner bad">
        <div className="mpk-banner-t">✗ Тип организации не подтверждён</div>
        <div className="mpk-banner-s">Причина: не соответствует требованиям</div>
        <Cta variant="ghost" onClick={() => onOpenContactTuran('Отклонение типа МПК')}>Обратиться в TURAN</Cta>
      </div>
    )
  }
  return (
    <div className="mpk-banner neutral">
      <div className="mpk-banner-t">Проверяем тип организации</div>
      <div className="mpk-banner-s">Подтверждаем: вы — мясокомбинат. 2–5 рабочих дней.</div>
      <Cta variant="ghost" onClick={onSimulateApprove}>демо: Подтвердить</Cta>
    </div>
  )
}

function MpkMemberBanner({ membership, realAccount, onSimulateMember }: {
  membership: MpkMembership
  realAccount?: boolean
  onSimulateMember: () => void
}) {
  if (membership === 'grace' || membership === 'active') {
    return (
      <div className="mpk-banner ok">
        <div className="mpk-banner-t">✓ Членство TURAN активно</div>
      </div>
    )
  }
  return (
    <div className="mpk-banner neutral">
      <div className="mpk-banner-t">Членство в TURAN на рассмотрении</div>
      <div className="mpk-banner-s">1–3 рабочих дня.</div>
      <Cta variant="ghost" onClick={onSimulateMember}>
        {realAccount ? 'Активировать членство' : 'демо: Активировать членство'}
      </Cta>
    </div>
  )
}

export function MpkHomeScreen({
  typeStatus, membership, pools, tspOpen, orgName, region, bin,
  onOpenTsp, onOpenOffers, offersCount, onOpenPool, onOpenContactTuran, realAccount, onSimulateApprove, onSimulateMember,
}: Props) {
  const activeCount = pools.filter((p) => p.status === 'filling' || p.status === 'executing').length
  const totalTonnes = Math.round(
    pools.filter((p) => p.status === 'executing').reduce((s, p) => s + p.filledHeads * 0.45, 0),
  )
  const dealsCount = pools.filter((p) => p.status === 'executed').length
  const recentPools = pools.slice(0, 2)

  return (
    <ShellFrame noTabs label="МПК · Главная">
      {/* 4.1 — Герой */}
      <div className="mpk-hero">
        <div className="mpk-hero-ic">🏭</div>
        <div className="mpk-hero-name">{orgName}</div>
        <div className="mpk-hero-sub">{region} · БИН {bin}</div>
        <div className="mpk-hero-stats">
          <div className="mpk-stat">
            <span className="mpk-stat-v">{activeCount}</span>
            <span className="mpk-stat-l">активных</span>
          </div>
          <div className="mpk-stat">
            <span className="mpk-stat-v">{totalTonnes}т</span>
            <span className="mpk-stat-l">набрано</span>
          </div>
          <div className="mpk-stat">
            <span className="mpk-stat-v">{dealsCount}</span>
            <span className="mpk-stat-l">сделок/мес</span>
          </div>
        </div>
      </div>

      {/* 4.2 — Баннер типа */}
      <MpkTypeBanner
        typeStatus={typeStatus}
        onSimulateApprove={onSimulateApprove}
        onOpenContactTuran={onOpenContactTuran}
      />

      {/* 4.3 — Баннер членства */}
      <MpkMemberBanner membership={membership} realAccount={realAccount} onSimulateMember={onSimulateMember} />

      {/* 4.4 — TSP замок / вход */}
      {!tspOpen ? (
        <div className="mpk-lock">
          <div className="mpk-lock-ic">🔒</div>
          <div className="mpk-lock-t">Доступ к закупкам</div>
          <div className="mpk-lock-s">Доступен после подтверждения типа и активации членства</div>
        </div>
      ) : (
        <div style={{ margin: '10px 14px', display: 'flex', flexDirection: 'column', gap: 10 }}>
          <Cta onClick={onOpenTsp}>Открыть закупки</Cta>
          <button className="pool-card" onClick={onOpenOffers}>
            <div className="pool-card-t">
              📨 Входящие офферы{offersCount > 0 ? ` · ${offersCount}` : ''}
            </div>
            <div className="pool-card-sub">
              {offersCount > 0
                ? 'Поставщики прислали предложения — ответьте'
                : 'Пока нет новых предложений'}
            </div>
          </button>
          {recentPools.map((p) => (
            <button key={p.id} className="pool-card" onClick={() => onOpenPool(p.id)}>
              <div className="pool-card-t">{p.title}</div>
              <div className="pool-card-sub">
                {p.filledHeads}/{p.totalHeads} гол ·{' '}
                <span className={'pool-chip ' + chipClass(p.status)}>{CHIP_LABEL[p.status]}</span>
              </div>
            </button>
          ))}
        </div>
      )}

      {/* 4.5 — Первые шаги (только пока нет доступа) */}
      {!tspOpen && (
        <div style={{ margin: '4px 14px 18px' }}>
          <div className="mpk-field-label">Что нужно сделать:</div>
          <ul style={{ margin: '6px 0 0', paddingLeft: 18, fontSize: 13, color: 'var(--ink-2)', lineHeight: 1.7 }}>
            <li>Заполнить профиль компании</li>
            <li>Дождаться подтверждения типа МПК</li>
            <li>Пригласить команду</li>
          </ul>
        </div>
      )}
    </ShellFrame>
  )
}
