// AgOS · ARS-282/ARS-283 (Ферма 2.0 · F6/F7) · SCR-TA «Задачи».
// Шапка (сегмент Неделя|Месяц|Год + «+») — общая для F6/F7/F8, строится здесь первой (Slice8 §3).
// Неделя (§3.1, F6): горит-блок (непролистываем) → полоса недели → план дня. Месяц (§3.2, F7,
// MonthScreen.tsx): календарная сетка-диапазоны → «Подготовиться к окнам» → «Вехи месяца». Год
// (§3.3, F8/ARS-284): вертикальный таймлайн фаз + единственная ручная правка «Старт случки»
// (превью→confirm→rpc_shift_breeding_start); заменяет временный мост FarmPlanView (ARS-215) —
// см. FarmScreen.tsx (HS-2: читатель ARS-215 переиспользован визуально — карточки фаз/чипы
// статуса — не выброшен, а поднят в полноценный SCR-TA). Все три сегмента теперь рабочие.
// Чек/перенос — общие RPC с Обзором (farm-overview.ts), общий факт (slice §6).

import { useCallback, useEffect, useState } from 'react'
import { PhIcon } from '../components/icons/PhIcon'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import { Sheet } from '../components/Sheet'
import { Cta } from '../components/Cta'
import type { FarmTab, FarmTabParams, GoFarmTab } from './tabs'
import { completeFarmTask, rescheduleFarmTaskToday, localToday } from './data/farm-overview'
import {
  loadWeekHorizon, loadNextMilestone, createFarmTask,
  loadYearHorizon, previewBreedingShift, shiftBreedingStart,
  type WeekHorizon, type WeekTask, type BurningItem, type MonthMilestone,
  type YearHorizon, type YearPhase, type CascadePreviewItem,
} from './data/farm-tasks'
import { MonthScreen } from './MonthScreen'

interface Props {
  orgId: string
  farmId: string
  goFarmTab: GoFarmTab
  params?: FarmTabParams
  toast: (text: string) => void
  onGlobalRefresh: () => void
  refreshNonce: number
}

const WEEKDAY = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']
const MON_GEN = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря']
const MON_ABBR = ['янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек']

const parseD = (d: string) => new Date(d + 'T00:00:00')
const dow = (d: string) => (parseD(d).getDay() + 6) % 7 // 0=Пн..6=Вс
const dm = (d: string) => `${parseD(d).getDate()} ${MON_GEN[parseD(d).getMonth()]}`
const hmTime = (t: string | null) => (t ? t.slice(0, 5) : '')
// HH:MM из ISO-таймстампа fetchedAt (F10/ARS-286, offline-cache.ts) — тот же приём, что hm() в OverviewScreen.tsx.
const hm = (ts: string) => new Date(ts).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })
const daysUntil = (d: string) => Math.max(0, Math.round((parseD(d).getTime() - parseD(localToday()).getTime()) / 86400000))
// Год (§3.3): диапазон цикла в шапке — «июн 26 → окт 27» (абброморфы месяца + 2-значный год).
const monYear = (d: string) => `${MON_ABBR[parseD(d).getMonth()]} ${String(parseD(d).getFullYear()).slice(-2)}`

const SEGMENTS: ReadonlyArray<{ key: NonNullable<FarmTabParams['horizon']>; label: string }> = [
  { key: 'week', label: 'Неделя' },
  { key: 'month', label: 'Месяц' },
  { key: 'year', label: 'Год' },
]

export function TasksScreen({ orgId, farmId, goFarmTab, params, toast, onGlobalRefresh, refreshNonce }: Props) {
  const horizon = params?.horizon ?? 'week'
  const [createOpen, setCreateOpen] = useState(false)
  const [createdNonce, setCreatedNonce] = useState(0)

  const setHorizon = (h: NonNullable<FarmTabParams['horizon']>) =>
    goFarmTab('tasks' as FarmTab, { ...params, horizon: h })

  return (
    <>
      <div className="ta-seg">
        <div className="ta-seg-btns">
          {SEGMENTS.map((s) => (
            <button key={s.key} className={'ta-seg-b' + (horizon === s.key ? ' on' : '')} onClick={() => setHorizon(s.key)}>
              {s.label}
            </button>
          ))}
        </div>
        <button className="ta-add" aria-label="Новая задача" onClick={() => setCreateOpen(true)}>
          <PhIcon name="plus" size={18} />
        </button>
      </div>

      {horizon === 'week' ? (
        <WeekView orgId={orgId} farmId={farmId} refreshNonce={refreshNonce} createdNonce={createdNonce} />
      ) : horizon === 'month' ? (
        <MonthScreen orgId={orgId} farmId={farmId} goFarmTab={goFarmTab} refreshNonce={refreshNonce} createdNonce={createdNonce} />
      ) : (
        <YearView orgId={orgId} farmId={farmId} refreshNonce={refreshNonce} toast={toast} onGlobalRefresh={onGlobalRefresh} />
      )}

      <CreateTaskSheet
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        orgId={orgId}
        farmId={farmId}
        onCreated={() => setCreatedNonce((n) => n + 1)}
      />
    </>
  )
}

// ── Неделя (F6, ARS-282 — единственный рабочий сегмент этого тикета) ──────────

function WeekView({ orgId, farmId, refreshNonce, createdNonce }: {
  orgId: string; farmId: string; refreshNonce: number; createdNonce: number
}) {
  const [data, setData] = useState<WeekHorizon | null>(null)
  const [noPlan, setNoPlan] = useState(false)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [milestone, setMilestone] = useState<MonthMilestone | null>(null)
  const [selectedDay, setSelectedDay] = useState<string>(() => localToday())
  const [done, setDone] = useState<Set<string>>(new Set())
  const [busy, setBusy] = useState<Set<string>>(new Set())
  const [err, setErr] = useState<string | null>(null)
  const [earlierOpen, setEarlierOpen] = useState(false)
  // «данные на HH:MM» (F10/ARS-286) — виден только при source==='cache' (не при обычной live-загрузке).
  const [fetchedAt, setFetchedAt] = useState<string | null>(null)
  const [source, setSource] = useState<'live' | 'cache'>('live')

  const load = useCallback(async (silent?: boolean) => {
    if (!silent) setLoading(true)
    try {
      const r = await loadWeekHorizon(orgId, farmId)
      const d = r.data
      setFetchedAt(r.fetchedAt); setSource(r.source)
      if (d.no_plan) {
        setNoPlan(true)
        setData(null)
      } else {
        setNoPlan(false)
        setData(d)
        // Пустая неделя (межфазье, §3.1) — ближайшая веха вместо пустоты.
        if (d.burning.length === 0 && d.days.every((day) => day.load === 0)) {
          loadNextMilestone(orgId, farmId).then(setMilestone).catch(() => setMilestone(null))
        } else {
          setMilestone(null)
        }
      }
      setFailed(false)
    } catch {
      setFailed(true)
    } finally {
      setLoading(false)
    }
  }, [orgId, farmId])

  useEffect(() => { load() }, [load])
  useEffect(() => { if (refreshNonce > 0) load(true) }, [refreshNonce, load])
  useEffect(() => { if (createdNonce > 0) load(true) }, [createdNonce, load])

  const flash = (m: string) => {
    setErr(m)
    window.setTimeout(() => setErr((v) => (v === m ? null : v)), 4000)
  }

  const toggleTask = async (t: WeekTask) => {
    if (t.status === 'completed' || done.has(t.id)) return
    setDone((prev) => new Set(prev).add(t.id))
    try {
      await completeFarmTask(orgId, farmId, t.id)
      load(true)
    } catch {
      setDone((prev) => { const n = new Set(prev); n.delete(t.id); return n })
      flash('Не удалось отметить — попробуйте ещё')
    }
  }

  const rescheduleToday = async (taskId: string) => {
    if (busy.has(taskId)) return
    setBusy((prev) => new Set(prev).add(taskId))
    try {
      const r = await rescheduleFarmTaskToday(orgId, farmId, taskId)
      if (r && r.ok === false) {
        flash(r.reason === 'WINDOW_TASK_IMMOVABLE' ? 'Задача-окно не переносится' : 'Не удалось перенести')
      } else {
        load(true)
      }
    } catch {
      flash('Не удалось перенести — попробуйте ещё')
    } finally {
      setBusy((prev) => { const n = new Set(prev); n.delete(taskId); return n })
    }
  }

  if (loading && !data && !noPlan) return <ScreenSkeleton variant="farm" />
  if (failed && !data) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="alert" size={40} /></div>
        <div className="mk-empty-h">Не удалось загрузить задачи</div>
        <div className="mk-empty-t">Проверьте связь и попробуйте ещё раз.</div>
        <button className="mk-cta ghost" onClick={() => load()}>Обновить</button>
      </div>
    )
  }
  if (noPlan) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="calendar" size={46} /></div>
        <div className="mk-empty-h">Плана пока нет</div>
        <div className="mk-empty-t">Как только запустите техкарту — здесь появится план недели.</div>
      </div>
    )
  }
  if (!data) return null

  // data.days всегда 7 записей (Пн..Вс, generate_series в rpc_get_tasks_horizon) — days[0] есть всегда.
  const day = data.days.find((d) => d.d === selectedDay) ?? data.days.find((d) => d.d === localToday()) ?? data.days[0]!
  const doneCount = day.tasks.filter((t) => t.status === 'completed' || done.has(t.id)).length
  const visible = day.tasks.filter((t) => t.status !== 'completed' || done.has(t.id))
  const earlier = day.tasks.filter((t) => t.status === 'completed' && !done.has(t.id))
  const isEmptyWeek = data.burning.length === 0 && data.days.every((d) => d.load === 0)

  return (
    <>
      {data.context && (
        <div className="ta-ctx">
          {data.context.phase_name} — день <span className="mk-mono">{data.context.day}</span>/<span className="mk-mono">{data.context.days_total}</span>
        </div>
      )}
      {source === 'cache' && fetchedAt && <div className="fo-asof">данные на {hm(fetchedAt)}</div>}
      {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}

      {/* Горит — закреплённый блок, первый, непролистываем (§3.1) */}
      {data.burning.length > 0 && (
        <div className="ta-burn">
          {data.burning.map((it: BurningItem) => it.kind === 'overdue' ? (
            <div className="ta-burn-row" key={it.task_id}>
              <span className="fo-dot bad" />
              <div className="ta-burn-main">
                <div className="ta-burn-t">{it.name}</div>
                <div className="ta-burn-s">
                  план был <span className="mk-mono">{dm(it.ref_date)}</span>
                  {it.heads != null && <> · <span className="mk-mono">{it.heads}</span> голов</>}
                </div>
              </div>
              <button className="ta-burn-btn" disabled={busy.has(it.action.ref_id)} onClick={() => rescheduleToday(it.action.ref_id)}>
                На сегодня
              </button>
            </div>
          ) : (
            <button className="ta-burn-row ta-burn-link" key={it.task_id} onClick={() => setSelectedDay(it.ref_date)}>
              <span className="fo-dot warn" />
              <div className="ta-burn-main">
                <div className="ta-burn-t">{it.name}</div>
                <div className="ta-burn-s">
                  осталось <span className="mk-mono">{daysUntil(it.ref_date)}</span> дн
                  {it.heads != null && <> · <span className="mk-mono">{it.heads}</span> голов</>}
                </div>
              </div>
              <PhIcon name="chevronRight" size={15} />
            </button>
          ))}
        </div>
      )}

      {/* Полоса недели */}
      <div className="ta-strip">
        {data.days.map((d) => {
          const dots = d.load > 0 ? Math.min(4, Math.ceil(d.load / 2)) : 0
          return (
            <button
              key={d.d}
              className={'ta-day' + (d.d === localToday() ? ' today' : '') + (d.d === selectedDay ? ' sel' : '')}
              onClick={() => setSelectedDay(d.d)}
            >
              <span className="ta-day-w">{WEEKDAY[dow(d.d)]}</span>
              <span className="ta-day-n mk-mono">{parseD(d.d).getDate()}</span>
              <span className="ta-day-dots">
                {Array.from({ length: dots }).map((_, i) => <i key={i} className={d.has_overdue ? 'bad' : ''} />)}
              </span>
            </button>
          )
        })}
      </div>

      {isEmptyWeek && milestone && (
        <div className="ta-next">
          <PhIcon name="calendar" size={16} />
          <span>Впереди: {WEEKDAY[dow(milestone.date)]} <span className="mk-mono">{parseD(milestone.date).getDate()}</span> — {milestone.name}</span>
        </div>
      )}

      {/* План дня */}
      <div className="fo-sec-h">
        <b>{WEEKDAY[dow(day.d)]}, {dm(day.d)}</b>
        <span className="fo-sec-cnt mk-mono">{doneCount}/{day.tasks.length}</span>
      </div>
      <div className="fo-box">
        {day.tasks.length === 0 ? (
          <div className="fo-note">На этот день задач нет.</div>
        ) : (
          <>
            {visible.map((t) => (
              <TaskRow key={t.id} t={t} isDone={done.has(t.id)} onToggle={() => toggleTask(t)} />
            ))}
            {earlier.length > 0 && (
              <button className="ta-collapse" onClick={() => setEarlierOpen((v) => !v)}>
                <span>Выполнено утром — {earlier.length} задач</span>
                <PhIcon name="chevronRight" size={14} style={{ transform: earlierOpen ? 'rotate(90deg)' : undefined }} />
              </button>
            )}
            {earlierOpen && earlier.map((t) => (
              <TaskRow key={t.id} t={t} isDone onToggle={() => {}} />
            ))}
          </>
        )}
      </div>
    </>
  )
}

function TaskRow({ t, isDone, onToggle }: { t: WeekTask; isDone: boolean; onToggle: () => void }) {
  return (
    <div className={'fo-tr' + (isDone ? ' done' : '')}>
      <button className={'fo-check' + (isDone ? ' on' : '')} aria-label="Отметить выполненной" onClick={onToggle}>
        {isDone && <PhIcon name="check" size={13} />}
      </button>
      <div className="fo-tr-main">
        <div className="fo-tr-t">{t.name}</div>
        <div className="fo-tr-m">
          {t.sop_code && <span className="ta-sop">{t.sop_code}</span>}
          {t.heads != null && <span><span className="mk-mono">{t.heads}</span> голов</span>}
          {t.source === 'deviation' && <span className="dev"><span className="fo-dot bad" />по отклонению</span>}
          {t.window_end && <span className="win">окно до <span className="mk-mono">{dm(t.window_end)}</span></span>}
        </div>
      </div>
      {t.assigned_to_name && (
        <span className="ta-avatar" title={t.assigned_to_name}>{t.assigned_to_name.trim().charAt(0).toUpperCase()}</span>
      )}
      {t.due_time && <div className="fo-tr-time mk-mono">{hmTime(t.due_time)}</div>}
    </div>
  )
}

// ── Год (F8, ARS-284) — вертикальный таймлайн фаз + сдвиг старта случки (§3.3) ─

function YearView({ orgId, farmId, refreshNonce, toast, onGlobalRefresh }: {
  orgId: string; farmId: string; refreshNonce: number; toast: (text: string) => void; onGlobalRefresh: () => void
}) {
  const [data, setData] = useState<YearHorizon | null>(null)
  const [noPlan, setNoPlan] = useState(false)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const [fetchedAt, setFetchedAt] = useState<string | null>(null)
  const [source, setSource] = useState<'live' | 'cache'>('live')

  const load = useCallback(async (silent?: boolean) => {
    if (!silent) setLoading(true)
    try {
      const r = await loadYearHorizon(orgId, farmId)
      setFetchedAt(r.fetchedAt); setSource(r.source)
      const d = r.data
      if (d.no_plan) { setNoPlan(true); setData(null) } else { setNoPlan(false); setData(d) }
      setFailed(false)
    } catch {
      setFailed(true)
    } finally {
      setLoading(false)
    }
  }, [orgId, farmId])

  useEffect(() => { load() }, [load])
  useEffect(() => { if (refreshNonce > 0) load(true) }, [refreshNonce, load])

  if (loading && !data && !noPlan) return <ScreenSkeleton variant="farm" />
  if (failed && !data) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="alert" size={40} /></div>
        <div className="mk-empty-h">Не удалось загрузить план</div>
        <div className="mk-empty-t">Проверьте связь и попробуйте ещё раз.</div>
        <button className="mk-cta ghost" onClick={() => load()}>Обновить</button>
      </div>
    )
  }
  if (noPlan) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="calendar" size={46} /></div>
        <div className="mk-empty-h">Плана пока нет</div>
        <div className="mk-empty-t">Как только запустите техкарту — здесь появится план на год.</div>
      </div>
    )
  }
  if (!data) return null

  const breeding = data.breeding
  const breedingPhase = breeding ? data.phases.find((p) => p.id === breeding.phase_id) ?? null : null

  return (
    <>
      <div className="ta-yr-h">
        <div className="ta-yr-name">Цикл {parseD(data.plan.cycle_start).getFullYear()} — целиком</div>
        <div className="ta-yr-range mk-mono">{monYear(data.plan.cycle_start)} → {monYear(data.plan.cycle_end)}</div>
      </div>
      {source === 'cache' && fetchedAt && <div className="fo-asof">данные на {hm(fetchedAt)}</div>}

      <div className="ta-yr-line">
        {data.phases.map((ph) => (
          <YearPhaseRow key={ph.id} ph={ph} isBreeding={breeding?.phase_id === ph.id} onEditBreeding={() => setEditOpen(true)} />
        ))}
      </div>

      {breedingPhase && (
        <BreedingShiftSheet
          open={editOpen}
          onClose={() => setEditOpen(false)}
          orgId={orgId}
          farmId={farmId}
          phase={breedingPhase}
          onShifted={(tasksCount) => {
            toast(tasksCount > 0 ? `Пересчитано задач: ${tasksCount}` : 'Дата не изменилась — пересчёт не нужен')
            load(true)
            onGlobalRefresh()
          }}
        />
      )}
    </>
  )
}

function YearPhaseRow({ ph, isBreeding, onEditBreeding }: { ph: YearPhase; isBreeding: boolean; onEditBreeding: () => void }) {
  if (ph.status === 'completed' || ph.status === 'skipped') {
    return (
      <div className="ta-yr-row">
        <span className="ta-yr-dot done"><PhIcon name="check" size={11} /></span>
        <div className="ta-yr-row-main">
          <div className="ta-yr-row-n muted">{ph.name_ru}</div>
          <div className="ta-yr-row-d mk-mono">{dm(ph.start_date)} — {dm(ph.end_date)}</div>
        </div>
      </div>
    )
  }

  if (ph.status === 'active') {
    return (
      <div className="ta-yr-card">
        <div className="ta-yr-row">
          <span className="ta-yr-dot on" />
          <div className="ta-yr-row-main">
            <div className="ta-yr-row-n">{ph.name_ru}</div>
            <div className="ta-yr-row-d">день <span className="mk-mono">{ph.day}</span>/<span className="mk-mono">{ph.days_total}</span></div>
          </div>
        </div>
        <div className="ta-yr-bar"><div className="ta-yr-bar-f" style={{ width: `${ph.progress_pct}%` }} /></div>
        {ph.milestones.length > 0 && (
          <div className="ta-yr-mile">
            {ph.milestones.map((m, i) => (
              <div className="ta-yr-mile-row" key={i}>
                <span className="mk-mono">{dm(m.date)}</span>
                <span>{m.name}</span>
              </div>
            ))}
          </div>
        )}
        {isBreeding && (
          <button className="ta-yr-edit" onClick={onEditBreeding}>
            <PhIcon name="pencil" size={14} />
            <span>Старт случки — {dm(ph.start_date)} · изменить</span>
          </button>
        )}
      </div>
    )
  }

  // upcoming
  return (
    <div className="ta-yr-row">
      <span className="ta-yr-dot" />
      <div className="ta-yr-row-main">
        <div className="ta-yr-row-n">{ph.name_ru}</div>
        <div className="ta-yr-row-d">
          <span className="mk-mono">{dm(ph.start_date)} — {dm(ph.end_date)}</span>
          {ph.expected_heads != null && <> · ожидается ~<span className="mk-mono">{ph.expected_heads}</span> голов</>}
        </div>
      </div>
      {isBreeding && (
        <button className="ta-yr-edit-sm" aria-label="Старт случки — изменить" onClick={onEditBreeding}>
          <PhIcon name="pencil" size={14} />
        </button>
      )}
    </div>
  )
}

// Флоу §3.3.3: date-picker → превью (fn_preview_cascade, read-only) → confirm → rpc_shift_breeding_start.
// Отмена на любом шаге — ничего не вызвано (превью само по себе ничего не пишет).
function BreedingShiftSheet({ open, onClose, orgId, farmId, phase, onShifted }: {
  open: boolean; onClose: () => void; orgId: string; farmId: string; phase: YearPhase
  onShifted: (shiftedTasksCount: number) => void
}) {
  const [step, setStep] = useState<'pick' | 'preview'>('pick')
  const [date, setDate] = useState(phase.start_date)
  const [preview, setPreview] = useState<CascadePreviewItem[]>([])
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (open) { setStep('pick'); setDate(phase.start_date); setPreview([]); setErr(null) }
  }, [open, phase.start_date])

  const showPreview = async () => {
    if (!date || loading) return
    setLoading(true)
    setErr(null)
    try {
      setPreview(await previewBreedingShift(phase.id, date))
      setStep('preview')
    } catch {
      setErr('Не удалось построить превью — попробуйте ещё')
    } finally {
      setLoading(false)
    }
  }

  const confirm = async () => {
    if (saving) return
    setSaving(true)
    setErr(null)
    try {
      const r = await shiftBreedingStart(orgId, farmId, date)
      if (r.ok) {
        onShifted(r.no_change ? 0 : r.shifted_tasks_count)
        onClose()
      } else {
        setErr('Не удалось пересчитать — попробуйте ещё')
      }
    } catch {
      setErr('Не удалось пересчитать — попробуйте ещё')
    } finally {
      setSaving(false)
    }
  }

  return (
    <Sheet open={open} onClose={onClose}>
      {step === 'pick' ? (
        <>
          <div className="sh-t">Старт случки</div>
          <input className="ta-input" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}
          <Cta onClick={showPreview} disabled={!date || loading}>{loading ? 'Считаю…' : 'Далее'}</Cta>
          <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
        </>
      ) : (
        <>
          <div className="sh-t">Пересчитает все будущие окна и вехи</div>
          <div className="ta-yr-prev-note">Прошлое не изменится.</div>
          {preview.length > 0 && (
            <div className="ta-yr-prev-list">
              {preview.map((p) => (
                <div className="ta-yr-prev-row" key={p.phase_id}>
                  <span className="ta-yr-prev-n">{p.phase_name}</span>
                  <span className="ta-yr-prev-d mk-mono">{dm(p.old_start)} → {dm(p.new_start)}</span>
                </div>
              ))}
            </div>
          )}
          {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}
          <Cta onClick={confirm} disabled={saving}>{saving ? 'Пересчитываю…' : 'Подтвердить'}</Cta>
          <Cta variant="ghost" onClick={() => setStep('pick')}>Назад</Cta>
        </>
      )}
    </Sheet>
  )
}

// ── «+» ручная задача (Slice8 §3, eng-spec §2.14) ──────────────────────────────
// Без выбора исполнителя — нет ростера участников; открытый вопрос handoff §12
// «раздача задач помощникам» не решён CEO (модель уже держит assigned_to для будущего поля).

function CreateTaskSheet({ open, onClose, orgId, farmId, onCreated }: {
  open: boolean; onClose: () => void; orgId: string; farmId: string; onCreated: () => void
}) {
  const [name, setName] = useState('')
  const [date, setDate] = useState(localToday())
  const [time, setTime] = useState('')
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (open) { setName(''); setDate(localToday()); setTime(''); setErr(null) }
  }, [open])

  const valid = name.trim().length > 0 && date.length > 0

  const save = async () => {
    if (!valid || saving) return
    setSaving(true)
    setErr(null)
    try {
      const r = await createFarmTask(orgId, farmId, { nameRu: name.trim(), dueDate: date, dueTime: time || null })
      if (r && r.ok === false) {
        setErr('Не удалось создать — попробуйте ещё')
      } else {
        onCreated()
        onClose()
      }
    } catch {
      setErr('Не удалось создать — попробуйте ещё')
    } finally {
      setSaving(false)
    }
  }

  return (
    <Sheet open={open} onClose={onClose}>
      <div className="sh-t">Новая задача</div>
      <input className="ta-input" type="text" placeholder="Название" value={name} onChange={(e) => setName(e.target.value)} />
      <input className="ta-input" type="date" value={date} onChange={(e) => setDate(e.target.value)} />
      <input className="ta-input" type="time" value={time} onChange={(e) => setTime(e.target.value)} placeholder="Время (опц.)" />
      {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}
      <Cta onClick={save} disabled={!valid || saving}>{saving ? 'Сохраняю…' : 'Создать'}</Cta>
      <Cta variant="ghost" onClick={onClose}>Отмена</Cta>
    </Sheet>
  )
}
