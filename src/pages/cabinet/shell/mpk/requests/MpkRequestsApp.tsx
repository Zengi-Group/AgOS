// AgOS · Slice11 (ARS-718) · Раздел «Мои заявки» десктопной консоли МПК.
//
// FR-001: раздел монтируется в СУЩЕСТВУЮЩУЮ консоль — тот же scoped-контейнер темы
// (`.agos-mpk-console` + `profile-console.css`), тот же сайдбар (`ProfileSidebar`), та же
// ширина контента. Новые здесь только маршруты `/mpk/requests` и `/mpk/requests/:poolId`;
// ни один живой URL не меняется и не переименовывается (`P7`).
//
// FR-014: мобильный шелл закупок (`MpkApp` и его экраны/модалки/шторки) не тронут ни
// строкой. Поэтому чтение переиспользуется из общего слоя (`data/pools-load.ts`), а ходы
// зовут те же RPC через `data/pool-actions.ts`.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
import { PhIcon } from '../../components/icons/PhIcon'
import { closeDuePools, loadPoolMatches, readMyPools } from '../data/pools-load'
import { acceptPartial, confirmDeliveryRow, returnBatches } from '../data/pool-actions'
import { MPK_OFFERS_URL, MPK_REQUESTS_URL, mpkRequestPoolIdFromUrl, mpkRequestUrl } from '../nav'
import type { Pool, SupplierRow } from '../types'
import { ProfileSidebar } from '../profile/ProfileSidebar'
import { CreateRequestModal } from './CreateRequestModal'
import { RequestMonitor, type MonitorView } from './RequestMonitor'
import { RequestsList } from './RequestsList'
import { statusLabel, tabCounts, tabFromParam } from './requests-model'
import '../profile/profile-console.css'
import './requests-console.css'

// §1.4 / FR-013: полная консоль поддерживается при ≥1024px — та же граница, что у
// консоли профиля (Slice 10 `FR-012`), один порог на поверхность.
const WIDE_QUERY = '(min-width: 1024px)'

export function MpkRequestsApp() {
  const navigate = useNavigate()
  const location = useLocation()

  // URL — источник истины экрана (FR-007): заявка в пути, вкладка списка и вкладка
  // монитора живут в адресе, поэтому reload и browser-back восстанавливают то же самое.
  const poolId = mpkRequestPoolIdFromUrl(location.pathname)
  const params = new URLSearchParams(location.search)
  const tab = tabFromParam(params.get('tab'))
  const view: MonitorView = params.get('view') === 'suppliers' ? 'suppliers' : 'overview'

  const [profile, setProfile] = useState<AccountProfile | null>(null)
  const [theme, setTheme] = useState<'dark' | 'light'>('dark')
  const [soonHint, setSoonHint] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'failed'>('idle')

  const [pools, setPools] = useState<Pool[]>([])
  const [poolsRead, setPoolsRead] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [poolsToken, setPoolsToken] = useState(0)

  const [matches, setMatches] = useState<SupplierRow[] | null>(null)
  const [matchesStatus, setMatchesStatus] = useState<'loading' | 'ready' | 'failed'>('loading')
  const [matchesToken, setMatchesToken] = useState(0)

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
      // Профиль нужен только для подписи шапки и заведения заявки: его отказ не должен
      // уносить экран — список читается своим путём и своё состояние показывает сам.
      .catch((error) => console.error('MpkRequestsApp: loadAccountProfile failed:', error))
    return () => { alive = false }
  }, [])

  // FR-023: ОТКРЫТИЕ списка запускает то же ленивое подметание просроченных заявок, что и
  // мобильный шелл — планировщика нет, и десктоп такой же вход в кабинет. Отказ подметания
  // оператору не всплывает (M-018): список после него читается в любом случае.
  //
  // Подметание живёт в СВОЁМ эффекте и не зависит от `poolsToken`. Иначе мутирующая RPC
  // уходила бы в базу после каждого хода и каждого «Повторить» — этого не требует ни один
  // id, а `rpc_self_close_due_pools` трогает чужие заявки, не только открытую.
  //
  // На узком экране подметание НЕ зовётся: мост обязан ничего не мутировать (FR-013).
  const [sweepDone, setSweepDone] = useState(false)
  useEffect(() => {
    if (!wide || sweepDone) return
    let alive = true
    // `.finally`: отказ подметания не должен оставить список непрочитанным — оператор
    // увидит прежнее состояние, но увидит (M-018).
    void closeDuePools().finally(() => { if (alive) setSweepDone(true) })
    return () => { alive = false }
  }, [wide, sweepDone])

  useEffect(() => {
    // Первое чтение ждёт подметания: иначе список успел бы мигнуть заявкой в «Требуют
    // решения», которую подметание в эту же секунду закрывает (M-018).
    if (wide && !sweepDone) return
    let alive = true
    void readMyPools().then((r) => {
      if (!alive) return
      if (r.kind === 'ok') { setPools(r.pools); setPoolsRead('ready'); return }
      // `no_session` здесь означает то же, что `failed`: списка у нас нет. Демо-заявки
      // оператору не показываются ни в одном исходе чтения (FR-012) — в этом разделе их
      // просто нет, а «пусто» утверждается только по прочитанному ответу.
      setPoolsRead('failed')
    })
    return () => { alive = false }
  }, [poolsToken, wide, sweepDone])

  const refetchPools = useCallback(() => { setPoolsToken((n) => n + 1) }, [])

  // Строки поставщиков читаются только когда открыта заявка — у списка своего чтения
  // матчей нет (FR-015: тоннаж и число партий на экране списка не показываются).
  useEffect(() => {
    if (!poolId) return
    let alive = true
    setMatchesStatus('loading')
    void loadPoolMatches(poolId).then((rows) => {
      if (!alive) return
      if (rows === null) { setMatchesStatus('failed'); return }
      setMatches(rows)
      setMatchesStatus('ready')
    })
    return () => { alive = false }
  }, [poolId, matchesToken])

  const counts = useMemo(() => tabCounts(pools), [pools])
  const openedPool = poolId ? pools.find((p) => p.id === poolId) ?? null : null

  const goList = useCallback((nextTab = tab) => {
    navigate(nextTab === 'all' ? MPK_REQUESTS_URL : `${MPK_REQUESTS_URL}?tab=${nextTab}`)
  }, [navigate, tab])

  const openPool = useCallback((id: string) => {
    // Вкладка списка остаётся в адресе заявки: «назад» из монитора обязан вернуть на ту
    // же вкладку, с которой ушли (M-009).
    navigate(`${mpkRequestUrl(id)}${tab === 'all' ? '' : `?tab=${tab}`}`)
  }, [navigate, tab])

  const setView = useCallback((v: MonitorView) => {
    if (!poolId) return
    const next = new URLSearchParams(location.search)
    if (v === 'overview') next.delete('view'); else next.set('view', v)
    const q = next.toString()
    navigate(`${mpkRequestUrl(poolId)}${q ? `?${q}` : ''}`, { replace: true })
  }, [navigate, poolId, location.search])

  const backToProfile = useCallback(() => { navigate('/mpk/profile/overview') }, [navigate])
  const backToMpk = useCallback(() => { navigate('/mpk') }, [navigate])

  // FR-013 / M-013 · узкий экран: тот же адрес, вместо таблицы — мост. Ничего не мутирует
  // (подметание выше гейтнуто по `wide`) и НЕ переписывает URL: уход на другой адрес терял
  // бы deep-link заявки и спорил бы с FR-007 (`D-MPK-NARROW-06`, Slice 10 `FR-012`).
  if (!wide) {
    const link = location.pathname + location.search
    // FR-013: мост называет ТЕКУЩЕЕ СОСТОЯНИЕ заявки, а не только прогресс набора —
    // «Нужно ваше решение» и «Недобрала» это разные вещи, и с телефона оператор приходит
    // сюда именно за ними.
    const state = openedPool
      ? `${openedPool.title} · ${statusLabel(openedPool).label} · ${openedPool.filledHeads} из ${openedPool.totalHeads} гол`
      : poolsRead === 'ready'
        ? `Заявок в кабинете: ${pools.length}`
        : poolsRead === 'failed'
          ? 'Список заявок не прочитан'
          : 'Читаем список заявок…'
    return (
      <div className="agos-mpk-console narrow" data-theme={theme === 'light' ? 'light' : undefined}>
        <div className="mpkc-narrow">
          <div className="mpkc-narrow-title">Мои заявки</div>
          <div className="mpkc-narrow-note">{state}</div>
          <div className="mpkc-narrow-note">
            Полный вид раздела открывается на экране шириной от 1024 пикселей. Ссылка
            сохранена — откройте её на компьютере. Здесь, с телефона, заявки ведутся в
            мобильном кабинете закупок.
          </div>
          <div className="mpkc-narrow-link">{link}</div>
          {/* Копирование может быть недоступно (незащищённый контекст, отказ прав) —
              тогда кнопка обязана сказать об этом, а не молча ничего не сделать: ссылка
              и так видна строкой выше, и её можно выделить руками. */}
          <button
            type="button"
            className="mpkc-stub-act"
            onClick={() => {
              const full = window.location.origin + link
              const done = navigator.clipboard?.writeText(full)
              if (!done) { setCopyState('failed'); return }
              done.then(() => setCopyState('copied')).catch(() => setCopyState('failed'))
            }}
          >
            {copyState === 'copied' ? 'Ссылка скопирована'
              : copyState === 'failed' ? 'Скопируйте ссылку вручную'
              : 'Скопировать ссылку'}
          </button>
          <button type="button" className="mpkc-stub-act" onClick={() => navigate('/mpk/tsp')}>
            Открыть закупки в мобильном кабинете
          </button>
        </div>
      </div>
    )
  }

  const body = () => {
    if (poolId) {
      // Пока список не прочитан, «заявка не найдена» утверждать нельзя — это разные
      // исходы (M-003 против M-010).
      if (poolsRead === 'loading') {
        return (
          <div className="mpkc-body"><div className="mpkc-body-inner">
            <div className="mpkc-skel" aria-busy="true" aria-label="Загрузка заявки">
              <div className="mpkc-skel-row" /><div className="mpkc-skel-row" />
            </div>
          </div></div>
        )
      }
      if (poolsRead === 'failed') {
        return (
          <div className="mpkc-body"><div className="mpkc-body-inner">
            <div className="mpkc-stub">
              <PhIcon name="wifiSlash" size={40} />
              <div className="mpkc-stub-title">Заявка не загрузилась</div>
              <div className="mpkc-stub-note">Это сбой чтения, а не отсутствие заявки.</div>
              <button type="button" className="mpkc-stub-act" onClick={refetchPools}>Повторить</button>
            </div>
          </div></div>
        )
      }
      if (!openedPool) {
        // M-010 · чужой или несуществующий id: `rpc_get_my_pools` отдаёт только свои
        // заявки, поэтому «не найдена» здесь ничего не сообщает о чужих — существование
        // заявки другого МПК экран не подтверждает и не опровергает.
        return (
          <div className="mpkc-body"><div className="mpkc-body-inner">
            <div className="mpkc-stub">
              <PhIcon name="fileText" size={40} />
              <div className="mpkc-stub-title">Заявка не найдена</div>
              <div className="mpkc-stub-note">Такой заявки нет среди заявок вашей организации.</div>
              <button type="button" className="mpkc-stub-act" onClick={() => goList()}>К списку заявок</button>
            </div>
          </div></div>
        )
      }
      return (
        <RequestMonitor
          pool={openedPool}
          suppliers={matches}
          matchesStatus={matchesStatus}
          view={view}
          onView={setView}
          onBack={() => goList()}
          onRetryMatches={() => setMatchesToken((n) => n + 1)}
          // Каждый ход перечитывает и заявку, и строки: состояние показывается ИЗ БАЗЫ,
          // а не угадывается локально (FR-011). То же — при ОТКАЗЕ хода (`onRefresh`).
          onRefresh={() => { refetchPools(); setMatchesToken((n) => n + 1) }}
          onAcceptPartial={(id) => acceptPartial(id).then(() => {
            refetchPools(); setMatchesToken((n) => n + 1)
          })}
          onReturnBatches={(id) => returnBatches(id).then(() => {
            refetchPools(); setMatchesToken((n) => n + 1)
          })}
          // ARS-684 FR-002: адрес приёмки берётся по маршруту строки — «партия целиком»
          // адресуется `batchId`, кусок — id строки (`matchId`). Сегодня у batch-строки
          // `matchId === batchId` (read-model кладёт `'matchId', b.id`), но правило пишется
          // по маршруту, а не по совпадению: канонический дом этого выбора —
          // `modals/PoolMonitorModal.tsx`, и десктоп обязан выбирать так же.
          onConfirmDelivery={(row) => {
            const id = row.source === 'batch' ? (row.batchId ?? row.id) : row.id
            return confirmDeliveryRow(id, row.source).then(() => {
              refetchPools(); setMatchesToken((n) => n + 1)
            })
          }}
        />
      )
    }
    return (
      <RequestsList
        status={poolsRead}
        pools={pools}
        counts={counts}
        tab={tab}
        onTab={(next) => goList(next)}
        onOpen={openPool}
        onCreate={() => setCreating(true)}
        // Заводить заявку не на что, пока не прочитана организация: модалка без `orgId`
        // не открывается, и кнопка не должна делать вид, что открывает (иначе клик молча
        // не делает ничего — исход, не отличимый от сломанного экрана).
        canCreate={!!profile?.orgId}
        onRetry={refetchPools}
      />
    )
  }

  return (
    <div className="agos-mpk-console" data-theme={theme === 'light' ? 'light' : undefined}>
      <ProfileSidebar
        orgName={profile?.name ?? 'Предприятие'}
        farmName="Turan Standard Pool · закупки"
        userName={profile?.ownerName ?? 'Сотрудник'}
        monogram="МПК"
        theme={theme}
        soonHint={soonHint}
        activeId="requests"
        onSelect={(item) => {
          if (item.id === 'requests') { setSoonHint(null); goList('all'); return }
          if (item.id === 'profile') { setSoonHint(null); backToProfile(); return }
          // ARS-785 / Slice 10 `FR-021`: «Входящие офферы» построены и ведут на свой
          // экран. Ветка появляется здесь вместе с записью id в `BUILT_SECTIONS` — иначе
          // построенный пункт молча мёртв: подсказку множество уже погасило, а перехода нет.
          if (item.id === 'offers') { setSoonHint(null); navigate(MPK_OFFERS_URL); return }
          setSoonHint(item.id)
        }}
        onThemeToggle={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}
        onBackToMpk={backToMpk}
      />

      <main className="mpkc-main">
        <div className="mpkc-head">
          <div className="mpkc-head-mono" aria-hidden="true"><PhIcon name="fileText" size={20} /></div>
          <div className="mpkc-head-txt">
            <div className="mpkc-head-row">
              <span className="mpkc-head-name">Мои заявки</span>
            </div>
            <div className="mpkc-head-sub">{profile?.name ?? ''}</div>
          </div>
          {/* FR-024: ход «завести заявку» доступен с любого состояния списка, включая
              пустое — иначе новый комбинат на пилоте упирается в кабинет без хода. */}
          <button
            type="button"
            className="mpkc-stub-act primary"
            onClick={() => setCreating(true)}
            disabled={!profile?.orgId}
          >
            <PhIcon name="plus" size={13} /> Новая заявка
          </button>
        </div>

        {body()}
      </main>

      {creating && profile?.orgId && (
        <CreateRequestModal
          organizationId={profile.orgId}
          onClose={() => setCreating(false)}
          onCreated={() => {
            // Заявка появляется в списке из перечитанного ответа базы, а не дорисовыванием
            // на клиенте: иначе список показывал бы то, чего в базе может не быть (M-019).
            setCreating(false)
            refetchPools()
            goList('filling')
          }}
        />
      )}
    </div>
  )
}
