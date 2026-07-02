// AgOS · Этап 1 · Корень оболочки фермера: состояние, localStorage, навигация,
// бейджи, AI-гейт, действия членства, платёжные шторки. Источник истины — прототип shell/app.jsx.

import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import './cabinet.css'
import { useAuth } from '@/hooks/useAuth'
import { ShellCtx } from './context'
import {
  INITIAL_STATE, STORAGE_KEY, tabOf, deriveMembership,
} from './store'
import { supabase } from '@/lib/supabase'
import type {
  MembershipStatus, Route, SheetState, ShellState, ToastState, ShellContextValue, Batch,
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
import { MembDocsSheet } from './components/sheets/MembDocsSheet'
import { PriceSheet } from './components/sheets/PriceSheet'
import { buildDecisions, buildObserve, type DecH } from './data/membership'
import { FARMER_LEAD_CAT, stickerData } from './data/prices'
import type { BannerCard, ServiceDef } from './data/banners'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
import { loadFarmState } from './data/farm-load'

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
  !!userId && localStorage.getItem(PAID_KEY(userId)) === '1'

function loadState(): ShellState {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (raw) {
      const saved = JSON.parse(raw) as Partial<ShellState>
      return { ...INITIAL_STATE, ...saved, route: saved.route?.name ? saved.route : { name: 'home' } }
    }
  } catch {
    /* noop */
  }
  return INITIAL_STATE
}

export function CabinetApp() {
  const navigate = useNavigate()
  const { signOut } = useAuth()
  const init = loadState()
  const [membership, setMembership] = useState<MembershipStatus>(init.membership)
  const [isPro, setIsPro] = useState(init.isPro)
  const [route, setRoute] = useState<Route>(init.route)
  // Профиль реального аккаунта (если вошёл). null = демо-режим (аноним / нет бэкенда).
  const [profile, setProfile] = useState<AccountProfile | null>(null)
  // Пока профиль грузится — показываем лоадер вместо демо-экрана. /cabinet всегда за
  // RequireAuth (сессия гарантирована), поэтому демо-фолбэк не должен даже мелькать.
  const [profileLoading, setProfileLoading] = useState(true)
  // Партии скоупятся по аккаунту (userId): backend фильтрует по org (fn_my_org_ids), а
  // localStorage-кеш — по ключу с userId, поэтому партии одного владельца не видны другому.
  const { batches, loading: batchesLoading, addBatch, patchBatch: patchBatchAsync } = useBatches(profile?.userId)
  const [notifs, setNotifs] = useState(init.notifs)
  const [newsOn, setNewsOn] = useState(init.newsOn)
  const [profileIncomplete] = useState(init.profileIncomplete)
  const [farmUnread, setFarmUnread] = useState(init.farmUnread)
  const [turanUnread, setTuranUnread] = useState(init.turanUnread)
  const [aiLog, setAiLog] = useState(init.aiLog)
  // Ферма: по умолчанию демо-сид (для анонима/без бэкенда). Для вошедшего аккаунта
  // ниже подгружается реальная сводка стада (rpc_get_farm_summary) и перекрывает сид.
  const [farm, setFarm] = useState(init.farm)

  const [offline] = useState(false)
  const loading = batchesLoading

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
      setProfile(null)
      setProfileLoading(false)
    })
    // Реальная сводка фермы (стадо + задачи) перекрывает демо-сид. null = аноним/нет
    // бэкенда/нет фермы → оставляем seedFarm() (демо). Лёгкий поллинг 30с — стадо/задачи
    // обновляются без перезагрузки после правок в профиле фермы (D-SYNC-01).
    const pullFarm = () => loadFarmState().then((fs) => { if (alive && fs) setFarm(fs) })
    pullFarm()
    const id = setInterval(pullFarm, 30000)
    return () => { alive = false; clearInterval(id) }
  }, [])

  // Изоляция по аккаунту: при входе под другим userId не наследуем кабинет предыдущего.
  useEffect(() => {
    if (!profile?.userId) return
    const ACC_KEY = 'agos.cabinet.account'
    const last = localStorage.getItem(ACC_KEY)
    if (last && last !== profile.userId) {
      localStorage.removeItem(STORAGE_KEY)
      // Партии предыдущего аккаунта: чистим и его скоуп-кеш, и легаси-ключ без скоупа
      // (в нём могли остаться партии старого владельца до введения скоупинга по userId).
      localStorage.removeItem(`agos.cabinet.batches.v1.${last}`)
      localStorage.removeItem('agos.cabinet.batches.v1')
      setMembership(INITIAL_STATE.membership)
      setIsPro(INITIAL_STATE.isPro)
      setRoute(INITIAL_STATE.route)
      setNotifs(INITIAL_STATE.notifs)
      setNewsOn(INITIAL_STATE.newsOn)
      setFarmUnread(INITIAL_STATE.farmUnread)
      setTuranUnread(INITIAL_STATE.turanUnread)
      setAiLog(INITIAL_STATE.aiLog)
    }
    localStorage.setItem(ACC_KEY, profile.userId)
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
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
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
  const go = (r: Route) => setRoute(r)
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
    setRoute((r) => (r.name === 'thread' && r.tid === 'consultant' ? r : { name: 'thread', tid: 'consultant', back: r }))
  }
  const openPrices = (catKey: string) => setSheet({ kind: 'prices', catKey })

  // ---------- членство ----------
  // Флоу: 'apply' → шторка документов (загрузка + подача заявки) → 'pending' (проверка админом)
  // → 'approved' (одобрено, взнос не оплачен) → 'pay' → оплата взноса → 'active'.
  const memberAct = (act: string) => {
    if (offline) { offlineToast(); return }
    if (act === 'apply') setSheet({ kind: 'membdocs' })
    else setSheet({ kind: 'payvznos' })
  }
  // Заявка с документами отправлена на проверку админу → ждём решения.
  const onMembDocsSubmitted = () => {
    setSheet(null)
    setMembership('pending')
    setTuranUnread(false)
    showToast('Заявка отправлена на проверку')
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
    if (!serverOk && profile?.userId) localStorage.setItem(PAID_KEY(profile.userId), '1')
    setMembership('active')
    showToast('Взнос оплачен · членство активно')
  }
  const payProDone = () => {
    setIsPro(true); setSheet(null)
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

  // ---------- рендер экрана ----------
  let screen
  if (route.name === 'cabinet') {
    screen = (
      <CabinetScreen
        membership={membership}
        profileIncomplete={profileIncomplete}
        newsOn={newsOn}
        onNewsToggle={() => setNewsOn((v) => !v)}
        memberAct={memberAct}
        onBack={() => go({ name: 'home' })}
        onTuran={() => go({ name: 'thread', tid: 'turan', back: { name: 'cabinet' } })}
        onLogout={handleLogout}
        profile={profile}
      />
    )
  } else if (route.name === 'farm') {
    screen = <PlaceholderScreen title="Ферма" sub="Стадо, задачи, события" />
  } else if (route.name === 'market') {
    if (wizActive) {
      screen = (
        <BatchWizard
          onDone={(batch, variant) => {
            addBatch(batch)
            setWizActive(false)
            setPubResult({ batch, variant })
          }}
          onExit={() => setWizActive(false)}
          onTuran={() => { setWizActive(false); go({ name: 'thread', tid: 'turan', back: { name: 'market' } }) }}
        />
      )
    } else if (pubResult) {
      screen = (
        <PubResult
          variant={pubResult.variant}
          batch={pubResult.batch}
          onToBatch={() => { const id = pubResult.batch.id; setPubResult(null); go({ name: 'batch', batchId: id }) }}
          onToList={() => { setPubResult(null); go({ name: 'p1list' }) }}
        />
      )
    } else {
      screen = (
        <MarketScreen
          membership={membership}
          batches={batches}
          loading={loading}
          onNew={() => setWizActive(true)}
          onApply={() => memberAct('apply')}
          onPay={() => memberAct('pay')}
          go={go}
        />
      )
    }
  } else if (route.name === 'p1list') {
    const ACTIVE_COUNT_LIMIT = 5
    const activeCount = batches.filter((b) =>
      ['scheduled', 'published', 'offering', 'decision', 'matched', 'confirmed', 'dispatched'].includes(b.state)
    ).length
    screen = (
      <ListScreen
        batches={batches}
        onBatch={(id) => go({ name: 'batch', batchId: id, back: { name: 'p1list' } })}
        onNew={() => {
          if (activeCount >= ACTIVE_COUNT_LIMIT) { setSheet({ kind: 'limit' }); return }
          setWizActive(true)
        }}
        onBack={() => go({ name: 'market' })}
      />
    )
  } else if (route.name === 'batch') {
    const currentBatch = batches.find((b) => b.id === route.batchId)
    if (!currentBatch) {
      screen = <PlaceholderScreen title="Партия не найдена" sub="" />
    } else {
      screen = (
        <BatchScreen
          batch={currentBatch}
          account={profile ? { name: profile.name, bin: profile.bin, phone: profile.phone, district: profile.district } : null}
          onBack={() => go(route.back ?? { name: 'p1list' })}
          onPatch={(patch) => patchBatch(currentBatch.id, patch)}
          onNew={() => setWizActive(true)}
          onReview={() => go({ name: 'review', batchId: currentBatch.id, back: { name: 'batch', batchId: currentBatch.id } })}
          onTuran={() => go({ name: 'thread', tid: 'turan', back: { name: 'batch', batchId: currentBatch.id } })}
          toast={showToast}
        />
      )
    }
  } else if (route.name === 'review') {
    const reviewBatch = batches.find((b) => b.id === route.batchId)
    if (!reviewBatch) {
      screen = <PlaceholderScreen title="Партия не найдена" sub="" />
    } else {
      screen = (
        <ReviewScreen
          batch={reviewBatch}
          onBack={() => go(route.back ?? { name: 'batch', batchId: reviewBatch.id })}
          onPatch={(patch) => patchBatch(reviewBatch.id, patch)}
          toast={showToast}
        />
      )
    }
  } else if (route.name === 'shop') {
    screen = <PlaceholderScreen title="Маркет" sub="Дистрибуция и специалисты TURAN" />
  } else if (route.name === 'thread' && route.tid === 'turan') {
    screen = (
      <TuranScreen
        onBack={() => go(route.back ?? { name: 'home' })}
        toast={showToast}
      />
    )
  } else if (route.name === 'messages' || route.name === 'thread') {
    screen = <PlaceholderScreen title="Сообщения" sub="Треды Рынка, Фермы и TURAN" />
  } else {
    screen = (
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
      />
    )
  }

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
        {screen}
        <Toast toast={toast} />
        {sheet?.kind === 'payvznos' && (
          <PayVznosSheet membership={membership} onClose={() => setSheet(null)} onDone={payVznosDone} />
        )}
        {sheet?.kind === 'paypro' && (
          <PayProSheet onClose={() => setSheet(null)} onDone={payProDone} />
        )}
        {sheet?.kind === 'progate' && (
          <ProGateSheet onClose={() => setSheet(null)} onPay={() => setSheet({ kind: 'paypro' })} />
        )}
        {sheet?.kind === 'membgate' && (
          <MembGateSheet membership={membership} onClose={() => setSheet(null)} onAct={memberAct} />
        )}
        {sheet?.kind === 'membdocs' && (
          <MembDocsSheet orgId={profile?.orgId ?? null} onClose={() => setSheet(null)} onSubmitted={onMembDocsSubmitted} />
        )}
        {sheet?.kind === 'prices' && (
          <PriceSheet catKey={sheet.catKey} onClose={() => setSheet(null)} onSell={sellByPrice} />
        )}
        {sheet?.kind === 'limit' && (
          <LimitSheet
            open
            onClose={() => setSheet(null)}
            onToList={() => { setSheet(null); go({ name: 'p1list' }) }}
          />
        )}
      </div>
    </ShellCtx.Provider>
  )
}

export default CabinetApp
