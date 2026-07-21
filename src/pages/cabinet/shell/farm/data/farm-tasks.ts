// AgOS · ARS-282 (Ферма 2.0 · F6) · Данные экрана «Задачи» (SCR-TA) — горизонт Неделя.
// rpc_get_tasks_horizon(p_horizon) — тот же кэш-юнит-паттерн, что у Обзора (eng-spec §2.8).
// Чек/перенос — общие RPC с Обзором (farm-overview.ts), НЕ дублируем (P4). Формы ниже сверены
// с телом задеплоенной функции на проде (pg_get_functiondef), не с доком (L-6) — включая
// ARS-282-дельту (assigned_to_name join + heads/ref_date в burning[]), которую в неё внесли.

import { supabase } from '@/lib/supabase'
import { localToday, type RpcResult } from './farm-overview'

export type Horizon = 'week' | 'month' | 'year'

export interface BurningItem {
  kind: 'overdue' | 'window'
  task_id: string
  name: string
  sub: string
  heads: number | null
  ref_date: string // due_date (overdue) либо window_end (window) — форматирует UI
  action: { type: 'reschedule_today' | 'open_window'; ref_id: string }
}

export interface WeekTask {
  id: string
  name: string
  status: string
  category: 'zootechnical' | 'veterinary' | 'management'
  heads: number | null
  due_time: string | null // 'HH:MM:SS'
  assigned_to: string | null
  assigned_to_name: string | null
  sop_code: string | null
  window_end: string | null
  source: 'cycle' | 'deviation' | 'manual'
}

export interface WeekDay {
  d: string
  load: number
  has_overdue: boolean
  tasks: WeekTask[]
}

export interface WeekHorizon {
  ok: true
  horizon: 'week'
  no_plan: false
  range: { from: string; to: string }
  context: { phase_name: string; day: number; days_total: number } | null
  burning: BurningItem[]
  days: WeekDay[]
}

export interface MonthMilestone { phase_id: string; name: string; date: string; kind: 'phase_start' }

export interface MonthHorizon {
  ok: true
  horizon: 'month'
  no_plan: false
  range: { from: string; to: string }
  milestones: MonthMilestone[]
  // grid/windows/prep не типизируем — Неделя (F6) их не читает (F7, ARS-283).
  [k: string]: unknown
}

export interface NoPlanHorizon {
  ok: true
  no_plan: true
  horizon: string
}

export type WeekHorizonResult = WeekHorizon | NoPlanHorizon

export async function loadWeekHorizon(orgId: string, farmId: string, anchor?: string): Promise<WeekHorizonResult> {
  const { data, error } = await supabase.rpc('rpc_get_tasks_horizon', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_horizon: 'week',
    p_anchor: anchor ?? localToday(),
  })
  if (error) throw error
  return data as WeekHorizonResult
}

// Только для «пустой недели» (межфазье, §3.1) — ближайшая веха месяца, когда в Неделе нечего показать.
export async function loadNextMilestone(orgId: string, farmId: string, anchor?: string): Promise<MonthMilestone | null> {
  const { data, error } = await supabase.rpc('rpc_get_tasks_horizon', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_horizon: 'month',
    p_anchor: anchor ?? localToday(),
  })
  if (error) throw error
  const month = data as MonthHorizon | NoPlanHorizon
  if (month.no_plan) return null
  const today = anchor ?? localToday()
  return (month as MonthHorizon).milestones.find((m) => m.date >= today) ?? null
}

// «+» ручная задача (slice §3, eng-spec §2.14). Исполнитель не выбираем — нет ростера участников
// (открытый вопрос handoff §12 «раздача помощникам» не решён CEO; поле — когда решится модель).
export async function createFarmTask(
  orgId: string, farmId: string,
  params: { nameRu: string; dueDate: string; dueTime?: string | null },
): Promise<RpcResult | null> {
  const { data, error } = await supabase.rpc('rpc_create_farm_task', {
    p_organization_id: orgId,
    p_farm_id: farmId,
    p_name_ru: params.nameRu,
    p_due_date: params.dueDate,
    p_due_time: params.dueTime ?? null,
    p_category: 'management',
    p_assigned_to: null,
    p_animal_event_id: null,
    p_client_task_id: null,
    p_actor_id: null,
  })
  if (error) throw error
  return data as RpcResult | null
}
