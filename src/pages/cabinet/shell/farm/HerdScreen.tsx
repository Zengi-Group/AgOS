// AgOS · ARS-285 (Ферма 2.0 · F9) · SCR-HD «Стадо» + SCR-WK «Обход» + SHEET-AN.
// Job (Slice8 §4): «зафиксировать неладное за секунды, не останавливая обход». Данные — один
// вызов rpc_get_herd_board = SCR-HD + SCR-WK = один кэш-юнит (§4/§5, D145); SHEET-AN — отдельный
// кэш-юнит rpc_get_animal_card. Вход в Обход — params.mode==='walk' (F4-контракт goFarmTab, уже
// вызывается из OverviewScreen «Стадо»-зоны); SHEET-AN — params.animalId (тот же контракт, что
// «Требует внимания» Обзора, §2.2 open_animal). Офлайн: полный outbox — F10/ARS-286 (ещё не
// построен); здесь — прямые RPC + optimistic reload + toast на отказ (тот же приём, что F5-F8);
// сетевой индикатор Обхода — useOnline() (существующий паттерн S3/ARS-149, не новый).
// Группы (§5): тап не ведёт никуда — «существующие экраны групп» (ARS-171) ещё не построены
// (проверено: только в доках), а мастер-wizard (onStart) — другой флоу (состав, не CRUD групп);
// изобретать переход на неверный экран хуже, чем оставить строки информационными до ARS-171.
// Инварианты: статус = точка+текст без заливок; mono только цифры (R-9); :active на каждом
// интерактиве (R-28); хиты ≥44 (кнопка обхода ≥48).

import { useCallback, useEffect, useState, useSyncExternalStore } from 'react'
import { PhIcon } from '../components/icons/PhIcon'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import { Sheet } from '../components/Sheet'
import { Cta } from '../components/Cta'
import { useOnline } from '@/platform/network'
import type { FarmTabParams, GoFarmTab } from './tabs'
import { localToday } from './data/farm-overview'
import {
  loadHerdBoard, markWalkthrough, logAnimalEvent, closeAnimalEvent, loadAnimalCard, loadEventTypes,
  createInspectionTask, createVetCaseFromEvent,
  type HerdBoard, type OpenEventRow, type RecentAnimal, type AnimalEventTypeOption, type AnimalCardData,
  type AnimalCardEvent,
} from './data/farm-herd'
import {
  subscribeOutbox, getPendingCount, getFailedItems, getPendingItems, retryItem, removeItem, type OutboxItem,
} from './data/outbox'

interface Props {
  orgId: string
  farmId: string
  goFarmTab: GoFarmTab
  params?: FarmTabParams
  toast: (text: string) => void
  refreshNonce: number
}

const hm = (ts: string | null) =>
  ts ? new Date(ts).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }) : ''
const isToday = (ts: string) => ts.slice(0, 10) === localToday()

// «Не записалось» (F10/ARS-286, «тихого дропа НЕТ») — русская подпись элемента очереди по RPC.
const OUTBOX_LABEL: Record<string, string> = {
  rpc_mark_walkthrough: 'Отметка обхода',
  rpc_log_animal_event: 'Отклонение',
  rpc_close_animal_event: 'Закрытие события',
  rpc_create_farm_task: 'Задача',
  rpc_complete_farm_task: 'Выполнение задачи',
  rpc_reschedule_farm_task: 'Перенос задачи',
}

// Цифры внутри русской фразы → mono (R-9), тот же приём, что OverviewScreen.tsx.
const monoNums = (s: string) =>
  s.split(/(\d+)/).map((p, i) => (/^\d+$/.test(p) ? <span key={i} className="mk-mono">{p}</span> : <span key={i}>{p}</span>))

export function HerdScreen({ orgId, farmId, goFarmTab, params, toast, refreshNonce }: Props) {
  const [data, setData] = useState<HerdBoard | null>(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  // «данные на HH:MM» (F10/ARS-286) — виден только при source==='cache'.
  const [fetchedAt, setFetchedAt] = useState<string | null>(null)
  const [source, setSource] = useState<'live' | 'cache'>('live')

  const load = useCallback(async (silent?: boolean) => {
    if (!silent) setLoading(true)
    try {
      const r = await loadHerdBoard(orgId, farmId)
      setData(r.data); setFetchedAt(r.fetchedAt); setSource(r.source)
      setFailed(false)
    } catch {
      setFailed(true)
    } finally {
      setLoading(false)
    }
  }, [orgId, farmId])

  useEffect(() => { load() }, [load])
  useEffect(() => { if (refreshNonce > 0) load(true) }, [refreshNonce, load])

  const animalId = params?.animalId
  const walkMode = params?.mode === 'walk'

  if (loading && !data) return <ScreenSkeleton variant="farm" />
  if (failed && !data) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="alert" size={40} /></div>
        <div className="mk-empty-h">Не удалось загрузить стадо</div>
        <div className="mk-empty-t">Проверьте связь и попробуйте ещё раз.</div>
        <button className="mk-cta ghost" onClick={() => load()}>Обновить</button>
      </div>
    )
  }
  if (!data) return null

  return (
    <>
      {source === 'cache' && fetchedAt && <div className="fo-asof">данные на {hm(fetchedAt)}</div>}
      {walkMode ? (
        <WalkView
          orgId={orgId} farmId={farmId} data={data} toast={toast}
          onBack={() => goFarmTab('herd')}
          onReload={() => load(true)}
        />
      ) : (
        <HerdTab
          data={data}
          onOpenWalk={() => goFarmTab('herd', { mode: 'walk' })}
          onOpenAnimal={(id) => goFarmTab('herd', { animalId: id })}
        />
      )}

      {animalId && (
        <AnimalCardSheet
          orgId={orgId} farmId={farmId} animalId={animalId} toast={toast}
          onClose={() => goFarmTab('herd', walkMode ? { mode: 'walk' } : undefined)}
          onChanged={() => load(true)}
        />
      )}
    </>
  )
}

// ── SCR-HD · таб «Стадо» (§5) ──────────────────────────────────────────────────
function HerdTab({ data, onOpenWalk, onOpenAnimal }: {
  data: HerdBoard; onOpenWalk: () => void; onOpenAnimal: (id: string) => void
}) {
  const walkOk = data.walkthrough.marked

  return (
    <>
      {/* Карточка обхода — первый блок (§5) */}
      <button className={'hd-walk-card' + (walkOk ? '' : ' warn')} onClick={onOpenWalk}>
        <span className={'fo-dot ' + (walkOk ? 'ok' : 'warn')} />
        <div className="hd-walk-card-main">
          <div className="hd-walk-card-t">
            {walkOk ? `Обход сделан · ${hm(data.walkthrough.marked_at)}` : 'Обход не отмечен'}
          </div>
          {!walkOk && <div className="hd-walk-card-s">Отметьте обход и внесите отклонения</div>}
        </div>
        <span className="hd-walk-card-cta">Обход<PhIcon name="chevronRight" size={15} /></span>
      </button>

      {/* Группы (§5) — информационно; тап ведёт в существующие экраны групп, когда те появятся (ARS-171) */}
      <div className="fo-sec-h"><b>Группы</b><span className="fo-sec-cnt mk-mono">{data.herd_total}</span></div>
      <div className="fo-box">
        {data.groups.length === 0 ? (
          <div className="fo-note">Групп пока нет.</div>
        ) : data.groups.map((g) => (
          <div className="hd-grp-row" key={g.id}>
            <div className="hd-grp-main">
              <div className="hd-grp-n">{g.category_name}</div>
              {g.avg_weight_kg != null && <div className="hd-grp-w">ср. вес <span className="mk-mono">{g.avg_weight_kg}</span> кг</div>}
            </div>
            <span className="hd-grp-h"><span className="mk-mono">{g.head_count}</span><span className="hd-grp-h-u">голов</span></span>
          </div>
        ))}
      </div>

      {/* Открытые события (§5) — тап по строке → SHEET-AN */}
      <div className="fo-sec-h">
        <b>Открытые события</b>
        {data.open_events.length > 0 && <span className="fo-sec-cnt mk-mono">{data.open_events.length}</span>}
      </div>
      <div className="fo-box">
        {data.open_events.length === 0 ? (
          <div className="fo-att-clear"><span className="fo-dot ok" /><span>Открытых событий нет</span></div>
        ) : data.open_events.map((e) => (
          <button className="fo-att hd-att-row" key={e.event_id} onClick={() => onOpenAnimal(e.animal_id)}>
            <span className="fo-dot bad" />
            <div className="fo-att-main">
              <div className="fo-att-t">{monoNums(`№${e.tag_number} — ${e.type_name}`)}</div>
              <div className="fo-att-s">{hm(e.occurred_at)}</div>
            </div>
            <PhIcon name="chevronRight" size={15} />
          </button>
        ))}
      </div>
    </>
  )
}

// ── SCR-WK · режим «Обход» (§4) ─────────────────────────────────────────────────
function WalkView({ orgId, farmId, data, toast, onBack, onReload }: {
  orgId: string; farmId: string; data: HerdBoard; toast: (text: string) => void
  onBack: () => void; onReload: () => void
}) {
  const online = useOnline()
  const [marking, setMarking] = useState(false)
  // Optimistic-правило (Slice8 §7/§8): «обход сделан» рисуется МГНОВЕННО, откат только на
  // доменный отказ — rpc_mark_walkthrough не имеет доменных причин отказа (в отличие от
  // reschedule/inspect), поэтому, в отличие от них, эта мутация флипается ДО ответа сервера.
  const [optimisticMarkedAt, setOptimisticMarkedAt] = useState<string | null>(null)
  const [wizardOpen, setWizardOpen] = useState(false)
  const [busy, setBusy] = useState<Set<string>>(new Set())
  const [resolved, setResolved] = useState<Record<string, string>>({})
  const [vetTarget, setVetTarget] = useState<OpenEventRow | null>(null)
  const [vetBusy, setVetBusy] = useState(false)
  const [outboxBusy, setOutboxBusy] = useState<Set<string>>(new Set())

  // Outbox — «не записалось» (F10/ARS-286): подписка зеркалит useOnline() (platform/network.ts).
  const pendingCount = useSyncExternalStore(
    useCallback((l: () => void) => subscribeOutbox(farmId, l), [farmId]),
    useCallback(() => getPendingCount(farmId), [farmId]),
  )
  const failedItems = useSyncExternalStore(
    useCallback((l: () => void) => subscribeOutbox(farmId, l), [farmId]),
    useCallback(() => getFailedItems(farmId), [farmId]),
  )
  const pendingItems = useSyncExternalStore(
    useCallback((l: () => void) => subscribeOutbox(farmId, l), [farmId]),
    useCallback(() => getPendingItems(farmId), [farmId]),
  )
  // Для «строка появляется без ожидания сети» (§7) нужно имя типа, а не только код — тот же
  // справочник, что уже грузит DeviationForm (loadEventTypes, платформенный, без organization_id).
  const [eventTypeNames, setEventTypeNames] = useState<Record<string, string>>({})
  useEffect(() => {
    loadEventTypes().then((list) => {
      setEventTypeNames(Object.fromEntries(list.map((t) => [t.code, t.name_ru])))
    }).catch(() => { /* офлайн/сбой — покажем код вместо имени, не критично */ })
  }, [])

  const doRetry = async (opId: string) => {
    if (outboxBusy.has(opId)) return
    setOutboxBusy((p) => new Set(p).add(opId))
    try {
      await retryItem(farmId, opId)
    } finally {
      setOutboxBusy((p) => { const n = new Set(p); n.delete(opId); return n })
    }
  }

  const walkOk = data.walkthrough.marked || optimisticMarkedAt != null
  const markedAt = data.walkthrough.marked ? data.walkthrough.marked_at : optimisticMarkedAt
  // «Отклонения с обхода» (§4.3) — счётчик и список за СЕГОДНЯ, отдельно от «Открытые события»
  // Стадо-таба (§5, все статус=open вне зависимости от даты) — иначе счётчик разойдётся со
  // списком (today_events_count считает сегодняшние, open_events — все открытые).
  // Ещё-не-синканные log_animal_event идут первыми (самый свежий факт) — строка гаснет сама,
  // когда drainOutbox уводит элемент из очереди (см. комментарий у getPendingItems, outbox.ts).
  const pendingDeviationRows: OpenEventRow[] = pendingItems
    .filter((it) => it.rpcName === 'rpc_log_animal_event')
    .map((it): OpenEventRow => {
      const p = it.params as Record<string, unknown>
      const occurredAt = String(p.p_occurred_at ?? it.queuedAt)
      const code = String(p.p_event_type_code ?? '')
      return {
        event_id: it.opId,
        animal_id: '',
        tag_number: String(p.p_tag_number ?? ''),
        type_code: code,
        type_name: eventTypeNames[code] ?? code,
        occurred_at: occurredAt,
        note: (p.p_note as string | null) ?? null,
        vet_case_id: null,
        task_id: null,
      }
    })
    .filter((e) => isToday(e.occurred_at))
  const pendingEventIds = new Set(pendingDeviationRows.map((e) => e.event_id))
  const todayEvents = [...pendingDeviationRows, ...data.open_events.filter((e) => isToday(e.occurred_at))]
  const now = new Date()

  const doMark = async () => {
    if (marking || walkOk) return
    setOptimisticMarkedAt(new Date().toISOString())
    setMarking(true)
    try {
      const r = await markWalkthrough(orgId, farmId)
      if (r.ok === false) {
        setOptimisticMarkedAt(null)
        toast('Не удалось отметить обход — попробуйте ещё')
      } else {
        onReload()
      }
    } catch {
      setOptimisticMarkedAt(null)
      toast('Не удалось отметить обход — попробуйте ещё')
    } finally {
      setMarking(false)
    }
  }

  const doInspect = async (e: OpenEventRow) => {
    if (busy.has(e.event_id)) return
    setBusy((p) => new Set(p).add(e.event_id))
    try {
      const r = await createInspectionTask(orgId, farmId, e.event_id, e.tag_number)
      if (r.ok === false) {
        toast(r.reason === 'NO_ACTIVE_PLAN' ? 'Нет активного плана — задачу создать нельзя' : 'Не удалось создать задачу')
      } else {
        setResolved((p) => ({ ...p, [e.event_id]: 'Осмотр — сегодня' }))
        toast('Задача на сегодня')
      }
    } catch {
      toast('Не удалось создать задачу — попробуйте ещё')
    } finally {
      setBusy((p) => { const n = new Set(p); n.delete(e.event_id); return n })
    }
  }

  const confirmVet = async () => {
    if (!vetTarget || vetBusy) return
    setVetBusy(true)
    try {
      const r = await createVetCaseFromEvent(orgId, vetTarget.event_id)
      if (r.ok === false) toast('Не удалось открыть случай')
      else { onReload(); toast('Случай открыт') }
    } catch {
      toast('Не удалось открыть случай — попробуйте ещё')
    } finally {
      setVetBusy(false)
      setVetTarget(null)
    }
  }

  return (
    <>
      <div className="wk-head">
        <button className="wk-back" aria-label="Назад" onClick={onBack}><PhIcon name="chevronLeft" size={18} /></button>
        <div className="wk-head-main">
          <div className="wk-head-t">Обход</div>
          <div className="wk-head-d">
            {now.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })} · <span className="mk-mono">{now.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}</span>
          </div>
        </div>
        {!online && <div className="wk-offline"><PhIcon name="wifiSlash" size={14} /><span>офлайн — запишется</span></div>}
      </div>
      <div className="wk-hint">По умолчанию все <span className="mk-mono">{data.herd_total}</span> в порядке. Вводите только отклонения.</div>
      {pendingCount > 0 && (
        <div className="wk-hint">Не отправлено — <span className="mk-mono">{pendingCount}</span> {pendingCount === 1 ? 'запись' : 'записи'}, отправим при связи.</div>
      )}

      {/* Блок отметки обхода (§4.2) */}
      {walkOk ? (
        <div className="wk-mark ok">
          <span className="fo-dot ok" />
          <div className="wk-mark-main">
            <div className="wk-mark-t">Обход сделан · {hm(markedAt)}</div>
            <div className="wk-mark-s">факт ушёл в «Обзор», зона «Стадо» обновлена</div>
          </div>
        </div>
      ) : (
        <div className="wk-mark warn">
          <span className="fo-dot warn" />
          <div className="wk-mark-main">
            <div className="wk-mark-t">Обход не отмечен</div>
            <div className="wk-mark-s">зона «Стадо» — нет данных</div>
          </div>
          <button className="wk-mark-cta" disabled={marking} onClick={doMark}>
            {marking ? 'Отмечаю…' : 'Обход сделан'}
          </button>
        </div>
      )}

      {/* Отклонения с обхода (§4.3) */}
      <div className="fo-sec-h">
        <b>Отклонения с обхода</b>
        {todayEvents.length > 0 && <span className="fo-sec-cnt mk-mono">{todayEvents.length}</span>}
      </div>
      <div className="fo-box">
        {todayEvents.length === 0 ? (
          <div className="wk-dash">Пока ничего — это хорошо</div>
        ) : todayEvents.map((e) => {
          // Ещё-не-синканная строка (event_id = opId, не реальный id) — «Осмотр»/«Ветврачу» шлют
          // p_animal_event_id на сервер; событие там пока не существует, действие бы упало.
          // Блокируем действия до синка, а не притворяемся, что они сработают (§8: тихого дропа НЕТ).
          const isPending = pendingEventIds.has(e.event_id)
          return (
            <div className="fo-att" key={e.event_id}>
              <span className="fo-dot bad" />
              <div className="fo-att-main">
                <div className="fo-att-t">{monoNums(`№${e.tag_number} — ${e.type_name}`)}</div>
                <div className="fo-att-s">{isPending ? 'запишется при связи' : hm(e.occurred_at)}</div>
              </div>
              {isPending ? (
                <span className="fo-att-badge"><PhIcon name="wifiSlash" size={14} />в очереди</span>
              ) : e.vet_case_id ? (
                <span className="fo-att-badge"><PhIcon name="checkCircle" size={14} />кейс открыт</span>
              ) : resolved[e.event_id] ? (
                <span className="fo-att-badge"><PhIcon name="checkCircle" size={14} />{resolved[e.event_id]}</span>
              ) : (
                <div className="wk-row-actions">
                  <button className="wk-act-btn" disabled={busy.has(e.event_id)} onClick={() => doInspect(e)}>Осмотр</button>
                  <button className="wk-act-btn" disabled={busy.has(e.event_id)} onClick={() => setVetTarget(e)}>Ветврачу</button>
                </div>
              )}
            </div>
          )
        })}
      </div>

      {/* «Не записалось» (§7/§8, «тихого дропа НЕТ») — доменные отказы outbox, retry/remove. */}
      {failedItems.length > 0 && (
        <>
          <div className="fo-sec-h"><b>Не записалось</b><span className="fo-sec-cnt mk-mono">{failedItems.length}</span></div>
          <div className="fo-box">
            {failedItems.map((it: OutboxItem) => (
              <div className="fo-att" key={it.opId}>
                <span className="fo-dot bad" />
                <div className="fo-att-main">
                  <div className="fo-att-t">{OUTBOX_LABEL[it.rpcName] ?? it.rpcName}</div>
                  {it.failReason && <div className="fo-att-s">{it.failReason}</div>}
                </div>
                <div className="wk-row-actions">
                  <button className="wk-act-btn" disabled={outboxBusy.has(it.opId)} onClick={() => doRetry(it.opId)}>Повторить</button>
                  <button className="wk-act-btn" disabled={outboxBusy.has(it.opId)} onClick={() => removeItem(farmId, it.opId)}>Убрать</button>
                </div>
              </div>
            ))}
          </div>
        </>
      )}

      <button className="wk-add" onClick={() => setWizardOpen(true)}>
        <PhIcon name="plus" size={16} /><span>Отклонение</span>
      </button>

      <div className="wk-foot">Поимённый чек — только в расколе (вакцинация, взвешивание) и при инвентаризации.</div>

      <Sheet open={wizardOpen} onClose={() => setWizardOpen(false)}>
        <DeviationForm
          orgId={orgId} farmId={farmId} animalsRecent={data.animals_recent}
          onCancel={() => setWizardOpen(false)}
          onDone={() => { setWizardOpen(false); onReload() }}
        />
      </Sheet>

      <Sheet open={!!vetTarget} onClose={() => setVetTarget(null)}>
        <div className="sh-t">Открыть случай ветврачу?</div>
        {vetTarget && <div className="wk-vet-note">№{vetTarget.tag_number} — {vetTarget.type_name}</div>}
        <Cta onClick={confirmVet} disabled={vetBusy}>{vetBusy ? 'Открываю…' : 'Подтвердить'}</Cta>
        <Cta variant="ghost" onClick={() => setVetTarget(null)}>Отмена</Cta>
      </Sheet>
    </>
  )
}

// ── «+ Отклонение» — инлайн-визард ровно 2 шага (§4.4). initialTag: SHEET-AN пропускает шаг 1
// (животное уже выбрано, §5). ──────────────────────────────────────────────────
// export — переиспользуется диспетчером «Записать событие» (ARS-301/302, EventCaptureSheet):
// то же тело «кто→что» и в «Обходе», и в глобальном захвате (P4, ноль дублирования логики).
export function DeviationForm({ orgId, farmId, animalsRecent, initialTag, onDone, onCancel }: {
  orgId: string; farmId: string; animalsRecent: RecentAnimal[]; initialTag?: string
  onDone: (eventId: string, tagNumber: string) => void; onCancel: () => void
}) {
  const [step, setStep] = useState<'who' | 'what'>(initialTag ? 'what' : 'who')
  const [tag, setTag] = useState(initialTag ?? '')
  const [search, setSearch] = useState('')
  const [types, setTypes] = useState<AnimalEventTypeOption[]>([])
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => { loadEventTypes().then(setTypes).catch(() => setTypes([])) }, [])

  const pickTag = (t: string) => { setTag(t); setStep('what'); setErr(null) }
  const confirmSearch = () => { const v = search.trim(); if (v) pickTag(v) }

  // Выбор типа завершает ввод (§4.4) — заметка (опционально) уходит тем же вызовом.
  const save = async (code: string) => {
    if (saving) return
    setSaving(true)
    setErr(null)
    try {
      const r = await logAnimalEvent(orgId, farmId, { tagNumber: tag, eventTypeCode: code, note: note.trim() || null })
      if (r.ok === false || !r.event_id) setErr('Не удалось сохранить — попробуйте ещё')
      else onDone(r.event_id, tag)
    } catch {
      setErr('Не удалось сохранить — попробуйте ещё')
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      {step === 'who' ? (
        <>
          <div className="sh-t">Шаг 1 из 2 — кто?</div>
          <div className="wk-chips">
            {animalsRecent.map((a) => (
              <button key={a.animal_id} className="wk-chip mk-mono" onClick={() => pickTag(a.tag_number)}>№{a.tag_number}</button>
            ))}
          </div>
          <div className="wk-search">
            <input
              className="ta-input" placeholder="поиск №…" value={search}
              onChange={(e) => setSearch(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') confirmSearch() }}
            />
            <button className="wk-search-go" disabled={!search.trim()} onClick={confirmSearch}>Далее</button>
          </div>
          <Cta variant="ghost" onClick={onCancel}>Отмена</Cta>
        </>
      ) : (
        <>
          <div className="sh-t">Шаг 2 из 2 — что с №{tag}?</div>
          <div className="wk-chips">
            {types.map((t) => (
              <button key={t.id} className="wk-chip" disabled={saving} onClick={() => save(t.code)}>{t.name_ru}</button>
            ))}
          </div>
          <input
            className="ta-input" placeholder="Заметка (опционально)" value={note}
            onChange={(e) => setNote(e.target.value)}
          />
          {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}
          <Cta variant="ghost" onClick={() => (initialTag ? onCancel() : setStep('who'))}>
            {initialTag ? 'Отмена' : 'Назад'}
          </Cta>
        </>
      )}
    </>
  )
}

// ── SHEET-AN · карточка животного (§5) ──────────────────────────────────────────
function AnimalCardSheet({ orgId, farmId, animalId, toast, onClose, onChanged }: {
  orgId: string; farmId: string; animalId: string; toast: (text: string) => void
  onClose: () => void; onChanged: () => void
}) {
  const [card, setCard] = useState<AnimalCardData | null>(null)
  const [failed, setFailed] = useState(false)
  const [busy, setBusy] = useState<Set<string>>(new Set())
  const [adding, setAdding] = useState(false)
  const [closeTarget, setCloseTarget] = useState<AnimalCardEvent | null>(null)
  const [fetchedAt, setFetchedAt] = useState<string | null>(null)
  const [source, setSource] = useState<'live' | 'cache'>('live')

  const load = useCallback(async () => {
    try {
      const res = await loadAnimalCard(orgId, farmId, animalId)
      const r = res.data
      if (r.ok) { setCard(r); setFetchedAt(res.fetchedAt); setSource(res.source); setFailed(false) } else { setFailed(true) }
    } catch {
      setFailed(true)
    }
  }, [orgId, farmId, animalId])

  useEffect(() => { load() }, [load])

  // «Закрыть событие» требует confirm (Slice8 §5) — тот же приём, что «Ветврачу» в WalkView.
  const confirmClose = async () => {
    if (!closeTarget || busy.has(closeTarget.event_id)) return
    const eventId = closeTarget.event_id
    setBusy((p) => new Set(p).add(eventId))
    try {
      const r = await closeAnimalEvent(orgId, farmId, eventId)
      if (r.ok === false) toast('Не удалось закрыть событие')
      else { load(); onChanged() }
    } catch {
      toast('Не удалось закрыть — попробуйте ещё')
    } finally {
      setBusy((p) => { const n = new Set(p); n.delete(eventId); return n })
      setCloseTarget(null)
    }
  }

  return (
    <Sheet open onClose={onClose}>
      {!card && !failed && <div className="wk-sheet-loading">Загрузка…</div>}
      {failed && <div className="fo-err"><PhIcon name="alert" size={14} />Не удалось загрузить карточку</div>}
      {card && !adding && !closeTarget && (
        <>
          <div className="sh-t mk-mono">№{card.animal.tag_number}</div>
          <div className="an-sub">
            {card.animal.herd_group_name ?? '—'}
            {card.animal.status === 'left_herd' && <span className="an-badge-left">выбыло</span>}
          </div>
          {source === 'cache' && fetchedAt && <div className="fo-asof">данные на {hm(fetchedAt)}</div>}

          <div className="fo-sec-h"><b>История событий</b></div>
          <div className="fo-box an-ev-box">
            {card.events.length === 0 ? (
              <div className="fo-note">Событий нет.</div>
            ) : card.events.map((e) => (
              <div className="an-ev-row" key={e.event_id}>
                <span className={'fo-dot ' + (e.status === 'open' ? 'bad' : 'ok')} />
                <div className="fo-att-main">
                  <div className="fo-att-t">{e.type_name}</div>
                  <div className="fo-att-s">
                    {hm(e.occurred_at)}
                    {e.recorded_by_name && ` · ${e.recorded_by_name}`}
                    {e.status === 'closed' && ` · закрыто${e.closed_by_name ? ` (${e.closed_by_name})` : ''}`}
                    {e.vet_case_id && ' · кейс открыт'}
                  </div>
                </div>
                {e.status === 'open' && card.animal.status === 'in_herd' && (
                  <button className="wk-act-btn" disabled={busy.has(e.event_id)} onClick={() => setCloseTarget(e)}>Закрыть</button>
                )}
              </div>
            ))}
          </div>

          {card.animal.status === 'in_herd' && (
            <button className="wk-add" onClick={() => setAdding(true)}>
              <PhIcon name="plus" size={16} /><span>Отклонение</span>
            </button>
          )}
          <Cta variant="ghost" onClick={onClose}>Закрыть</Cta>
        </>
      )}
      {card && adding && (
        <DeviationForm
          orgId={orgId} farmId={farmId} animalsRecent={[]} initialTag={card.animal.tag_number}
          onCancel={() => setAdding(false)}
          onDone={() => { setAdding(false); load(); onChanged() }}
        />
      )}
      {card && closeTarget && (
        <>
          <div className="sh-t">Закрыть событие?</div>
          <div className="wk-vet-note">№{card.animal.tag_number} — {closeTarget.type_name}</div>
          <Cta onClick={confirmClose} disabled={busy.has(closeTarget.event_id)}>
            {busy.has(closeTarget.event_id) ? 'Закрываю…' : 'Подтвердить'}
          </Cta>
          <Cta variant="ghost" onClick={() => setCloseTarget(null)}>Отмена</Cta>
        </>
      )}
    </Sheet>
  )
}
