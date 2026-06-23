// AgOS · Этап 2 · Шторка цен (shell/pricesheet.jsx PriceSheet). Открывается тапом по стикеру.
// Антитраст: только официальные справочные цены TURAN, никаких агрегатов сделок.

import { useEffect, useState } from 'react'
import { fmtDGen, fmtMoney, TODAY } from '../../data/fmt'
import { FARMER_LEAD_CAT, PRICE_CAT_ORDER, PRICE_NEXT, herdValueMln, stickerData } from '../../data/prices'
import { PriceBars } from '../PriceBars'
import { PriceDelta } from '../PriceDelta'

export function PriceSheet({ catKey, onClose, onSell }: { catKey?: string; onClose: () => void; onSell: (catKey: string) => void }) {
  const [sel, setSel] = useState(catKey || FARMER_LEAD_CAT)
  useEffect(() => { if (catKey) setSel(catKey) }, [catKey])
  const s = stickerData(sel, 'auto')
  const others = PRICE_CAT_ORDER.filter((k) => k !== sel)
  const hv = s.herd ? herdValueMln(s.herd, s.price) : null

  return (
    <div className="ps-wrap" onClick={onClose}>
      <div className="ps-sheet" onClick={(e) => e.stopPropagation()} data-screen-label="шторка цен">
        <div className="ps-handle" />
        <div className="ps-head">
          <div className="ps-title">Цены TURAN</div>
          <div className="ps-sub mono">обновлено {fmtDGen(TODAY)} · следующее ~{PRICE_NEXT}</div>
        </div>
        <div className="ps-scroll">
          <div className="ps-main">
            <div className="psm-top">
              <span className="psm-name">{s.name}</span>
              <PriceDelta s={s} />
            </div>
            <div className="psm-pricerow">
              <span className="psm-price mono">{fmtMoney(s.price)}<span className="psm-unit"> ₸/кг</span></span>
              <PriceBars bars={s.bars} />
            </div>
            <div className="psm-note">{s.note}</div>
            <div className="psm-prot">Защитная цена (минимум): <b className="mono">{fmtMoney(s.prot)} ₸/кг</b></div>
            {s.herd ? (
              <div className="psm-herd">
                <div className="ph-l">
                  <div className="ph-k mono">ВАШЕ СТАДО · {s.herd.group.toUpperCase()}</div>
                  <div className="ph-v">{s.herd.heads} голов · ср. {s.herd.avgW} кг ≈ <b className="mono">{hv} млн ₸</b></div>
                </div>
                <button className="ph-cta" onClick={() => onSell(sel)}>Продать по этой цене →</button>
              </div>
            ) : (
              <div className="psm-herd none">В вашем стаде нет товарной группы этой категории.</div>
            )}
          </div>

          <div className="ps-others-h mono">ДРУГИЕ КАТЕГОРИИ</div>
          <div className="ps-others">
            {others.map((k) => {
              const o = stickerData(k, 'auto')
              return (
                <button key={k} className="ps-row" onClick={() => setSel(k)}>
                  <span className="psr-n">{o.name}</span>
                  <span className="psr-r">
                    <b className="mono">{fmtMoney(o.price)} ₸/кг</b>
                    <PriceDelta s={o} />
                  </span>
                </button>
              )
            })}
          </div>
          <div className="ps-disc">Справочная информация ассоциации TURAN. Не является обязательной — цену вы назначаете сами.</div>
        </div>
        <button className="ps-close" onClick={onClose}>Закрыть</button>
      </div>
    </div>
  )
}
