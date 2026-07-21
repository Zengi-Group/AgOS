// AgOS · ARS-283 (Ферма 2.0 · F7) · SCR-TA «Задачи» — сегмент «Месяц» (Dok6 Slice8 §3.2).
// Job: «что готовить заранее» — окна-диапазоны месяца, подготовка к ним, вехи фаз.
// Данные — один вызов rpc_get_tasks_horizon('month', anchor) (кэш-юнит на (horizon,anchor),
// eng-spec §2.8). Чек подготовительной задачи — общий rpc_complete_farm_task (farm-overview.ts,
// общий факт с Обзором/Неделей, slice §6).
//
// Встройка (HS-3/HS-5): ARS-282 (F6) параллельно строит общую шапку SCR-TA
// (сегмент-контрол Неделя|Месяц|Год, TasksScreen.tsx) в отдельном воркетри — не смёржено на
// момент этого тикета. Чтобы не дублировать/не конфликтовать на файле, который сейчас активно
// пишет другая сессия, этот экран самодостаточен (сам заголовок месяца + пагинация) и включается
// в «Задачи» точечно по params.horizon==='month' (см. FarmScreen.tsx). Когда F6 смёржится,
// интеграция — один свап MonthSoon() → <MonthScreen> внутри TasksScreen.tsx (небольшой,
// предсказуемый мердж-конфликт, см. DECISIONS_LOG).

import { useCallback, useEffect, useState } from 'react'
import { PhIcon } from '../components/icons/PhIcon'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import { completeFarmTask, localToday } from './data/farm-overview'
import {
  loadMonthHorizon,
  type MonthHorizon, type MonthWindow, type MonthPrepTask, type MonthMilestone,
} from './data/farm-tasks-month'
import type { GoFarmTab } from './tabs'

interface Props {
  orgId: string
  farmId: string
  goFarmTab: GoFarmTab
  refreshNonce: number
  createdNonce?: number   // инкремент после ручной задачи «+» (TasksScreen, F6) — тихий refetch
}

const MON_RU = ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь']
const WEEKDAY_H = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс']

const parseD = (d: string) => new Date(d + 'T00:00:00')
const dm = (d: string) => `${parseD(d).getDate()} ${['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'][parseD(d).getMonth()]}`
const firstOfMonth = (d: Date) => new Date(d.getFullYear(), d.getMonth(), 1)
const toAnchor = (d: Date) => {
  const m = String(d.getMonth() + 1).padStart(2, '0')
  return `${d.getFullYear()}-${m}-01`
}
const dow = (d: string) => (parseD(d).getDay() + 6) % 7 // 0=Пн..6=Вс

// диапазон windows[] покрывает день d? (D75 merge ops+vet уже сделан сервером — здесь только
// проверка попадания дня в диапазон для заливки сетки; grid[].window_ids отдаёт ТОЛЬКО ops-id —
// vet-окна в него не попадают, поэтому заливку считаем по windows[], не по window_ids)
const dayInAnyWindow = (d: string, windows: MonthWindow[]) =>
  windows.some((w) => d >= w.date_start && d <= w.date_end)

export function MonthScreen({ orgId, farmId, goFarmTab, refreshNonce, createdNonce }: Props) {
  const [anchor, setAnchor] = useState<Date>(() => firstOfMonth(new Date()))
  const [data, setData] = useState<MonthHorizon | null>(null)
  const [noPlan, setNoPlan] = useState(false)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [done, setDone] = useState<Set<string>>(new Set())
  const [err, setErr] = useState<string | null>(null)

  const load = useCallback(async (silent?: boolean) => {
    if (!silent) setLoading(true)
    try {
      const d = await loadMonthHorizon(orgId, farmId, toAnchor(anchor))
      if (d.no_plan) {
        setNoPlan(true)
        setData(null)
      } else {
        setNoPlan(false)
        setData(d)
      }
      setFailed(false)
    } catch {
      setFailed(true)
    } finally {
      setLoading(false)
    }
  }, [orgId, farmId, anchor])

  useEffect(() => { load() }, [load])
  useEffect(() => { if (refreshNonce > 0) load(true) }, [refreshNonce, load])
  useEffect(() => { if (createdNonce && createdNonce > 0) load(true) }, [createdNonce, load])

  const flash = (m: string) => {
    setErr(m)
    window.setTimeout(() => setErr((v) => (v === m ? null : v)), 4000)
  }

  const togglePrep = async (t: MonthPrepTask) => {
    if (done.has(t.task_id)) return
    setDone((prev) => new Set(prev).add(t.task_id))
    try {
      await completeFarmTask(orgId, t.task_id)
      load(true)
    } catch {
      setDone((prev) => { const n = new Set(prev); n.delete(t.task_id); return n })
      flash('Не удалось отметить — попробуйте ещё')
    }
  }

  const shiftMonth = (delta: number) => setAnchor((a) => firstOfMonth(new Date(a.getFullYear(), a.getMonth() + delta, 1)))

  if (loading && !data && !noPlan) return <ScreenSkeleton variant="farm" />
  if (failed && !data) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="alert" size={40} /></div>
        <div className="mk-empty-h">Не удалось загрузить месяц</div>
        <div className="mk-empty-t">Проверьте связь и попробуйте ещё раз.</div>
        <button className="mk-cta ghost" onClick={() => load()}>Обновить</button>
      </div>
    )
  }

  // Заголовок месяца — виден и в state «плана нет» (пагинация не блокируется отсутствием плана).
  const header = (
    <div className="mo-head">
      <button className="mo-nav" aria-label="Предыдущий месяц" onClick={() => shiftMonth(-1)}>
        <PhIcon name="chevronLeft" size={16} />
      </button>
      <div className="mo-head-t">{MON_RU[anchor.getMonth()]} {anchor.getFullYear()}</div>
      <button className="mo-nav" aria-label="Следующий месяц" onClick={() => shiftMonth(1)}>
        <PhIcon name="chevronRight" size={16} />
      </button>
    </div>
  )

  if (noPlan) {
    return (
      <>
        {header}
        <div className="mk-empty">
          <div className="mk-empty-art"><PhIcon name="calendar" size={46} /></div>
          <div className="mk-empty-h">Плана пока нет</div>
          <div className="mk-empty-t">Как только запустите техкарту — здесь появится календарь месяца.</div>
        </div>
      </>
    )
  }
  if (!data) return null

  const today = localToday()
  const firstDow = dow(data.grid[0]!.d)

  return (
    <>
      {header}
      {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}

      {/* Календарная сетка месяца (§3.2.1) */}
      <div className="mo-wd">{WEEKDAY_H.map((w) => <span key={w}>{w}</span>)}</div>
      <div className="mo-grid">
        {Array.from({ length: firstDow }).map((_, i) => <span key={'pad' + i} className="mo-cell pad" />)}
        {data.grid.map((day) => {
          const inWindow = dayInAnyWindow(day.d, data.windows)
          const isToday = day.d === today
          const isPast = day.d < today
          const dots = day.load > 0 ? Math.min(4, Math.ceil(day.load / 2)) : 0
          return (
            <div
              key={day.d}
              className={'mo-cell' + (inWindow ? ' win' : '') + (isToday ? ' today' : '') + (isPast ? ' past' : '')}
            >
              <span className="mo-cell-n mk-mono">{parseD(day.d).getDate()}</span>
              {(dots > 0 || day.has_overdue) && (
                <span className="mo-cell-dots">
                  {day.has_overdue && <i className="bad" />}
                  {Array.from({ length: Math.max(0, dots - (day.has_overdue ? 1 : 0)) }).map((_, i) => <i key={i} />)}
                </span>
              )}
            </div>
          )
        })}
      </div>
      <div className="mo-legend">
        <span><i className="mo-lg-sw" />окно</span>
        <span><i className="mo-lg-dot" />нагрузка</span>
        <span><i className="mo-lg-dot bad" />просрочка</span>
      </div>

      {/* Подготовиться к окнам (§3.2.2) */}
      <div className="fo-sec-h"><b>Подготовиться к окнам</b></div>
      <div className="fo-box">
        {data.prep.length === 0 ? (
          <div className="fo-note">Подготовительных задач в этом месяце нет.</div>
        ) : data.prep.map((t) => {
          const isDone = done.has(t.task_id)
          return (
            <div className={'fo-tr' + (isDone ? ' done' : '')} key={t.task_id}>
              <button
                className={'fo-check' + (isDone ? ' on' : '')}
                aria-label="Отметить выполненной"
                onClick={() => togglePrep(t)}
              >
                {isDone && <PhIcon name="check" size={13} />}
              </button>
              <div className="fo-tr-main">
                <div className="fo-tr-t">{t.name}</div>
                <div className="fo-tr-m">
                  <span>до старта окна · дедлайн <span className="mk-mono">{dm(t.deadline)}</span></span>
                </div>
              </div>
              <div className="fo-tr-time mk-mono">{Math.max(0, t.days_left)} дн</div>
            </div>
          )
        })}
      </div>

      {/* Вехи месяца (§3.2.3, derived D146) */}
      <div className="fo-sec-h"><b>Вехи месяца</b></div>
      <div className="fo-box">
        {data.milestones.length === 0 ? (
          <div className="fo-note">Вех в этом месяце нет.</div>
        ) : data.milestones.map((m: MonthMilestone) => (
          <button
            className="mo-ms"
            key={m.phase_id + m.date}
            onClick={() => goFarmTab('tasks', { horizon: 'year' })}
          >
            <span className="mo-ms-d mk-mono">{dm(m.date)}</span>
            <span className="fo-dot warn" />
            <span className="mo-ms-t">{m.name}</span>
            <PhIcon name="chevronRight" size={14} />
          </button>
        ))}
      </div>
    </>
  )
}
