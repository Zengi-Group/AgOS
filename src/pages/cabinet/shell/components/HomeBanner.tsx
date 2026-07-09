// AgOS · Баннер «Актуальное» (прототип home.jsx Banner): полноширинные плитки-картинки
// со scroll-snap + точки, авто-смена 22.5с. Первая плитка реагирует на статус членства.

import { useEffect, useRef, useState } from 'react'
import { useShell } from '../context'
import type { MembershipStatus } from '../types'
import bannerMembership from '@/assets/turan/banner-membership.jpg'
import bannerCourse from '@/assets/turan/banner-course.jpg'
import bannerPrices from '@/assets/turan/banner-prices.jpg'
import bannerMarket from '@/assets/turan/banner-market.jpg'

interface Tile {
  img: string
  label: string
  onClick?: () => void
}

export function HomeBanner() {
  const ctx = useShell()
  const stripRef = useRef<HTMLDivElement>(null)
  const [active, setActive] = useState(0)
  const pausedRef = useRef(false)

  const memberOnClick = (m: MembershipStatus): (() => void) | undefined => {
    if (m === 'approved' || m === 'expired' || m === 'expiring' || m === 'grace') return () => ctx.memberAct('pay')
    if (m === 'none' || m === 'terminated' || m === 'rejected') return () => ctx.memberAct('apply')
    return undefined // active / pending — информационная
  }

  const tiles: Tile[] = [
    { img: bannerMembership, label: 'Членство TURAN', onClick: memberOnClick(ctx.membership) },
    { img: bannerCourse, label: 'Курс TURAN: сезон отёла', onClick: () => ctx.toast('Курс TURAN откроется в обучении') },
    { img: bannerPrices, label: 'Справочные цены', onClick: () => ctx.openPrices('bychki') },
    { img: bannerMarket, label: 'Маркет · скоро', onClick: () => ctx.toast('Маркет откроется с партнёрами TURAN') },
  ]

  const goTo = (i: number) => {
    const el = stripRef.current
    if (!el) return
    const child = el.children[i] as HTMLElement | undefined
    if (!child) return
    el.scrollTo({ left: child.offsetLeft - el.offsetLeft, behavior: 'smooth' })
  }

  useEffect(() => {
    const el = stripRef.current
    if (!el) return
    const onScroll = () => {
      const x = el.scrollLeft
      let best = 0
      let bestD = Infinity
      for (let i = 0; i < el.children.length; i++) {
        const c = el.children[i] as HTMLElement
        const d = Math.abs(c.offsetLeft - el.offsetLeft - x)
        if (d < bestD) { bestD = d; best = i }
      }
      setActive(best)
    }
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => el.removeEventListener('scroll', onScroll)
  }, [])

  useEffect(() => {
    const id = setInterval(() => {
      if (pausedRef.current) return
      goTo((active + 1) % tiles.length)
    }, 22500)
    return () => clearInterval(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [active, tiles.length])

  const pause = () => { pausedRef.current = true }
  const resume = () => { pausedRef.current = false }

  return (
    <div className="ban-wrap" onMouseEnter={pause} onMouseLeave={resume} onTouchStart={pause} onTouchEnd={resume} data-screen-label="баннер «Актуальное»">
      <div className="ban-strip" ref={stripRef}>
        {tiles.map((c, j) => (
          <button
            key={j}
            type="button"
            className="ban-tile"
            style={{ backgroundImage: `url(${c.img})` }}
            aria-label={c.label}
            onClick={c.onClick}
          />
        ))}
      </div>
      <div className="ban-dots" role="tablist" aria-label="Актуальное">
        {tiles.map((_c, i) => (
          <button key={i} className={'ban-dot' + (i === active ? ' on' : '')} aria-label={'Слайд ' + (i + 1)} aria-selected={i === active} onClick={() => goTo(i)} />
        ))}
      </div>
    </div>
  )
}
