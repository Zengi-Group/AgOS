// AgOS · TSP-3 · Партия на маркет-борде (анонимно — только регион).

import { useState } from 'react'
import { Cta } from '../../components/Cta'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { MarketBatch } from '../data/pools'
import type { PendingDeal, Pool } from '../types'

interface Props {
  batch: MarketBatch | undefined
  pools: Pool[]   // активные пулы МПК (для привязки)
  onClose: () => void
  toast: (text: string) => void
  onMatch?: (poolId: string, batchId: string, heads: number, price: number) => Promise<void>  // реальный оффер (price = бид МПК ≥ ask)
  onOffer?: (deal: PendingDeal) => void   // прямая покупка: фермер согласился → завершение сделки
}

// Реальный матч возможен только когда и пул, и партия — настоящие строки БД (UUID).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function BatchDetailModal({ batch, pools, onClose, toast, onMatch, onOffer }: Props) {
  const [offer, setOffer] = useState(batch ? String(batch.minPrice + 90) : '')
  const [sending, setSending] = useState(false)
  const [poolId, setPoolId] = useState('')

  if (!batch) {
    return (
      <div className="mpk-modal">
        <div className="mpk-modal-head">
          <div className="mpk-modal-title">Партия не найдена</div>
          <button className="mpk-modal-close" onClick={onClose} aria-label="Закрыть">×</button>
        </div>
      </div>
    )
  }

  const tonnes = Math.round((batch.heads * batch.avgWeight) / 100) / 10
  const offerNum = parseInt(offer, 10)
  const offerValid = !Number.isNaN(offerNum) && offerNum > 0
  const aboveMin = offerValid && offerNum >= batch.minPrice

  const send = async () => {
    if (!offerValid) { toast('Укажите цену предложения'); return }

    // Реальный оффер: пул выбран И обе строки — настоящие (UUID). Матчим партию в пул.
    if (onMatch && poolId && UUID_RE.test(poolId) && UUID_RE.test(batch.id)) {
      if (sending) return
      setSending(true)
      try {
        await onMatch(poolId, batch.id, batch.heads, offerNum)
        toast('Оффер отправлен — партия привязана к закупке')
        onClose()
      } catch (e: unknown) {
        toast('Не удалось отправить оффер: ' + (e instanceof Error ? e.message : ''))
        setSending(false)
      }
      return
    }

    if (onOffer) {
      // Демо: фермер сразу принимает → завершение прямой сделки с раскрытием контактов.
      onOffer({
        batchId: batch.id,
        catName: batch.catName,
        farm: 'КХ «Берекет», ' + batch.region,
        region: batch.region,
        heads: batch.heads,
        avgWeight: batch.avgWeight,
        price: offerNum,
      })
      return
    }
    toast('Предложение отправлено поставщику')
    onClose()
  }

  return (
    <div className="mpk-modal">
      <div className="mpk-modal-head">
        <div className="mpk-modal-title">{batch.catName}</div>
        <button className="mpk-modal-close" onClick={onClose} aria-label="Закрыть">×</button>
      </div>

      <div className="mpk-modal-body">
        <div className="pool-card-sub">{batch.region} (анонимно — только регион)</div>
        <div className="pool-card-sub">
          {batch.heads} гол · ~{batch.avgWeight} кг · {tonnes} т
        </div>
        <div className="pool-card-sub">Вакцинация: {batch.vaccinated ? '✓ есть' : '✗ нет'}</div>

        <div>
          <div className="mpk-field-label">Ваше предложение (₸/кг)</div>
          <input
            className={'mpk-input' + (offerValid && !aboveMin ? ' error' : '')}
            type="number"
            min={1}
            value={offer}
            onChange={(e) => setOffer(e.target.value)}
          />
          {offerValid && (aboveMin
            ? <div className="mpk-ok-hint">≥ мин. цены ✓</div>
            : <div className="mpk-error-hint">&lt; мин. цены ✗ (минимум {fmtMoney(batch.minPrice)}{NBSP}₸/кг)</div>)}
        </div>

        <div>
          <div className="mpk-field-label">Привязать к закупке</div>
          <select className="mpk-select" value={poolId} onChange={(e) => setPoolId(e.target.value)}>
            <option value="">Без привязки</option>
            {pools.map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
          </select>
        </div>

        <Cta onClick={send}>{sending ? 'Отправляем…' : 'Отправить предложение'}</Cta>
        <Cta variant="ghost" onClick={onClose}>Назад</Cta>
      </div>
    </div>
  )
}
