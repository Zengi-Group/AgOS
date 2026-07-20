// AgOS · Этап 1 · Корень оболочки фермера: состояние, localStorage, навигация,
// бейджи, AI-гейт, действия членства, платёжные шторки. Источник истины — прототип shell/app.jsx.

import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { BootScreen } from '@/components/BootScreen'
// S2 (ARS-148, ADR-NATIVE-ROUTER-01 AMEND-1): Ionic-навигация. IonReactRouter живёт
// на изолированном react-router v5 (v5-остров, vite.config.ts agos:ionic-v5-island);
// остальное приложение остаётся на v6. Гейт-спайк пройден 2026-07-03.
import { setupIonicReact, IonApp, IonPage, IonRouterOutlet, IonTabs, IonTabBar, IonTabButton } from '@ionic/react'
import { PhIcon } from './components/icons/PhIcon'
import type { UseIonRouterResult } from '@ionic/react'
import { useIonRouter } from '@ionic/react'
import { IonReactRouter } from '@ionic/react-router'
// @ts-expect-error v5-alias пакет без @types — импорты v5-острова (спайк-проверено).
// RouteV5 — иначе конфликт имён с типом Route из './types'. RedirectV5 — нормализация
// старых плоских deep-link/push-путей в канонический таб-URL (N-2 backward-compat).
import { Route as RouteV5, Redirect as RedirectV5, useLocation } from 'react-router-dom-v5'
import '@ionic/react/css/core.css'
import './cabinet.css'
import './ionic.css'
import './shell-proto.css'
import './market-proto.css'
import './messages-proto.css'
// ARS-231 (решение CEO): чат-механика — Chatscope; база kit → перекраска в daylight
import '@chatscope/chat-ui-kit-styles/dist/default/styles.min.css'
import './messages-chatscope.css'
import { useAuth } from '@/hooks/useAuth'
import { ShellCtx } from './context'
import {
  INITIAL_STATE, STORAGE_KEY, tabOf, deriveMembership,
} from './store'
import { routeToUrl, urlToRoute, routeKey, dirFor } from './nav'
import { supabase } from '@/lib/supabase'
import type {
  MembershipStatus, Route, RouteName, SheetKind, SheetState, ShellState, ToastState, ShellContextValue, Batch,
} from './types'
import { useBatches } from './hooks/useBatches'
import { Toast } from './components/Toast'
import { PlaceholderScreen } from './screens/PlaceholderScreen'
import { IonShellFrame } from './components/IonShellFrame'
import { ScreenSkeleton } from './components/ScreenSkeleton'
import { CabinetScreen } from './screens/CabinetScreen'
import { HomeScreen } from './screens/HomeScreen'
import { MarketScreen } from './screens/MarketScreen'
import { ListScreen } from './screens/ListScreen'
import { BatchScreen } from './screens/BatchScreen'
import { ReviewScreen } from './screens/ReviewScreen'
import { TuranScreen } from './screens/TuranScreen'
// ARS-231: сообщения — треды модулей + AI-консультант (порт Фазы 03 прототипа)
import { MessagesScreen } from './screens/MessagesScreen'
import { ThreadScreen } from './screens/ThreadScreen'
import { ConsultantScreen } from './screens/ConsultantScreen'
import { aiReply, type ThreadEnv, type ThreadH, type ThreadId } from './data/threads'
import { LimitSheet } from './components/sheets/LimitSheet'
import { BatchWizard } from './tsp/wizard/BatchWizard'
import { PubResult } from './tsp/wizard/PubResult'
import type { PubVariant } from './tsp/types/batch'
import { FarmScreen } from './screens/FarmScreen'
import { FarmWizard } from './farm/wizard/FarmWizard'
import { PayVznosSheet } from './components/sheets/PayVznosSheet'
import { SubscribeSheet } from './components/sheets/SubscribeSheet'
import { PayProSheet } from './components/sheets/PayProSheet'
import { ProGateSheet } from './components/sheets/ProGateSheet'
import { MembGateSheet } from './components/sheets/MembGateSheet'
import { PriceSheet } from './components/sheets/PriceSheet'
import { buildDecisions, buildObserve, type DecH } from './data/membership'
import { FARMER_LEAD_CAT, stickerData } from './data/prices'
import type { BannerCard, ServiceDef } from './data/banners'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
import { useEntitlementsRealtimeSync } from '@/hooks/useEntitlementsRealtimeSync'
import { loadFarmState } from './data/farm-load'
import { emptyFarm } from './data/farm-seed'
// S3 (ARS-149, EngSpec §4): платформенные адаптеры — KV-хранилище и реальный сетевой статус.
import { appStorage } from '@/platform/storage'
import { useOnline } from '@/platform/network'
// S2.1 (ARS-157, spec §7): тактильный отклик на ключевых действиях через Host Bridge.
// В web — no-op; S4 (CapacitorHost) получит вибрацию бесплатно. НЕ звать @capacitor/* напрямую.
import { useHost } from '@/platform/host/HostContext'

// Инициалы для аватара хозяйства из названия орг/имени владельца.
// «КХ Тестовое» → «ТЕ», «Алтын Дала» → «АД». Снимаем юр. форму-приставку,
// берём первые буквы 1–2 значимых слов. Пусто/нет профиля → демо-фолбэк «АД».
function deriveInitials(name: string | null | undefined): string {
  if (!name) return 'АД'
  const cleaned = name.replace(/^(КХ|КФХ|ТОО|ИП|АО|ТО|ПК|ЧП|ОО)\.?\s+/i, '').trim()
  const words = cleaned.split(/\s+/).filter(Boolean)
  const w0 = words[0]
  const w1 = words[1]
  if (!w0) return 'АД'
  if (!w1) return w0.slice(0, 2).toUpperCase()
  return ((w0[0] ?? '') + (w1[0] ?? '')).toUpperCase()
}

// Локальный признак «взнос оплачен» (на демо/пилоте), ключ по userId. Нужен, чтобы оплата
// переживала перезагрузку даже если серверный RPC недоступен (миграция не применена и т.п.).
// Серверный сигнал (rpc_pay_membership_dues → memberships.level) — основной (виден админу);
// этот флаг — фолбэк, чтобы фермер после оплаты не видел повторный запрос подтверждения.
const PAID_KEY = (userId: string) => 'agos.memb.paid.' + userId
const isPaidLocally = (userId: string | undefined | null) =>
  !!userId && appStorage.getItem(PAID_KEY(userId)) === '1'

// D4 (офлайн-чтение): страж от вечного BootScreen. rpc_get_my_context / getUser могут
// подвиснуть без ответа (медленная/пропавшая сеть) — гонка с таймаутом даёт кабинету
// сорваться с загрузки на персистнутый стейт и повторить в фоне.
const BOOT_TIMEOUT_MS = 8000
const TIMED_OUT = Symbol('boot-timeout')
function withTimeout<T>(p: Promise<T>): Promise<T | typeof TIMED_OUT> {
  return Promise.race([
    p,
    new Promise<typeof TIMED_OUT>((res) => setTimeout(() => res(TIMED_OUT), BOOT_TIMEOUT_MS)),
  ])
}

function loadState(): ShellState {
  try {
    const raw = appStorage.getItem(STORAGE_KEY)
    if (raw) {
      const saved = JSON.parse(raw) as Partial<ShellState>
      return { ...INITIAL_STATE, ...saved, route: saved.route?.name ? saved.route : { name: 'home' } }
    }
  } catch {
    /* noop */
  }
  return INITIAL_STATE
}

// iOS-режим для всей оболочки: slide push/pop-переходы + edge-swipe-назад
// (в браузере/Android md-режим не даёт swipe-back — acceptance ARS-148 требует).
setupIonicReact({ mode: 'ios' })

// Мост v5-роутера: отдаёт ionRouter наружу для go() и синкает URL → Route-состояние
// (browser-back / edge-swipe / deep-link меняют URL мимо go()).
function IonBridge({ onIon, onPath }: { onIon: (ion: UseIonRouterResult) => void; onPath: (path: string) => void }) {
  const ion = useIonRouter()
  useEffect(() => { onIon(ion) })
  const loc = useLocation() as { pathname: string }
  useEffect(() => { onPath(loc.pathname) }, [loc.pathname, onPath])
  return null
}

export function CabinetApp() {
  const navigate = useNavigate()
  const { signOut, refreshContext } = useAuth()
  const host = useHost()   // S2.1: тактильный отклик (web no-op)
  const init = loadState()
  const [membership, setMembership] = useState<MembershipStatus>(init.membership)
  const [isPro, setIsPro] = useState(init.isPro)
  // S2: URL — источник истины экрана (deep-link открывает нужный экран);
  // сохранённый в localStorage route больше не восстанавливает экран после перезагрузки —
  // его роль выполняет сам URL (перезагрузка держит текущий экран автоматически).
  const [route, setRoute] = useState<Route>(() => urlToRoute(window.location.pathname))
  // Профиль реального аккаунта (если вошёл). null = демо-режим (аноним / нет бэкенда).
  const [profile, setProfile] = useState<AccountProfile | null>(null)
  // Пока профиль грузится — показываем лоадер вместо демо-экрана. /cabinet всегда за
  // RequireAuth (сессия гарантирована), поэтому демо-фолбэк не должен даже мелькать.
  const [profileLoading, setProfileLoading] = useState(true)
  // Партии скоупятся по аккаунту (userId): backend фильтрует по org (fn_my_org_ids), а
  // localStorage-кеш — по ключу с userId, поэтому партии одного владельца не видны другому.
  const { batches, loading: batchesLoading, error: batchesError, addBatch, patchBatch: patchBatchAsync, refetch: refetchBatches } = useBatches(profile?.userId)
  const [notifs, setNotifs] = useState(init.notifs)
  const [newsOn, setNewsOn] = useState(init.newsOn)
  const [profileIncomplete] = useState(init.profileIncomplete)
  const [farmUnread, setFarmUnread] = useState(init.farmUnread)
  const [turanUnread, setTuranUnread] = useState(init.turanUnread)
  const [aiLog, setAiLog] = useState(init.aiLog)
  // ARS-231: индикатор «Консультант печатает…» (мок aiReply до подключения AI Gateway)
  const [aiTyping, setAiTyping] = useState(false)
  // Ферма: по умолчанию демо-сид (для анонима/без бэкенда). Для вошедшего аккаунта
  // ниже подгружается реальная сводка стада (rpc_get_farm_summary) и перекрывает сид.
  const [farm, setFarm] = useState(init.farm)
  // P-3 (ARS-219, F6): пока первая загрузка фермы не завершилась — Главная показывает
  // скелет, а не демо-сид `init.farm` (иначе вошедший фермер видит фейковые «N голов»,
  // которые затем подменяются реальными). Флаг взводится после ПЕРВОГО settle pullFarm()
  // (resolve ИЛИ reject) — для анонима (loadFarmState→null) сид тогда показывается штатно.
  const [farmLoaded, setFarmLoaded] = useState(false)

  // S3 (ARS-149): реальный сетевой статус вместо заглушки — OfflineBar и
  // офлайн-гейты (memberAct → offlineToast) оживают. Web = navigator.onLine (Dok6 Slice1).
  const online = useOnline()
  const offline = !online
  const loading = batchesLoading
  // P-3 (ARS-219, F6): Главная зависит и от партий, и от сводки фермы — скелет держим,
  // пока не готовы ОБА источника (иначе herd-строка поповит демо-сид → реальные данные).
  const homeLoading = loading || !farmLoaded

  // Реальная сводка фермы (стадо + задачи) перекрывает демо-сид. Хойстнута из эффекта
  // (S2): переиспользуется pull-to-refresh на Главной (IonRefresher, spec §7).
  // D1 (офлайн-чтение): реальная сводка перекрывает демо-сид. fs===null при живой сессии
  // НЕ должен оставлять демо-«Отёл, день 34» — на ПЕРВОМ заходе показываем честный emptyFarm();
  // на фоновых поллингах при null держим последнее хорошее (не перетираем реальное стадо
  // транзиентным сбоем summary/сети). /cabinet всегда за RequireAuth — демо-сид тут не легитимен.
  const pullFarm = useCallback(
    (opts?: { firstLoad?: boolean }) => loadFarmState().then((fs) => {
      if (fs) setFarm(fs)
      else if (opts?.firstLoad) setFarm(emptyFarm())
    }),
    []
  )

  useEffect(() => {
    let alive = true
    let retried = false

    // C3 (офлайн-чтение): сессия жива (/cabinet за RequireAuth), но контекст не загрузился.
    // Сервер недоступен/офлайн → НЕ трогаем membership (активный член остаётся членом на
    // персистнутом init.membership, Рынок не закрывается гейтом), ферму показываем честным
    // пусто вместо демо-сида. Профиль (имя орг/инициалы) освежится при возврате связи/маунте.
    function settleOffline() {
      if (!alive) return
      setFarm(emptyFarm())
      setProfileLoading(false)
      // D4: один фоновый повтор через 5с (реконнект отдельно ловит wasOffline-эффект ниже).
      if (!retried) {
        retried = true
        setTimeout(() => { if (alive) loadProfile() }, 5000)
      }
    }

    async function loadProfile() {
      const p = await withTimeout(loadAccountProfile('farmer'))
      if (!alive) return
      if (p === TIMED_OUT) { settleOffline(); return }   // D4: подвисло — на персист
      if (p) { setProfile(p); setProfileLoading(false); return }
      // Профиль пуст при наличии сессии: возможна «осиротевшая» сессия (пользователь удалён
      // из БД, но JWT остался в браузере). Проверяем на сервере через getUser() — он обращается
      // к Auth и возвращает 401/403, если пользователя больше нет. Тогда выходим и уводим на
      // лендинг, чтобы не залипать в демо-кабинете. Сетевые сбои (без статуса) НЕ разлогиниваем.
      let userData: Awaited<ReturnType<typeof supabase.auth.getUser>>['data'] | null = null
      let getErr: unknown = null
      try {
        const r = await withTimeout(supabase.auth.getUser())
        if (!alive) return
        if (r === TIMED_OUT) { settleOffline(); return }  // D4
        userData = r.data; getErr = r.error
      } catch (e) {
        getErr = e   // сетевой бросок (fetch failed) — трактуем как офлайн ниже
      }
      if (!alive) return
      const status = (getErr as { status?: number } | null)?.status
      const orphaned = (status === 401 || status === 403) || (!getErr && !userData?.user)
      if (orphaned) {
        await signOut()
        navigate('/', { replace: true })
        return
      }
      if (getErr) {
        // C3: getUser не подтвердил сессию не из-за 401/403 → сеть/сервер недоступны → офлайн.
        settleOffline()
        return
      }
      // Сессия валидна (getUser прошёл), но контекста нет — напр. зарегистрирован, ещё нет
      // орг/членства. Показываем реальный ПУСТОЙ стейт, а НЕ демо-сид (ARS-210): членства нет,
      // фермы нет. Иначе фермер без членства видел бы фейковые «Членство активно» + «Отёл, день 34».
      setProfile(null)
      setMembership('none')
      setFarm(emptyFarm())
      setProfileLoading(false)
    }

    loadProfile()
    // Поллинг 30с — стадо/задачи обновляются без перезагрузки после правок в профиле (D-SYNC-01).
    // D1: firstLoad=true — сбой первой сводки при живой сессии даёт emptyFarm(), не демо-сид.
    pullFarm({ firstLoad: true }).finally(() => { if (alive) setFarmLoaded(true) })
    const id = setInterval(() => pullFarm(), 30000)
    return () => { alive = false; clearInterval(id) }
  }, [pullFarm])

  // Dok6 offline-контракт: retry — при восстановлении сети сразу перезагружаем данные,
  // не дожидаясь 30с-поллинга. Первый рендер пропускаем (данные и так грузятся на маунте).
  const wasOffline = useRef(false)
  useEffect(() => {
    if (offline) { wasOffline.current = true; return }
    if (!wasOffline.current) return
    wasOffline.current = false
    pullFarm()
    refetchBatches()
  }, [offline, pullFarm, refetchBatches])

  // ARS-269 (slice B): живой слушатель entitlements.invalidated. Админ-действия по
  // подписке (revoke / ручная оплата / продление — ARS-267) и lifecycle d13 эмитят это
  // событие в platform_events; RLS platform_events_read_own скоупит доставку до орг
  // вошедшего фермера. Пере-грузим профиль → deriveMembership пересчитает статус за
  // секунды, а не «до полного reload» (soft-invalidation M3 D-FG-4: сервер и так
  // enforce'ит TSP-гейты, это свежесть UI). Профиль иначе грузится только на маунте —
  // visibilitychange/30с-поллинг обновляют ферму/партии, но не подписку.
  const reloadEntitlements = useCallback(async () => {
    const p = await loadAccountProfile('farmer')
    if (p) setProfile(p)   // только на успехе — транзиентный сбой держит last-good профиль
    refreshContext()       // синхронизируем и глобальный auth-контекст (useAuth)
  }, [refreshContext])
  useEntitlementsRealtimeSync(reloadEntitlements)

  // D12 (офлайн-чтение): возврат из фона (разблокировка/переключение вкладки) — сразу
  // тихо освежаем стадо и партии, чтобы не показывать до 30с/20с устаревшие данные.
  // На нативе appStateChange уже покрыт S4-хостом; здесь web-путь через visibilitychange.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState !== 'visible') return
      pullFarm()
      refetchBatches()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => document.removeEventListener('visibilitychange', onVisible)
  }, [pullFarm, refetchBatches])

  // Изоляция по аккаунту: при входе под другим userId не наследуем кабинет предыдущего.
  useEffect(() => {
    if (!profile?.userId) return
    const ACC_KEY = 'agos.cabinet.account'
    const last = appStorage.getItem(ACC_KEY)
    if (last && last !== profile.userId) {
      appStorage.removeItem(STORAGE_KEY)
      // Партии предыдущего аккаунта: чистим и его скоуп-кеш, и легаси-ключ без скоупа
      // (в нём могли остаться партии старого владельца до введения скоупинга по userId).
      appStorage.removeItem(`agos.cabinet.batches.v1.${last}`)
      appStorage.removeItem('agos.cabinet.batches.v1')
      setMembership(INITIAL_STATE.membership)
      setIsPro(INITIAL_STATE.isPro)
      setRoute(INITIAL_STATE.route)
      setNotifs(INITIAL_STATE.notifs)
      setNewsOn(INITIAL_STATE.newsOn)
      setFarmUnread(INITIAL_STATE.farmUnread)
      setTuranUnread(INITIAL_STATE.turanUnread)
      setAiLog(INITIAL_STATE.aiLog)
    }
    appStorage.setItem(ACC_KEY, profile.userId)
  }, [profile?.userId])

  // Реальный статус членства из БД перекрывает локальный (для вошедшего аккаунта).
  // Аноним (profile === null) остаётся на демо/localStorage.
  useEffect(() => {
    if (!profile?.userId) return
    // ARS-263: подписка (subscriptionState) — канонический источник статуса (D-BILL-TRUTH-01).
    // Переживает reload: статус выводится из БД-подписки, а не только level+заявка (B1).
    let derived = deriveMembership(profile.membershipLevel, profile.applicationStatus, profile.subscriptionState)
    // Фолбэк: если взнос уже оплачен локально (демо), но БД ещё отдаёт 'approved'
    // (RPC недоступен/не применён), не сбрасываем в запрос оплаты — держим 'active'.
    if (derived === 'approved' && isPaidLocally(profile.userId)) derived = 'active'
    setMembership(derived)
  }, [profile?.userId, profile?.membershipLevel, profile?.applicationStatus, profile?.subscriptionState])
  const [sheet, setSheet] = useState<SheetState | null>(null)
  const [toast, setToast] = useState<ToastState | null>(null)
  // S2-ревью (PR #27): IonModal-шторки держим смонтированными — программное закрытие
  // анимируется через isOpen=false (условный unmount рвал dismiss-анимацию). Сброс
  // внутреннего состояния stateful-шторок — у них самих по open=true (НЕ через key-remount:
  // размонтирование ion-modal в момент презентации соседнего ломает overlay-стек Ionic).
  // closeSheet гардит по kind: поздний onDidDismiss закрывающейся шторки не должен убить
  // следующую, уже открытую (переход progate→paypro).
  const closeSheet = (kind: SheetKind) => setSheet((cur) => (cur?.kind === kind ? null : cur))

  // ---------- TSP-1: визард «Новая партия» + результат публикации (роуты 'batchwiz'/'pub') ----------
  // N-3/N-5/M4/M5: визард и результат — реальные роуты острова, не state-оверлей. PubVariant —
  // транзиентная UI-подсказка (searching-анимация), на партии не хранится → держим в ref по id
  // батча на время флоу (deep-link/reload → фолбэк 'D', без searching).
  const pubVariantRef = useRef<Record<string, PubVariant>>({})

  // ---------- ARS-212: мастер профиля фермы (теперь роут 'farmwiz', не state-оверлей) ----------
  // startAt держится в state (какой ярус открыть); сам показ мастера — навигацией на роут.
  const [farmWizStart, setFarmWizStart] = useState<'herd' | 'plan'>('herd')

  // ---------- persistence ----------
  useEffect(() => {
    try {
      // farm НЕ персистим: для вошедшего аккаунта это реальное стадо (rpc_get_farm_summary),
      // которое перезагружается на каждом маунте; сохранение в localStorage только давало бы
      // устаревшее/чужое стадо при следующем входе (изоляция данных). Сид грузится по умолчанию.
      const state: Omit<ShellState, 'batches' | 'farm'> = {
        membership, isPro, route, notifs, aiLog,
        newsOn, profileIncomplete, farmUnread, turanUnread,
      }
      appStorage.setItem(STORAGE_KEY, JSON.stringify(state))
    } catch {
      /* noop */
    }
  }, [membership, isPro, route, notifs, aiLog, newsOn, profileIncomplete, farmUnread, turanUnread])

  // ---------- хелперы ----------
  const showToast = (text: string) => {
    const t = { id: Date.now(), text }
    setToast(t)
    setTimeout(() => setToast((cur) => (cur && cur.id === t.id ? null : cur)), 2800)
  }
  const offlineToast = () => showToast('Нет связи. Попробуйте, когда появится сеть')

  // ---------- S2: навигация через Ionic-роутер (v5-остров) ----------
  // go сохраняет сигнатуру (r: Route) => void — экраны не переписываются (spec §3).
  // Направление анимации — из карты глубины nav.ts (DEBT-NATIVE-ROUTER-01: поддерживать
  // при добавлении роутов). Таб-корни — 'root'+'replace' (native tab UX, история не растёт).
  const ionRef = useRef<UseIonRouterResult | null>(null)
  const routeRef = useRef(route)
  routeRef.current = route
  // C11 (issue #4, 2026-07-15): iOS-mode push/pop ≈ 540мс. «Назад», пойманный ПОКА идёт
  // forward-переход (открытие треда), заставляет StackManager Ionic проиграть вход целевого
  // экрана ДВАЖДЫ («список чатов въезжал дважды»). Отложить pop не помогает — важен сам факт
  // навигации во время незавершённого forward-перехода. Поэтому, как в нативном iOS, «назад»
  // на время анимации ЗАБЛОКИРОВАН (тап игнорируется). navBusyUntil — метка конца forward-анимации.
  const NAV_ANIM_MS = 650
  const navBusyUntilRef = useRef(0)
  const navBusy = () => performance.now() < navBusyUntilRef.current
  const go = (r: Route) => {
    const from = routeRef.current
    setRoute(r)
    if (routeKey(from) === routeKey(r)) return   // тот же экран — обновилось только состояние (back/tid)
    const ion = ionRef.current
    if (!ion) return
    const dir = dirFor(from, r)
    const url = routeToUrl(r)
    // Метку «переход занят» ставим ДО push (чтобы «назад» в тот же тик уже видел занятость).
    navBusyUntilRef.current = performance.now() + NAV_ANIM_MS
    // C8 (аудит 2026-07-13): go() НИКОГДА не поппит историю — 'back' здесь только направление
    // анимации (push с back-slide). Реальный pop делает goBackTo (кнопки ‹). Прежняя pop-ветка
    // уводила cross-nav (карточка партии → «Обратитесь в TURAN», dir=back по глубине 2→1) назад
    // в список вместо открытия экрана TURAN.
    if (dir === 'root') ion.push(url, 'root', 'replace')
    else ion.push(url, dir)
  }
  // Явный «назад» (кнопки ←): настоящий pop, когда стек позволяет — иначе возврат на
  // таб-корень анимировался как смена корня (ревью PR #27, SIG-2). Холодный deep-link
  // (стек пуст) → push с back-анимацией; URL→Route-синк выправит состояние при расхождении.
  const goBackTo = (r: Route) => {
    // C11: пока forward-переход анимируется — игнорируем «назад» (иначе двойной вход экрана).
    // Нативное поведение iOS: «назад» недоступен, пока экран въезжает. Окно ≤650мс — реальный
    // возврат (после чтения треда) не задевается; гасится только сверх-быстрый тап в анимацию.
    if (navBusy()) return
    setRoute(r)
    const ion = ionRef.current
    if (!ion) return
    if (ion.canGoBack()) ion.goBack()
    else ion.push(routeToUrl(r), 'back')
    navBusyUntilRef.current = performance.now() + NAV_ANIM_MS
  }
  // Подпись к «‹ назад» в SubHead внутренних страниц — из имени back-роута (нативный iOS-стиль).
  const backLabelFor = (r?: Route): string => {
    const labels: Record<string, string> = {
      home: 'Главная', market: 'Рынок', p1list: 'Мои партии', cabinet: 'Кабинет', farm: 'Ферма', batch: 'Партия',
    }
    return (r && labels[r.name]) || 'Назад'
  }
  // URL → Route-синк: browser-back / edge-swipe / deep-link меняют URL мимо go().
  // `back` при этом не восстанавливается — onBack-хендлеры используют `route.back ?? fallback`.
  const syncFromPath = useCallback((path: string) => {
    const r = urlToRoute(path)
    setRoute((cur) => (routeKey(cur) === routeKey(r) ? cur : r))
  }, [])
  // C10 (аудит 2026-07-13): тёплый deep-link (тап по push при открытом приложении) должен
  // переключать экран ВНУТРИ v5-острова. v6-navigate (PushDeepLinkBridge) меняет внешний URL,
  // но остров с собственным history-инстансом его не слышит. Подписываемся на host.onDeepLink
  // напрямую и гоним /cabinet-пути через go(); пути вне острова остаются за PushDeepLinkBridge.
  // goRef — чтобы подписка ставилась один раз, а не пересоздавалась на каждый рендер go.
  const goRef = useRef(go)
  goRef.current = go
  useEffect(() => {
    const unsub = host.onDeepLink((path) => {
      if (path.startsWith('/cabinet')) goRef.current(urlToRoute(path))
    })
    return unsub
  }, [host])
  const tab = tabOf(route)
  // P-4 (ARS-220): единый постоянный IonTabBar (не пересобирается при переходах). На
  // детальных экранах он скрыт — как было при per-page noTabs (решение CEO: сохранить UX).
  // Флоу-страницы (agos-flow-page: TSP-визард, результат публикации, мастер фермы) — полноэкранные,
  // без таб-бара (контракт Slice 5a/7). До P-4 (ARS-220) бар не рендерился внутри их IonPage;
  // с постоянным IonTabBar его надо прятать явно — иначе бар просвечивает под визардом.
  // Флоу-страницы теперь реальные роуты (farmwiz/batchwiz/pub) — таб-бар прячется по имени роута,
  // без state-флагов (ушла и причина C9-«призрачного» переоткрытия: нет флагов мимо URL).
  const hideTabBar = (['p1list', 'batch', 'review', 'turan', 'thread', 'farmwiz', 'batchwiz', 'pub'] as RouteName[]).includes(route.name)

  const handleLogout = async () => {
    await signOut()
    navigate('/login', { replace: true })
  }

  // ---------- бейджи ----------
  const marketDot = batches.some((b) => b.state === 'decision')
  const unread = notifs.filter((n) => n.unread).length
  // ARS-231: решения (decision) считаются в бейдже сообщений — pinned «ТРЕБУЕТ РЕШЕНИЯ»
  // треда Рынка остаётся непрочитанным, пока фермер не решит (прототип app/messages.jsx).
  const decCount = batches.filter((b) => b.state === 'decision').length
  const msgBadge = unread + decCount + (farmUnread ? 1 : 0) + (turanUnread ? 1 : 0)
  const avatarDot = (['approved', 'grace', 'expired'] as MembershipStatus[]).includes(membership)

  // ---------- AI: Консультант только с Platform Pro ----------
  const openAI = (_ctx2?: string, _opts?: { voice?: boolean; batchId?: string }) => {
    if (!isPro) {
      setSheet({ kind: 'progate' })
      return
    }
    setAiLog((l) => l)
    // S2: через go() — иначе URL разъедется с экраном (прямой setRoute мимо роутера).
    const r = routeRef.current
    if (!(r.name === 'thread' && r.tid === 'consultant')) go({ name: 'thread', tid: 'consultant', back: r })
  }
  const openPrices = (catKey: string) => setSheet({ kind: 'prices', catKey })

  // ---------- членство ----------
  // Флоу: 'apply' → полноэкранный процесс подачи заявки (/membership: интро → документы →
  // отправка → 'pending') → 'approved' (одобрено, взнос не оплачен) → 'pay' → оплата → 'active'.
  // Единый вход: все CTA «Вступить» / «Подать заявку» ведут в /membership (не в шторку).
  const memberAct = (act: string) => {
    if (offline) { offlineToast(); return }
    if (act === 'apply') {
      setSheet(null)
      // Членство требует юр. хозяйства (БИН). Нет организации (незавершённая регистрация) →
      // сначала достраиваем регистрацию (создать орг), оттуда откроется членство. Иначе —
      // полноэкранный процесс подачи заявки.
      navigate(profile?.orgId ? '/membership' : '/register')
    }
    // ARS-207 (решение CEO 2026-07-15): оплата членства = рекуррентная подписка.
    // Старый разовый взнос (kind 'payvznos') выведен из UI (deprecated, код сохранён).
    else setSheet({ kind: 'subscribe' })
  }
  // Оплата взноса — симуляция на пилоте (реальной платёжной системы пока нет): выбор способа →
  // «Оплатить» → членство сразу активно, Рынок (TSP) открывается.
  // Персистентность: (1) серверный сигнал rpc_pay_membership_dues поднимает memberships.level
  // registered→observer — переживает перезагрузку И виден админу; (2) локальный флаг PAID_KEY —
  // фолбэк, чтобы оплата не запрашивалась повторно даже если RPC недоступен (миграция не применена).
  const payVznosDone = async () => {
    // S4=A · C4: оплата взноса — серверное действие; офлайн честно блокируем
    // (у него своя оптимистичная setMembership мимо patchBatch, поэтому гейт здесь).
    if (offline) { offlineToast(); return }
    // Этап 2 · D9: отклик мгновенный — членство активно ДО сетевого вызова. Раньше
    // setMembership('active') стоял ПОСЛЕ await: секунды «ничего не произошло», а плашка
    // «Оплатить взнос» оставалась и была повторно нажимаема. Сервер — источник правды,
    // синхронизируется в фоне; фолбэк на локальный флаг делает оптимизм безопасным.
    setSheet(null)
    setTuranUnread(false)
    setMembership('active')
    host.haptics('medium')   // S2.1: оплата взноса — ключевое действие
    showToast('Взнос оплачен · членство активно')
    // Источник истины — сервер: rpc_pay_membership_dues поднимает memberships.level
    // registered→observer (переживает перезагрузку И виден админу). Локальный флаг ставим
    // ТОЛЬКО если серверный вызов не прошёл — иначе клиент и БД расходятся (UI «оплачено»,
    // а в БД нет), что и приводило к «у админа не оплачено».
    let serverOk = false
    if (profile?.orgId) {
      const { error } = await supabase.rpc('rpc_pay_membership_dues', { p_organization_id: profile.orgId })
      if (!error) serverOk = true
      else console.warn('rpc_pay_membership_dues не прошёл, локальный фолбэк:', error.message)
    }
    if (!serverOk && profile?.userId) appStorage.setItem(PAID_KEY(profile.userId), '1')
  }
  const payProDone = () => {
    setIsPro(true); setSheet(null)
    host.haptics('medium')   // S2.1: подключение Pro — ключевое действие
    showToast('Platform Pro подключён · Консультант открыт')
  }
  // ARS-207: подписка оформлена (rpc_subscribe_org_membership прошёл в шторке) — членство
  // активно, Рынок (TSP) открывается. Мгновенный статус мок-фолбэком не подпираем: сервер
  // уже создал live-подписку (trialing/active), а deriveMembership при следующем pull её учтёт.
  const subscribeDone = () => {
    setSheet(null)
    setMembership('active')
    host.haptics('medium')
    showToast('Подписка оформлена · членство активно')
  }

  // ---------- Главная: ярусы, баннер, стикер, сервисы ----------
  const bannerVariant = (membership === 'none' || membership === 'terminated') ? 'join' : 'season'
  const sticker = stickerData(FARMER_LEAD_CAT, 'auto')

  // S4=A · C4+D7 (единый источник фидбека мутаций партий). Все действия через onPatch
  // (снятие/отгрузка/цена/отзыв/отмена) сходятся сюда.
  //  - C4: офлайн → честный гейт, БЕЗ локальной мутации и без ложного «успеха».
  //  - D7: тост успеха показываем ТОЛЬКО после сетевого round-trip (patchBatchAsync
  //    резолвится после попытки RPC), а не оптимистично до отправки. Копия тоста
  //    приходит из call-site как successToast (контекст остаётся у вызывающего).
  const patchBatch = (id: string, patch: Partial<Batch>, successToast?: string) => {
    if (offline) { offlineToast(); return }
    patchBatchAsync(id, patch)
      .then(() => { if (successToast) showToast(successToast) })
      .catch((e: unknown) => {
        const msg = e instanceof Error ? e.message : 'Ошибка'
        showToast(msg)
      })
  }

  // обработчики ярусов и тредов (один объект — две поверхности)
  const decH: DecH = {
    lower: (b) => {
      patchBatch(b.id, { state: 'offering', deadlineLabel: 'завтра, 14:30' }, 'Предложение отправлено покупателям по новой цене')
    },
    open: () => go({ name: 'market' }),
    dispatch: (b) => {
      patchBatch(b.id, { state: 'dispatched' }, 'Покупатель получил уведомление об отгрузке')
      host.haptics('medium')   // S2.1: отгрузка — ключевое действие
    },
    review: (b) => go({ name: 'review', batchId: b.id, back: { name: 'home' } }),
    pay: () => memberAct('pay'),
    apply: () => memberAct('apply'),
    cabinet: () => go({ name: 'cabinet' }),
    farm: () => go({ name: 'farm' }),
  }
  const decisions = buildDecisions({ batches, membership, h: decH })
  const observe = buildObserve({ batches, membership, h: decH })

  const onBanner = (c: BannerCard) => {
    if (c.act === 'join') memberAct('apply')
    else if (c.act === 'pro') { if (isPro) showToast('Platform Pro уже подключён'); else setSheet({ kind: 'paypro' }) }
    else if (c.act === 'prices') openPrices(sticker.catKey)
    else if (c.act === 'course') showToast('Курс TURAN откроется в обучении — вне прототипа')
    else showToast('Маркет откроется с партнёрами TURAN — следите за сообщениями')
  }

  const openService = (s: ServiceDef) => {
    if (s.k === 'market') go({ name: 'market' })
    else if (s.k === 'experts') go({ name: 'shop' })
    else showToast('Все сервисы откроются на следующих этапах')
  }

  const sellByPrice = () => {
    setSheet(null)
    showToast('Продажа партий откроется на следующих этапах')
  }

  // ---------- вход в тред гасит непрочитанные ----------
  useEffect(() => {
    if (route.name !== 'thread') return
    if (route.tid === 'market') setNotifs((ns) => (ns.some((n) => n.unread) ? ns.map((n) => (n.unread ? { ...n, unread: false } : n)) : ns))
    if (route.tid === 'farm') setFarmUnread(false)
    if (route.tid === 'turan') setTuranUnread(false)
  }, [route])

  // ---------- контекст ----------
  // Инициалы хозяйства для аватара из реального аккаунта (имя орг → иначе имя владельца).
  // Демо-фолбэк «АД» — когда профиль не загружен (аноним / бэкенд недоступен).
  const avatarInitials = deriveInitials(profile?.name || profile?.ownerName)
  const ctxVal: ShellContextValue = {
    tab, go, route,
    openAI, openPrices, aiCtxDefault: tab === 'farm' ? 'farm' : 'home',
    marketDot, msgBadge, avatarDot, avatarInitials,
    farmRegion: profile?.district ?? null,
    offline, offlineToast, toast: showToast,
    membership, isPro, memberAct,
  }

  // ---------- рендер экрана: v5-Route в IonRouterOutlet (S2, spec §3) ----------
  // Каждый рендер — 1:1 ветка прежнего if/else switch; экраны получают те же пропсы
  // (замыкания CabinetApp). batchId приходит из URL-параметра (:id), не из route-state.
  const renderHome = () => (
    <HomeScreen
      membership={membership}
      farm={farm}
      decisions={decisions}
      observe={observe}
      bannerVariant={bannerVariant}
      sticker={sticker}
      loading={homeLoading}
      onBanner={onBanner}
      openService={openService}
      go={go}
      onRefresh={() => Promise.all([pullFarm(), refetchBatches()])}
    />
  )

  const renderMarket = () => (
    <MarketScreen
      membership={membership}
      batches={batches}
      loading={loading}
      error={batchesError}
      onRetry={refetchBatches}
      onNew={() => {
        // Лимит 5 активных партий (совпадает с renderList): «Продать» на табе рынка —
        // основной вход в визард, поэтому guard тоже здесь.
        const activeCount = batches.filter((b) =>
          ['scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched'].includes(b.state)
        ).length
        if (activeCount >= 5) { setSheet({ kind: 'limit' }); return }
        go({ name: 'batchwiz' })
      }}
      onApply={() => memberAct('apply')}
      onPay={() => memberAct('pay')}
      go={go}
      onRefresh={refetchBatches}
      orgId={profile?.orgId ?? null}
    />
  )
  // N-3/N-5/M4/M5: визард публикации и результат — реальные роуты острова (как farmwiz). Свой
  // стек-энтри → нативный push/pop + edge-swipe + exit-анимация; system-back шагает внутрь флоу.
  const renderBatchWiz = () => (
    <IonPage className="agos-flow-page">
      <BatchWizard
        onDone={(batch, variant) => {
          addBatch(batch)
          host.haptics('heavy')   // S2.1: публикация партии — крупное действие
          pubVariantRef.current[batch.id] = variant
          go({ name: 'pub', batchId: batch.id })
        }}
        onExit={() => goBackTo({ name: 'market' })}
        onTuran={() => go({ name: 'turan', back: { name: 'market' } })}
      />
    </IonPage>
  )
  const renderPub = ({ match }: { match: { params: { id: string } } }) => {
    const batch = batches.find((b) => b.id === match.params.id)
    // Партия только что создана addBatch — есть в batches. Фолбэк (deep-link/reload на pub):
    // партии нет локально → уводим на карточку (реальные данные подъедут поллингом).
    if (!batch) return <PlaceholderScreen title="Партия опубликована" sub="Открываю карточку…" />
    return (
      <IonPage className="agos-flow-page">
        <PubResult
          variant={pubVariantRef.current[batch.id] ?? 'D'}
          batch={batch}
          onToBatch={() => go({ name: 'batch', batchId: batch.id })}
          onToList={() => go({ name: 'p1list' })}
        />
      </IonPage>
    )
  }

  const renderList = () => {
    const ACTIVE_COUNT_LIMIT = 5
    const activeCount = batches.filter((b) =>
      ['scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched'].includes(b.state)
    ).length
    return (
      <ListScreen
        batches={batches}
        loading={loading}
        error={batchesError}
        onRetry={refetchBatches}
        onBatch={(id) => go({ name: 'batch', batchId: id, back: { name: 'p1list' } })}
        onNew={() => {
          if (activeCount >= ACTIVE_COUNT_LIMIT) { setSheet({ kind: 'limit' }); return }
          // Визард публикации — свой роут (1b): «+Новая» со Списка навигирует прямо в него;
          // system-back вернёт на Список (нативный pop к источнику). Прежний квирк (тап ничего
          // не делал, S2.1/ARS-157) закрыт роутом.
          go({ name: 'batchwiz' })
        }}
        onBack={() => goBackTo({ name: 'market' })}
      />
    )
  }

  const renderBatch = ({ match }: { match: { params: { id: string } } }) => {
    const currentBatch = batches.find((b) => b.id === match.params.id)
    // P-3 (ARS-219): на deep-link/reload партии ещё грузятся → скелет карточки,
    // а НЕ ложное «Партия не найдена» (F5). «Не найдена» — только когда загрузка завершена.
    if (!currentBatch && loading) {
      return <IonShellFrame noTabs label="Партия"><ScreenSkeleton variant="batch" /></IonShellFrame>
    }
    if (!currentBatch) return <PlaceholderScreen title="Партия не найдена" sub="" />
    return (
      <BatchScreen
        batch={currentBatch}
        account={profile ? { name: profile.name, bin: profile.bin, phone: profile.phone, district: profile.district } : null}
        orgId={profile?.orgId ?? null}
        onBack={() => goBackTo(route.back ?? { name: 'p1list' })}
        backLabel={backLabelFor(route.back)}
        onPatch={(patch, successToast) => patchBatch(currentBatch.id, patch, successToast)}
        onNew={() => {
          // Визард публикации — свой роут (1b): «+Новая» с карточки навигирует прямо в него.
          go({ name: 'batchwiz' })
        }}
        onReview={() => go({ name: 'review', batchId: currentBatch.id, back: { name: 'batch', batchId: currentBatch.id } })}
        onTuran={() => go({ name: 'turan', back: { name: 'batch', batchId: currentBatch.id } })}
        toast={showToast}
      />
    )
  }

  const renderReview = ({ match }: { match: { params: { id: string } } }) => {
    const reviewBatch = batches.find((b) => b.id === match.params.id)
    // P-3 (ARS-219): загрузка ещё идёт → скелет, не ложное «не найдена» (F5).
    if (!reviewBatch && loading) {
      return <IonShellFrame noTabs label="Партия"><ScreenSkeleton variant="batch" /></IonShellFrame>
    }
    if (!reviewBatch) return <PlaceholderScreen title="Партия не найдена" icon="ban" emptyTitle="Партия не найдена" emptySub="Возможно, она была удалена или ещё не создана" />
    return (
      <ReviewScreen
        batch={reviewBatch}
        onBack={() => goBackTo(route.back ?? { name: 'batch', batchId: reviewBatch.id })}
        onPatch={(patch, successToast) => patchBatch(reviewBatch.id, patch, successToast)}
      />
    )
  }

  const renderCabinet = () => (
    <CabinetScreen
      membership={membership}
      profileIncomplete={profileIncomplete}
      newsOn={newsOn}
      onNewsToggle={() => setNewsOn((v) => !v)}
      memberAct={memberAct}
      onBack={() => goBackTo({ name: 'home' })}
      onTuran={() => go({ name: 'turan', back: { name: 'cabinet' } })}
      onLogout={handleLogout}
      profile={profile}
    />
  )

  const renderTuran = () => (
    <TuranScreen
      onBack={() => goBackTo(route.back ?? { name: 'home' })}
      toast={showToast}
    />
  )

  // ---------- ARS-231: Сообщения — треды модулей + AI-консультант ----------
  // Хендлеры тредов = хендлеры ярусов Главной (один объект — две поверхности):
  // decision решён из треда — погашен и на Главной, и в списке тредов.
  const threadH: ThreadH = {
    lower: decH.lower,
    open: decH.open,
    openId: (id) => go({ name: 'batch', batchId: id, back: routeRef.current }),
    dispatch: decH.dispatch,
    review: decH.review,
    farm: decH.farm,
    member: memberAct,
    writeTuran: () => go({ name: 'turan', back: routeRef.current }),
  }
  const threadEnv: ThreadEnv = { batches, notifs, membership, farm, aiLog, farmUnread, turanUnread, newsOn, h: threadH }

  // Мок Консультанта (aiReply по справочным данным TURAN) — до подключения AI Gateway (Dok 5).
  const sendAi = (text: string) => {
    setAiLog((l) => [...l, { who: 'u', t: text }])
    setAiTyping(true)
    setTimeout(() => {
      setAiLog((l) => [...l, { who: 'c', t: aiReply(text) }])
      setAiTyping(false)
    }, 1100)
  }

  const renderMessages = () => (
    <MessagesScreen
      env={threadEnv}
      loading={loading}
      onOpen={(tid) => {
        // Консультант — через openAI (гейт Platform Pro сохраняется)
        if (tid === 'consultant') { openAI(); return }
        go({ name: 'thread', tid, back: { name: 'messages' } })
      }}
    />
  )

  const renderThread = ({ match }: { match: { params: { tid: string } } }) => {
    const raw = match.params.tid
    if (raw === 'consultant') {
      return (
        <ConsultantScreen
          aiLog={aiLog}
          typing={aiTyping}
          offline={offline}
          offlineToast={offlineToast}
          onSend={sendAi}
          onBack={() => goBackTo(route.back ?? { name: 'messages' })}
        />
      )
    }
    const tid: Exclude<ThreadId, 'consultant'> =
      raw === 'market' || raw === 'farm' ? raw : 'turan'
    return (
      <ThreadScreen
        tid={tid}
        env={threadEnv}
        onBack={() => goBackTo(route.back ?? { name: 'messages' })}
      />
    )
  }

  // ARS-212: таб «Ферма» — F0 (FarmScreen) или флоу-страница мастера (зеркально renderMarket).
  // «Продать через TURAN» с Payoff-1 закрывает мастер и открывает TSP-визард на Рынке (гейт
  // членства — существующие правила Рынка; кнопку показываем только продающим статусам).
  const farmCanSell = (['active', 'grace', 'expiring'] as MembershipStatus[]).includes(membership)
  const sellFromFarm = () => {
    // Мастер фермы теперь роут — уход на Рынок (go) сам покидает 'farmwiz', флаг не нужен.
    const activeCount = batches.filter((b) =>
      ['scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched'].includes(b.state)
    ).length
    if (activeCount >= 5) { go({ name: 'market' }); setSheet({ kind: 'limit' }); return }
    go({ name: 'batchwiz' })
  }
  const renderFarm = () => (
    <FarmScreen
      onStart={() => { setFarmWizStart('herd'); go({ name: 'farmwiz' }) }}
      onResume={() => { setFarmWizStart('plan'); go({ name: 'farmwiz' }) }}
    />
  )
  // N-3/N-5/M4/M5 (аудит нативности): мастер фермы — реальный роут острова, а не state-оверлей.
  // Свой стек-энтри → нативный push/pop + edge-swipe + exit-анимация; system-back/edge-swipe
  // возвращает на «Ферму», не выкидывает из флоу. Компонент FarmWizard не тронут; startAt в state.
  const renderFarmWiz = () => (
    <IonPage className="agos-flow-page">
      <FarmWizard
        startAt={farmWizStart}
        onExit={() => goBackTo({ name: 'farm' })}
        onSell={farmCanSell ? sellFromFarm : undefined}
      />
    </IonPage>
  )

  // Пока грузится реальный профиль — брендовый boot (а не голый спиннер/демо-экран).
  // P-2 (ARS-218): единый BootScreen на всём пути в кабинет. См. profileLoading выше.
  if (profileLoading) {
    return <BootScreen label="Загрузка кабинета…" />
  }

  return (
    <ShellCtx.Provider value={ctxVal}>
      <div className="agos-cabinet-stage">
        <div className="phone">
          <IonApp>
            <IonReactRouter>
              <IonBridge onIon={(ion) => { ionRef.current = ion }} onPath={syncFromPath} />
              {/* P-4 (ARS-220): IonTabs владеет ОДНИМ постоянным IonTabBar — он больше не
                  пересобирается при каждом переходе (раньше таб-бар рендерился внутри каждой
                  страницы через IonShellFrame). Роуты в outlet не изменены. */}
              <IonTabs>
                <IonRouterOutlet>
                  {/* N-2: роуты сгруппированы по табам (sibling-префиксы /cabinet/{home,farm,
                      market,messages}/…). Каждый под-экран под URL-префиксом своего таба →
                      Ionic держит независимый стек+скролл на вкладку и подсвечивает таб по
                      совпадению href-префикса. */}
                  {/* --- таб «Главная» --- */}
                  <RouteV5 exact path="/cabinet/home" render={renderHome} />
                  <RouteV5 exact path="/cabinet/home/account" render={renderCabinet} />
                  <RouteV5 exact path="/cabinet/home/turan" render={renderTuran} />
                  <RouteV5 exact path="/cabinet/home/shop" render={() => <PlaceholderScreen title="Маркет" sub="Дистрибуция и специалисты TURAN" icon="bag" emptySub="Дистрибуция и специалисты TURAN появятся здесь" />} />
                  <RouteV5 exact path="/cabinet/home/services" render={() => <PlaceholderScreen title="Сервисы" sub="Специалисты и услуги TURAN" icon="grid" emptySub="Специалисты и услуги TURAN появятся здесь" />} />
                  {/* --- таб «Ферма» --- */}
                  <RouteV5 exact path="/cabinet/farm" render={renderFarm} />
                  <RouteV5 exact path="/cabinet/farm/wizard" render={renderFarmWiz} />
                  {/* --- таб «Рынок» --- */}
                  <RouteV5 exact path="/cabinet/market" render={renderMarket} />
                  <RouteV5 exact path="/cabinet/market/new" render={renderBatchWiz} />
                  <RouteV5 exact path="/cabinet/market/list" render={renderList} />
                  <RouteV5 exact path="/cabinet/market/batch/:id" render={renderBatch} />
                  <RouteV5 exact path="/cabinet/market/review/:id" render={renderReview} />
                  <RouteV5 exact path="/cabinet/market/pub/:id" render={renderPub} />
                  {/* --- таб «Сообщения» --- */}
                  <RouteV5 exact path="/cabinet/messages" render={renderMessages} />
                  <RouteV5 exact path="/cabinet/messages/thread/:tid" render={renderThread} />
                  {/* N-2 backward-compat: старые плоские deep-link/push-пути (до N-2, C10/IMPL_DEBT)
                      → канонический таб-URL. Декларативные Redirect (НЕ морфят persistent pathless-вью
                      → без churn вью-стека, в отличие от условного рендера в fallback). market/new и
                      farm/wizard уже сгруппированы — редирект не нужен. Ретайрится с островом. */}
                  <RedirectV5 exact from="/cabinet" to="/cabinet/home" />
                  <RedirectV5 exact from="/cabinet/account" to="/cabinet/home/account" />
                  <RedirectV5 exact from="/cabinet/turan" to="/cabinet/home/turan" />
                  <RedirectV5 exact from="/cabinet/shop" to="/cabinet/home/shop" />
                  <RedirectV5 exact from="/cabinet/services" to="/cabinet/home/services" />
                  <RedirectV5 exact from="/cabinet/list" to="/cabinet/market/list" />
                  <RedirectV5 exact from="/cabinet/batch/:id" to="/cabinet/market/batch/:id" />
                  <RedirectV5 exact from="/cabinet/review/:id" to="/cabinet/market/review/:id" />
                  <RedirectV5 exact from="/cabinet/pub/:id" to="/cabinet/market/pub/:id" />
                  <RedirectV5 exact from="/cabinet/thread/:tid" to="/cabinet/messages/thread/:tid" />
                  {/* неизвестный под-путь → Главная (стабильный контент — без churn) */}
                  <RouteV5 render={renderHome} />
                </IonRouterOutlet>
                {/* Постоянный таб-бар. N-2: кнопки навигируют через href (нативный таб-свитч
                    Ionic) — свой стек на вкладку восстанавливается, повторный тап по активному
                    табу поппит к корню и скроллит вверх (N-6, из коробки). Подсветка активного
                    таба — авто по совпадению href-префикса с URL (ручной selected убран).
                    hideTabBar скрывает бар на детальных/флоу-экранах (сохранение UX, решение CEO). */}
                <IonTabBar slot="bottom" className={'agos-tabbar' + (hideTabBar ? ' agos-tabbar--hidden' : '')}>
                  <IonTabButton tab="home" href="/cabinet/home">
                    <span className="bn-ic"><PhIcon name="home" size={22} /></span>
                    <span className="bn-t">Главная</span>
                  </IonTabButton>
                  <IonTabButton tab="farm" href="/cabinet/farm">
                    <span className="bn-ic"><PhIcon name="sprout" size={22} /></span>
                    <span className="bn-t">Ферма</span>
                  </IonTabButton>
                  <IonTabButton tab="market" href="/cabinet/market">
                    <span className="bn-ic">
                      <PhIcon name="market" size={22} />
                      {marketDot && <i className="tb-dot" />}
                    </span>
                    <span className="bn-t">Рынок</span>
                  </IonTabButton>
                  <IonTabButton tab="messages" href="/cabinet/messages">
                    <span className="bn-ic">
                      <PhIcon name="chat" size={22} />
                      {msgBadge > 0 && <i className="tb-badge mono">{msgBadge}</i>}
                    </span>
                    <span className="bn-t">Сообщения</span>
                  </IonTabButton>
                </IonTabBar>
              </IonTabs>
            </IonReactRouter>
            {/* Тост и шторки — поверх страниц; IonModal (Sheet.tsx) сам портится в ion-app.
                Шторки смонтированы постоянно (open-флаг) — dismiss-анимация играет и при
                программном закрытии (ревью PR #27). key=epoch у stateful-шторок — каждый
                показ с чистого состояния. S2.1 (ARS-157): PriceSheet теперь тоже IonModal
                (agos-sheet-modal) и монтируется постоянно — все 10 шторок однородны. */}
            <Toast toast={toast} />
            {/* ARS-207: рекуррентная подписка на членство — основная поверхность оплаты. */}
            <SubscribeSheet
              open={sheet?.kind === 'subscribe'}
              orgId={profile?.orgId}
              onClose={() => closeSheet('subscribe')}
              onSubscribed={subscribeDone}
              toast={showToast}
            />
            {/* DEPRECATED (ARS-207): разовый взнос заменён подпиской. Смонтирован, но
                kind 'payvznos' больше не выставляется — код сохранён (HS-2). */}
            <PayVznosSheet
              open={sheet?.kind === 'payvznos'}
              membership={membership}
              onClose={() => closeSheet('payvznos')}
              onDone={payVznosDone}
            />
            <PayProSheet open={sheet?.kind === 'paypro'} onClose={() => closeSheet('paypro')} onDone={payProDone} />
            <ProGateSheet
              open={sheet?.kind === 'progate'}
              onClose={() => closeSheet('progate')}
              onPay={() => setSheet({ kind: 'paypro' })}
            />
            <MembGateSheet
              open={sheet?.kind === 'membgate'}
              membership={membership}
              onClose={() => closeSheet('membgate')}
              onAct={memberAct}
            />
            <PriceSheet
              open={sheet?.kind === 'prices'}
              catKey={sheet?.catKey}
              onClose={() => closeSheet('prices')}
              onSell={sellByPrice}
            />
            <LimitSheet
              open={sheet?.kind === 'limit'}
              onClose={() => closeSheet('limit')}
              onToList={() => { setSheet(null); go({ name: 'p1list' }) }}
            />
          </IonApp>
        </div>
      </div>
    </ShellCtx.Provider>
  )
}

export default CabinetApp
