// AgOS · ARS-282 (Ферма 2.0 · F6) · SCR-TA «Задачи».
// Шапка (сегмент Неделя|Месяц|Год + «+») — общая для F6/F7/F8, строится здесь первой (Slice8 §3).
// Неделя (§3.1, единственный полностью рабочий сегмент здесь): горит-блок (непролистываем) →
// полоса недели → план дня. Месяц — заглушка (F7, ARS-283). Год — существующий мост
// FarmPlanView (ARS-215, HS-2), передаётся снаружи как yearBridge — до полноценного SCR-TA (F8).
// Чек/перенос — общие RPC с Обзором (farm-overview.ts), общий факт (slice §6).

import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { PhIcon } from '../components/icons/PhIcon'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import { Sheet } from '../components/Sheet'
import { Cta } from '../components/Cta'
import type { FarmTab, FarmTabParams, GoFarmTab } from './tabs'
import { completeFarmTask, rescheduleFarmTaskToday, localToday } from './data/farm-overview'
import {
  loadWeekHorizon, loadNextMilestone, createFarmTask,
  type WeekHorizon, type WeekTask, type BurningItem, type MonthMilestone,
} from './data/farm-tasks'

interface Props {
  orgId: string
  farmId: string
  goFarmTab: GoFarmTab
  params?: FarmTabParams
  yearBridge: ReactNode
  refreshNonce: number
}

const WEEKDAY = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']
const MON_GEN = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря']

const parseD = (d: string) => new Date(d + 'T00:00:00')
const dow = (d: string) => (parseD(d).getDay() + 6) % 7 // 0=Пн..6=Вс
const dm = (d: string) => `${parseD(d).getDate()} ${MON_GEN[parseD(d).getMonth()]}`
const hmTime = (t: string | null) => (t ? t.slice(0, 5) : '')
const daysUntil = (d: string) => Math.max(0, Math.round((parseD(d).getTime() - parseD(localToday()).getTime()) / 86400000))

const SEGMENTS: ReadonlyArray<{ key: NonNullable<FarmTabParams['horizon']>; label: string }> = [
  { key: 'week', label: 'Неделя' },
  { key: 'month', label: 'Месяц' },
  { key: 'year', label: 'Год' },
]

export function TasksScreen({ orgId, farmId, goFarmTab, params, yearBridge, refreshNonce }: Props) {
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
        <MonthSoon />
      ) : (
        yearBridge
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

function MonthSoon() {
  return (
    <div className="mk-empty">
      <div className="mk-empty-art"><PhIcon name="calendar" size={46} /></div>
      <div className="mk-empty-h">Месяц скоро появится</div>
      <div className="mk-empty-t">Календарь окон и подготовка к ним. Готовим этот экран.</div>
    </div>
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

  const load = useCallback(async (silent?: boolean) => {
    if (!silent) setLoading(true)
    try {
      const d = await loadWeekHorizon(orgId, farmId)
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
      await completeFarmTask(orgId, t.id)
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
      const r = await rescheduleFarmTaskToday(orgId, taskId)
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
