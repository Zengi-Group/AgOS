// AgOS · TSP · ARS-229 · Секция «Спрос комбинатов» на экране Рынка фермера.
// Обезличенный агрегат активного спроса МПК (rpc_get_demand_board, M6): категория ·
// регион · индикативная цена · объём. НИКОГДА не раскрывает личность МПК (ст.171,
// aggregate-only; D40 / D-M6-5/12). Обязательный антитраст-дисклеймер под списком.
// Канон: PhIcon-only, плоские строки, тактильный отклик R-28.

import { PhIcon } from './icons/PhIcon'
import { fmtMoney } from '../tsp/data/tsp-utils'
import { NBSP } from '../tsp/data/tsp-dicts'
import { useDemandBoard, type DemandRow } from '../hooks/useDemandBoard'

interface DemandBoardProps {
  orgId: string | null | undefined
}

function priceLabel(r: DemandRow): string {
  if (r.priceMin == null && r.priceMax == null) return '—'
  if (r.priceMin != null && r.priceMax != null && r.priceMin !== r.priceMax) {
    return `${fmtMoney(r.priceMin)}–${fmtMoney(r.priceMax)}${NBSP}₸/кг`
  }
  const p = r.priceAvg ?? r.priceMin ?? r.priceMax
  return p != null ? `${fmtMoney(p)}${NBSP}₸/кг` : '—'
}

function metaLine(r: DemandRow): string {
  const parts: string[] = []
  if (r.regionName) parts.push(r.regionName)
  if (r.targetVolumeKg && r.targetVolumeKg > 0) {
    parts.push(`~${Math.round(r.targetVolumeKg / 100) / 10}${NBSP}т`)
  }
  if (r.lineCount > 1) parts.push(`${r.lineCount} заявок`)
  return parts.join(' · ')
}

export function DemandBoard({ orgId }: DemandBoardProps) {
  const { items, disclaimer, loading, canUse } = useDemandBoard(orgId)

  // Нет backend/аноним — секции нет. Пусто (нет активного спроса) — тоже не показываем.
  if (!canUse) return null
  if (items.length === 0 && !loading) return null

  return (
    <div className="blk">
      <div className="tier-h">
        <span className="tier-h-l">
          <span className="tier-label">СПРОС КОМБИНАТОВ</span>
          {items.length > 0 && <span className="tier-count mk-mono">{items.length}</span>}
        </span>
      </div>

      <div className="mk-demand">
        {items.map((r, i) => (
          <div className="mk-demand-row" key={`${r.categoryName}-${r.regionId ?? 'all'}-${i}`}>
            <span className="mk-demand-ic"><PhIcon name="bag" size={16} /></span>
            <div className="mk-demand-bd">
              <div className="mk-demand-t">{r.categoryName}</div>
              {metaLine(r) && <div className="mk-demand-m">{metaLine(r)}</div>}
            </div>
            <div className="mk-demand-price mk-mono">{priceLabel(r)}</div>
          </div>
        ))}

        {disclaimer && <div className="mk-demand-note">{disclaimer}</div>}
      </div>
    </div>
  )
}
