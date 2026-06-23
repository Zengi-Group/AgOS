// AgOS · Этап 2 · Баннер «Актуальное» (shell/ui.jsx HomeBanner). Карусель ≤3 карточек,
// фикс-высота, авто-смена каждые 6000 мс — блок не пустует никогда (иначе грид прыгает).

import { useEffect, useState } from 'react'
import { ShIc } from './icons/ShIc'
import type { IconKey } from './icons/ShIc'
import { SparkIc } from './icons/SparkIc'
import { BANNER_SETS, type BannerCard } from '../data/banners'

export function HomeBanner({ variant, onAct }: { variant: string; onAct: (c: BannerCard) => void }) {
  const cards = BANNER_SETS[variant] ?? BANNER_SETS.season ?? []
  const [i, setI] = useState(0)
  useEffect(() => { setI(0) }, [variant])
  useEffect(() => {
    const t = setInterval(() => setI((x) => (x + 1) % cards.length), 6000)
    return () => clearInterval(t)
  }, [cards.length, variant])
  return (
    <div className="ban" data-screen-label="баннер «Актуальное»">
      <div className="ban-track" style={{ transform: 'translateX(-' + i * 100 + '%)' }}>
        {cards.map((c) => {
          const tone = c.tone === 'gold' ? ' gold' : c.tone === 'green' ? ' green' : ''
          return (
            <button key={c.t} className={'ban-card' + tone} onClick={() => onAct(c)}>
              <span className="ban-ic">
                {c.spark ? <SparkIc size={19} /> : c.tenge ? <span className="ban-tenge">₸</span> : <ShIc k={(c.ic || 'grid') as IconKey} size={19} />}
              </span>
              <span className="ban-tx">
                <span className="ban-k mono">{c.k}</span>
                <span className="ban-t">{c.t}</span>
                {c.s && <span className="ban-s">{c.s}</span>}
              </span>
            </button>
          )
        })}
      </div>
      <div className="ban-dots">
        {cards.map((_c, j) => (
          <button key={j} className={'ban-dot' + (j === i ? ' on' : '')} onClick={() => setI(j)} aria-label={'карточка ' + (j + 1)} />
        ))}
      </div>
    </div>
  )
}
