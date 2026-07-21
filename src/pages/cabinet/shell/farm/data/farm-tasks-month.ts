// AgOS · ARS-283 (Ферма 2.0 · F7) · Данные экрана «Задачи · Месяц» (SCR-TA §3.2).
// rpc_get_tasks_horizon(p_horizon='month') — кэш-юнит на (horizon, anchor) (eng-spec §2.8).
// Форма ниже сверена с телом задеплоенной функции (pg_get_functiondef, prod, 2026-07-21) — не
// с доком (L-6). Дрейф канон↔деплой: Dok6 §3.2.3 «Вехи месяца» описывает диапазон + поголовье +
// тап в окно/задачу; реальный RPC отдаёт только {phase_id, name, date, kind:'phase_start'} —
// границы фаз, без поголовья и без прямой ссылки на окно/задачу. Флаг для Slice8 §3.2 (аналог
// дрейфа F5/ARS-281 §2.2). UI ниже построен под реальный RPC; тап по вехе ведёт на Год
// (единственная доступная навигация — веха = граница фазы).

import { supabase } from '@/lib/supabase'
import { localToday } from './farm-overview'

export interface MonthGridDay {
  d: string             // date 'YYYY-MM-DD'
  load: number          // задач в этот день (farm_tasks, status <> skipped)
  has_overdue: boolean
  window_ids: string[]  // только 'ops'-окна (farm_tasks.window_start); vet-окна — см. windows[]
}

export interface MonthWindow {
  id: string
  source: 'ops' | 'vet'
  name: string
  date_start: string
  date_end: string
  heads_planned: number | null
  heads_done: number | null
}

export interface MonthPrepTask {
  task_id: string
  name: string
  deadline: string       // = дата старта окна (D141)
  days_left: number       // от p_anchor
  window_ref: string | null
}

export interface MonthMilestone {
  phase_id: string
  name: string
  date: string
  kind: string           // 'phase_start' (единственный вид в деплое, D146)
}

export interface MonthHorizon {
  ok: true
  horizon: 'month'
  no_plan: false
  range: { from: string; to: string }
  grid: MonthGridDay[]
  windows: MonthWindow[]
  prep: MonthPrepTask[]
  milestones: MonthMilestone[]
}

export interface MonthHorizonNoPlan {
  ok: true
  no_plan: true
  horizon: 'month'
}

export type MonthHorizonResult = MonthHorizon | MonthHorizonNoPlan

// p_anchor — любая дата внутри целевого месяца (пагинация ‹ ›, slice §2.8); по умолчанию сегодня.
export async function loadMonthHorizon(orgId: string, farmId: string, anchor?: string): Promise<MonthHorizonResult> {
  const { data, error } = await supabase.rpc('rpc_get_tasks_horizon', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_horizon: 'month',
    p_anchor: anchor ?? localToday(),
  })
  if (error) throw error
  return data as MonthHorizonResult
}
