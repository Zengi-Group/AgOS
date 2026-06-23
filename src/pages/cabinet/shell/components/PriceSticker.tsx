// AgOS · Этап 2 · Стикер цены в хедере Главной (shell/ui.jsx PriceSticker). Тап → шторка цен.

import { fmtMoney } from '../data/fmt'
import type { StickerData } from '../data/prices'

export function PriceSticker({ sticker, onOpen }: { sticker: StickerData; onOpen: () => void }) {
  return (
    <button className={'sticker trend-' + sticker.trend} onClick={onOpen} title="Цены TURAN">
      <span className="st-k mono">{sticker.short.toUpperCase()} ₸/КГ</span>
      <span className="st-v mono">
        {fmtMoney(sticker.price)}
        <i className="st-arr">{sticker.arrow}</i>
      </span>
    </button>
  )
}
