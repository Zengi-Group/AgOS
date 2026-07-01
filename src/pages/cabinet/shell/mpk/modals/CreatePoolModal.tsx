// AgOS · TSP-3 · Модал «Заявка на закупку». Флор-цена жёстко блокирует публикацию.

import { useState } from 'react'
import { supabase } from '@/lib/supabase'
import { REGIONS } from '@/pages/registration/constants'
import { BREEDS } from '@/pages/cabinet/shell/tsp/data/tsp-dicts'
import { Cta } from '../../components/Cta'
import { MPK_CATS, type MpkCatKey, type Pool, type PoolLine } from '../types'

interface Props {
  orgId?: string | null   // org реального МПК — если есть, заявка пишется в БД
  onClose: () => void
  onSubmit: (pool: Pool) => void
}

// Окно поставки → первый день целевого месяца (для pool_requests.target_month).
// Строку собираем из ЛОКАЛЬНЫХ компонент: toISOString() сдвигает локальную полночь
// 1-го числа в UTC и при положительном offset (UTC+5 в KZ) откатывает дату на конец
// прошлого месяца → пул «Этот месяц» рождался просроченным и авто-закрывался.
function windowToDate(key: string): string {
  const off = key === 'm1' ? 1 : key === 'm2' ? 2 : 0
  const d = new Date()
  d.setMonth(d.getMonth() + off, 1)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}

// Реальные области (UUID = public.regions, тот же список что в регистрации).
// Мультивыбор: пустой набор = «Все области» → p_region_ids=null → пул матчится по
// любому региону. МПК может отметить одну или несколько конкретных областей.
const WINDOWS: { k: string; t: string }[] = [
  { k: 'm0', t: 'Этот месяц' },
  { k: 'm1', t: 'Следующий' },
  { k: 'm2', t: 'Через 2 мес' },
  { k: 'own', t: 'Свои даты' },
]
const CAT_KEYS = Object.keys(MPK_CATS) as MpkCatKey[]

export function CreatePoolModal({ orgId, onClose, onSubmit }: Props) {
  const [saving, setSaving] = useState(false)
  const [totalHeads, setTotalHeads] = useState('')
  // Мультивыбор областей: пустой набор = «Все области».
  const [regionIds, setRegionIds] = useState<string[]>([])
  const allRegions = regionIds.length === 0
  const region = allRegions
    ? 'Все области'
    : regionIds.length === 1
      ? (REGIONS.find((r) => r.id === regionIds[0])?.name ?? 'Область')
      : `${regionIds.length} обл.`
  const [targetMonth, setTargetMonth] = useState('')
  const [lines, setLines] = useState<PoolLine[]>([{ catKey: 'vysshaya', price: 0, breed: '' }])

  const toggleRegion = (id: string) =>
    setRegionIds((ids) => (ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id]))

  const heads = parseInt(totalHeads, 10)
  const headsValid = !Number.isNaN(heads) && heads > 0

  const targetMonthLabel = WINDOWS.find((w) => w.k === targetMonth)?.t ?? ''

  const canPublish =
    headsValid &&
    lines.length > 0 &&
    lines.every((l) => l.catKey && l.price >= MPK_CATS[l.catKey].floorPrice) &&
    targetMonth !== ''

  const patchLine = (i: number, patch: Partial<PoolLine>) =>
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)))
  const addLine = () => setLines((ls) => [...ls, { catKey: 'pervaya', price: 0, breed: '' }])
  const delLine = (i: number) => setLines((ls) => ls.filter((_, idx) => idx !== i))

  const buildPool = (status: 'filling'): Pool => {
    const first = lines[0]
    return {
    id: `p${Date.now()}`,
    status,
    title: first ? `${MPK_CATS[first.catKey].name} · ${region}` : `Закупка · ${region}`,
    region,
    totalHeads: heads,
    filledHeads: 0,
    targetMonth: targetMonthLabel || 'этот месяц',
    lines,
    suppliers: [],
    createdAt: 'сегодня',
    }
  }

  // Записать заявку в БД: create_pool_request → activate. Реальный pool_id
  // проставляем в Pool.id, чтобы оффер на партию матчился к настоящему пулу.
  const persist = async (pool: Pool): Promise<Pool> => {
    if (!orgId) return pool
    try {
      const { data: reqId, error: e1 } = await supabase.rpc('rpc_self_create_pool_request', {
        p_organization_id: orgId,
        p_total_heads: heads,
        p_target_month: windowToDate(targetMonth),
        p_region_id: regionIds[0] ?? null,
        p_region_ids: regionIds.length ? regionIds : null,
        p_accepted_skus: lines.map((l) => ({
          code: l.catKey,
          price: l.price,
          maxHeads: l.maxHeads ?? null,
          breed: l.breed || null,
        })),
        p_notes: null,
      })
      if (e1 || !reqId) return pool
      const { data: act, error: e2 } = await supabase.rpc('rpc_self_activate_pool_request', {
        p_request_id: reqId,
      })
      const poolId = (act as { pool_id?: string } | null)?.pool_id
      if (e2 || !poolId) return pool
      return { ...pool, id: poolId }
    } catch {
      return pool
    }
  }

  const publish = async () => {
    if (!canPublish || saving) return
    setSaving(true)
    const pool = await persist(buildPool('filling'))
    onSubmit(pool)
  }

  return (
    <div className="mpk-modal">
      <div className="mpk-modal-head">
        <div className="mpk-modal-title">Заявка на закупку</div>
        <button className="mpk-modal-close" onClick={onClose} aria-label="Закрыть">×</button>
      </div>

      <div className="mpk-modal-body">
        <div>
          <div className="mpk-field-label">Общий объём закупа (голов) *</div>
          <input
            className="mpk-input"
            type="number"
            min={1}
            value={totalHeads}
            placeholder="Сколько голов"
            onChange={(e) => setTotalHeads(e.target.value)}
          />
        </div>

        <div>
          <div className="mpk-field-label">Регионы закупа</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <button
              className={'pool-chip ' + (allRegions ? 'filling' : '')}
              style={{ padding: '8px 12px', fontSize: 12, cursor: 'pointer', border: 'none' }}
              onClick={() => setRegionIds([])}
            >
              Все области
            </button>
            {REGIONS.map((r) => (
              <button
                key={r.id}
                className={'pool-chip ' + (regionIds.includes(r.id) ? 'filling' : '')}
                style={{ padding: '8px 12px', fontSize: 12, cursor: 'pointer', border: 'none' }}
                onClick={() => toggleRegion(r.id)}
              >
                {r.name}
              </button>
            ))}
          </div>
          <div className="mpk-hint" style={{ marginTop: 6, fontSize: 11, opacity: 0.7 }}>
            Не выбрано ни одной = все области. Можно отметить несколько.
          </div>
        </div>

        <div>
          <div className="mpk-field-label">Окно поставки</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {WINDOWS.map((w) => (
              <button
                key={w.k}
                className={'pool-chip ' + (targetMonth === w.k ? 'filling' : '')}
                style={{ padding: '8px 12px', fontSize: 12, cursor: 'pointer', border: 'none' }}
                onClick={() => setTargetMonth(w.k)}
              >
                {w.t}
              </button>
            ))}
          </div>
        </div>

        <div>
          <div className="mpk-field-label">Категории и породы</div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {lines.map((l, i) => {
              const floor = MPK_CATS[l.catKey].floorPrice
              const below = l.price > 0 && l.price < floor
              return (
                <div key={i}>
                  <div className="pool-line-row">
                    <select
                      className="mpk-select"
                      value={l.catKey}
                      onChange={(e) => patchLine(i, { catKey: e.target.value as MpkCatKey })}
                    >
                      {CAT_KEYS.map((k) => <option key={k} value={k}>{MPK_CATS[k].name}</option>)}
                    </select>
                    <input
                      className={'mpk-input' + (below ? ' error' : '')}
                      type="number"
                      min={1}
                      value={l.price || ''}
                      placeholder="Цена ₸/кг"
                      onChange={(e) => patchLine(i, { price: parseInt(e.target.value, 10) || 0 })}
                    />
                    <input
                      className="mpk-input"
                      type="number"
                      min={1}
                      value={l.maxHeads ?? ''}
                      placeholder="Макс гол"
                      onChange={(e) => {
                        const v = parseInt(e.target.value, 10)
                        patchLine(i, { maxHeads: Number.isNaN(v) ? undefined : v })
                      }}
                    />
                    {lines.length > 1 && (
                      <button className="pool-line-del" onClick={() => delLine(i)} aria-label="Удалить">×</button>
                    )}
                  </div>
                  <select
                    className="mpk-select"
                    style={{ marginTop: 6, width: '100%' }}
                    value={l.breed ?? ''}
                    onChange={(e) => patchLine(i, { breed: e.target.value })}
                  >
                    <option value="">Любая порода</option>
                    {BREEDS.map((b) => <option key={b} value={b}>{b}</option>)}
                  </select>
                  {below && <div className="mpk-error-hint">Минимум {floor} ₸/кг</div>}
                </div>
              )
            })}
          </div>
          <button
            className="mpk-back"
            style={{ color: 'var(--primary)', fontSize: 13, fontWeight: 700, paddingLeft: 0 }}
            onClick={addLine}
          >
            + Добавить строку (категория + порода)
          </button>
        </div>

        <Cta onClick={publish} disabled={!canPublish || saving}>
          {saving ? 'Публикуем…' : 'Опубликовать'}
        </Cta>
        <Cta variant="ghost" onClick={() => onSubmit(buildPool('filling'))}>Сохранить черновик</Cta>
      </div>
    </div>
  )
}
