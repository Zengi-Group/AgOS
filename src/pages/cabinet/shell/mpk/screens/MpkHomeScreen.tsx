// AgOS · TSP-3 · Главная МПК. Герой + два гейт-баннера + TSP-замок/вход + первые шаги.

// S6 (ARS-152): IonShellFrame вместо ShellFrame — IonPage + нативный скролл + refresher.
import { IonShellFrame } from '../../components/IonShellFrame'
import { Cta } from '../../components/Cta'
import { useRpc } from '@/hooks/useRpc'
import type { MpkMembership, MpkTypeStatus, Pool, PoolStatus } from '../types'

// Строка из rpc_list_home_banners (см. Docs/AGOS-Slice-AppBanners.md).
interface BannerRow {
  id: string
  title: string
  subtitle?: string | null
  kicker?: string | null
  tone?: 'gold' | 'green' | 'neutral'
  action_type: 'internal' | 'external' | 'none'
  action_target?: string | null
}

interface Props {
  typeStatus: MpkTypeStatus
  membership: MpkMembership
  membershipPeriodEnd: string | null
  membershipNextBillingAt: string | null
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
  // Pull-to-refresh (spec §7): экран с поллингом получает рефетч от MpkApp.
  onRefresh?: () => Promise<unknown>
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

function MpkTypeBanner({ typeStatus, realAccount, onSimulateApprove, onOpenContactTuran }: {
  typeStatus: MpkTypeStatus
  realAccount?: boolean
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
        <div className="mpk-banner-s">Уточните документы и следующий шаг у TURAN.</div>
        <Cta variant="ghost" onClick={() => onOpenContactTuran('Отклонение типа МПК')}>Обратиться в TURAN</Cta>
      </div>
    )
  }
  return (
    <div className="mpk-banner neutral">
      <div className="mpk-banner-t">Статус типа МПК ещё не подтверждён</div>
      <div className="mpk-banner-s">TURAN проверяет сведения и документы организации.</div>
      <Cta
        variant="ghost"
        onClick={realAccount ? () => onOpenContactTuran('Верификация типа МПК') : onSimulateApprove}
      >
        {realAccount ? 'Уточнить статус в TURAN' : 'демо: Подтвердить'}
      </Cta>
    </div>
  )
}

function fmtMpkDate(iso: string | null): string | null {
  if (!iso) return null
  const date = new Date(iso)
  return Number.isNaN(date.getTime())
    ? null
    : date.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' })
}

function MpkMemberBanner({
  membership,
  membershipPeriodEnd,
  membershipNextBillingAt,
  realAccount,
  onSimulateMember,
  onOpenContactTuran,
}: {
  membership: MpkMembership
  membershipPeriodEnd: string | null
  membershipNextBillingAt: string | null
  realAccount?: boolean
  onSimulateMember: () => void
  onOpenContactTuran: (topic?: string) => void
}) {
  const periodEnd = fmtMpkDate(membershipPeriodEnd)
  const nextBillingAt = fmtMpkDate(membershipNextBillingAt)

  if (membership === 'trialing' || membership === 'active') {
    return (
      <div className="mpk-banner ok">
        <div className="mpk-banner-t">✓ Членство TURAN активно</div>
        {membership === 'trialing' && <div className="mpk-banner-s">Пробный период{periodEnd ? ` до ${periodEnd}` : ''}.</div>}
        {membership === 'active' && periodEnd && <div className="mpk-banner-s">Действует до {periodEnd}.</div>}
      </div>
    )
  }

  if (membership === 'grace') {
    return (
      <div className="mpk-banner neutral">
        <div className="mpk-banner-t">Членство временно активно</div>
        <div className="mpk-banner-s">
          {periodEnd ? `Доступ сохранён до ${periodEnd}. ` : ''}
          Оплату и продление подтверждает TURAN вручную.
        </div>
        <Cta variant="ghost" onClick={() => onOpenContactTuran('Проверка оплаты членства')}>Уточнить оплату в TURAN</Cta>
      </div>
    )
  }

  if (membership === 'past_due') {
    return (
      <div className="mpk-banner bad">
        <div className="mpk-banner-t">Членство ожидает проверки оплаты</div>
        <div className="mpk-banner-s">
          {nextBillingAt ? `Дата расчёта: ${nextBillingAt}. ` : ''}
          Для ручной проверки обратитесь в TURAN.
        </div>
        <Cta variant="ghost" onClick={() => onOpenContactTuran('Проверка оплаты членства')}>Связаться с TURAN</Cta>
      </div>
    )
  }

  if (membership === 'expired' || membership === 'canceled' || membership === 'revoked') {
    const title = membership === 'revoked'
      ? 'Доступ к членству приостановлен'
      : membership === 'canceled' ? 'Членство отменено' : 'Срок членства завершён'
    return (
      <div className="mpk-banner bad">
        <div className="mpk-banner-t">{title}</div>
        <div className="mpk-banner-s">Условия дальнейшего оформления уточните у TURAN.</div>
        <Cta variant="ghost" onClick={() => onOpenContactTuran('Статус членства TURAN')}>Связаться с TURAN</Cta>
      </div>
    )
  }

  const isSubmitted = membership === 'submitted'
  return (
    <div className="mpk-banner neutral">
      <div className="mpk-banner-t">{isSubmitted ? 'Членство TURAN ожидает решения' : 'Членство TURAN не оформлено'}</div>
      <div className="mpk-banner-s">
        {isSubmitted ? 'Статус и дальнейшие действия подтверждает TURAN.' : 'Оформление членства выполняется через TURAN.'}
      </div>
      <Cta variant="ghost" onClick={realAccount ? () => onOpenContactTuran('Членство TURAN') : onSimulateMember}>
        {realAccount ? 'Уточнить в TURAN' : 'демо: Активировать членство'}
      </Cta>
    </div>
  )
}

// 4.3b — Промо-плейсмент МПК (управляемый из админки, app='mpk').
// Пустой список → ничего не рендерим (без пустой рамки). Статус-баннеры выше не трогаем.
function MpkPromoBanner({ onOpenTsp, onOpenOffers, onOpenContactTuran }: {
  onOpenTsp: () => void
  onOpenOffers: () => void
  onOpenContactTuran: (topic?: string) => void
}) {
  const { data } = useRpc<BannerRow[]>('rpc_list_home_banners', { p_app: 'mpk', p_membership_variant: 'all' })
  if (!data || data.length === 0) return null

  const onClick = (row: BannerRow): (() => void) | undefined => {
    if (row.action_type === 'external' && row.action_target) {
      const url = row.action_target
      return () => window.open(url, '_blank', 'noopener,noreferrer')
    }
    if (row.action_type === 'internal') {
      switch (row.action_target) {
        case 'open_tsp':    return onOpenTsp
        case 'open_market': return onOpenTsp
        case 'open_offers': return onOpenOffers
        default:            return () => onOpenContactTuran(row.title)
      }
    }
    return undefined
  }

  return (
    <div style={{ margin: '10px 14px', display: 'flex', flexDirection: 'column', gap: 10 }}>
      {data.map((row) => (
        <button key={row.id} className="pool-card" onClick={onClick(row)}>
          {row.kicker && <div className="pool-card-sub" style={{ textTransform: 'uppercase', letterSpacing: '.04em' }}>{row.kicker}</div>}
          <div className="pool-card-t">{row.title}</div>
          {row.subtitle && <div className="pool-card-sub">{row.subtitle}</div>}
        </button>
      ))}
    </div>
  )
}

export function MpkHomeScreen({
  typeStatus, membership, membershipPeriodEnd, membershipNextBillingAt, pools, tspOpen, orgName, region, bin,
  onOpenTsp, onOpenOffers, offersCount, onOpenPool, onOpenContactTuran, realAccount, onSimulateApprove, onSimulateMember,
  onRefresh,
}: Props) {
  const activeCount = pools.filter((p) => p.status === 'filling' || p.status === 'executing').length
  const totalTonnes = Math.round(
    pools.filter((p) => p.status === 'executing').reduce((s, p) => s + p.filledHeads * 0.45, 0),
  )
  const dealsCount = pools.filter((p) => p.status === 'executed').length
  const recentPools = pools.slice(0, 2)

  return (
    <IonShellFrame noTabs label="МПК · Главная" onRefresh={onRefresh}>
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
        realAccount={realAccount}
        onSimulateApprove={onSimulateApprove}
        onOpenContactTuran={onOpenContactTuran}
      />

      {/* 4.3 — Баннер членства */}
      <MpkMemberBanner
        membership={membership}
        membershipPeriodEnd={membershipPeriodEnd}
        membershipNextBillingAt={membershipNextBillingAt}
        realAccount={realAccount}
        onSimulateMember={onSimulateMember}
        onOpenContactTuran={onOpenContactTuran}
      />

      {/* 4.3b — Промо-плейсмент (управляемый из админки) */}
      <MpkPromoBanner onOpenTsp={onOpenTsp} onOpenOffers={onOpenOffers} onOpenContactTuran={onOpenContactTuran} />

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
    </IonShellFrame>
  )
}
