// AgOS · TSP-3 · Раздел закупок МПК. Таб «Мои заявки» + таб «Маркет-борд».

import { useState } from 'react'
import { ShellFrame } from '../../components/ShellFrame'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { MarketBatch } from '../data/pools'
import type { Pool, PoolStatus } from '../types'

interface Props {
  pools: Pool[]
  batches: MarketBatch[]
  onBack: () => void
  onCreatePool: () => void
  onOpenPool: (id: string) => void
  onOpenBatch: (id: string) => void
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

function progressColor(pct: number): string {
  if (pct < 50) return 'var(--primary)'
  if (pct <= 80) return 'var(--amber)'
  return 'var(--ok)'
}

function PoolCard({ p, onClick }: { p: Pool; onClick: () => void }) {
  const pct = p.totalHeads > 0 ? Math.round((p.filledHeads / p.totalHeads) * 100) : 0
  return (
    <button className="pool-card" onClick={onClick}>
      <div className="pool-card-t">{p.title}</div>
      <div className="pool-card-sub">{p.createdAt} · окно: {p.targetMonth}</div>
      <div className="pool-progress">
        <div className="pool-progress-fill" style={{ width: `${pct}%`, background: progressColor(pct) }} />
      </div>
      <div className="pool-card-sub">
        {p.filledHeads} из {p.totalHeads} гол ·{' '}
        <span className={'pool-chip ' + chipClass(p.status)}>{CHIP_LABEL[p.status]}</span>
      </div>
    </button>
  )
}

export function MpkTspScreen({ pools, batches, onBack, onCreatePool, onOpenPool, onOpenBatch }: Props) {
  const [tab, setTab] = useState<'pools' | 'board'>('pools')

  const activeCount = pools.filter((p) => p.status === 'filling' || p.status === 'executing').length
  const totalTonnes = Math.round(
    pools.filter((p) => p.status === 'executing').reduce((s, p) => s + p.filledHeads * 0.45, 0),
  )
  const dealsCount = pools.filter((p) => p.status === 'executed').length

  return (
    <ShellFrame noTabs label="МПК · Закупки">
      <div className="mpk-head">
        <button className="mpk-back" onClick={onBack} aria-label="Назад">←</button>
        <div className="mpk-title">TSP — Закупки</div>
        <button className="mpk-new" onClick={onCreatePool}>+ Создать</button>
      </div>

      <div className="mpk-stats-row">
        <div className="mpk-stat-pill">
          <div className="mpk-stat-v">{activeCount}</div>
          <div className="mpk-stat-l">Активных заявок</div>
        </div>
        <div className="mpk-stat-pill">
          <div className="mpk-stat-v">{totalTonnes} т</div>
          <div className="mpk-stat-l">Набрано</div>
        </div>
        <div className="mpk-stat-pill">
          <div className="mpk-stat-v">{dealsCount}</div>
          <div className="mpk-stat-l">Сделок</div>
        </div>
      </div>

      <div className="mpk-tabs">
        <button className={'mpk-tab' + (tab === 'pools' ? ' active' : '')} onClick={() => setTab('pools')}>
          Мои заявки
        </button>
        <button className={'mpk-tab' + (tab === 'board' ? ' active' : '')} onClick={() => setTab('board')}>
          Маркет-борд
        </button>
      </div>

      {tab === 'pools' ? (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: '12px 14px' }}>
          {pools.length === 0 ? (
            <div className="mpk-lock" style={{ border: 'none' }}>
              <div className="mpk-lock-t">Нет заявок на закупку</div>
              <button className="mpk-new" onClick={onCreatePool}>+ Создать первую заявку</button>
            </div>
          ) : (
            pools.map((p) => <PoolCard key={p.id} p={p} onClick={() => onOpenPool(p.id)} />)
          )}
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: '12px 14px' }}>
          <div className="mpk-field-label" style={{ margin: 0 }}>
            <span className="mb-live-dot" />Доступные партии · {batches.length}
          </div>
          {batches.map((b) => {
            const tonnes = Math.round((b.heads * b.avgWeight) / 100) / 10
            return (
              <button key={b.id} className="mb-card" onClick={() => onOpenBatch(b.id)}>
                <div className="mb-card-t">{b.catName}</div>
                <div className="mb-card-sub">{b.region} · {b.heads} гол. · ~{b.avgWeight} кг</div>
                <div className="mb-card-sub">{tonnes} т живого веса</div>
                <div className="mb-card-price">Мин. цена: {fmtMoney(b.minPrice)}{NBSP}₸/кг</div>
                {b.suitable
                  ? <div className="mb-suitable ok">Подходит ✓</div>
                  : <div className="mb-suitable no">{b.suitableNote}</div>}
              </button>
            )
          })}
        </div>
      )}
    </ShellFrame>
  )
}
