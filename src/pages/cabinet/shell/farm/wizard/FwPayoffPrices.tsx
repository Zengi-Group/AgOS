// AgOS · ARS-212 · SCR-F2 · Payoff-1 «Цены по вашему стаду». Награда, не шаг (D-FW-1): без
// wiz-bar/«Назад», только X. Вход — пауза-ритуал 900 мс (D-FW-4, паттерн PubResult.searching).
// Карточки только категорий фермера (heads>0, есть ценовая catKey), сортировка по головам desc;
// единый источник данных с шторкой PriceSheet — stickerData (P4). Антимонопольный дисклеймер
// Ст.171 (.ps-disc, тот же текст) виден сразу под карточками. Мост-CTA называет точное N ветки.
//
// D-FW-3 · Иерархия CTA: primary = мост к плану; «Продать через TURAN» — вторичная на карточке
// (только членам, onSell задан); выход — третичный link. Оценка стада в ₸ не показывается (D-FW-2:
// весов не спрашиваем). F-Q11: v1 — только справочные цены (слот под пулы не строим).

import { useEffect, useState } from 'react'
import { fmtMoney, fmtDGen, ruPlural, TODAY } from '../../data/fmt'
import { PRICE_NEXT, stickerData, FARMER_LEAD_CAT } from '../../data/prices'
import { HERD_FIELDS, type FwState } from '../types'
import { FwShell } from './FwShell'
import { TuranLoader } from '@/components/TuranLoader'
import { MkCta } from '../../tsp/components/MkCta'
import { PriceBars } from '../../components/PriceBars'
import { PriceDelta } from '../../components/PriceDelta'
import { PhIcon } from '../../components/icons/PhIcon'

const PAUSE_MS = 900

interface Props {
  heads: FwState['heads']
  region: string | null
  planQuestions: number          // N вопросов яруса 2 (по ветке)
  onBridge: () => void           // мост к ярусу «План»
  onExit: () => void             // «Пока хватит» / X → выход (F0b)
  onSell?: (catKey: string) => void      // «Продать через TURAN» (только членам)
}

export function FwPayoffPrices({ heads, region, planQuestions, onBridge, onExit, onSell }: Props) {
  const [ready, setReady] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => setReady(true), PAUSE_MS)
    return () => clearTimeout(t)
  }, [])

  // Категории фермера с ценовой картой, по убыванию поголовья.
  const cards = HERD_FIELDS
    .filter((f) => f.catKey && heads[f.key] > 0)
    .map((f) => ({ heads: heads[f.key], sticker: stickerData(f.catKey!) }))
    .sort((a, b) => b.heads - a.heads)
  // Ни одна не мапится (только бык) → одна карточка lead-категории без бейджа «у вас…».
  const onlyLead = cards.length === 0

  const eyebrow = 'ЦЕНЫ TURAN' + (region ? ' · ' + region.toUpperCase() : '')
  const bridgeLabel = `Ещё ${planQuestions} ${planQuestions === 1 ? 'вопрос' : planQuestions < 5 ? 'вопроса' : 'вопросов'} — план работ на год`

  if (!ready) {
    return (
      <FwShell onExit={onExit} exitTop screenLabel="SCR-F2 · Payoff-1 · поиск цен">
        <div className="mk-loader">
          <TuranLoader variant="breathe" size={44} />
          <div>Смотрим цены по вашему стаду…</div>
        </div>
      </FwShell>
    )
  }

  const renderCard = (s: ReturnType<typeof stickerData>, herdCount: number | null) => (
    <div className="fw-pay-card" key={s.catKey}>
      <div className="fw-pay-head">
        <div className="fw-pay-hl">
          <div className="fw-pay-name">{s.name}</div>
          {herdCount != null && <div className="fw-pay-herd">у вас {herdCount} {ruPlural(herdCount, 'голова', 'головы', 'голов')}</div>}
        </div>
        <PriceDelta s={s} />
      </div>
      <div className="fw-pay-row">
        <span className="psm-price mk-mono">{fmtMoney(s.price)}<span className="psm-unit"> ₸/кг</span></span>
        <PriceBars bars={s.bars} />
      </div>
      <div className="fw-pay-prot"><PhIcon name="shieldCheck" size={14} color="var(--fg3)" /> защитная цена <span className="mk-mono">{fmtMoney(s.prot)} ₸/кг</span></div>
      {onSell && <button className="fw-pay-sell" onClick={() => onSell(s.catKey)}>Продать через TURAN <PhIcon name="chevronRight" size={13} /></button>}
    </div>
  )

  return (
    <FwShell
      onExit={onExit}
      exitTop
      title="Вот что почём сегодня"
      sub={`обновлено ${fmtDGen(TODAY)} · след. ~${PRICE_NEXT}`}
      screenLabel="SCR-F2 · Payoff-1 · цены"
      footer={<>
        <MkCta onClick={onBridge}>{bridgeLabel}</MkCta>
        <button className="mk-link" onClick={onExit}>Пока хватит — стадо сохранено</button>
      </>}
    >
      <div className="fw-pay-eyebrow">{eyebrow}</div>
      <div className="fw-pay-list">
        {onlyLead
          ? renderCard(stickerData(FARMER_LEAD_CAT), null)
          : cards.map((c) => renderCard(c.sticker, c.heads))}
      </div>
      {onlyLead && <div className="mk-note" style={{ textAlign: 'left' }}>Цены по остальным категориям — в разделе «Цены» на Главной</div>}
      <div className="ps-disc">Справочная информация ассоциации TURAN. Не является обязательной — цену вы назначаете сами.</div>
    </FwShell>
  )
}
