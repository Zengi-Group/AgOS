// AgOS · ARS-785 · Раздел «Входящие офферы» десктопной консоли МПК.
//
// Раздел монтируется в СУЩЕСТВУЮЩУЮ консоль: тот же scoped-контейнер темы
// (`.agos-mpk-console` + `profile-console.css`), тот же сайдбар (`ProfileSidebar`), та же
// ширина контента — как это сделал Slice 11 для «Моих заявок».
//
// ── Про адрес ────────────────────────────────────────────────────────────────
// `/mpk/offers` — НЕ новый адрес: он уже принадлежит мобильному шеллу закупок
// (`RouteV5 exact path="/mpk/offers"` в `MpkApp`). Решение владельца 24.09: один URL,
// две поверхности, граница — ширина экрана. Ниже 1024px этот компонент отдаёт управление
// `MpkApp`, который сам смонтирует свой Ionic-роутер и покажет мобильный экран офферов со
// всей его обвязкой (тосты, pull-to-refresh, принять/отклонить). Поэтому:
//   · живой URL не переименован и с телефона ведёт ровно туда же, куда вёл (P7);
//   · мобильный шелл не правится ни строкой — он переиспользуется целиком;
//   · моста-заглушки «откройте на компьютере» здесь нет намеренно: у офферов, в отличие
//     от заявок, мобильный экран СУЩЕСТВУЕТ, и отправлять оператора к компьютеру от
//     работающего экрана было бы регрессом.
//
// Отвечать на офферы в десктопной консоли — ARS-786. Здесь их только видно.

import { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
import { PhIcon } from '../../components/icons/PhIcon'
import { readIncomingOffers } from '../data/offers-load'
import { MPK_REQUESTS_URL } from '../nav'
import type { IncomingOffer } from '../types'
import { ProfileSidebar } from '../profile/ProfileSidebar'
import { OffersList } from './OffersList'
import '../profile/profile-console.css'
import '../requests/requests-console.css'
import './offers-console.css'

// Та же граница, что у консоли профиля (Slice 10 `FR-012`) и «Моих заявок» (Slice 11
// `FR-013`) — один порог на поверхность.
const WIDE_QUERY = '(min-width: 1024px)'

// Мобильный шелл грузится ТОЛЬКО когда экран узкий. Статический импорт затянул бы весь
// Ionic-остров (отдельный чанк ~1.2 МБ) в десктопную консоль, которая его никогда не
// рендерит; в `App.tsx` `MpkApp` ровно поэтому тоже lazy.
const MpkApp = lazy(() => import('../MpkApp').then((m) => ({ default: m.MpkApp })))

export function MpkOffersApp() {
  const navigate = useNavigate()

  const [profile, setProfile] = useState<AccountProfile | null>(null)
  const [theme, setTheme] = useState<'dark' | 'light'>('dark')
  const [soonHint, setSoonHint] = useState<string | null>(null)

  const [offers, setOffers] = useState<IncomingOffer[]>([])
  const [offersRead, setOffersRead] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [offersToken, setOffersToken] = useState(0)

  const [wide, setWide] = useState(() =>
    typeof window === 'undefined' ? true : window.matchMedia(WIDE_QUERY).matches)

  useEffect(() => {
    const mq = window.matchMedia(WIDE_QUERY)
    const onChange = () => setWide(mq.matches)
    mq.addEventListener('change', onChange)
    setWide(mq.matches)
    return () => mq.removeEventListener('change', onChange)
  }, [])

  useEffect(() => {
    let alive = true
    loadAccountProfile('mpk')
      .then((p) => { if (alive) setProfile(p) })
      // Профиль нужен только для подписи шапки: его отказ не должен уносить экран —
      // список читается своим путём и своё состояние показывает сам.
      .catch((error) => console.error('MpkOffersApp: loadAccountProfile failed:', error))
    return () => { alive = false }
  }, [])

  useEffect(() => {
    // На узком экране читает мобильный шелл — второе чтение того же RPC здесь только
    // удвоило бы запросы.
    if (!wide) return
    let alive = true
    void readIncomingOffers().then((r) => {
      if (!alive) return
      if (r.kind === 'ok') { setOffers(r.offers); setOffersRead('ready'); return }
      // `no_session` здесь означает то же, что `failed`: списка у нас нет. Демо-офферы
      // оператору не показываются ни в одном исходе чтения (п. 4 `ARS-688`) — в этом
      // разделе их просто нет, а «офферов нет» утверждается только по ответу базы.
      setOffers([])
      setOffersRead('failed')
    })
    return () => { alive = false }
  }, [offersToken, wide])

  const refetch = useCallback(() => { setOffersToken((n) => n + 1) }, [])

  // Ниже 1024px адрес обслуживает мобильный шелл — он сам разберёт путь своим роутером.
  // Пока его чанк едет, показываем пустой каркас, а не чужую разметку: это доли секунды,
  // и любой текст здесь спорил бы с экраном, который вот-вот отрисуется.
  if (!wide) return <Suspense fallback={<div className="agos-cabinet-stage" />}><MpkApp /></Suspense>

  return (
    <div className="agos-mpk-console" data-theme={theme === 'light' ? 'light' : undefined}>
      <ProfileSidebar
        orgName={profile?.name ?? 'Предприятие'}
        farmName="Turan Standard Pool · закупки"
        userName={profile?.ownerName ?? 'Сотрудник'}
        monogram="МПК"
        theme={theme}
        soonHint={soonHint}
        activeId="offers"
        onSelect={(item) => {
          if (item.id === 'offers') { setSoonHint(null); refetch(); return }
          if (item.id === 'requests') { setSoonHint(null); navigate(MPK_REQUESTS_URL); return }
          if (item.id === 'profile') { setSoonHint(null); navigate('/mpk/profile/overview'); return }
          setSoonHint(item.id)
        }}
        onThemeToggle={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}
        onBackToMpk={() => navigate('/mpk')}
      />

      <main className="mpkc-main">
        <div className="mpkc-head">
          <div className="mpkc-head-mono" aria-hidden="true"><PhIcon name="mail" size={20} /></div>
          <div className="mpkc-head-txt">
            <div className="mpkc-head-row">
              <span className="mpkc-head-name">Входящие офферы</span>
            </div>
            <div className="mpkc-head-sub">{profile?.name ?? ''}</div>
          </div>
        </div>

        <OffersList status={offersRead} offers={offers} onRetry={refetch} />
      </main>
    </div>
  )
}
