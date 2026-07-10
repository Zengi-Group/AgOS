// AgOS · Этап 1 · Корень оболочки фермера: состояние, localStorage, навигация,
// бейджи, AI-гейт, действия членства, платёжные шторки. Источник истины — прототип shell/app.jsx.

import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
// S2 (ARS-148, ADR-NATIVE-ROUTER-01 AMEND-1): Ionic-навигация. IonReactRouter живёт
// на изолированном react-router v5 (v5-остров, vite.config.ts agos:ionic-v5-island);
// остальное приложение остаётся на v6. Гейт-спайк пройден 2026-07-03.
import { setupIonicReact, IonApp, IonPage, IonRouterOutlet } from '@ionic/react'
import type { UseIonRouterResult } from '@ionic/react'
import { useIonRouter } from '@ionic/react'
import { IonReactRouter } from '@ionic/react-router'
// @ts-expect-error v5-alias пакет без @types — импорты v5-острова (спайк-проверено).
// RouteV5 — иначе конфликт имён с типом Route из './types'.
import { Route as RouteV5, useLocation } from 'react-router-dom-v5'
import '@ionic/react/css/core.css'
import './cabinet.css'
import './ionic.css'
import './shell-proto.css'
import './market-proto.css'
import { useAuth } from '@/hooks/useAuth'
import { ShellCtx } from './context'
import {
  INITIAL_STATE, STORAGE_KEY, tabOf, deriveMembership,
} from './store'
import { routeToUrl, urlToRoute, routeKey, dirFor } from './nav'
import { supabase } from '@/lib/supabase'
import type {
  MembershipStatus, Route, SheetKind, SheetState, ShellState, ToastState, ShellContextValue, Batch,
} from './types'
import { useBatches } from './hooks/useBatches'
import { Toast } from './components/Toast'
import { PlaceholderScreen } from './screens/PlaceholderScreen'
import { CabinetScreen } from './screens/CabinetScreen'
import { HomeScreen } from './screens/HomeScreen'
import { MarketScreen } from './screens/MarketScreen'
import { ListScreen } from './screens/ListScreen'
import { BatchScreen } from './screens/BatchScreen'
import { ReviewScreen } from './screens/ReviewScreen'
import { TuranScreen } from './screens/TuranScreen'
import { LimitSheet } from './components/sheets/LimitSheet'
import { BatchWizard } from './tsp/wizard/BatchWizard'
import { PubResult } from './tsp/wizard/PubResult'
import type { PubVariant } from './tsp/types/batch'
import { PayVznosSheet } from './components/sheets/PayVznosSheet'
import { PayProSheet } from './components/sheets/PayProSheet'
import { ProGateSheet } from './components/sheets/ProGateSheet'
import { MembGateSheet } from './components/sheets/MembGateSheet'
import { PriceSheet } from './components/sheets/PriceSheet'
import { buildDecisions, buildObserve, type DecH } from './data/membership'
import { FARMER_LEAD_CAT, stickerData } from './data/prices'
import type { BannerCard, ServiceDef } from './data/banners'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
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
  const { signOut } = useAuth()
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
  const { batches, loading: batchesLoading, addBatch, patchBatch: patchBatchAsync, refetch: refetchBatches } = useBatches(profile?.userId)
  const [notifs, setNotifs] = useState(init.notifs)
  const [newsOn, setNewsOn] = useState(init.newsOn)
  const [profileIncomplete] = useState(init.profileIncomplete)
  const [farmUnread, setFarmUnread] = useState(init.farmUnread)
  const [turanUnread, setTuranUnread] = useState(init.turanUnread)
  const [aiLog, setAiLog] = useState(init.aiLog)
  // Ферма: по умолчанию демо-сид (для анонима/без бэкенда). Для вошедшего аккаунта
  // ниже подгружается реальная сводка стада (rpc_get_farm_summary) и перекрывает сид.
  const [farm, setFarm] = useState(init.farm)

  // S3 (ARS-149): реальный сетевой статус вместо заглушки — OfflineBar и
  // офлайн-гейты (memberAct → offlineToast) оживают. Web = navigator.onLine (Dok6 Slice1).
  const online = useOnline()
  const offline = !online
  const loading = batchesLoading

  // Реальная сводка фермы (стадо + задачи) перекрывает демо-сид. Хойстнута из эффекта
  // (S2): переиспользуется pull-to-refresh на Главной (IonRefresher, spec §7).
  const pullFarm = useCallback(
    () => loadFarmState().then((fs) => { if (fs) setFarm(fs) }),
    []
  )

  useEffect(() => {
    let alive = true
    loadAccountProfile('farmer').then(async (p) => {
      if (!alive) return
      if (p) { setProfile(p); setProfileLoading(false); return }
      // Профиль пуст при наличии сессии: возможна «осиротевшая» сессия (пользователь удалён
      // из БД, но JWT остался в браузере). Проверяем на сервере через getUser() — он обращается
      // к Auth и возвращает 401/403, если пользователя больше нет. Тогда выходим и уводим на
      // лендинг, чтобы не залипать в демо-кабинете. Сетевые сбои (без статуса) НЕ разлогиниваем.
      const { data, error } = await supabase.auth.getUser()
      if (!alive) return
      const orphaned = (!!error && (error.status === 401 || error.status === 403)) || (!error && !data?.user)
      if (orphaned) {
        await signOut()
        navigate('/', { replace: true })
        return
      }
      // Сессия валидна (getUser прошёл), но контекста нет — напр. зарегистрирован, ещё нет
      // орг/членства. Показываем реальный ПУСТОЙ стейт, а НЕ демо-сид (ARS-210): членства нет,
      // фермы нет. Иначе фермер без членства видел бы фейковые «Членство активно» + «Отёл, день 34».
      setProfile(null)
      setMembership('none')
      setFarm(emptyFarm())
      setProfileLoading(false)
    })
    // Поллинг 30с — стадо/задачи обновляются без перезагрузки после правок в профиле (D-SYNC-01).
    // loadFarmState: контекст есть, но фермы нет → emptyFarm(); аноним/сбой сети → null (сид не трогаем).
    pullFarm()
    const id = setInterval(pullFarm, 30000)
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
    let derived = deriveMembership(profile.membershipLevel, profile.applicationStatus)
    // Фолбэк: если взнос уже оплачен локально (демо), но БД ещё отдаёт 'approved'
    // (RPC недоступен/не применён), не сбрасываем в запрос оплаты — держим 'active'.
    if (derived === 'approved' && isPaidLocally(profile.userId)) derived = 'active'
    setMembership(derived)
  }, [profile?.userId, profile?.membershipLevel, profile?.applicationStatus])
  const [sheet, setSheet] = useState<SheetState | null>(null)
  const [toast, setToast] = useState<ToastState | null>(null)
  // S2-ревью (PR #27): IonModal-шторки держим смонтированными — программное закрытие
  // анимируется через isOpen=false (условный unmount рвал dismiss-анимацию). Сброс
  // внутреннего состояния stateful-шторок — у них самих по open=true (НЕ через key-remount:
  // размонтирование ion-modal в момент презентации соседнего ломает overlay-стек Ionic).
  // closeSheet гардит по kind: поздний onDidDismiss закрывающейся шторки не должен убить
  // следующую, уже открытую (переход progate→paypro).
  const closeSheet = (kind: SheetKind) => setSheet((cur) => (cur?.kind === kind ? null : cur))

  // ---------- TSP-1: визард «Новая партия» + результат публикации ----------
  const [wizActive, setWizActive] = useState(false)
  const [pubResult, setPubResult] = useState<{ batch: Batch; variant: PubVariant } | null>(null)

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
  const go = (r: Route) => {
    const from = routeRef.current
    setRoute(r)
    if (routeKey(from) === routeKey(r)) return   // тот же экран — обновилось только состояние (back/tid)
    const ion = ionRef.current
    if (!ion) return
    const dir = dirFor(from, r)
    const url = routeToUrl(r)
    if (dir === 'back' && ion.canGoBack()) ion.goBack()
    else if (dir === 'root') ion.push(url, 'root', 'replace')
    else ion.push(url, dir)
  }
  // Явный «назад» (кнопки ←): настоящий pop, когда стек позволяет — иначе возврат на
  // таб-корень анимировался как смена корня (ревью PR #27, SIG-2). Холодный deep-link
  // (стек пуст) → push с back-анимацией; URL→Route-синк выправит состояние при расхождении.
  const goBackTo = (r: Route) => {
    setRoute(r)
    const ion = ionRef.current
    if (!ion) return
    if (ion.canGoBack()) ion.goBack()
    else ion.push(routeToUrl(r), 'back')
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
  const tab = tabOf(route)

  const handleLogout = async () => {
    await signOut()
    navigate('/login', { replace: true })
  }

  // ---------- бейджи ----------
  const marketDot = batches.some((b) => b.state === 'decision')
  const unread = notifs.filter((n) => n.unread).length
  const msgBadge = unread + (farmUnread ? 1 : 0) + (turanUnread ? 1 : 0)
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
    else setSheet({ kind: 'payvznos' })
  }
  // Оплата взноса — симуляция на пилоте (реальной платёжной системы пока нет): выбор способа →
  // «Оплатить» → членство сразу активно, Рынок (TSP) открывается.
  // Персистентность: (1) серверный сигнал rpc_pay_membership_dues поднимает memberships.level
  // registered→observer — переживает перезагрузку И виден админу; (2) локальный флаг PAID_KEY —
  // фолбэк, чтобы оплата не запрашивалась повторно даже если RPC недоступен (миграция не применена).
  const payVznosDone = async () => {
    setSheet(null)
    setTuranUnread(false)
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
    setMembership('active')
    host.haptics('medium')   // S2.1: оплата взноса — ключевое действие
    showToast('Взнос оплачен · членство активно')
  }
  const payProDone = () => {
    setIsPro(true); setSheet(null)
    host.haptics('medium')   // S2.1: подключение Pro — ключевое действие
    showToast('Platform Pro подключён · Консультант открыт')
  }

  // ---------- Главная: ярусы, баннер, стикер, сервисы ----------
  const bannerVariant = (membership === 'none' || membership === 'terminated') ? 'join' : 'season'
  const sticker = stickerData(FARMER_LEAD_CAT, 'auto')

  const patchBatch = (id: string, patch: Partial<Batch>) => {
    patchBatchAsync(id, patch).catch((e: unknown) => {
      const msg = e instanceof Error ? e.message : 'Ошибка'
      showToast(msg)
    })
  }

  // обработчики ярусов и тредов (один объект — две поверхности)
  const decH: DecH = {
    lower: (b) => {
      patchBatch(b.id, { state: 'offering', deadlineLabel: 'завтра, 14:30' })
      showToast('Предложение отправлено покупателям по новой цене')
    },
    open: () => go({ name: 'market' }),
    dispatch: (b) => {
      patchBatch(b.id, { state: 'dispatched' })
      host.haptics('medium')   // S2.1: отгрузка — ключевое действие
      showToast('Покупатель получил уведомление об отгрузке')
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
      loading={loading}
      onBanner={onBanner}
      openService={openService}
      go={go}
      onRefresh={() => Promise.all([pullFarm(), refetchBatches()])}
    />
  )

  const renderMarket = () => {
    if (wizActive) {
      return (
        <IonPage className="agos-flow-page">
          <BatchWizard
            onDone={(batch, variant) => {
              addBatch(batch)
              setWizActive(false)
              host.haptics('heavy')   // S2.1: публикация партии — крупное действие
              setPubResult({ batch, variant })
            }}
            onExit={() => setWizActive(false)}
            onTuran={() => { setWizActive(false); go({ name: 'thread', tid: 'turan', back: { name: 'market' } }) }}
          />
        </IonPage>
      )
    }
    if (pubResult) {
      return (
        <IonPage className="agos-flow-page">
          <PubResult
            variant={pubResult.variant}
            batch={pubResult.batch}
            onToBatch={() => { const id = pubResult.batch.id; setPubResult(null); go({ name: 'batch', batchId: id }) }}
            onToList={() => { setPubResult(null); go({ name: 'p1list' }) }}
          />
        </IonPage>
      )
    }
    return (
      <MarketScreen
        membership={membership}
        batches={batches}
        loading={loading}
        onNew={() => {
          // Лимит 5 активных партий (совпадает с renderList): «Продать» на табе рынка —
          // теперь основной вход в визард, поэтому guard тоже здесь.
          const activeCount = batches.filter((b) =>
            ['scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched'].includes(b.state)
          ).length
          if (activeCount >= 5) { setSheet({ kind: 'limit' }); return }
          setWizActive(true)
        }}
        onApply={() => memberAct('apply')}
        onPay={() => memberAct('pay')}
        go={go}
        onRefresh={refetchBatches}
      />
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
        onBatch={(id) => go({ name: 'batch', batchId: id, back: { name: 'p1list' } })}
        onNew={() => {
          if (activeCount >= ACTIVE_COUNT_LIMIT) { setSheet({ kind: 'limit' }); return }
          // S2.1 (ARS-157): визард рендерится только на market-роуте — уводим туда,
          // иначе тап «+Новая» со Списка визуально ничего не делал (решение CEO: починить).
          setWizActive(true); go({ name: 'market' })
        }}
        onBack={() => goBackTo({ name: 'market' })}
      />
    )
  }

  const renderBatch = ({ match }: { match: { params: { id: string } } }) => {
    const currentBatch = batches.find((b) => b.id === match.params.id)
    if (!currentBatch) return <PlaceholderScreen title="Партия не найдена" sub="" />
    return (
      <BatchScreen
        batch={currentBatch}
        account={profile ? { name: profile.name, bin: profile.bin, phone: profile.phone, district: profile.district } : null}
        onBack={() => goBackTo(route.back ?? { name: 'p1list' })}
        backLabel={backLabelFor(route.back)}
        onPatch={(patch) => patchBatch(currentBatch.id, patch)}
        onNew={() => {
          // S2.1 (ARS-157): визард только на market-роуте — уводим туда (решение CEO: починить).
          setWizActive(true); go({ name: 'market' })
        }}
        onReview={() => go({ name: 'review', batchId: currentBatch.id, back: { name: 'batch', batchId: currentBatch.id } })}
        onTuran={() => go({ name: 'thread', tid: 'turan', back: { name: 'batch', batchId: currentBatch.id } })}
        toast={showToast}
      />
    )
  }

  const renderReview = ({ match }: { match: { params: { id: string } } }) => {
    const reviewBatch = batches.find((b) => b.id === match.params.id)
    if (!reviewBatch) return <PlaceholderScreen title="Партия не найдена" icon="ban" emptyTitle="Партия не найдена" emptySub="Возможно, она была удалена или ещё не создана" />
    return (
      <ReviewScreen
        batch={reviewBatch}
        onBack={() => goBackTo(route.back ?? { name: 'batch', batchId: reviewBatch.id })}
        onPatch={(patch) => patchBatch(reviewBatch.id, patch)}
        toast={showToast}
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
      onTuran={() => go({ name: 'thread', tid: 'turan', back: { name: 'cabinet' } })}
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

  // Пока грузится реальный профиль — лоадер (а не демо-экран). См. profileLoading выше.
  if (profileLoading) {
    return (
      <div className="agos-cabinet-stage" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Loader2 className="animate-spin" style={{ width: 28, height: 28, color: '#b0a18f' }} />
      </div>
    )
  }

  return (
    <ShellCtx.Provider value={ctxVal}>
      <div className="agos-cabinet-stage">
        <div className="phone">
          <IonApp>
            <IonReactRouter>
              <IonBridge onIon={(ion) => { ionRef.current = ion }} onPath={syncFromPath} />
              <IonRouterOutlet>
                <RouteV5 exact path="/cabinet" render={renderHome} />
                <RouteV5 exact path="/cabinet/market" render={renderMarket} />
                <RouteV5 exact path="/cabinet/list" render={renderList} />
                <RouteV5 exact path="/cabinet/batch/:id" render={renderBatch} />
                <RouteV5 exact path="/cabinet/review/:id" render={renderReview} />
                <RouteV5 exact path="/cabinet/account" render={renderCabinet} />
                <RouteV5 exact path="/cabinet/turan" render={renderTuran} />
                <RouteV5 exact path="/cabinet/farm" render={() => <PlaceholderScreen tab title="Ферма" sub="Стадо, задачи, события" icon="sprout" emptySub="Стадо, задачи и события хозяйства появятся здесь" />} />
                <RouteV5 exact path="/cabinet/shop" render={() => <PlaceholderScreen title="Маркет" sub="Дистрибуция и специалисты TURAN" icon="bag" emptySub="Дистрибуция и специалисты TURAN появятся здесь" />} />
                <RouteV5 exact path="/cabinet/services" render={() => <PlaceholderScreen title="Сервисы" sub="Специалисты и услуги TURAN" icon="grid" emptySub="Специалисты и услуги TURAN появятся здесь" />} />
                <RouteV5 exact path="/cabinet/messages" render={() => <PlaceholderScreen tab title="Сообщения" sub="Треды Рынка, Фермы и TURAN" icon="chat" emptySub="Треды Рынка, Фермы и TURAN появятся здесь" />} />
                <RouteV5 exact path="/cabinet/thread/:tid" render={() => <PlaceholderScreen title="Сообщения" sub="Треды Рынка, Фермы и TURAN" icon="chat" emptySub="Треды Рынка, Фермы и TURAN появятся здесь" />} />
                {/* неизвестный под-путь → Главная (первое совпадение выигрывает) */}
                <RouteV5 render={renderHome} />
              </IonRouterOutlet>
            </IonReactRouter>
            {/* Тост и шторки — поверх страниц; IonModal (Sheet.tsx) сам портится в ion-app.
                Шторки смонтированы постоянно (open-флаг) — dismiss-анимация играет и при
                программном закрытии (ревью PR #27). key=epoch у stateful-шторок — каждый
                показ с чистого состояния. S2.1 (ARS-157): PriceSheet теперь тоже IonModal
                (agos-sheet-modal) и монтируется постоянно — все 10 шторок однородны. */}
            <Toast toast={toast} />
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
