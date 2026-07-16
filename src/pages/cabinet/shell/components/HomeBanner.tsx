// AgOS · Баннер «Актуальное» (прототип home.jsx Banner): полноширинные плитки-картинки
// со scroll-snap + точки, авто-смена 22.5с. Первая плитка реагирует на статус членства.

import { useEffect, useRef, useState } from 'react'
import { useShell } from '../context'
import { useRpc } from '@/hooks/useRpc'
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

// Строка из rpc_list_home_banners (см. Docs/AGOS-Slice-AppBanners.md).
interface BannerRow {
  id: string
  title: string
  subtitle?: string | null
  image_path?: string | null
  action_type: 'internal' | 'external' | 'none'
  action_target?: string | null
}

// asset-ключ → импорт (баннеры фермера — фоновые картинки из бандла).
const ASSET_MAP: Record<string, string> = {
  'banner-membership': bannerMembership,
  'banner-course': bannerCourse,
  'banner-prices': bannerPrices,
  'banner-market': bannerMarket,
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

  // Вариант набора по членству (перенесено из CabinetApp bannerVariant, P4 — источник тот же ctx).
  const variant = (ctx.membership === 'none' || ctx.membership === 'terminated') ? 'join' : 'season'

  // Диспетч «рабочих ссылок»: internal-enum → хендлеры ctx; external → внешний переход; none → тост.
  const dispatch = (row: BannerRow): (() => void) | undefined => {
    if (row.action_type === 'external' && row.action_target) {
      const url = row.action_target
      return () => window.open(url, '_blank', 'noopener,noreferrer')
    }
    if (row.action_type === 'internal') {
      switch (row.action_target) {
        case 'join_membership': return memberOnClick(ctx.membership) // реактивно к статусу членства
        case 'pay_membership':  return () => ctx.memberAct('pay')
        case 'open_prices':     return () => ctx.openPrices('bychki')
        case 'open_market':     return () => ctx.go({ name: 'market' })
        case 'open_tsp':        return () => ctx.go({ name: 'market' })
        case 'open_offers':     return () => ctx.go({ name: 'market' })
        case 'open_course':     return () => ctx.toast('Курс TURAN откроется в обучении')
        default:                return undefined // неизвестный ключ — no-op (defensive)
      }
    }
    // none — информационная плитка с мягким тостом
    return () => ctx.toast(row.subtitle || row.title)
  }

  // Данные из БД (rpc_list_home_banners). Фолбэк — прежние хардкод-плитки:
  // нулевой визуальный регресс, работает офлайн и до деплоя SQL (HS-2).
  const { data } = useRpc<BannerRow[]>('rpc_list_home_banners', {
    p_app: 'farmer',
    p_membership_variant: variant,
  })

  const fallbackTiles: Tile[] = [
    { img: bannerMembership, label: 'Членство TURAN', onClick: memberOnClick(ctx.membership) },
    { img: bannerCourse, label: 'Курс TURAN: сезон отёла', onClick: () => ctx.toast('Курс TURAN откроется в обучении') },
    { img: bannerPrices, label: 'Справочные цены', onClick: () => ctx.openPrices('bychki') },
    { img: bannerMarket, label: 'Маркет · скоро', onClick: () => ctx.toast('Маркет откроется с партнёрами TURAN') },
  ]

  const tiles: Tile[] = (data && data.length > 0)
    ? data.map((row) => ({
        img: (row.image_path && ASSET_MAP[row.image_path]) || row.image_path || bannerMarket,
        label: row.title,
        onClick: dispatch(row),
      }))
    : fallbackTiles

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
