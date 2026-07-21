// AgOS · ARS-281 (Ферма 2.0 · F5) · SCR-OV «Обзор».
// Job (Slice8 §2): «за 30 секунд — иду по плану или что сегодня первым делом». Не дашборд KPI.
// Данные — один вызов rpc_get_farm_overview (кэш-юнит). Единственный ввод на экране — чек задачи
// дня (§2.4); всё остальное — переходы goFarmTab (F4-шов) или действия строк «Требует внимания».
// Инварианты: статус = точка + текст без заливок; красный текст только на данных; mono только
// цифры (R-9); :active на каждом интерактиве (R-28); хиты ≥44. Формы данных — из тела RPC (L-6).

import { useCallback, useEffect, useState } from 'react'
import { PhIcon } from '../components/icons/PhIcon'
import { ScreenSkeleton } from '../components/ScreenSkeleton'
import type { GoFarmTab } from './tabs'
import {
  loadFarmOverview, completeFarmTask, rescheduleFarmTaskToday, activateProductionPlan,
  localToday, type FarmOverview, type AttentionItem, type AttentionAction, type TodayTask,
} from './data/farm-overview'

interface Props {
  orgId: string
  farmId: string
  goFarmTab: GoFarmTab
  onSetupPlan: () => void   // state D «Настроить план» → мастер/resume (нет draft-плана)
  refreshNonce: number      // PTR из FarmScreen (инкремент → тихий refetch)
}

const ATT_LABEL: Record<AttentionAction, string> = {
  open_animal: 'Открыть',
  open_window: 'К окну',
  reschedule_today: 'На сегодня',
  open_resources: 'Настроить',
}

// HH:MM из timestamptz (as_of / marked_at)
const hm = (ts: string | null) =>
  ts ? new Date(ts).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }) : ''
// HH:MM из time 'HH:MM:SS'
const hmTime = (t: string | null) => (t ? t.slice(0, 5) : '')
// DD.MM из date
const dm = (d: string | null) =>
  d ? new Date(d + 'T00:00:00').toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit' }) : ''

// Цифры внутри русской фразы → mono (R-9). Безопасно: React экранирует сегменты.
const monoNums = (s: string) =>
  s.split(/(\d+)/).map((p, i) =>
    /^\d+$/.test(p) ? <span key={i} className="mk-mono">{p}</span> : <span key={i}>{p}</span>)

export function OverviewScreen({ orgId, farmId, goFarmTab, onSetupPlan, refreshNonce }: Props) {
  const [data, setData] = useState<FarmOverview | null>(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [done, setDone] = useState<Set<string>>(new Set())          // оптимистично отмеченные задачи
  const [busy, setBusy] = useState<Set<string>>(new Set())          // строки внимания с действием в полёте
  const [resolved, setResolved] = useState<Record<string, string>>({}) // ref_id → бейдж после действия
  const [activating, setActivating] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [online, setOnline] = useState<boolean>(() =>
    typeof navigator === 'undefined' ? true : navigator.onLine)

  const load = useCallback(async (silent?: boolean) => {
    if (!silent) setLoading(true)
    try {
      const d = await loadFarmOverview(orgId, farmId)
      setData(d); setFailed(false)
    } catch {
      setFailed(true)
    } finally {
      setLoading(false)
    }
  }, [orgId, farmId])

  useEffect(() => { load() }, [load])
  // PTR из IonShellFrame: FarmScreen инкрементит refreshNonce (0 на маунте — пропускаем).
  useEffect(() => { if (refreshNonce > 0) load(true) }, [refreshNonce, load])
  // офлайн-метка «данные на HH:MM» (полный офлайн-слой — F10)
  useEffect(() => {
    const on = () => setOnline(true)
    const off = () => setOnline(false)
    window.addEventListener('online', on)
    window.addEventListener('offline', off)
    return () => { window.removeEventListener('online', on); window.removeEventListener('offline', off) }
  }, [])

  const flash = (m: string) => {
    setErr(m)
    window.setTimeout(() => setErr((v) => (v === m ? null : v)), 4000)
  }

  // Чек задачи дня (§2.3): мгновенно (line-through + пересчёт зоны), затем синк с сервером.
  const toggleTask = async (t: TodayTask) => {
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

  // Действие строки «Требует внимания» (§2.2). Навигация — синхронно; reschedule — мутация.
  const runAttention = async (it: AttentionItem) => {
    const rid = it.action.ref_id
    switch (it.action.type) {
      case 'open_animal':
        return goFarmTab('herd', rid ? { animalId: rid } : undefined)
      case 'open_window':
        return goFarmTab('tasks', { horizon: 'month' })
      case 'open_resources':
        return goFarmTab('more')
      case 'reschedule_today': {
        if (!rid || busy.has(rid)) return
        setBusy((prev) => new Set(prev).add(rid))
        try {
          const r = await rescheduleFarmTaskToday(orgId, rid)
          if (r && r.ok === false) {
            flash(r.reason === 'WINDOW_TASK_IMMOVABLE' ? 'Задача-окно не переносится' : 'Не удалось перенести')
          } else {
            setResolved((prev) => ({ ...prev, [rid]: 'На сегодня' }))
            load(true)
          }
        } catch {
          flash('Не удалось перенести — попробуйте ещё')
        } finally {
          setBusy((prev) => { const n = new Set(prev); n.delete(rid); return n })
        }
      }
    }
  }

  const activate = async (planId: string) => {
    if (activating) return
    setActivating(true)
    try {
      const r = await activateProductionPlan(orgId, planId)
      if (r && r.ok === false) {
        flash(r.reason === 'PLAN_ALREADY_ACTIVE_EXISTS' ? 'У фермы уже есть активный план' : 'Не удалось активировать')
      } else {
        load(true)
      }
    } catch {
      flash('Не удалось активировать — попробуйте ещё')
    } finally {
      setActivating(false)
    }
  }

  if (loading && !data) return <ScreenSkeleton variant="farm" />
  if (failed && !data) {
    return (
      <div className="mk-empty">
        <div className="mk-empty-art"><PhIcon name="alert" size={40} /></div>
        <div className="mk-empty-h">Не удалось загрузить обзор</div>
        <div className="mk-empty-t">Проверьте связь и попробуйте ещё раз.</div>
        <button className="mk-cta ghost" onClick={() => load()}>Обновить</button>
      </div>
    )
  }
  if (!data) return null

  const { herd, cycle, tasks, resources, attention, today, today_more_count, as_of } = data

  // Зона «Задачи сегодня» — оптимистичный пересчёт: +1 за каждую отмеченную задачу С СЕГОДНЯШНЕЙ
  // датой (после refetch выполненная уходит из today[], двойного счёта нет).
  const tday = localToday()
  const extraDone = today.filter((t) => done.has(t.task_id) && t.due_date === tday).length
  const todayDone = Math.min(tasks.today_total, tasks.today_done + extraDone)
  const walkOk = herd.walkthrough_marked
  const firstBuy = resources.signals.find((s) => s.buy)
  const tdot = tasks.overdue > 0 ? 'bad'
    : tasks.today_total === 0 ? ''
    : todayDone >= tasks.today_total ? 'ok' : 'warn'

  return (
    <>
      {!online && <div className="fo-asof">данные на {hm(as_of)}</div>}
      {err && <div className="fo-err"><PhIcon name="alert" size={14} />{err}</div>}

      {/* ── 4 зоны контроля · 2×2 (§2.1) ── */}
      <div className="fo-zgrid">
        {/* Стадо */}
        <button className="fo-zone" onClick={() => goFarmTab('herd', walkOk ? undefined : { mode: 'walk' })}>
          <div className="fo-z-cap">Стадо</div>
          <div className="fo-z-num mk-mono">{herd.total}</div>
          <div className="fo-z-sub">голов</div>
          <div className="fo-z-st">
            <span className={'fo-dot ' + (walkOk ? 'ok' : 'warn')} />
            {walkOk ? `обход ${hm(herd.marked_at)} · все группы` : 'обход не отмечен — нет данных'}
          </div>
          <span className="fo-chev"><PhIcon name="chevronRight" size={15} /></span>
        </button>

        {/* Цикл */}
        {cycle.no_plan ? (
          <div className="fo-zone">
            <div className="fo-z-cap">Цикл</div>
            <div className="fo-z-num sm">Плана нет</div>
            <div className="fo-z-sub" style={{ marginBottom: 'auto' }}>техкарта не запущена</div>
            {cycle.draft_plan_id ? (
              <button className="fo-z-cta" disabled={activating} onClick={() => activate(cycle.draft_plan_id!)}>
                {activating ? 'Активирую…' : 'Активировать план'}
              </button>
            ) : (
              <button className="fo-z-cta ghost" onClick={onSetupPlan}>Настроить план</button>
            )}
          </div>
        ) : (
          <button className="fo-zone" onClick={() => goFarmTab('tasks', { horizon: 'year' })}>
            <div className="fo-z-cap">Цикл</div>
            <div className="fo-z-num sm">{cycle.phase_name ?? 'Цикл идёт'}</div>
            {cycle.day != null && cycle.days_total != null && (
              <>
                <div className="fo-z-sub">
                  день <span className="mk-mono">{cycle.day}</span>/<span className="mk-mono">{cycle.days_total}</span>
                </div>
                <div className="fo-prog">
                  <i style={{ width: `${Math.min(100, Math.round((cycle.day / cycle.days_total) * 100))}%` }} />
                </div>
              </>
            )}
            <div className={'fo-z-st' + (cycle.next_window?.burning ? ' bad' : '')}>
              {cycle.next_window ? (
                <>
                  <span className={'fo-dot ' + (cycle.next_window.burning ? 'bad' : 'warn')} />
                  <span>{cycle.next_window.name} · осталось <span className="mk-mono">{cycle.next_window.ends_in_days}</span> дн{cycle.next_window.burning ? ' · горит' : ''}</span>
                </>
              ) : (
                <><span className="fo-dot ok" />по плану</>
              )}
            </div>
            <span className="fo-chev"><PhIcon name="chevronRight" size={15} /></span>
          </button>
        )}

        {/* Задачи сегодня */}
        <button className="fo-zone" onClick={() => goFarmTab('tasks', { horizon: 'week' })}>
          <div className="fo-z-cap">Задачи сегодня</div>
          <div className="fo-z-num">
            <span className="mk-mono">{todayDone}</span><span className="fo-z-slash">/</span><span className="mk-mono">{tasks.today_total}</span>
          </div>
          <div className="fo-z-sub">выполнено</div>
          <div className={'fo-z-st' + (tasks.overdue > 0 ? ' bad' : '')}>
            <span className={'fo-dot ' + tdot} />
            {tasks.overdue > 0
              ? <span><span className="mk-mono">{tasks.overdue}</span> просрочены</span>
              : (tasks.today_total === 0 ? 'на сегодня задач нет' : 'по плану')}
          </div>
          <span className="fo-chev"><PhIcon name="chevronRight" size={15} /></span>
        </button>

        {/* Ресурсы · корма */}
        <button className="fo-zone" onClick={() => goFarmTab('more')}>
          <div className="fo-z-cap">Ресурсы · корма</div>
          {resources.tracked && resources.min_days_left != null ? (
            <>
              <div className="fo-z-num mk-mono">{resources.min_days_left}</div>
              <div className="fo-z-sub">дней запаса</div>
            </>
          ) : (
            <>
              <div className="fo-z-num sm">Не ведётся</div>
              <div className="fo-z-sub">учёт остатков</div>
            </>
          )}
          <div className="fo-z-st">
            {resources.tracked
              ? <><span className={'fo-dot ' + (firstBuy ? 'warn' : 'ok')} />{firstBuy ? `${firstBuy.feed} — закупить` : 'запас в норме'}</>
              : <><span className="fo-dot" />учёт не ведётся</>}
          </div>
          <span className="fo-chev"><PhIcon name="chevronRight" size={15} /></span>
        </button>
      </div>

      {/* ── Требует внимания (§2.2) ── */}
      <div className="fo-sec-h">
        <b>Требует внимания</b>
        {attention.length > 0 && <span className="fo-sec-cnt mk-mono">{attention.length}</span>}
      </div>
      <div className="fo-box">
        {attention.length === 0 ? (
          <div className="fo-att-clear"><span className="fo-dot ok" /><span>Отклонений нет — техкарта идёт по плану</span></div>
        ) : attention.map((it, i) => {
          const rid = it.action.ref_id
          const dotTone = it.kind === 'animal' || it.kind === 'task' ? 'bad' : 'warn'
          const badge = rid ? resolved[rid] : undefined
          return (
            <div className="fo-att" key={(rid ?? 'x') + i}>
              <span className={'fo-dot ' + dotTone} />
              <div className="fo-att-main">
                <div className="fo-att-t">{monoNums(it.title)}</div>
                {it.subtitle && <div className="fo-att-s">{monoNums(it.subtitle)}</div>}
              </div>
              {badge ? (
                <span className="fo-att-badge"><PhIcon name="checkCircle" size={14} />{badge}</span>
              ) : (
                <button
                  className="fo-att-btn"
                  disabled={!!rid && busy.has(rid)}
                  onClick={() => runAttention(it)}
                >
                  {ATT_LABEL[it.action.type]}
                </button>
              )}
            </div>
          )
        })}
      </div>

      {/* ── Сегодня — ближайшие (§2.3) ── */}
      <div className="fo-sec-h"><b>Сегодня — ближайшие</b></div>
      <div className="fo-box">
        {today.length === 0 ? (
          <div className="fo-note">На сегодня задач нет.</div>
        ) : (
          <>
            {today.map((t) => {
              const isDone = done.has(t.task_id)
              return (
                <div className={'fo-tr' + (isDone ? ' done' : '')} key={t.task_id}>
                  <button
                    className={'fo-check' + (isDone ? ' on' : '')}
                    aria-label="Отметить выполненной"
                    onClick={() => toggleTask(t)}
                  >
                    {isDone && <PhIcon name="check" size={13} />}
                  </button>
                  <div className="fo-tr-main">
                    <div className="fo-tr-t">{t.name}</div>
                    <div className="fo-tr-m">
                      {t.heads != null && <span><span className="mk-mono">{t.heads}</span> голов</span>}
                      {t.source === 'deviation' && <span className="dev"><span className="fo-dot bad" />по отклонению</span>}
                      {t.window_end && <span className="win">окно до <span className="mk-mono">{dm(t.window_end)}</span></span>}
                    </div>
                  </div>
                  {t.due_time && <div className="fo-tr-time mk-mono">{hmTime(t.due_time)}</div>}
                </div>
              )
            })}
            {today_more_count > 0 && (
              <button className="fo-more" onClick={() => goFarmTab('tasks', { horizon: 'week' })}>
                <span>Ещё <span className="mk-mono">{today_more_count}</span> задач — до вечера</span>
                <PhIcon name="chevronRight" size={15} />
              </button>
            )}
          </>
        )}
      </div>
    </>
  )
}
