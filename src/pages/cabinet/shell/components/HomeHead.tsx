// AgOS · Хедер Главной (прототип home.jsx HomeHead): ask-бар (TuranStar + «Спросить…»
// + микрофон → Консультант) + аватар хозяйства (→ Кабинет, янтарная точка = нужно действие).
// Стикер цены убран — как в прототипе (цены доступны через баннер/грид «Цены»).

import { useShell } from '../context'
import { PhIcon } from './icons/PhIcon'
import { TuranStar } from './icons/TuranStar'
import { AccountBtn } from './AccountBtn'

export function HomeHead() {
  const ctx = useShell()
  return (
    <div className="hh-row" data-screen-label="хедер Главной">
      <div className="askbar">
        <button className="ask-go" onClick={() => ctx.openAI('home')}>
          <TuranStar size={17} />
          <span className="ask-ph">Спросить…</span>
        </button>
        <button className="ask-mic2" title="Голосовой вопрос" onClick={() => ctx.openAI('home', { voice: true })}>
          <PhIcon name="mic" size={15} />
        </button>
      </div>
      <AccountBtn />
    </div>
  )
}
