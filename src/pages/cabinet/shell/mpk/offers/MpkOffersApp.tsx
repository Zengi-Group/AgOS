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
// ARS-786: ходы по офферу — принять и отклонить — живут здесь же. Заявку-получателя
// выбирает БАЗА (наибольший бид), экран называет её из ответа; исход показан на месте, а
// не тостом, и список после любого хода перечитывается.

import { lazy, Suspense, useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
import { PhIcon } from '../../components/icons/PhIcon'
import { readIncomingOffers } from '../data/offers-load'
import { acceptOffer, explainOfferFailure, rejectOffer } from '../data/offer-actions'
import { readMyPools } from '../data/pools-load'
import { MPK_REQUESTS_URL } from '../nav'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { IncomingOffer, Pool } from '../types'
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

  // ARS-786 · исход хода. `flash` — успех, `failure` — отказ; оба не гаснут сами (довод
  // `.mpkr-flash` из «Моих заявок»: на десктопе оператор читает результат там же, где
  // нажал). `busyId` запирает кнопки на время хода.
  const [busy, setBusy] = useState<{ id: string; kind: 'accept' | 'reject' } | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const [failure, setFailure] = useState<{ text: string; rawCode: string | null } | null>(null)

  // Заявки читаются РАДИ ИМЕНИ заявки-получателя: `rpc_self_accept_offer` возвращает
  // только `poolId` (проверено по телу функции), а обещание экрана — назвать заявку.
  // Своего названия заявки у RPC нет, поэтому берём его из списка, который консоль и так
  // умеет читать (`readMyPools`). Отказ этого чтения ход не ломает — см. `poolTitle`.
  const [pools, setPools] = useState<Pool[]>([])

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

  // Список заявок — только ради имени заявки-получателя после принятия. Читается вместе с
  // офферами: к моменту хода имя уже под рукой, и ход не ждёт второго запроса.
  useEffect(() => {
    if (!wide) return
    let alive = true
    void readMyPools().then((r) => {
      if (alive && r.kind === 'ok') setPools(r.pools)
      // Отказ молчит намеренно: без имени заявки ход всё равно состоится и будет назван
      // (см. `poolTitle`), а свой отказ у этого чтения оператору сообщать не о чем.
    })
    return () => { alive = false }
  }, [offersToken, wide])

  // Ручное перечитывание («Повторить», клик по своему пункту сайдбара) гасит исход
  // прошлого хода: оставить его — значит держать над свежим списком сообщение о том,
  // чего на экране уже нет.
  const refetch = useCallback(() => {
    setFlash(null)
    setFailure(null)
    setOffersToken((n) => n + 1)
  }, [])

  /** Имя заявки по id из ответа RPC. Не нашли (список не прочитан или заявка новая) —
   *  говорим «в вашу заявку», а не выдумываем название и не показываем сырой uuid. */
  const poolTitle = useCallback((poolId: string): string => {
    const hit = pools.find((p) => p.id === poolId)
    // Предлог внутри обеих веток: снаружи он дал бы «принята «Высшая · Алматы»» без «в».
    return hit ? `в заявку «${hit.title}»` : 'в вашу заявку'
  }, [pools])

  // Один дом обоих ходов: запереть кнопки → позвать базу → показать исход → перечитать.
  // Перечитывание идёт в ЛЮБОМ случае, включая отказ: после `INVALID_STATUS` или
  // `OFFER_EXPIRED` список на экране заведомо устарел, и оставить его — значит дать
  // оператору нажать второй раз по тому же мёртвому офферу (тот же довод, что в
  // `RequestMonitor.run()`).
  // Компонент мог уйти (смена ширины, уход в другой раздел), пока база отвечала: тогда
  // ставить состояние и перечитывать некуда и незачем.
  const alive = useRef(true)
  useEffect(() => () => { alive.current = false }, [])

  const runAction = useCallback(async (
    offerId: string,
    kind: 'accept' | 'reject',
    act: () => Promise<string>,
  ) => {
    setBusy({ id: offerId, kind })
    setFlash(null)
    setFailure(null)
    try {
      const text = await act()
      if (alive.current) setFlash(text)
    } catch (e) {
      // Ошибку отдаём словарю ЦЕЛИКОМ, не текстом: он сам различает `LocalError`
      // (собственный текст фронта) от кода базы и логирует исходное сообщение.
      if (alive.current) setFailure(explainOfferFailure(e))
    } finally {
      if (alive.current) {
        setBusy(null)
        // Перечитываем И офферы, И заявки: принятие могло закрыть заявку-получателя
        // (`closed_filled`), и следующий ход назвал бы уже неактуальное состояние.
        setOffersToken((n) => n + 1)
      }
    }
  }, [])

  const onAccept = useCallback((offerId: string) => runAction(offerId, 'accept', async () => {
    const r = await acceptOffer(offerId)
    // Заявку и цену называем ИЗ ОТВЕТА базы: `dealPrice` — бид комбината, не ask фермера
    // (`D-M6-DEALPRICE`), и предсказывать его экран не вправе.
    return `Партия принята ${poolTitle(r.poolId)} · цена сделки ${fmtMoney(r.dealPrice)}${NBSP}₸/кг`
  }), [runAction, poolTitle])

  const onReject = useCallback((offerId: string) => runAction(offerId, 'reject', async () => {
    await rejectOffer(offerId)
    return 'Предложение отклонено — партия осталась доступна другим комбинатам'
  }), [runAction])

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

        {/* Исход хода — над списком, не тостом: оператор читает его там же, где нажал,
            и он не исчезает сам (образец `.mpkr-flash` из «Моих заявок»). */}
        {flash && <div className="mpkr-flash" role="status">{flash}</div>}
        {failure && (
          <div className="mpkr-flash bad" role="alert">
            {failure.text}
            {/* Код показываем ТОЛЬКО когда не смогли его перевести: опознанный код
                оператору ничего не говорит, а неопознанный — единственное, с чем он
                придёт в поддержку. */}
            {failure.rawCode && <span className="mpko-code">{failure.rawCode}</span>}
          </div>
        )}

        <OffersList
          status={offersRead}
          offers={offers}
          onRetry={refetch}
          onAccept={onAccept}
          onReject={onReject}
          busy={busy}
        />
      </main>
    </div>
  )
}
