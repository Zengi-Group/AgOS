// AgOS · TSP-3 · Партия на маркет-борде (анонимно — только регион).

import { useEffect, useRef, useState } from 'react'
import { Cta } from '../../components/Cta'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { MarketBatch } from '../data/pools'
import type { PendingDeal, Pool, PoolsRead } from '../types'

interface Props {
  batch: MarketBatch | undefined
  pools: Pool[]   // активные пулы МПК (для привязки)
  // ARS-687 (FR-009): исход чтения заявок — «грузится» и «не загрузился» отличимы от «пусто».
  poolsState: PoolsRead
  onClose: () => void
  toast: (text: string) => void
  // ARS-687 (FR-006/M-011): для реальной партии это единственный путь отправки, поэтому проп
  // обязателен — незаданный вернул бы выдуманную сделку через onOffer.
  onMatch: (poolId: string, batchId: string, heads: number, price: number) => Promise<void>  // реальный оффер (price = бид МПК ≥ ask)
  onCreatePool: () => void   // FR-004: заявок нет → увести на создание (окно партии закрывается)
  onRetryPools: () => void   // M-013: повторить чтение списка заявок
  onOffer?: (deal: PendingDeal) => void   // прямая покупка: фермер согласился → завершение сделки (только демо-партия, FR-007)
}

// Реальный матч возможен только когда и пул, и партия — настоящие строки БД (UUID).
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function BatchDetailModal({
  batch, pools, poolsState, onClose, toast, onMatch, onCreatePool, onRetryPools, onOffer,
}: Props) {
  const [offer, setOffer] = useState(batch ? String(batch.minPrice + 90) : '')
  const [sending, setSending] = useState(false)
  // M-009: «отправка идёт» нужна двум потребителям — рендеру (надпись + неактивная кнопка)
  // и самому обработчику. У обработчика своя копия в ref: она не зависит от того, успел ли
  // React применить setSending до следующего нажатия. Что именно отсекает второй клик в
  // конкретном браузере — ref или уже выставленный `disabled` — здесь не утверждается и
  // тестом не изолируется: матрица требует ИСХОДА («вторая привязка не создаётся»), а не
  // механизма. Ref и state пишутся строго вместе, в одних строках.
  const sendingRef = useRef(false)
  const [poolId, setPoolId] = useState('')
  // FR-003: авто-подстановка не отменяет выбор, сделанный руками — включая осознанное
  // «Без привязки» (это тоже выбор, а не «ещё не выбрано»).
  const [poolTouched, setPoolTouched] = useState(false)

  // FR-003/M-003: единственная доступная заявка выбрана заранее — но только ПОСЛЕ того, как
  // список прочитан из базы (FR-009). Хук объявлен до раннего return по !batch: порядок
  // хуков не должен зависеть от пропса.
  const onlyPool = pools.length === 1 ? pools[0] : undefined
  const autofillPoolId =
    poolsState === 'ready' && !poolTouched && onlyPool && batch && UUID_RE.test(batch.id)
      ? onlyPool.id
      : null
  useEffect(() => {
    if (autofillPoolId === null) return
    setPoolId((cur) => (cur === '' ? autofillPoolId : cur))
  }, [autofillPoolId])

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

  // Реальная партия = строка БД (UUID). Демо-партия идёт прежним путём целиком (FR-007).
  const realBatch = UUID_RE.test(batch.id)
  const poolsReady = poolsState === 'ready'
  // FR-004/M-004: список прочитан и пуст — отправлять некуда. Пока отправка идёт, состояние
  // не подменяем: поллинг (20с) может опустошить список ровно в этот момент (closeDuePools
  // закрывает добравшую заявку), и форма с введённой ценой исчезла бы у оператора из-под рук.
  const noPools = realBatch && poolsReady && pools.length === 0 && !sending
  // FR-001: заявка «комбината» — та, что есть в прочитанном списке доступных для привязки,
  // а не любой id нужной формы. Список меняется под открытым окном (поллинг 20с, refetch
  // после привязки/приёмки): ушедшая из него заявка перестаёт быть выбором — в селекторе
  // её `option` уже нет, и отправка должна закрыться вместе с ним.
  const chosenPool = pools.find((p) => p.id === poolId)
  const realPoolChosen = poolsReady && chosenPool !== undefined && UUID_RE.test(chosenPool.id)
  const sendBlocked = realBatch && (!realPoolChosen || sending)
  // FR-002: причина недоступности — дословно, рядом с кнопкой. Состояния чтения списка
  // («грузится» / «не загрузился») показаны на месте самого списка — тут не дублируем (P4).
  const blockHint = !realBatch || !poolsReady ? null
    : chosenPool === undefined ? 'Выберите свою заявку: предложение уходит в конкретную закупку'
    : !UUID_RE.test(chosenPool.id) ? 'Эта заявка демонстрационная — выберите настоящую'
    : null

  const send = async () => {
    if (!offerValid) { toast('Укажите цену предложения'); return }

    // Реальная партия: единственный путь — привязка к реальной заявке (FR-001). Выдуманная
    // сделка (onOffer/DealClosedModal) для строки БД недостижима (FR-006/M-011).
    if (realBatch) {
      if (!realPoolChosen || sendingRef.current) return
      sendingRef.current = true; setSending(true)
      try {
        await onMatch(poolId, batch.id, batch.heads, offerNum)
        toast('Оффер отправлен — партия привязана к закупке')
        onClose()
      } catch (e: unknown) {
        toast('Не удалось отправить оффер: ' + (e instanceof Error ? e.message : ''))
        sendingRef.current = false; setSending(false)
      }
      return
    }

    if (onOffer) {
      // Демо-партия (FR-007): фермер сразу принимает → прямая сделка с раскрытием контактов.
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

        {noPools ? (
          // FR-004/M-004: заявок нет — отправлять некуда, показываем что создать.
          <>
            <div className="mpk-error-hint">Сначала создайте заявку на закупку — предложение уходит в неё</div>
            <Cta onClick={onCreatePool}>Создать заявку на закупку</Cta>
          </>
        ) : (
          <>
            <div>
              <div className="mpk-field-label">Ваше предложение (₸/кг)</div>
              <input
                className={'mpk-input' + (offerValid && !aboveMin ? ' error' : '')}
                type="text"
                inputMode="numeric"
                value={offer}
                onChange={(e) => setOffer(e.target.value)}
              />
              {offerValid && (aboveMin
                ? <div className="mpk-ok-hint">≥ мин. цены ✓</div>
                : <div className="mpk-error-hint">&lt; мин. цены ✗ (минимум {fmtMoney(batch.minPrice)}{NBSP}₸/кг)</div>)}
            </div>

            <div>
              <div className="mpk-field-label">Привязать к закупке</div>
              {/* FR-009: до прочтения списка селектор не рисуется вовсе — демо-заявки
                  реальному пользователю не подставляются. */}
              {realBatch && poolsState === 'loading' ? (
                <div className="pool-card-sub">Заявки загружаются…</div>
              ) : realBatch && poolsState === 'failed' ? (
                <>
                  <div className="mpk-error-hint">Список заявок не загрузился</div>
                  <Cta variant="ghost" onClick={onRetryPools}>Повторить</Cta>
                </>
              ) : (
                <select
                  className="mpk-select"
                  value={poolId}
                  onChange={(e) => { setPoolTouched(true); setPoolId(e.target.value) }}
                >
                  <option value="">Без привязки</option>
                  {pools.map((p) => <option key={p.id} value={p.id}>{p.title}</option>)}
                </select>
              )}
            </div>

            <Cta onClick={send} disabled={sendBlocked}>{sending ? 'Отправляем…' : 'Отправить предложение'}</Cta>
            {blockHint && <div className="mpk-error-hint">{blockHint}</div>}
          </>
        )}
        <Cta variant="ghost" onClick={onClose}>Назад</Cta>
      </div>
    </div>
  )
}
