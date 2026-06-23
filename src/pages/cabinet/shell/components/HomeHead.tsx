// AgOS · Этап 1 · Хедер Главной: строка «Спросить» + аватар хозяйства (shell/ui.jsx).
// Аватар → Кабинет; янтарная точка = в Кабинете нужно действие. Строка «Спросить» — единственный вход в AI.

import { useShell } from '../context'
import { ShIc } from './icons/ShIc'
import { SparkIc } from './icons/SparkIc'
import { PriceSticker } from './PriceSticker'
import type { StickerData } from '../data/prices'

export function HomeHead({ sticker }: { sticker?: StickerData }) {
  const ctx = useShell()
  return (
    <div className="hh-row" data-screen-label="хедер Главной">
      <div className="askbar">
        <button className="ask-go" onClick={() => ctx.openAI('home')}>
          <span className="ask-spark"><SparkIc size={15} /></span>
          <span className="ask-ph">Спросить…</span>
        </button>
        <button className="ask-mic2" title="Голосовой вопрос" onClick={() => ctx.openAI('home', { voice: true })}>
          <ShIc k="mic" size={15} />
        </button>
      </div>
      {sticker && <PriceSticker sticker={sticker} onOpen={() => ctx.openPrices(sticker.catKey)} />}
      <button className="avatar-btn" title="Кабинет хозяйства" onClick={() => ctx.go({ name: 'cabinet' })}>
        {ctx.avatarInitials}
        {ctx.avatarDot && <i className="avatar-dot" />}
      </button>
    </div>
  )
}
