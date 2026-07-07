// AgOS · TSP-3 · Корень оболочки МПК (мясокомбинат). Аналог CabinetApp:
// 3 маршрута (home/tsp/offers), 4 модала и одна шторка.
// S6 (ARS-152, ADR-NATIVE-ROUTER-01 AMEND-1): Ionic-навигация по S2-паттерну —
// IonReactRouter живёт на изолированном react-router v5 (v5-остров,
// vite.config.ts agos:ionic-v5-island); остальное приложение остаётся на v6.
// Бизнес-логика (RPC, поллинг, seed-фолбэк) сохранена дословно.

import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { setupIonicReact, IonApp, IonModal, IonRouterOutlet } from '@ionic/react'
import type { UseIonRouterResult } from '@ionic/react'
import { useIonRouter } from '@ionic/react'
import { IonReactRouter } from '@ionic/react-router'
// @ts-expect-error v5-alias пакет без @types — импорты v5-острова (спайк-проверено, S2).
import { Route as RouteV5, useLocation } from 'react-router-dom-v5'
import '@ionic/react/css/core.css'
import '../cabinet.css'
import '../ionic.css'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/hooks/useAuth'
import { loadAccountProfile } from '@/lib/account'
// S2.1-паттерн (ARS-157): тактильный отклик на ключевых действиях через Host Bridge.
// В web — no-op; CapacitorHost даёт вибрацию. НЕ звать @capacitor/* напрямую.
import { useHost } from '@/platform/host/HostContext'
import { Toast } from '../components/Toast'
import { MpkHomeScreen } from './screens/MpkHomeScreen'
import { MpkTspScreen } from './screens/MpkTspScreen'
import { MpkIncomingOffersScreen } from './screens/MpkIncomingOffersScreen'
import { CreatePoolModal } from './modals/CreatePoolModal'
import { PoolMonitorModal } from './modals/PoolMonitorModal'
import { BatchDetailModal } from './modals/BatchDetailModal'
import { DealClosedModal } from './modals/DealClosedModal'
import { ContactTuranSheet } from './sheets/ContactTuranSheet'
import { seedPools } from './data/pools'
import { loadMarketBatches, seedMarketBatches, type MarketBatch } from './data/market'
import { loadMyPools, loadPoolMatches, closeDuePools } from './data/pools-load'
import { loadIncomingOffers } from './data/offers-load'
import { mpkRouteToUrl, mpkUrlToRoute, mpkRouteKey, mpkDirFor } from './nav'
import type {
  IncomingOffer, MpkMembership, MpkModal, MpkRoute, MpkSheet, MpkState, MpkTypeStatus, PendingDeal, Pool,
} from './types'

interface MpkAppProps {
  // Начальное состояние можно переопределить для дев-режима
  initialState?: Partial<MpkState>
}

// Гейты МПК из БД. Тип МПК назначается при регистрации (organization_type_assignments)
// → наличие 'mpk' = подтверждён. Членство: registered → нужен self-join; observer/active_buyer = активно.
function deriveMpkType(orgTypes: string[]): MpkTypeStatus {
  return orgTypes.includes('mpk') ? 'approved' : 'under_review'
}
function deriveMpkMembership(level: string | null): MpkMembership {
  if (level === 'observer' || level === 'active_buyer') return 'active'
  if (level) return 'submitted'   // 'registered' — членство на рассмотрении (нужен self-join)
  return 'none'
}

// iOS-режим для всей оболочки (S-1 архитект-ревью ARS-152): МПК не полагается на
// побочный эффект модуля CabinetApp — идемпотентный вызов и здесь (конфиг идентичен).
setupIonicReact({ mode: 'ios' })

// Мост v5-роутера (зеркало CabinetApp.IonBridge — унифицировать в ARS-109): отдаёт
// ionRouter наружу для go() и синкает URL → Route-состояние (browser-back /
// edge-swipe / deep-link меняют URL мимо go()).
function IonBridge({ onIon, onPath }: { onIon: (ion: UseIonRouterResult) => void; onPath: (path: string) => void }) {
  const ion = useIonRouter()
  useEffect(() => { onIon(ion) })
  const loc = useLocation() as { pathname: string }
  useEffect(() => { onPath(loc.pathname) }, [loc.pathname, onPath])
  return null
}

export function MpkApp({ initialState }: MpkAppProps = {}) {
  const navigate = useNavigate()
  const { signOut } = useAuth()
  const host = useHost()   // S2.1-паттерн: тактильный отклик (web no-op)
  const [typeStatus, setTypeStatus] = useState<MpkTypeStatus>(initialState?.typeStatus ?? 'under_review')
  const [membership, setMembership] = useState<MpkMembership>(initialState?.membership ?? 'submitted')
  const [pools, setPools] = useState<Pool[]>(initialState?.pools ?? seedPools())
  // S6: URL — источник истины экрана (deep-link открывает нужный экран).
  const [route, setRoute] = useState<MpkRoute>(() => mpkUrlToRoute(window.location.pathname))
  const [modal, setModal] = useState<MpkModal>(null)
  const [sheet, setSheet] = useState<MpkSheet>(null)
  const [toast, setToast] = useState<{ id: number; text: string } | null>(null)

  // S-2 (архитект-ревью ARS-152): параметры модалов переживают dismiss-анимацию —
  // контент размонтируется в onDidDismiss, а не в момент isOpen=false (урок ревью
  // PR #27: условный unmount рвал анимацию). Ремоунт контента при следующем открытии
  // сбрасывает форм-состояние модалов с чистого листа, а cleanup эффектов
  // останавливает их внутренний поллинг (PoolMonitor, 8с).
  const [monitorPoolId, setMonitorPoolId] = useState<string | null>(null)
  const [detailBatchId, setDetailBatchId] = useState<string | null>(null)
  const [closedDeal, setClosedDeal] = useState<PendingDeal | null>(null)
  const [createRendered, setCreateRendered] = useState(false)
  // Тема шторки TURAN — переживает dismiss (шторка смонтирована постоянно, open-флаг).
  const [sheetTopic, setSheetTopic] = useState<string | undefined>(undefined)

  // Открытие модала: isOpen-состояние + rendered-параметры контента.
  const openModal = (m: NonNullable<MpkModal>) => {
    setModal(m)
    if (m.kind === 'pool_monitor') setMonitorPoolId(m.poolId)
    else if (m.kind === 'batch_detail') setDetailBatchId(m.batchId)
    else if (m.kind === 'deal_closed') setClosedDeal(m.deal)
    else setCreateRendered(true)
  }
  // Закрытие гардится по kind: поздний onDidDismiss закрывающегося модала не должен
  // убить следующий, уже открытый (переход batch_detail → deal_closed).
  const closeModal = (kind: NonNullable<MpkModal>['kind']) =>
    setModal((cur) => (cur?.kind === kind ? null : cur))
  const openSheet = (topic?: string) => { setSheetTopic(topic); setSheet({ kind: 'contact_turan', topic }) }

  // Профиль реального МПК-аккаунта перекрывает демо; иначе — демо-фолбэк.
  const [orgName, setOrgName] = useState(initialState?.orgName ?? 'ТОО «АгроМит»')
  const [region, setRegion] = useState(initialState?.region ?? 'ЮКО')
  const [bin, setBin] = useState(initialState?.bin ?? '123456789012')
  const [orgId, setOrgId] = useState<string | null>(null)  // org реального МПК — для self-serve RPC
  // Маркет-борд: реальные партии ферм через RPC; seed — демо-фолбэк (аноним/нет backend).
  const [marketBatches, setMarketBatches] = useState<MarketBatch[]>(seedMarketBatches())
  // Входящие broadcast-офферы (Слайс C): партии без прямого матча, разосланные мне (FCFS).
  const [offers, setOffers] = useState<IncomingOffer[]>([])
  useEffect(() => {
    let alive = true
    loadAccountProfile('mpk').then(async (p) => {
      if (!alive) return
      if (!p) {
        // Профиль пуст при сессии: возможна «осиротевшая» сессия (пользователь удалён из БД),
        // но ГОРАЗДО чаще — временный сбой rpc_get_my_context или гонка обновления токена
        // (создание пула шлёт несколько RPC разом). Разлогиниваем ТОЛЬКО при явном 401/403
        // от Auth (сессия реально невалидна). Неоднозначный ответ getUser (нет ошибки, но и
        // нет user) НЕ выкидываем — оставляем на демо-фолбэке, иначе МПК вылетает на ровном
        // месте при каждом транзиентном сбое профиля. (Фикс: «с аккаунта МПК выкидывает».)
        const { error } = await supabase.auth.getUser()
        if (!alive) return
        const authInvalid = !!error && (error.status === 401 || error.status === 403)
        if (authInvalid) {
          await signOut()
          navigate('/', { replace: true })
        }
        return
      }
      if (p.name) setOrgName(p.name)
      if (p.district) setRegion(p.district)
      if (p.bin) setBin(p.bin)
      if (p.orgId) {
        setOrgId(p.orgId)
        // Реальный аккаунт МПК — гейты типа/членства из БД (вместо демо-дефолтов).
        setTypeStatus(deriveMpkType(p.orgTypes))
        setMembership(deriveMpkMembership(p.membershipLevel))
      }
    })
    loadMarketBatches().then((list) => {
      if (alive && list !== null) setMarketBatches(list)
    })
    // Реальные пулы МПК из БД; null (аноним/нет backend) — оставляем seed-демо.
    // Перед загрузкой — авто-закрытие просроченных пулов (D-AUTOCLOSE-01).
    closeDuePools().then(() => loadMyPools()).then((list) => {
      if (alive && list !== null) setPools(list)
    })
    loadIncomingOffers().then((list) => {
      if (alive && list !== null) setOffers(list)
    })
    return () => { alive = false }
  }, [])

  // Перечитать всё разом — тело поллинга и pull-to-refresh (IonRefresher, spec §7).
  // Безопасно для демо/анонима: load* вернут null → seed сохраняется.
  const pullAll = useCallback(() => Promise.all([
    closeDuePools().then(() => loadMyPools()).then((list) => { if (list !== null) setPools(list) }),
    loadMarketBatches().then((list) => { if (list !== null) setMarketBatches(list) }),
    loadIncomingOffers().then((list) => { if (list !== null) setOffers(list) }),
  ]), [])

  // Лёгкий поллинг (D-SYNC-01): пулы и маркет-борд обновляются раз в 20с — МПК
  // видит авто-матч партий фермеров и изменения без перезагрузки.
  useEffect(() => {
    const id = setInterval(pullAll, 20000)
    return () => clearInterval(id)
  }, [pullAll])

  // Перечитать маркет-борд (после матча матченная партия уходит из published).
  const refetchMarket = () =>
    loadMarketBatches().then((list) => { if (list !== null) setMarketBatches(list) })

  // Перечитать пулы из БД (после смены статуса/матча).
  const refetchPools = () =>
    loadMyPools().then((list) => { if (list !== null) setPools(list) })

  // Перечитать входящие офферы (после accept/reject/истечения).
  const refetchOffers = () =>
    loadIncomingOffers().then((list) => { if (list !== null) setOffers(list) })

  // Принять broadcast-оффер (FCFS): партия → моя заявка, deal=мой бид ≥ ask. Бросает при ошибке.
  const acceptOffer = async (offerId: string) => {
    const { error } = await supabase.rpc('rpc_self_accept_offer', { p_offer_id: offerId })
    if (error) throw new Error(error.message)
    host.haptics('medium')   // S2.1-паттерн: принятие оффера — ключевое действие
    await Promise.all([refetchOffers(), refetchPools(), refetchMarket()])
  }

  // Отклонить broadcast-оффер. Бросает при ошибке.
  const rejectOffer = async (offerId: string) => {
    const { error } = await supabase.rpc('rpc_self_reject_offer', { p_offer_id: offerId })
    if (error) throw new Error(error.message)
    await refetchOffers()
  }

  // Подтвердить приёмку КУСКА (BT-18): allocation dispatched→delivered (Слайс 9 S3).
  // id строки поставщика = allocation.id (rpc_get_pool_matches.matchId). Бросает при ошибке.
  const confirmDelivery = async (allocationId: string) => {
    const { error } = await supabase.rpc('rpc_self_confirm_delivery_alloc', { p_allocation_id: allocationId })
    if (error) throw new Error(error.message)
    host.haptics('medium')   // S2.1-паттерн: приёмка подтверждена — ключевое действие
    await refetchPools()
  }

  // GAP-REVIEW-MOCK-01: МПК оценивает фермера по доставленному куску (rating = и overall,
  // и ключевая размерность — форма пока с одной звёздной шкалой). Бросает при ошибке.
  const submitMpkReview = async (batchId: string, rating: number) => {
    const { error } = await supabase.rpc('rpc_self_submit_mpk_review', {
      p_batch_id: batchId, p_r1: rating, p_r2: rating, p_comment: '',
    })
    if (error) throw new Error(error.message)
  }

  // Реальный перевод статуса пула в БД. Бросает при ошибке (caller покажет тост).
  const advancePool = async (poolId: string, status: string) => {
    const { error } = await supabase.rpc('rpc_self_advance_pool_status', {
      p_pool_id: poolId, p_new_status: status,
    })
    if (error) throw new Error(error.message)
    await refetchPools()
  }

  // Реальный оффер МПК → партия фермера. Бросает при ошибке (caller покажет тост).
  const offerBatch = async (poolId: string, batchId: string, heads: number, price: number) => {
    const { error } = await supabase.rpc('rpc_self_match_batch_to_pool', {
      p_pool_id: poolId, p_batch_id: batchId, p_matched_heads: heads, p_price_per_kg: price,
    })
    if (error) throw new Error(error.message)
    host.haptics('medium')   // S2.1-паттерн: оффер отправлен — ключевое действие
    await refetchMarket()
  }

  // Реальное self-serve вступление в членство (registered → observer). Бросает при ошибке.
  const joinMembership = async () => {
    if (!orgId) return
    const { error } = await supabase.rpc('rpc_self_join_membership', { p_organization_id: orgId })
    if (error) throw new Error(error.message)
    const p = await loadAccountProfile('mpk')
    if (p) setMembership(deriveMpkMembership(p.membershipLevel))
  }

  const tspOpen = typeStatus === 'approved' && (membership === 'grace' || membership === 'active')

  const showToast = (text: string) => {
    const t = { id: Date.now(), text }
    setToast(t)
    setTimeout(() => setToast((cur) => (cur && cur.id === t.id ? null : cur)), 2800)
  }
  const patchPool = (id: string, patch: Partial<Pool>) =>
    setPools((ps) => ps.map((p) => (p.id === id ? { ...p, ...patch } : p)))
  const addPool = (p: Pool) => setPools((ps) => [p, ...ps])

  // ---------- S6: навигация через Ionic-роутер (v5-остров, S2-паттерн) ----------
  // go сохраняет семантику прежнего setRoute — экраны не переписываются (spec §3).
  // Направление — из карты глубины mpk/nav.ts (DEBT-NATIVE-ROUTER-01: поддерживать
  // при добавлении роутов). К home — настоящий pop (edge-swipe/кнопка ← едины).
  const ionRef = useRef<UseIonRouterResult | null>(null)
  const routeRef = useRef(route)
  routeRef.current = route
  const go = (r: MpkRoute) => {
    const from = routeRef.current
    setRoute(r)
    if (mpkRouteKey(from) === mpkRouteKey(r)) return
    const ion = ionRef.current
    if (!ion) return
    const dir = mpkDirFor(from, r)
    if (dir === 'back' && ion.canGoBack()) ion.goBack()
    else ion.push(mpkRouteToUrl(r), dir)
  }
  // URL → Route-синк: browser-back / edge-swipe / deep-link меняют URL мимо go().
  const syncFromPath = useCallback((path: string) => {
    const r = mpkUrlToRoute(path)
    setRoute((cur) => (mpkRouteKey(cur) === mpkRouteKey(r) ? cur : r))
  }, [])

  // ---------- рендер экрана: v5-Route в IonRouterOutlet (S6, spec §3) ----------
  // Каждый рендер — 1:1 ветка прежнего route.name-switch; экраны получают те же пропсы.
  const renderHome = () => (
    <MpkHomeScreen
      typeStatus={typeStatus}
      membership={membership}
      pools={pools}
      tspOpen={tspOpen}
      orgName={orgName}
      region={region}
      bin={bin}
      onOpenTsp={() => go({ name: 'tsp' })}
      onOpenOffers={() => go({ name: 'offers' })}
      offersCount={offers.length}
      onOpenPool={(id) => openModal({ kind: 'pool_monitor', poolId: id })}
      onOpenContactTuran={(topic) => openSheet(topic)}
      realAccount={orgId !== null}
      onSimulateApprove={() => { setTypeStatus('approved'); showToast('Тип МПК подтверждён (демо)') }}
      onSimulateMember={() => {
        if (orgId) {
          joinMembership()
            .then(() => showToast('Членство активировано'))
            .catch((e) => showToast('Не удалось: ' + (e instanceof Error ? e.message : '')))
        } else {
          setMembership('grace'); showToast('Членство активировано (демо)')
        }
      }}
      onRefresh={pullAll}
    />
  )

  const renderOffers = () => (
    <MpkIncomingOffersScreen
      offers={offers}
      onBack={() => go({ name: 'home' })}
      onAccept={(id) =>
        acceptOffer(id)
          .then(() => showToast('Оффер принят — партия в вашей заявке'))
          .catch((e) => { showToast('Не удалось принять: ' + (e instanceof Error ? e.message : '')); throw e })}
      onReject={(id) =>
        rejectOffer(id)
          .then(() => showToast('Оффер отклонён'))
          .catch((e) => { showToast('Не удалось: ' + (e instanceof Error ? e.message : '')); throw e })}
      onRefresh={pullAll}
    />
  )

  const renderTsp = () => (
    <MpkTspScreen
      pools={pools}
      batches={marketBatches}
      onBack={() => go({ name: 'home' })}
      onCreatePool={() => openModal({ kind: 'create_pool' })}
      onOpenPool={(id) => openModal({ kind: 'pool_monitor', poolId: id })}
      onOpenBatch={(id) => openModal({ kind: 'batch_detail', batchId: id })}
      onRefresh={pullAll}
    />
  )

  // Контент модалов по retained-параметрам (S-2): lookup живёт до onDidDismiss.
  const monitorPool = monitorPoolId ? pools.find((p) => p.id === monitorPoolId) ?? null : null

  return (
    <div className="agos-cabinet-stage">
      <div className="phone">
        <IonApp>
          <IonReactRouter>
            <IonBridge onIon={(ion) => { ionRef.current = ion }} onPath={syncFromPath} />
            <IonRouterOutlet>
              <RouteV5 exact path="/mpk" render={renderHome} />
              <RouteV5 exact path="/mpk/tsp" render={renderTsp} />
              <RouteV5 exact path="/mpk/offers" render={renderOffers} />
              {/* неизвестный под-путь → Главная (первое совпадение выигрывает) */}
              <RouteV5 render={renderHome} />
            </IonRouterOutlet>
          </IonReactRouter>

          {/* Модалы — IonModal поверх страниц (полноэкранные, agos-mpk-modal в ionic.css).
              Смонтированы постоянно (isOpen-флаг) — dismiss-анимация играет и при
              программном закрытии; контент — по retained-параметрам до onDidDismiss. */}
          <IonModal
            isOpen={modal?.kind === 'create_pool'}
            onDidDismiss={() => { closeModal('create_pool'); setCreateRendered(false) }}
            className="agos-mpk-modal"
          >
            {createRendered && (
              <CreatePoolModal
                orgId={orgId}
                onClose={() => closeModal('create_pool')}
                onSubmit={(pool) => {
                  addPool(pool)
                  closeModal('create_pool')
                  host.haptics('medium')   // S2.1-паттерн: публикация заявки — ключевое действие
                  showToast('Заявка на закупку создана')
                }}
              />
            )}
          </IonModal>

          <IonModal
            isOpen={modal?.kind === 'pool_monitor'}
            onDidDismiss={() => { closeModal('pool_monitor'); setMonitorPoolId(null) }}
            className="agos-mpk-modal"
          >
            {monitorPool && (
              <PoolMonitorModal
                pool={monitorPool}
                onClose={() => closeModal('pool_monitor')}
                onPatch={(patch) => patchPool(monitorPool.id, patch)}
                toast={showToast}
                onContactTuran={() => { closeModal('pool_monitor'); openSheet() }}
                mpk={{ orgName, region, bin }}
                onAdvance={advancePool}
                onLoadMatches={loadPoolMatches}
                onConfirmDelivery={confirmDelivery}
                onSubmitReview={submitMpkReview}
              />
            )}
          </IonModal>

          <IonModal
            isOpen={modal?.kind === 'batch_detail'}
            onDidDismiss={() => { closeModal('batch_detail'); setDetailBatchId(null) }}
            className="agos-mpk-modal"
          >
            {detailBatchId !== null && (
              <BatchDetailModal
                batch={marketBatches.find((b) => b.id === detailBatchId)}
                pools={pools.filter((p) => p.status === 'filling')}
                onClose={() => closeModal('batch_detail')}
                toast={showToast}
                onMatch={offerBatch}
                onOffer={(deal) => openModal({ kind: 'deal_closed', deal })}
              />
            )}
          </IonModal>

          <IonModal
            isOpen={modal?.kind === 'deal_closed'}
            onDidDismiss={() => { closeModal('deal_closed'); setClosedDeal(null) }}
            className="agos-mpk-modal"
          >
            {closedDeal && (
              <DealClosedModal
                deal={closedDeal}
                onClose={() => closeModal('deal_closed')}
                toast={showToast}
              />
            )}
          </IonModal>

          {/* Шторка — уже IonModal через Sheet.tsx (S2); смонтирована постоянно,
              каждый показ с чистого состояния (реинициализация по open внутри). */}
          <ContactTuranSheet
            open={sheet?.kind === 'contact_turan'}
            topic={sheetTopic}
            onClose={() => setSheet(null)}
            onSubmit={() => { setSheet(null); showToast('Обращение принято') }}
          />

          <Toast toast={toast} />
        </IonApp>
      </div>
    </div>
  )
}
